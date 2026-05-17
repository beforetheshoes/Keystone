import Foundation
import GRDB
import Dependencies

/// Pre-/post-sync watchdog over the `records` table.
///
/// Adapted from the Traveling Snails port. The original guard snapshotted
/// per-collection model arrays so it could re-insert vanished rows; for
/// Keystone the equivalent unit of user-visible loss is a `records` row
/// (every property value, block, and asset is keyed off `record_id`,
/// so a record disappearing is the only loss the user actually notices).
///
/// **First-cut behavior**: this guard only *detects* and logs.
/// `recoverIfNeeded` does NOT attempt to recreate vanished records —
/// the row's payload (title, properties, blocks, assets) lives across
/// many tables and a faithful restore would need a full pre-image we
/// don't yet capture. The diagnostic value of detection alone is
/// significant (we'd otherwise have no signal at all when sync drops a
/// row), and the auto-restore can land in a follow-up once we've seen
/// real loss patterns in dogfood.
enum SyncRecoveryGuard {
    /// Snapshot of every visible (`deleted_at IS NULL`) record's id,
    /// grouped by `database_id` so loss diagnostics show *which*
    /// database lost rows. Cheap to take — one indexed scan; small
    /// memory footprint (a string ID per record).
    struct Snapshot: Sendable, Equatable {
        var idsByDatabase: [String: Set<String>]

        var totalCount: Int {
            idsByDatabase.values.reduce(0) { $0 + $1.count }
        }
    }

    /// Capture the current set of record IDs by database. Run before
    /// kicking a sync cycle so a missing-after-sync diff is meaningful.
    static func takeSnapshot() throws -> Snapshot {
        @Dependency(\.defaultDatabase) var database
        return try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, database_id
                    FROM records
                    WHERE deleted_at IS NULL
                """
            )
            var groups: [String: Set<String>] = [:]
            for row in rows {
                let id: String = row["id"]
                let dbID: String = row["database_id"]
                groups[dbID, default: []].insert(id)
            }
            return Snapshot(idsByDatabase: groups)
        }
    }

    /// Diff the live `records` set against `snapshot`. Any ID that was
    /// in the snapshot but is now absent gets logged as `items_lost`.
    /// Returns the number of lost rows so the caller can surface a
    /// summary value in the UI / CLI.
    ///
    /// Newly-arrived records (in DB but not in snapshot) are
    /// **deliberately not logged** — sync routinely brings down rows
    /// from other devices, and that's normal traffic, not a diagnostic
    /// signal.
    @discardableResult
    static func recoverIfNeeded(snapshot: Snapshot) throws -> Int {
        @Dependency(\.defaultDatabase) var database
        let liveIDs: [String: Set<String>] = try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, database_id
                    FROM records
                    WHERE deleted_at IS NULL
                """
            )
            var groups: [String: Set<String>] = [:]
            for row in rows {
                let id: String = row["id"]
                let dbID: String = row["database_id"]
                groups[dbID, default: []].insert(id)
            }
            return groups
        }

        var lostTotal = 0
        for (dbID, beforeIDs) in snapshot.idsByDatabase {
            let afterIDs = liveIDs[dbID] ?? []
            let missing = beforeIDs.subtracting(afterIDs)
            guard !missing.isEmpty else { continue }
            lostTotal += missing.count
            for missingID in missing {
                SyncEventLogger.log(
                    type: SyncEventType.itemsLost,
                    recordType: "records",
                    recordID: missingID,
                    details: "database_id=\(dbID)"
                )
            }
        }
        return lostTotal
    }
}
