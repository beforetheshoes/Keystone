import XCTest
@testable import Keystone

final class BookStatusNudgeTests: XCTestCase {

    private func record(_ values: [String: String]) -> RecordRow {
        RecordRow(
            id: "rec1",
            databaseID: "books",
            title: "Test",
            glyph: "T",
            tone: .graphite,
            sortIndex: 0,
            values: values
        )
    }

    func testAdvancesFromToReadOnFirstPageProgress() {
        let r = record([
            "page_count": "300",
            "current_page": "1",
            "started_date": "",
            "finished_date": "",
        ])
        let outcome = BookStatusNudge.computeNudge(record: r, status: "to_read")
        XCTAssertEqual(outcome?.newStatus, "reading")
        XCTAssertTrue(outcome?.stampStartedDate ?? false)
        XCTAssertFalse(outcome?.stampFinishedDate ?? true)
    }

    func testAdvancesFromEmptyStatusOnFirstPageProgress() {
        let r = record([
            "page_count": "300",
            "current_page": "50",
            "started_date": "2026-05-01",  // already set; don't stamp again
        ])
        let outcome = BookStatusNudge.computeNudge(record: r, status: "")
        XCTAssertEqual(outcome?.newStatus, "reading")
        XCTAssertFalse(outcome?.stampStartedDate ?? true)
        XCTAssertFalse(outcome?.stampFinishedDate ?? true)
    }

    func testAdvancesToReadWhenCurrentPageHitsTotal() {
        let r = record([
            "page_count": "300",
            "current_page": "300",
            "started_date": "2026-05-01",
            "finished_date": "",
        ])
        let outcome = BookStatusNudge.computeNudge(record: r, status: "reading")
        XCTAssertEqual(outcome?.newStatus, "read")
        XCTAssertTrue(outcome?.stampFinishedDate ?? false)
    }

    func testReadableOverridesPageCount() {
        // Book "ends" at page 250 even though page_count is 300.
        let r = record([
            "page_count": "300",
            "readable_pages": "250",
            "current_page": "250",
        ])
        let outcome = BookStatusNudge.computeNudge(record: r, status: "reading")
        XCTAssertEqual(outcome?.newStatus, "read")
    }

    func testPercentModeHonored() {
        let r = record([
            "progress_mode": "percent",
            "progress_percent": "100",
        ])
        let outcome = BookStatusNudge.computeNudge(record: r, status: "reading")
        XCTAssertEqual(outcome?.newStatus, "read")
    }

    func testAbandonedStatusIsNeverOverridden() {
        let r = record([
            "page_count": "300",
            "current_page": "300",
        ])
        let outcome = BookStatusNudge.computeNudge(record: r, status: "abandoned")
        XCTAssertNil(outcome)
    }

    func testNoChangeWhenZeroProgressAndReadingStatus() {
        let r = record([
            "page_count": "300",
            "current_page": "0",
        ])
        let outcome = BookStatusNudge.computeNudge(record: r, status: "reading")
        XCTAssertNil(outcome)
    }

    func testNoChangeWithoutTotalPages() {
        let r = record([
            "current_page": "50",
        ])
        let outcome = BookStatusNudge.computeNudge(record: r, status: "to_read")
        XCTAssertNil(outcome)
    }
}
