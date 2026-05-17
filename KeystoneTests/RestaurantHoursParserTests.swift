import XCTest
@testable import Keystone

final class RestaurantHoursParserTests: XCTestCase {

    func testSingleWeekdayRangeExpands() throws {
        let parsed = try XCTUnwrap(RestaurantHoursParser.parse("Mon–Fri 11:00–22:00"))
        XCTAssertEqual(parsed.count, 7)
        XCTAssertEqual(parsed[0].label, "11:00–22:00")  // Mon
        XCTAssertEqual(parsed[4].label, "11:00–22:00")  // Fri
        XCTAssertEqual(parsed[5].label, "Closed")       // Sat
        XCTAssertEqual(parsed[6].label, "Closed")       // Sun
    }

    func testMultiSegmentWithDifferentRanges() throws {
        let parsed = try XCTUnwrap(
            RestaurantHoursParser.parse("Mon–Tue 17:00–21:00, Wed–Fri 17:00–22:00, Sat 16:00–22:00")
        )
        XCTAssertEqual(parsed[0].label, "17:00–21:00")  // Mon
        XCTAssertEqual(parsed[1].label, "17:00–21:00")  // Tue
        XCTAssertEqual(parsed[2].label, "17:00–22:00")  // Wed
        XCTAssertEqual(parsed[3].label, "17:00–22:00")  // Thu
        XCTAssertEqual(parsed[4].label, "17:00–22:00")  // Fri
        XCTAssertEqual(parsed[5].label, "16:00–22:00")  // Sat
        XCTAssertEqual(parsed[6].label, "Closed")       // Sun
    }

    func testTwentyFourSevenLabelExpands() throws {
        let parsed = try XCTUnwrap(RestaurantHoursParser.parse("Mon–Sun open 24h"))
        for day in parsed {
            XCTAssertEqual(day.label, "open 24h")
        }
    }

    func testAllClosedSentinel() throws {
        let parsed = try XCTUnwrap(RestaurantHoursParser.parse("Closed"))
        XCTAssertEqual(parsed.count, 7)
        XCTAssertTrue(parsed.allSatisfy { $0.label == "Closed" })
    }

    func testHyphenFallbackForHandTypedInput() throws {
        // User pastes "Mon-Fri 11:00-22:00" with hyphens — we still
        // accept it as long as the structure is otherwise our format.
        let parsed = try XCTUnwrap(RestaurantHoursParser.parse("Mon-Fri 11:00-22:00"))
        XCTAssertEqual(parsed[0].label, "11:00-22:00")
        XCTAssertEqual(parsed[5].label, "Closed")
    }

    func testSingleDayKeepsOtherDaysClosed() throws {
        let parsed = try XCTUnwrap(RestaurantHoursParser.parse("Fri 17:00–22:00"))
        XCTAssertEqual(parsed[4].label, "17:00–22:00")
        XCTAssertTrue(parsed.indices.filter { $0 != 4 }.allSatisfy { parsed[$0].label == "Closed" })
    }

    func testFreeFormTextReturnsNil() {
        // Hand-typed values that don't match the format fall back to
        // raw-text display upstream. Parser signals this with nil.
        XCTAssertNil(RestaurantHoursParser.parse("call ahead"))
        XCTAssertNil(RestaurantHoursParser.parse(""))
        XCTAssertNil(RestaurantHoursParser.parse("Mon–Fri"))  // no time portion
    }

    func testDuplicateSegmentsFirstWins() throws {
        // Defensive: if upstream ever emits overlapping segments we
        // keep the first label rather than crashing.
        let parsed = try XCTUnwrap(
            RestaurantHoursParser.parse("Mon 11:00–22:00, Mon 09:00–14:00")
        )
        XCTAssertEqual(parsed[0].label, "11:00–22:00")
    }

    // MARK: - Multi-window (continuation chunks)

    func testMultiWindowContinuationAppendsToPreviousGroup() throws {
        let parsed = try XCTUnwrap(
            RestaurantHoursParser.parse("Mon–Fri 11:00–14:00, 17:00–22:00, Sat–Sun 09:00–23:00")
        )
        XCTAssertEqual(parsed[0].windows, ["11:00–14:00", "17:00–22:00"])
        XCTAssertEqual(parsed[4].windows, ["11:00–14:00", "17:00–22:00"])
        XCTAssertEqual(parsed[5].windows, ["09:00–23:00"])
        XCTAssertEqual(parsed[6].windows, ["09:00–23:00"])
    }

    func testSingleDayMultiWindow() throws {
        let parsed = try XCTUnwrap(
            RestaurantHoursParser.parse("Fri 11:00–14:00, 17:00–22:00")
        )
        XCTAssertEqual(parsed[4].windows, ["11:00–14:00", "17:00–22:00"])
        XCTAssertTrue(parsed.indices.filter { $0 != 4 }.allSatisfy { parsed[$0].windows.isEmpty })
    }

    func testContinuationBeforeAnyDayGroupRejected() {
        // A digit-leading first segment has no day-group to attach
        // to — bail out rather than silently dropping the value.
        XCTAssertNil(RestaurantHoursParser.parse("11:00–14:00, Mon 11:00–14:00"))
    }
}
