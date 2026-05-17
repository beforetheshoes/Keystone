import XCTest
import Dependencies
import GRDB
@testable import Keystone

/// Coverage for the local-only `sync_events` log:
///
///   1. `log` round-trips into `recentEvents` in newest-first order.
///   2. `summary(within:)` counts the right window and surfaces the
///      most recent error.
///   3. `purge(olderThanDays:)` drops only old rows.
///   4. `clear` empties the table.
final class SyncEventLoggerTests: XCTestCase {

    func testLogRoundTripNewestFirst() throws {
        try withHermeticDB {
            SyncEventLogger.log(type: SyncEventType.engineStarted)
            SyncEventLogger.log(
                type: SyncEventType.syncFailed,
                errorCode: "force_pull",
                details: "network timed out"
            )
            SyncEventLogger.log(type: SyncEventType.syncSucceeded)

            let rows = try SyncEventLogger.recentEvents(limit: 50)
            XCTAssertEqual(rows.count, 3)
            // Newest first — last write should be first.
            XCTAssertEqual(rows[0].eventType, SyncEventType.syncSucceeded)
            XCTAssertEqual(rows[1].eventType, SyncEventType.syncFailed)
            XCTAssertEqual(rows[1].errorCode, "force_pull")
            XCTAssertEqual(rows[1].details, "network timed out")
            XCTAssertEqual(rows[2].eventType, SyncEventType.engineStarted)
        }
    }

    func testSummaryCountsConflictsAndSurfacesLastError() throws {
        try withHermeticDB {
            SyncEventLogger.log(type: SyncEventType.syncBegan)
            SyncEventLogger.log(type: SyncEventType.syncSucceeded)
            SyncEventLogger.log(
                type: SyncEventType.syncFailed,
                details: "bad token"
            )
            SyncEventLogger.log(
                type: SyncEventType.itemsLost,
                recordType: "records",
                recordID: "rec-1",
                details: "database_id=books"
            )

            let summary = try SyncEventLogger.summary(within: 24)
            XCTAssertEqual(summary.totalEvents, 4)
            XCTAssertEqual(summary.conflictEvents, 2) // sync_failed + items_lost
            XCTAssertNotNil(summary.lastSyncTimestamp)
            XCTAssertEqual(summary.lastErrorDetails, "bad token")
        }
    }

    func testPurgeDropsOldRowsOnly() throws {
        try withHermeticDB {
            // Inject one stale and one fresh row directly so we can
            // backdate the timestamp without waiting in real time.
            @Dependency(\.defaultDatabase) var database
            try database.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO sync_events (timestamp, event_type)
                        VALUES (?, ?)
                    """,
                    arguments: ["2020-01-01T00:00:00.000Z", SyncEventType.engineStarted]
                )
            }
            SyncEventLogger.log(type: SyncEventType.syncSucceeded)

            let deleted = try SyncEventLogger.purge(olderThanDays: 7)
            XCTAssertEqual(deleted, 1)

            let remaining = try SyncEventLogger.recentEvents(limit: 50)
            XCTAssertEqual(remaining.count, 1)
            XCTAssertEqual(remaining[0].eventType, SyncEventType.syncSucceeded)
        }
    }

    func testClearEmptiesTable() throws {
        try withHermeticDB {
            SyncEventLogger.log(type: SyncEventType.syncSucceeded)
            SyncEventLogger.log(type: SyncEventType.syncBegan)
            try SyncEventLogger.clear()
            let rows = try SyncEventLogger.recentEvents(limit: 50)
            XCTAssertTrue(rows.isEmpty)
        }
    }
}
