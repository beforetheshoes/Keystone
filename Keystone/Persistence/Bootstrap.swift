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
    /// Open the Keystone database **for CLI use** — without running
    /// migrations, seed, backfills, cleanup sweeps, or attaching the
    /// CloudKit sync engine. Suitable for short-lived processes that need
    /// to read or write the live workspace while the GUI app is running.
    ///
    /// Critical: sets `busy_timeout` so the CLI waits politely for the
    /// app's write transactions instead of failing immediately with
    /// `database is locked`. Bypasses the heavy boot-pass logic (which
    /// the running app has already performed) so two writers don't race
    /// over migrations or cleanup.
    mutating func bootstrapKeystoneDatabaseForCLI() throws {
        let fm = FileManager.default
        let dbFolder = AppDatabase.databaseFolder
        if !fm.fileExists(atPath: dbFolder.path) {
            try fm.createDirectory(at: dbFolder, withIntermediateDirectories: true)
        }
        let url = dbFolder.appendingPathComponent("workspace.sqlite")

        var config = Configuration()
        config.foreignKeysEnabled = true
        // Wait up to 10s for the GUI app to release a write lock before
        // giving up. The app holds locks only for the duration of a
        // single write transaction, which is milliseconds in practice.
        config.busyMode = .timeout(10)

        let writer: any DatabaseWriter = try SQLiteData.defaultDatabase(
            path: url.path,
            configuration: config
        )
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

        defaultSyncEngine = try SyncEngine(
            for: writer,
            tables:
                Workspace.self,
                Area.self,
                ObjectDatabase.self,
                PropertyDef.self,
                Record.self,
                PropertyValueRow.self,
                Block.self,
                TagRow.self,
                RecordTag.self,
                RelationRow.self,
                ViewDef.self,
                AssetRow.self,
            containerIdentifier: CloudKitConfig.containerIdentifier,
            logger: Logger(subsystem: "Keystone", category: "CloudKit")
        )
        keystoneSyncEngineConfigured = true

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

/// Touch every row in every CloudKit-synced table so the `afterUpdate`
/// trigger sqlite-data installs creates `SyncMetadata` for any row that
/// got into the user table without going through the trigger path. See
/// the call site for the bug this works around.
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

    try writer.write { db in
        for (table, setClause) in touches {
            do {
                try db.execute(sql: "UPDATE \(table) \(setClause)")
            } catch {
                bootstrapLog.error("seedSyncMetadata: UPDATE \(table) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    bootstrapLog.notice("seedSyncMetadataForExistingRows: completed touch on \(touches.count) tables")
}
