import XCTest
@testable import Keystone

final class SortGroupEngineTests: XCTestCase {

    // MARK: - Helpers

    private func makeRecord(
        id: String,
        title: String = "Untitled",
        values: [String: String] = [:]
    ) -> RecordRow {
        RecordRow(
            id: id,
            databaseID: "test",
            title: title,
            glyph: "X",
            tone: .graphite,
            sortIndex: 0,
            values: values
        )
    }

    private func makeProperty(
        key: String,
        type: PropertyType,
        configJSON: String = "{}"
    ) -> PropertyRow {
        PropertyRow(
            id: "test.\(key)",
            key: key,
            name: key.capitalized,
            type: type,
            sortIndex: 0,
            configJSON: configJSON
        )
    }

    // MARK: - SortEngine

    func testSortNumberAscending() {
        let prop = makeProperty(key: "rating", type: .number)
        let records = [
            makeRecord(id: "a", values: ["rating": "3"]),
            makeRecord(id: "b", values: ["rating": "1"]),
            makeRecord(id: "c", values: ["rating": "5"]),
        ]
        let sorted = SortEngine.apply(records, key: "rating", ascending: true, properties: [prop])
        XCTAssertEqual(sorted.map(\.id), ["b", "a", "c"])
    }

    func testSortNumberDescending() {
        let prop = makeProperty(key: "rating", type: .number)
        let records = [
            makeRecord(id: "a", values: ["rating": "3"]),
            makeRecord(id: "b", values: ["rating": "1"]),
            makeRecord(id: "c", values: ["rating": "5"]),
        ]
        let sorted = SortEngine.apply(records, key: "rating", ascending: false, properties: [prop])
        XCTAssertEqual(sorted.map(\.id), ["c", "a", "b"])
    }

    func testSortByTitleCaseInsensitive() {
        let records = [
            makeRecord(id: "a", title: "banana"),
            makeRecord(id: "b", title: "Apple"),
            makeRecord(id: "c", title: "cherry"),
        ]
        let sorted = SortEngine.apply(records, key: "title", ascending: true, properties: [])
        XCTAssertEqual(sorted.map(\.id), ["b", "a", "c"])
    }

    func testSortBySelectFollowsOptionOrder() {
        let prop = makeProperty(
            key: "status",
            type: .select,
            configJSON: #"{"options":["to_read","reading","read","abandoned"]}"#
        )
        let records = [
            makeRecord(id: "a", values: ["status": "read"]),
            makeRecord(id: "b", values: ["status": "to_read"]),
            makeRecord(id: "c", values: ["status": "reading"]),
        ]
        let sorted = SortEngine.apply(records, key: "status", ascending: true, properties: [prop])
        XCTAssertEqual(sorted.map(\.id), ["b", "c", "a"])
    }

    func testSortPutsEmptyValuesLast() {
        let prop = makeProperty(key: "rating", type: .number)
        let records = [
            makeRecord(id: "a", values: ["rating": "5"]),
            makeRecord(id: "b", values: [:]),
            makeRecord(id: "c", values: ["rating": "3"]),
        ]
        let sorted = SortEngine.apply(records, key: "rating", ascending: true, properties: [prop])
        XCTAssertEqual(sorted.first?.id, "c")
        XCTAssertEqual(sorted.last?.id, "b")
    }

    // MARK: - GroupEngine

    func testGroupReturnsSingleBucketWhenKeyNil() {
        let records = [makeRecord(id: "a"), makeRecord(id: "b")]
        let groups = GroupEngine.group(records, key: nil, properties: [])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].rows.count, 2)
    }

    func testGroupBySelectUsesOptionOrder() {
        let prop = makeProperty(
            key: "status",
            type: .select,
            configJSON: #"{"options":["to_read","reading","read"]}"#
        )
        let records = [
            makeRecord(id: "a", values: ["status": "read"]),
            makeRecord(id: "b", values: ["status": "to_read"]),
            makeRecord(id: "c", values: ["status": "reading"]),
            makeRecord(id: "d", values: ["status": ""]),
        ]
        let groups = GroupEngine.group(records, key: "status", properties: [prop])
        // Select-type bucket labels go through `SelectOptionDisplay.format`
        // for the section-header display, turning the raw `"to_read"`
        // option key into `"To read"`. Test against the formatted label
        // because that's what users see.
        XCTAssertEqual(groups.map(\.label), ["To read", "Reading", "Read", "—"])
        XCTAssertEqual(groups.last?.rows.map(\.id), ["d"])
    }

    func testGroupByMultiSelectFanoutMembers() {
        let prop = makeProperty(key: "tags", type: .multiSelect)
        let records = [
            makeRecord(id: "a", values: ["tags": "fiction|mystery"]),
            makeRecord(id: "b", values: ["tags": "mystery"]),
            makeRecord(id: "c", values: ["tags": ""]),
        ]
        let groups = GroupEngine.group(records, key: "tags", properties: [prop])
        // multiSelect labels go through `SelectOptionDisplay.format`, so
        // the bucket headers read as "Fiction" / "Mystery" in the UI.
        // Look up by the raw bucket key, not the display label.
        let fictionRows = groups.first { $0.key == "fiction" }?.rows.map(\.id) ?? []
        let mysteryRows = groups.first { $0.key == "mystery" }?.rows.map(\.id) ?? []
        XCTAssertEqual(fictionRows, ["a"])
        XCTAssertEqual(mysteryRows, ["a", "b"])
        XCTAssertEqual(groups.last?.label, "—")
    }
}
