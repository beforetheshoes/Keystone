import XCTest
@testable import Keystone

final class RestaurantHoursModelTests: XCTestCase {

    // MARK: - parse → serialize round-trip

    func testEmptyInputProducesEmptyModel() throws {
        let model = try XCTUnwrap(RestaurantHoursModel.parse(""))
        XCTAssertEqual(model.days.count, 7)
        XCTAssertTrue(model.days.allSatisfy { $0.mode == .closed })
        XCTAssertEqual(model.serialize(), "Closed")
    }

    func testSingleWindowRoundTrips() throws {
        let raw = "Mon–Fri 11:00–22:00"
        let model = try XCTUnwrap(RestaurantHoursModel.parse(raw))
        XCTAssertEqual(model.days[0].mode, .scheduled)
        XCTAssertEqual(model.days[0].windows.count, 1)
        XCTAssertEqual(model.days[0].windows[0].openMinutes, 11 * 60)
        XCTAssertEqual(model.days[0].windows[0].closeMinutes, 22 * 60)
        XCTAssertEqual(model.days[5].mode, .closed)
        XCTAssertEqual(model.serialize(), raw)
    }

    func testMultiWindowRoundTrips() throws {
        // Mon–Fri lunch + dinner split, weekend single window.
        let raw = "Mon–Fri 11:00–14:00, 17:00–22:00, Sat–Sun 09:00–23:00"
        let model = try XCTUnwrap(RestaurantHoursModel.parse(raw))
        XCTAssertEqual(model.days[0].windows.count, 2)
        XCTAssertEqual(model.days[0].windows[0].openMinutes, 11 * 60)
        XCTAssertEqual(model.days[0].windows[0].closeMinutes, 14 * 60)
        XCTAssertEqual(model.days[0].windows[1].openMinutes, 17 * 60)
        XCTAssertEqual(model.days[0].windows[1].closeMinutes, 22 * 60)
        XCTAssertEqual(model.days[5].windows.count, 1)
        XCTAssertEqual(model.serialize(), raw)
    }

    func testOpen24hRoundTrips() throws {
        let raw = "Mon–Sun open 24h"
        let model = try XCTUnwrap(RestaurantHoursModel.parse(raw))
        XCTAssertTrue(model.days.allSatisfy { $0.mode == .open24h })
        XCTAssertEqual(model.serialize(), raw)
    }

    func testAllClosedSentinelRoundTrips() throws {
        let model = try XCTUnwrap(RestaurantHoursModel.parse("Closed"))
        XCTAssertTrue(model.days.allSatisfy { $0.mode == .closed })
        XCTAssertEqual(model.serialize(), "Closed")
    }

    func testCrossMidnightWindowRoundTrips() throws {
        // Fri bar hours: 6 PM to 2 AM Saturday.
        let raw = "Fri 18:00–02:00"
        let model = try XCTUnwrap(RestaurantHoursModel.parse(raw))
        XCTAssertEqual(model.days[4].windows.count, 1)
        XCTAssertTrue(model.days[4].windows[0].crossesMidnight)
        XCTAssertEqual(model.serialize(), raw)
    }

    func testMixedModesRoundTrip() throws {
        var model = RestaurantHoursModel.empty
        // Sun 24h, Mon closed, Tue–Wed lunch+dinner, Thu single window.
        model.days[6].mode = .open24h
        model.days[1].mode = .scheduled
        model.days[1].windows = [.init(openMinutes: 11 * 60, closeMinutes: 14 * 60),
                                 .init(openMinutes: 17 * 60, closeMinutes: 22 * 60)]
        model.days[2].mode = .scheduled
        model.days[2].windows = [.init(openMinutes: 11 * 60, closeMinutes: 14 * 60),
                                 .init(openMinutes: 17 * 60, closeMinutes: 22 * 60)]
        model.days[3].mode = .scheduled
        model.days[3].windows = [.init(openMinutes: 17 * 60, closeMinutes: 22 * 60)]
        let serialized = model.serialize()
        // Round-trip — parse should re-produce a structurally equal
        // model (window identities differ, only the values matter).
        let reparsed = try XCTUnwrap(RestaurantHoursModel.parse(serialized))
        XCTAssertEqual(reparsed.days[1].mode, .scheduled)
        XCTAssertEqual(reparsed.days[1].windows.count, 2)
        XCTAssertEqual(reparsed.days[2].windows.count, 2)
        XCTAssertEqual(reparsed.days[3].windows.count, 1)
        XCTAssertEqual(reparsed.days[6].mode, .open24h)
        XCTAssertEqual(reparsed.days[0].mode, .closed)
    }

    func testUnparseableInputReturnsNil() {
        XCTAssertNil(RestaurantHoursModel.parse("call ahead"))
        XCTAssertNil(RestaurantHoursModel.parse(", , ,"))
    }

    // MARK: - OSM-grammar fallback

    /// Records enriched via Overpass can land in the DB with raw OSM
    /// grammar in `hours`. The editor's parser falls back to the OSM
    /// translator so opening such a record presents the user with a
    /// fully-populated structured editor instead of an empty one.
    func testParseFallsBackToOSMGrammar() throws {
        // The exact real-world string from a ChowNow-style menu
        // platform: every distinct day-time pair separated by `,`.
        let raw = """
        Mo 09:00-15:00, Mo 17:00-19:00, Tu 09:00-15:00, Tu 17:00-19:00, \
        We 09:00-15:00, We 17:00-19:00, Th 09:00-15:00, Th 17:00-19:00, \
        Fr 09:00-15:00, Fr 17:00-19:00, Sa 09:00-15:00, Sa 17:00-19:00, \
        Su 09:00-15:00, Su 17:00-19:00
        """
        let model = try XCTUnwrap(RestaurantHoursModel.parse(raw))
        // Every day should be scheduled with two windows.
        for day in model.days {
            XCTAssertEqual(day.mode, .scheduled, "day \(day.dayIndex) should be scheduled")
            XCTAssertEqual(day.windows.count, 2, "day \(day.dayIndex) should have lunch + dinner")
            XCTAssertEqual(day.windows[0].openMinutes, 9 * 60)
            XCTAssertEqual(day.windows[0].closeMinutes, 15 * 60)
            XCTAssertEqual(day.windows[1].openMinutes, 17 * 60)
            XCTAssertEqual(day.windows[1].closeMinutes, 19 * 60)
        }
        // Serializing the parsed model produces our canonical compact
        // form — what the editor's `loadFromBindingIfNeeded` writes
        // back to clean up the storage.
        XCTAssertEqual(model.serialize(), "Mon–Sun 09:00–15:00, 17:00–19:00")
    }

    // MARK: - Bulk operations

    func testApplyDayCopiesModeAndWindows() {
        var model = RestaurantHoursModel.empty
        model.days[0].mode = .scheduled
        model.days[0].windows = [.init(openMinutes: 11 * 60, closeMinutes: 22 * 60)]
        model.applyDay(at: 0, to: RestaurantHoursModel.weekdayIndexes)
        for i in 1...4 {
            XCTAssertEqual(model.days[i].mode, .scheduled)
            XCTAssertEqual(model.days[i].windows.count, 1)
            XCTAssertEqual(model.days[i].windows[0].openMinutes, 11 * 60)
            XCTAssertEqual(model.days[i].windows[0].closeMinutes, 22 * 60)
        }
        // Weekend untouched.
        XCTAssertEqual(model.days[5].mode, .closed)
        XCTAssertEqual(model.days[6].mode, .closed)
    }

    func testApplyDayWindowsGetFreshIdentities() {
        var model = RestaurantHoursModel.empty
        model.days[0].mode = .scheduled
        model.days[0].windows = [.init(openMinutes: 9 * 60, closeMinutes: 17 * 60)]
        let sourceID = model.days[0].windows[0].id
        model.applyDay(at: 0, to: [1])
        XCTAssertNotEqual(model.days[1].windows[0].id, sourceID,
                          "Each copied window should get a fresh UUID so SwiftUI ForEach IDs stay unique")
    }

    func testApplyPresetSetsExactWindows() {
        var model = RestaurantHoursModel.empty
        let template: [RestaurantHoursModel.TimeWindow] = [
            .init(openMinutes: 9 * 60, closeMinutes: 17 * 60)
        ]
        model.applyPreset(mode: .scheduled, windows: template, to: RestaurantHoursModel.weekdayIndexes)
        for i in 0...4 {
            XCTAssertEqual(model.days[i].mode, .scheduled)
            XCTAssertEqual(model.days[i].windows.count, 1)
            XCTAssertEqual(model.days[i].windows[0].openMinutes, 9 * 60)
        }
        XCTAssertTrue(model.days[5...].allSatisfy { $0.mode == .closed })
    }

    func testApplyPresetClosedDiscardsWindows() {
        var model = RestaurantHoursModel.empty
        model.days[0].mode = .scheduled
        model.days[0].windows = [.init(openMinutes: 9 * 60, closeMinutes: 17 * 60)]
        model.applyPreset(mode: .closed, windows: [], to: [0])
        XCTAssertEqual(model.days[0].mode, .closed)
        XCTAssertEqual(model.days[0].windows, [])
    }
}
