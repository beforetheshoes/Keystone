import Foundation
import Dependencies
import GRDB
@preconcurrency import SQLiteData
import OSLog

private let bootstrapLog = Logger(subsystem: "Keystone", category: "Boot")

/// True iff `bootstrapKeystoneDatabase` configured a real CloudKit `SyncEngine`.
/// Read by `SyncEngineClient` to decide whether to observe sync state or stay
/// in the `.local` state.
nonisolated(unsafe) var keystoneSyncEngineConfigured: Bool = false

extension DependencyValues {
    /// Open the Keystone database **for CLI use**. Same path resolution,
    /// migrations, seed, and boot-time backfills as the GUI bootstrap —
    /// what's omitted is the CloudKit `SyncEngine` (CLI is short-lived
    /// and the GUI app, when running, owns the sync session).
    ///
    /// Schema correctness is non-negotiable: a CLI binary newer than
    /// the on-disk DB must apply its own migrations before doing
    /// anything, otherwise every property/relation reference can break
    /// with FK violations the moment the schema diverges. GRDB's
    /// `migrator.migrate()` is idempotent — concurrent calls from a
    /// running GUI just no-op against already-applied versions —
    /// and the 10-second `busy_timeout` set inside `make()` keeps
    /// the two writers cooperative.
    mutating func bootstrapKeystoneDatabaseForCLI() throws {
        let writer = try AppDatabase.make()
        defaultDatabase = writer
        keystoneSyncEngineConfigured = false
    }

    /// Configure the default database (and optionally the CloudKit sync engine)
    /// once at app launch. Mirrors the AuralystApp pattern.
    mutating func bootstrapKeystoneDatabase(configureSyncEngine: Bool = true) throws {
        let writer = try AppDatabase.make()
        defaultDatabase = writer

        guard configureSyncEngine else {
            keystoneSyncEngineConfigured = false
            return
        }

        // NO blanket orphan sweep here. CloudKit syncs rows independently
        // and out-of-order — a child row commonly arrives before its
        // parent. A `PRAGMA foreign_key_check` sweep at boot interprets
        // every freshly-synced row whose parent hasn't landed yet as an
        // orphan, deletes it, and the SyncEngine's `afterDelete` trigger
        // then propagates the deletion to CloudKit, wiping the row from
        // every other device. This is real data loss on multi-device
        // setups, not just local cleanup.
        //
        // Targeted, one-shot orphan removal goes in numbered migrations
        // (e.g. `removeLegacyDemoOrphansV21`) so it runs once per device
        // and only against IDs we know are stale.

        // SyncEngine init can throw when the CloudKit container has
        // FK-violating rows that get applied during the initial pull —
        // e.g. a `property_values` row referencing a `records.id` that
        // was hard-deleted on another device. Historically we treated
        // this as fatal; that strands the user on an unbootable app
        // with no recovery path. Fall back to local-only mode instead:
        // the app launches, the user sees their data, and the next boot
        // (or a manual "reset CloudKit" action) can resolve the
        // server-side mismatch. Loud log so the user can find this in
        // Console.app if they wonder why sync is silent.
        do {
            // CKShare cross-user sharing (#14): only `Record` is a
            // shareable root. Its single-FK children
            // (`PropertyValueRow`, `Block`, `AssetRow`) follow the
            // record into a share zone via sqlite-data's
            // parent-FK-routing trigger (see
            // `SQLiteData/CloudKit/Internal/Triggers.swift`).
            //
            // `privateTables:` are synchronized but force-pinned to the
            // default zone — they never become share roots and never
            // follow a parent into a share zone. Workspace-level
            // metadata (workspaces, areas, databases, properties,
            // tags, views) lives there. RelationRow + RecordTag also
            // sit private for v1: they have multi-FK shapes that
            // wouldn't follow records into a share zone anyway, and
            // recipients don't need our local tags / cross-DB
            // relations to read a shared record's body.
            defaultSyncEngine = try SyncEngine(
                for: writer,
                tables:
                    Record.self,
                    PropertyValueRow.self,
                    Block.self,
                    AssetRow.self,
                privateTables:
                    Workspace.self,
                    Area.self,
                    ObjectDatabase.self,
                    PropertyDef.self,
                    TagRow.self,
                    RecordTag.self,
                    RelationRow.self,
                    ViewDef.self,
                containerIdentifier: CloudKitConfig.containerIdentifier,
                logger: Logger(subsystem: "Keystone", category: "CloudKit")
            )
            keystoneSyncEngineConfigured = true
        } catch {
            keystoneSyncEngineConfigured = false
            bootstrapLog.error(
                "SyncEngine init failed — running in LOCAL-ONLY mode this session. Error: \(String(describing: error), privacy: .public)"
            )
            SyncEventLogger.log(
                type: SyncEventType.engineInitFailed,
                details: String(describing: error)
            )
            return
        }

        // Per-record protection-key rotation (#14). Idempotent + cheap
        // when nothing to do (one Keychain read returns nil → early
        // return). Runs before SyncMetadata seeding so the re-encrypted
        // ciphertext is what the touch-update broadcasts to CloudKit,
        // not the soon-to-be-stale workspace-key form.
        @Dependency(\.protectionKeyClient) var keys
        ProtectionKeyRotation.runIfNeeded(writer: writer, keys: keys)

        // Backfill `SyncMetadata` for rows inserted before `SyncEngine`
        // attached its triggers (e.g. seed rows, or any direct
        // `INSERT OR IGNORE` in a `DatabaseMigrator` migration).
        //
        // Without this, those rows have no metadata, the SyncEngine never
        // pushes them to CloudKit, and any *child* row that references one
        // of them is rejected on push with `Reference Violation`. Worse:
        // sqlite-data's reference-violation handler interprets the failure
        // as "parent was server-deleted" and **honors the FK CASCADE** on
        // the failing child — silently deleting it locally. Net effect of
        // the original bug: every record referencing a metadata-less
        // parent gets cascade-deleted on first sync attempt.
        //
        // The fix is a no-op `UPDATE` on each synced table. The
        // `afterUpdate` trigger sqlite-data installs runs
        // `SyncMetadata.insert(... onConflictDoUpdate: {})`, which is a
        // safe upsert: rows that already have metadata are unchanged,
        // rows that don't get a fresh metadata row.
        try seedSyncMetadataForExistingRows(writer: writer)
    }
}

/// Touch rows in CloudKit-synced tables that **don't yet have a
/// `sqlitedata_icloud_metadata` entry**, so sqlite-data's `afterUpdate`
/// trigger creates one. This catches rows inserted via migration
/// `INSERT OR IGNORE`s, which bypass the `afterInsert` trigger.
///
/// **Why the WHERE filter matters.** The original implementation
/// touched every row on every launch on the theory that the trigger's
/// `SyncMetadata.insert(... onConflictDoUpdate: {})` was a true no-op
/// for rows that already had metadata. Reading sqlite-data's actual
/// trigger (`Triggers.swift:afterUpdate`) shows the trigger also runs
/// `SyncMetadata.update(...)` which unconditionally bumps
/// `userModificationTime = currentTime()`. That metadata-row change
/// fires `SyncMetadata.afterUpdateTrigger`, which calls
/// `syncEngine.$didUpdate(...)` — re-queuing the row for push to
/// CloudKit. On a workspace with hundreds of vehicle-maintenance
/// `property_values` rows this meant every launch flooded the engine's
/// outbox; CloudKit responded with `Service Unavailable` / 429 throttles
/// in the 30-second range and the queue never drained, so other devices
/// saw no new data.
///
/// The `WHERE id NOT IN (… sqlitedata_icloud_metadata …)` filter makes
/// the touch surgical: only rows that genuinely bypassed the insert
/// trigger get touched. After they pick up metadata once, subsequent
/// launches no-op.
private func seedSyncMetadataForExistingRows(writer: any DatabaseWriter) throws {
    // Each entry is (table, "no-op-set-clause"). Tables without an
    // `updated_at` column reuse a stable column to make the UPDATE a
    // genuine no-op.
    let touches: [(String, String)] = [
        ("workspaces",      "SET updated_at = updated_at"),
        ("areas",           "SET sort_index = sort_index"),
        ("databases",       "SET updated_at = updated_at"),
        ("properties",      "SET updated_at = updated_at"),
        ("records",         "SET updated_at = updated_at"),
        ("property_values", "SET updated_at = updated_at"),
        ("blocks",          "SET updated_at = updated_at"),
        ("tags",            "SET updated_at = updated_at"),
        ("record_tags",     "SET created_at = created_at"),
        ("relations",       "SET updated_at = updated_at"),
        ("views",           "SET updated_at = updated_at"),
        ("assets",          "SET updated_at = updated_at"),
    ]

    var totalTouched = 0
    try writer.write { db in
        for (table, setClause) in touches {
            do {
                // Column names in `sqlitedata_icloud_metadata` are
                // camelCase (`recordPrimaryKey`, `recordType`) — they're
                // CREATE'd with double quotes in sqlite-data's
                // metadatabase migration, so the literal name is what
                // matters, not the snake_case convention used elsewhere
                // in this DB. Quote them defensively.
                try db.execute(
                    sql: """
                        UPDATE \(table) \(setClause)
                        WHERE id NOT IN (
                            SELECT "recordPrimaryKey"
                            FROM sqlitedata_icloud_metadata
                            WHERE "recordType" = ?
                        )
                    """,
                    arguments: [table]
                )
                totalTouched += db.changesCount
            } catch {
                bootstrapLog.error("seedSyncMetadata: UPDATE \(table) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    bootstrapLog.notice(
        "seedSyncMetadataForExistingRows: touched \(totalTouched, privacy: .public) row(s) lacking SyncMetadata across \(touches.count) table(s)"
    )
}
