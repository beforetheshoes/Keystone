import XCTest
@testable import Keystone

final class RestaurantHoursSummaryTests: XCTestCase {

    /// Mon Jan 5 2026 14:00 — keeps the "today" weekday stable for
    /// the assertions regardless of when the test runs.
    private let monday: Date = {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 1; comps.day = 5
        comps.hour = 14; comps.minute = 0
        return Calendar.current.date(from: comps)!
    }()

    private let saturday: Date = {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 1; comps.day = 10
        comps.hour = 14; comps.minute = 0
        return Calendar.current.date(from: comps)!
    }()

    // MARK: - todayShort

    func testTodayShortPicksTodayWindow() {
        let raw = "Mon 09:00–17:00, Tue 10:00–18:00"
        let result = RestaurantHoursSummary.todayShort(raw, now: monday)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("AM") || result!.contains("09"))
    }

    func testTodayShortClosedDay() {
        let raw = "Tue–Fri 09:00–17:00"
        XCTAssertEqual(
            RestaurantHoursSummary.todayShort(raw, now: monday),
            "Closed today"
        )
    }

    func testTodayShort24Hour() {
        let raw = "Mon–Sun open 24h"
        XCTAssertEqual(
            RestaurantHoursSummary.todayShort(raw, now: monday),
            "Open 24 hours"
        )
    }

    // MARK: - todayShortPadded

    func testPaddedSingleWindow() {
        // Mon at 14:00 with 3 PM – 8 PM Monday hours.
        let raw = "Mon 15:00–20:00"
        let padded = RestaurantHoursSummary.todayShortPadded(raw, now: monday)
        XCTAssertNotNil(padded)
        // Result should contain the open and close times separated by " – ".
        XCTAssertTrue(padded!.contains(" – "))
    }

    func testPaddedShorterOpenIsLeadingFigureSpaced() {
        // "3:00 PM" (7 chars) gets 1 leading figure-space to reach 8.
        // "11:00 AM" (8 chars) gets none.
        let short = RestaurantHoursSummary.todayShortPadded(
            "Mon 15:00–20:00", now: monday
        )
        let long = RestaurantHoursSummary.todayShortPadded(
            "Sat 11:00–14:00", now: saturday
        )
        XCTAssertNotNil(short)
        XCTAssertNotNil(long)
        // The slice before " – " should be the same length on both
        // when measured in characters — that's the property that
        // gives the table column its dash-aligned look.
        let shortPrefix = short!.components(separatedBy: " – ").first ?? ""
        let longPrefix = long!.components(separatedBy: " – ").first ?? ""
        XCTAssertEqual(shortPrefix.count, longPrefix.count)
        // The shorter one carries at least one figure-space.
        XCTAssertTrue(shortPrefix.contains("\u{2007}"))
        XCTAssertFalse(longPrefix.contains("\u{2007}"))
    }

    func testPaddedClosedSentinelPassesThrough() {
        // The sentinel has no dash to align — return verbatim.
        let result = RestaurantHoursSummary.todayShortPadded(
            "Tue–Fri 09:00–17:00", now: monday
        )
        XCTAssertEqual(result, "Closed today")
    }

    func testTodayShortFallsBackToOSMGrammar() {
        // Records enriched by an older build can carry raw OSM
        // grammar in `hours`. The display layer should translate it
        // on the fly so the user doesn't see `Mo 09:00-15:00, Tu-Su
        // 11:00-22:00` literally in the column.
        let raw = "Mo 09:00-15:00; Tu-Su 11:00-22:00"
        let result = RestaurantHoursSummary.todayShort(raw, now: monday)
        XCTAssertNotNil(result)
        // Monday's window from the OSM-grammar input.
        XCTAssertTrue(result?.contains(":") ?? false)
        XCTAssertNotEqual(result, raw)  // not just passing through
    }

    func testPaddedMultiWindowPassesThrough() {
        // Lunch + dinner has a comma; we don't try to pad multi-window
        // strings because there's no single dash to anchor on.
        let raw = "Mon 11:00–14:00, 17:00–22:00"
        let padded = RestaurantHoursSummary.todayShortPadded(raw, now: monday)
        XCTAssertNotNil(padded)
        XCTAssertFalse(padded!.contains("\u{2007}"))
        XCTAssertTrue(padded!.contains(","))
    }
}
