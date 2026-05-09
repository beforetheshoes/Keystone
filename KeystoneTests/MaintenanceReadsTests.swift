import XCTest
import Dependencies
import GRDB
@testable import Keystone

/// DB-backed tests for the maintenance reads helper. Covers
/// derive-on-read semantics for `vehicles.current_mileage` — the value
/// must always reflect the highest event reading even when the stored
/// snapshot is stale or absent. Without this guarantee, the next-due
/// engine computes mileage thresholds against an out-of-date base and
/// every "due in N miles" number is wrong.
final class MaintenanceReadsTests: XCTestCase {

    /// Helper: insert a vehicle + N events with given mileages and dates.
    private func seed(_ db: Database,
                      vehicleID: String,
                      vehicleTitle: String,
                      storedMileage: Int? = nil,
                      storedAsOf: String? = nil,
                      events: [(id: String, mileage: Int?, dateISO: String?)]) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())
        try db.execute(
            sql: """
                INSERT INTO records (id, database_id, title, glyph, tone, created_at, updated_at, sort_index)
                VALUES (?, 'vehicles', ?, 'V', 'iris', ?, ?, 0)
            """,
            arguments: [vehicleID, vehicleTitle, now, now]
        )
        if let storedMileage {
            try db.execute(sql: """
                INSERT INTO property_values (id, record_id, property_id, number_value, created_at, updated_at)
                VALUES (?, ?, 'vehicles.current_mileage', ?, ?, ?)
            """, arguments: ["\(vehicleID).current_mileage", vehicleID, Double(storedMileage), now, now])
        }
        if let storedAsOf {
            try db.execute(sql: """
                INSERT INTO property_values (id, record_id, property_id, date_value, text_value, created_at, updated_at)
                VALUES (?, ?, 'vehicles.current_mileage_as_of', ?, ?, ?, ?)
            """, arguments: ["\(vehicleID).current_mileage_as_of", vehicleID, storedAsOf, storedAsOf, now, now])
        }
        for ev in events {
            try db.execute(sql: """
                INSERT INTO records (id, database_id, title, glyph, tone, created_at, updated_at, sort_index)
                VALUES (?, 'vehicle_maintenance', ?, 'VM', 'iris', ?, ?, 0)
            """, arguments: [ev.id, ev.id, now, now])
            try db.execute(sql: """
                INSERT INTO relations (id, source_record_id, target_record_id, property_id, created_at, updated_at)
                VALUES (?, ?, ?, 'vehicle_maintenance.vehicle', ?, ?)
            """, arguments: ["\(ev.id).vehicle", ev.id, vehicleID, now, now])
            if let m = ev.mileage {
                try db.execute(sql: """
                    INSERT INTO property_values (id, record_id, property_id, number_value, created_at, updated_at)
                    VALUES (?, ?, 'vehicle_maintenance.mileage', ?, ?, ?)
                """, arguments: ["\(ev.id).mileage", ev.id, Double(m), now, now])
            }
            if let d = ev.dateISO {
                try db.execute(sql: """
                    INSERT INTO property_values (id, record_id, property_id, date_value, text_value, created_at, updated_at)
                    VALUES (?, ?, 'vehicle_maintenance.date', ?, ?, ?, ?)
                """, arguments: ["\(ev.id).date", ev.id, d, d, now, now])
            }
        }
    }

    /// The bug that surfaced this fix: a stale stored
    /// `current_mileage` value (set by the import pass at one point in
    /// time and never refreshed) returned 6,393 mi for a Fit that
    /// actually had 145,225 mi worth of recorded service. The reads
    /// helper now derives from MAX(event mileage) and the stale stored
    /// value is overridden whenever events go higher.
    func testCurrentMileageReflectsHighestEventEvenWhenStoredIsStale() throws {
        try withHermeticDB {
            @Dependency(\.defaultDatabase) var database
            try database.write { db in
                try seed(
                    db,
                    vehicleID: "v-fit", vehicleTitle: "Fit",
                    storedMileage: 6_393, storedAsOf: "2016-02-18",
                    events: [
                        ("e1", 6_393, "2016-02-18"),
                        ("e2", 50_000, "2020-01-01"),
                        ("e3", 145_225, "2026-01-15"),
                    ]
                )
            }
            let snaps = try database.read { db in try MaintenanceReads.vehicleSnapshots(db) }
            let fit = try XCTUnwrap(snaps.first(where: { $0.id == "v-fit" }))
            XCTAssertEqual(fit.currentMileage, 145_225,
                           "max event mileage must override a lower stored snapshot")
            // Cleanup
            try database.write { db in
                try db.execute(sql: "DELETE FROM records WHERE id IN ('v-fit', 'e1', 'e2', 'e3')")
            }
        }
    }

    /// User override case: if the user manually set
    /// `current_mileage` higher than any event, that's a deliberate
    /// assertion ("my odometer reads 150k today even though no event
    /// recorded it") and wins over the events.
    func testStoredMileageWinsWhenHigherThanAnyEvent() throws {
        try withHermeticDB {
            @Dependency(\.defaultDatabase) var database
            try database.write { db in
                try seed(
                    db,
                    vehicleID: "v-userset", vehicleTitle: "User Set",
                    storedMileage: 150_000, storedAsOf: "2026-05-01",
                    events: [
                        ("eu1", 100_000, "2025-01-01"),
                    ]
                )
            }
            let snaps = try database.read { db in try MaintenanceReads.vehicleSnapshots(db) }
            let v = try XCTUnwrap(snaps.first(where: { $0.id == "v-userset" }))
            XCTAssertEqual(v.currentMileage, 150_000,
                           "stored value wins when higher than max event")
            try database.write { db in
                try db.execute(sql: "DELETE FROM records WHERE id IN ('v-userset', 'eu1')")
            }
        }
    }

    /// No events at all: fall back to the stored value (or nil).
    func testNoEventsReturnsStoredOrNil() throws {
        try withHermeticDB {
            @Dependency(\.defaultDatabase) var database
            try database.write { db in
                try seed(
                    db,
                    vehicleID: "v-noevents", vehicleTitle: "No Events",
                    storedMileage: 42, storedAsOf: "2026-01-01",
                    events: []
                )
                try seed(
                    db,
                    vehicleID: "v-empty", vehicleTitle: "Empty",
                    storedMileage: nil, storedAsOf: nil,
                    events: []
                )
            }
            let snaps = try database.read { db in try MaintenanceReads.vehicleSnapshots(db) }
            XCTAssertEqual(snaps.first(where: { $0.id == "v-noevents" })?.currentMileage, 42)
            XCTAssertNil(snaps.first(where: { $0.id == "v-empty" })?.currentMileage)
            try database.write { db in
                try db.execute(sql: "DELETE FROM records WHERE id IN ('v-noevents', 'v-empty')")
            }
        }
    }
}
