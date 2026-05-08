import XCTest
import Dependencies
import GRDB
@preconcurrency import SQLiteData
@testable import Keystone

final class DateTZTests: XCTestCase {
    private func withDB<T>(_ body: () throws -> T) rethrows -> T {
        try withDependencies { values in
            do {
                try values.bootstrapKeystoneDatabase(configureSyncEngine: false)
            } catch {
                XCTFail("Bootstrap failed: \(error)")
            }
        } operation: {
            try body()
        }
    }

    // MARK: - Codec

    func testEncodeParseTZRoundTripTimed() throws {
        // 2026-04-28 12:00:00 UTC, displayed as 14:00 in Paris (CEST).
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let utc = try XCTUnwrap(formatter.date(from: "2026-04-28T12:00:00Z"))

        let original = DateTZValue(
            date: utc,
            timezone: TimeZone(identifier: "Europe/Paris")!,
            isAllDay: false
        )
        let encoded = DateValueCodec.encodeTZ(original)
        XCTAssertEqual(encoded, "2026-04-28T12:00:00Z|Europe/Paris")

        let parsed = try XCTUnwrap(DateValueCodec.parseTZ(encoded))
        XCTAssertEqual(parsed.date, original.date)
        XCTAssertEqual(parsed.timezone.identifier, "Europe/Paris")
        XCTAssertFalse(parsed.isAllDay)
    }

    func testEncodeParseTZRoundTripAllDay() throws {
        // 2026-05-08 in Asia/Tokyo, all-day. The Date instance is the
        // UTC instant of midnight Tokyo time.
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let date = calendar.date(from: DateComponents(year: 2026, month: 5, day: 8))!
        let original = DateTZValue(date: date, timezone: tz, isAllDay: true)

        let encoded = DateValueCodec.encodeTZ(original)
        XCTAssertEqual(encoded, "2026-05-08|Asia/Tokyo")

        let parsed = try XCTUnwrap(DateValueCodec.parseTZ(encoded))
        XCTAssertEqual(parsed.timezone.identifier, "Asia/Tokyo")
        XCTAssertTrue(parsed.isAllDay)
    }

    func testParseTZRejectsMalformed() {
        XCTAssertNil(DateValueCodec.parseTZ(""))
        XCTAssertNil(DateValueCodec.parseTZ("2026-05-08"))               // no pipe
        XCTAssertNil(DateValueCodec.parseTZ("|Europe/Paris"))            // empty date
        XCTAssertNil(DateValueCodec.parseTZ("2026-05-08|"))              // empty tz
        XCTAssertNil(DateValueCodec.parseTZ("2026-05-08|Not/A_Real_TZ")) // unknown tz
        XCTAssertNil(DateValueCodec.parseTZ("not a date|Europe/Paris"))  // bad date
    }

    func testParseTZRawForwardsBoth() throws {
        let split = try XCTUnwrap(DateValueCodec.parseTZRaw("2026-04-28T12:00:00Z|Europe/Paris"))
        XCTAssertEqual(split.dateString, "2026-04-28T12:00:00Z")
        XCTAssertEqual(split.tz, "Europe/Paris")
    }

    // MARK: - Migration

    func testV23FlipsTravelDateProperties() throws {
        try withDB {
            @Dependency(\.defaultDatabase) var database
            try database.read { db in
                let activitiesStart: String? = try String.fetchOne(
                    db,
                    sql: "SELECT type FROM properties WHERE id = 'activities.start'"
                )
                XCTAssertEqual(activitiesStart, "date_tz",
                               "v23 (or v22 with the type baked in) should leave activities.start as date_tz")

                let lodgingCheckOut: String? = try String.fetchOne(
                    db,
                    sql: "SELECT type FROM properties WHERE id = 'lodging.check_out'"
                )
                XCTAssertEqual(lodgingCheckOut, "date_tz")

                // Trip windows stay whole-day.
                let tripStart: String? = try String.fetchOne(
                    db,
                    sql: "SELECT type FROM properties WHERE id = 'trips.start_date'"
                )
                XCTAssertEqual(tripStart, "date")
            }
        }
    }

    // MARK: - Storage round-trip

    func testWriteSplitsCompoundIntoColumns() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue
            let act = try dbClient.createRecord("activities", "Boat tour")
            defer { try? dbClient.deleteRecord(act.id) }

            try dbClient.updatePropertyValue(act.id, "start", "2026-05-08T12:00:00Z|Europe/Paris")

            @Dependency(\.defaultDatabase) var database
            try database.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT text_value, date_value
                        FROM property_values
                        WHERE record_id = ? AND property_id = 'activities.start'
                    """,
                    arguments: [act.id]
                )
                XCTAssertEqual(row?["text_value"], "Europe/Paris")
                XCTAssertEqual(row?["date_value"], "2026-05-08T12:00:00Z")
            }
        }
    }

    func testReadComposesCompound() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue
            let act = try dbClient.createRecord("activities", "Boat tour")
            defer { try? dbClient.deleteRecord(act.id) }

            let stored = "2026-05-08T12:00:00Z|Europe/Paris"
            try dbClient.updatePropertyValue(act.id, "start", stored)

            let after = try dbClient.record(act.id)
            XCTAssertEqual(after?.values["start"], stored)
        }
    }

    func testReadAllDayCompound() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue
            let lodging = try dbClient.createRecord("lodging", "Stay")
            defer { try? dbClient.deleteRecord(lodging.id) }

            try dbClient.updatePropertyValue(lodging.id, "check_in", "2026-05-08|Asia/Tokyo")

            let after = try dbClient.record(lodging.id)
            XCTAssertEqual(after?.values["check_in"], "2026-05-08|Asia/Tokyo")
            XCTAssertEqual(DateValueCodec.parseTZ(after?.values["check_in"] ?? "")?.isAllDay, true)
        }
    }
}
