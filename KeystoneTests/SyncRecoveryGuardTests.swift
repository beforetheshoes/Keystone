import XCTest
import Dependencies
import GRDB
@testable import Keystone

/// Coverage for `SyncRecoveryGuard`:
///
///   1. `takeSnapshot` groups records by `database_id`, ignoring
///      soft-deleted rows.
///   2. `recoverIfNeeded` reports zero loss when nothing changed.
///   3. `recoverIfNeeded` writes one `items_lost` row per missing record
///      after a sync cycle, with `record_id` populated.
///   4. New records that didn't exist at snapshot time are NOT logged
///      (downstream sync arrivals are normal traffic, not a signal).
final class SyncRecoveryGuardTests: XCTestCase {

    /// Insert a record into a database that the seed has already
    /// created (`books` is always present after migration). Returns the
    /// new record ID. We bypass `DBWrites.createRecord` so the test
    /// exercises only the guard's read/diff logic, not the broader
    /// write pipeline.
    @discardableResult
    private func insertRecord(_ db: Database, dbID: String, title: String) throws -> String {
        let id = UUID().uuidString
        let now = AppDatabase.isoFormatter.string(from: Date())
        try db.execute(
            sql: """
                INSERT INTO records (
                    id, database_id, title, glyph, tone, sort_index,
                    created_at, updated_at
                ) VALUES (?, ?, ?, '', 'graphite', 0.0, ?, ?)
            """,
            arguments: [id, dbID, title, now, now]
        )
        return id
    }

    private func deleteRecord(_ db: Database, id: String) throws {
        try db.execute(
            sql: "DELETE FROM records WHERE id = ?",
            arguments: [id]
        )
    }

    func testSnapshotGroupsByDatabaseAndIgnoresSoftDeletes() throws {
        try withHermeticDB {
            @Dependency(\.defaultDatabase) var database
            let bookID  = try database.write { try insertRecord($0, dbID: "books", title: "B1") }
            let movieID = try database.write { try insertRecord($0, dbID: "movies", title: "M1") }
            // Soft-delete a row — guard should ignore it.
            let ghostID = try database.write { try insertRecord($0, dbID: "books", title: "Ghost") }
            try database.write { db in
                try db.execute(
                    sql: "UPDATE records SET deleted_at = ? WHERE id = ?",
                    arguments: ["2026-01-01T00:00:00.000Z", ghostID]
                )
            }

            let snap = try SyncRecoveryGuard.takeSnapshot()
            XCTAssertTrue(snap.idsByDatabase["books"]?.contains(bookID) ?? false)
            XCTAssertTrue(snap.idsByDatabase["movies"]?.contains(movieID) ?? false)
            XCTAssertFalse(snap.idsByDatabase["books"]?.contains(ghostID) ?? false)
        }
    }

    func testRecoverIfNeededReportsZeroLossWhenStable() throws {
        try withHermeticDB {
            @Dependency(\.defaultDatabase) var database
            _ = try database.write { try insertRecord($0, dbID: "books", title: "B1") }
            let snap = try SyncRecoveryGuard.takeSnapshot()
            let lost = try SyncRecoveryGuard.recoverIfNeeded(snapshot: snap)
            XCTAssertEqual(lost, 0)
            XCTAssertTrue(try SyncEventLogger.recentEvents(limit: 50).isEmpty)
        }
    }

    func testRecoverIfNeededLogsItemsLostPerMissingRecord() throws {
        try withHermeticDB {
            @Dependency(\.defaultDatabase) var database
            let id1 = try database.write { try insertRecord($0, dbID: "books", title: "B1") }
            let id2 = try database.write { try insertRecord($0, dbID: "books", title: "B2") }
            let snap = try SyncRecoveryGuard.takeSnapshot()

            // Simulate "the sync cycle dropped these rows."
            try database.write { db in
                try deleteRecord(db, id: id1)
                try deleteRecord(db, id: id2)
            }

            let lost = try SyncRecoveryGuard.recoverIfNeeded(snapshot: snap)
            XCTAssertEqual(lost, 2)

            let events = try SyncEventLogger.recentEvents(limit: 50)
            let lostEvents = events.filter { $0.eventType == SyncEventType.itemsLost }
            XCTAssertEqual(lostEvents.count, 2)
            let recoveredIDs = Set(lostEvents.map(\.recordID))
            XCTAssertEqual(recoveredIDs, [id1, id2])
            for ev in lostEvents {
                XCTAssertEqual(ev.recordType, "records")
                XCTAssertTrue(ev.details.contains("database_id=books"))
            }
        }
    }

    func testNewRecordsAfterSnapshotAreNotLogged() throws {
        try withHermeticDB {
            @Dependency(\.defaultDatabase) var database
            let snap = try SyncRecoveryGuard.takeSnapshot()
            // Add a record that didn't exist at snapshot time.
            _ = try database.write { try insertRecord($0, dbID: "books", title: "New") }
            let lost = try SyncRecoveryGuard.recoverIfNeeded(snapshot: snap)
            XCTAssertEqual(lost, 0)
            XCTAssertTrue(try SyncEventLogger.recentEvents(limit: 50).isEmpty)
        }
    }
}
