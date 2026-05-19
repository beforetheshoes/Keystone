import Foundation
import GRDB
import Dependencies

/// One row of the local-only `sync_events` log. Owned by the sync layer
/// (this device's view of CloudKit activity), never replicated through
/// `SyncEngine` — diagnostic noise has no business amplifying writes
/// across the user's whole fleet.
struct SyncEventEntry: Equatable, Identifiable, Sendable {
    let id: Int64
    let timestamp: String
    let eventType: String
    let recordType: String
    let recordID: String
    let errorCode: String
    let details: String
}

/// Canonical event-type strings. Free-form `String` is allowed at the
/// SQL boundary (the `event_type` column has no CHECK), but writers
/// should stick to these so the diagnostic UI / CLI can color and
/// summarize consistently.
enum SyncEventType {
    static let engineStarted     = "engine_started"
    static let engineStopped     = "engine_stopped"
    static let engineInitFailed  = "engine_init_failed"
    static let syncBegan         = "sync_began"
    static let syncSucceeded     = "sync_succeeded"
    static let syncFailed        = "sync_failed"
    static let forcePullInvoked  = "force_pull_invoked"
    static let forcePushInvoked  = "force_push_invoked"
    static let itemsLost         = "items_lost"
    static let itemsRecovered    = "items_recovered"
}

/// Append-only, local-only CloudKit sync diagnostic log.
///
/// The table is created by migration `v40-sync-events`; this namespace
/// is the only API surface above the SQL. Every call resolves the
/// writer through `@Dependency(\.defaultDatabase)` so a scoped DB
/// (tests, CLI, hermetic harness) is honored automatically.
///
/// The logger is intentionally fail-soft: a write failure on the
/// diagnostic table must NEVER cascade into the operation it's
/// describing. Callers `try?` this when the originating action can
/// continue without the log line.
enum SyncEventLogger {
    /// Append a diagnostic row. `recordType`, `recordID`, `errorCode`,
    /// and `details` default to empty strings so callers only pass the
    /// columns that mean something for their event.
    static func log(
        type eventType: String,
        recordType: String = "",
        recordID: String = "",
        errorCode: String = "",
        details: String = ""
    ) {
        @Dependency(\.defaultDatabase) var database
        do {
            try database.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO sync_events
                          (event_type, record_type, record_id, error_code, details)
                        VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [eventType, recordType, recordID, errorCode, details]
                )
            }
        } catch {
            // Diagnostic failures must not propagate. Surface to the
            // unified log so a forensic pass can find them; the column
            // we couldn't write would be the same column we'd lose
            // either way.
        }
    }

    /// Async variant for callers already on an async path. Identical
    /// fail-soft semantics.
    static func logAsync(
        type eventType: String,
        recordType: String = "",
        recordID: String = "",
        errorCode: String = "",
        details: String = ""
    ) async {
        log(
            type: eventType,
            recordType: recordType,
            recordID: recordID,
            errorCode: errorCode,
            details: details
        )
    }

    /// Most-recent-first slice of the log. `limit` caps how many rows
    /// the UI / CLI pulls into memory at once.
    static func recentEvents(limit: Int = 200) throws -> [SyncEventEntry] {
        @Dependency(\.defaultDatabase) var database
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, timestamp, event_type, record_type, record_id, error_code, details
                    FROM sync_events
                    ORDER BY id DESC
                    LIMIT ?
                """,
                arguments: [limit]
            ).map { row in
                SyncEventEntry(
                    id: row["id"],
                    timestamp: row["timestamp"],
                    eventType: row["event_type"],
                    recordType: row["record_type"],
                    recordID: row["record_id"],
                    errorCode: row["error_code"],
                    details: row["details"]
                )
            }
        }
    }

    /// Headline numbers for the Settings inline summary. Runs as a
    /// single SQL roundtrip so it's cheap to call on every Settings
    /// open + sheet dismiss.
    static func summary(within hours: Int = 24) throws -> Summary {
        @Dependency(\.defaultDatabase) var database
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        let cutoffString = Self.iso8601String(cutoff)
        return try database.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                      COUNT(*) AS total,
                      COUNT(*) FILTER (WHERE event_type IN ('sync_failed','items_lost')) AS conflicts,
                      MAX(timestamp) FILTER (WHERE event_type = 'sync_succeeded') AS last_sync,
                      (SELECT details FROM sync_events
                         WHERE event_type IN ('sync_failed','engine_init_failed')
                         ORDER BY id DESC LIMIT 1) AS last_error
                    FROM sync_events
                    WHERE timestamp >= ?
                """,
                arguments: [cutoffString]
            )
            return Summary(
                totalEvents: row?["total"] ?? 0,
                conflictEvents: row?["conflicts"] ?? 0,
                lastSyncTimestamp: row?["last_sync"],
                lastErrorDetails: (row?["last_error"] as String?).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }

    /// Drop rows older than `days`. Cheap, idempotent — call from
    /// boot or from the diagnostic UI's "trim" affordance.
    @discardableResult
    static func purge(olderThanDays days: Int) throws -> Int {
        @Dependency(\.defaultDatabase) var database
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let cutoffString = Self.iso8601String(cutoff)
        return try database.write { db in
            try db.execute(
                sql: "DELETE FROM sync_events WHERE timestamp < ?",
                arguments: [cutoffString]
            )
            return db.changesCount
        }
    }

    /// Drop every row. Used by the diagnostic UI's "Clear log" action.
    static func clear() throws {
        @Dependency(\.defaultDatabase) var database
        try database.write { db in
            try db.execute(sql: "DELETE FROM sync_events")
        }
    }

    struct Summary: Equatable, Sendable {
        var totalEvents: Int
        var conflictEvents: Int
        var lastSyncTimestamp: String?
        var lastErrorDetails: String?
    }

    private static func iso8601String(_ date: Date) -> String {
        AppDatabase.isoFormatter.string(from: date)
    }
}
