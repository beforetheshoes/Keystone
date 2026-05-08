import XCTest
@testable import Keystone

final class CalendarTests: XCTestCase {
    // MARK: - CalendarLayout

    func testMonthGridIs42Days() {
        let may = makeDate(year: 2026, month: 5, day: 15)
        let grid = CalendarLayout.monthGrid(for: may)
        XCTAssertEqual(grid.count, 42)
    }

    func testMonthGridStartsOnFirstWeekday() {
        let may = makeDate(year: 2026, month: 5, day: 15)
        let grid = CalendarLayout.monthGrid(for: may)
        let weekday = Calendar.current.component(.weekday, from: grid[0])
        XCTAssertEqual(weekday, Calendar.current.firstWeekday)
    }

    func testWeekIs7Days() {
        let day = makeDate(year: 2026, month: 5, day: 8)  // Friday
        let week = CalendarLayout.week(containing: day)
        XCTAssertEqual(week.count, 7)
        XCTAssertTrue(week.contains { Calendar.current.isDate($0, inSameDayAs: day) })
    }

    func testStepMonthCrossesMonthBoundary() {
        let may = makeDate(year: 2026, month: 5, day: 31)
        let next = CalendarLayout.step(may, by: 1, mode: .month)
        XCTAssertEqual(Calendar.current.component(.month, from: next), 6)
    }

    func testStepDayDoesntDriftOnDST() {
        // Spring-forward in PT: 2026-03-08 02:00 → 03:00.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let mar7 = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12))!
        let mar8 = CalendarLayout.step(mar7, by: 1, mode: .day, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: mar8), 8)
    }

    // MARK: - CalendarEventBuilder

    func testPairedEndKeyForStart() {
        let start = makeProp(key: "start", type: .dateTZ)
        let end = makeProp(key: "end", type: .dateTZ)
        let other = makeProp(key: "notes", type: .text)
        XCTAssertEqual(CalendarEventBuilder.pairedEndKey(for: start, in: [start, end, other]), "end")
    }

    func testPairedEndKeyForCheckIn() {
        let cin = makeProp(key: "check_in", type: .dateTZ)
        let cout = makeProp(key: "check_out", type: .dateTZ)
        XCTAssertEqual(CalendarEventBuilder.pairedEndKey(for: cin, in: [cin, cout]), "check_out")
    }

    func testPairedEndKeyRefusesCrossType() {
        let start = makeProp(key: "start", type: .dateTZ)
        let end = makeProp(key: "end", type: .date)  // type mismatch
        XCTAssertNil(CalendarEventBuilder.pairedEndKey(for: start, in: [start, end]))
    }

    func testPairedEndKeyAbsentByDefault() {
        let when = makeProp(key: "when", type: .date)
        XCTAssertNil(CalendarEventBuilder.pairedEndKey(for: when, in: [when]))
    }

    func testEventsBuildsRangeWhenBothEndpointsPresent() {
        let start = makeProp(key: "start", type: .dateTZ)
        let end = makeProp(key: "end", type: .dateTZ)
        let record = makeRecord(
            id: "act-1",
            title: "Boat tour",
            values: [
                "start": "2026-05-08T13:00:00Z|Europe/Paris",
                "end":   "2026-05-08T17:00:00Z|Europe/Paris",
            ]
        )
        let events = CalendarEventBuilder.events(from: [record], anchor: start, in: [start, end])
        XCTAssertEqual(events.count, 1)
        XCTAssertNotNil(events[0].end)
        XCTAssertEqual(events[0].timezone.identifier, "Europe/Paris")
    }

    func testEventsBuildsSingleAnchorWhenEndMissing() {
        let when = makeProp(key: "when", type: .date)
        let record = makeRecord(id: "ev-1", title: "Birthday", values: ["when": "1989-03-14"])
        let events = CalendarEventBuilder.events(from: [record], anchor: when, in: [when])
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events[0].end)
    }

    func testEventLandsOnEventLocalDay() {
        let start = makeProp(key: "start", type: .dateTZ)
        // 23:00 May 8 Paris = 21:00 May 8 UTC = 14:00 May 8 PDT — same
        // calendar day across all three. Test the Tokyo case: 01:00
        // May 8 Tokyo = 16:00 May 7 UTC = 09:00 May 7 PDT — Tokyo day
        // is May 8, viewer day (PDT) is May 7. Calendar should place
        // on May 8.
        let record = makeRecord(
            id: "act-tok",
            title: "Early breakfast",
            values: ["start": "2026-05-07T16:00:00Z|Asia/Tokyo"]  // 01:00 May 8 Tokyo
        )
        let events = CalendarEventBuilder.events(from: [record], anchor: start, in: [start])
        let event = events[0]
        let may8Tokyo = makeDate(year: 2026, month: 5, day: 8)
        let may7Tokyo = makeDate(year: 2026, month: 5, day: 7)
        XCTAssertTrue(CalendarEventBuilder.event(event, intersects: may8Tokyo))
        XCTAssertFalse(CalendarEventBuilder.event(event, intersects: may7Tokyo))
    }

    // MARK: - Helpers

    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func makeProp(key: String, type: PropertyType) -> PropertyRow {
        PropertyRow(id: "test.\(key)", key: key, name: key, type: type, sortIndex: 0, configJSON: "{}")
    }

    private func makeRecord(id: String, title: String, values: [String: String]) -> RecordRow {
        RecordRow(
            id: id,
            databaseID: "test",
            title: title,
            glyph: "T",
            tone: .cerulean,
            sortIndex: 0,
            values: values,
            relationTargets: [:],
            coverAssetID: nil,
            coverRelativePath: nil
        )
    }
}
