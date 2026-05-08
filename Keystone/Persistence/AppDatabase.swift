import Foundation
import GRDB
import os
@preconcurrency import SQLiteData

private let bootLog = Logger(subsystem: "Keystone", category: "Boot")

/// Dump record counts per database, plus relation/property_value/asset
/// totals, to the Keystone log subsystem under category `Boot`. Used as a
/// tracer at known checkpoints in the boot path so a session that loses
/// data shows exactly which step the loss happened at. Cheap; fine to
/// call several times per launch.
func logDBCensus(_ db: GRDB.Database, label: String) {
    do {
        let dbRows = try Row.fetchAll(db, sql: """
            SELECT d.id AS id,
                   (SELECT COUNT(*) FROM records r WHERE r.database_id = d.id AND r.deleted_at IS NULL) AS rcount
            FROM databases d
            ORDER BY d.id
        """)
        let parts = dbRows.map { row -> String in
            let id: String = row["id"] ?? "?"
            let count: Int = row["rcount"] ?? 0
            return "\(id)=\(count)"
        }
        let pvCount = (try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM property_values")) ?? -1
        let relCount = (try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM relations")) ?? -1
        let assetCount = (try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets")) ?? -1
        bootLog.notice("census \(label, privacy: .public): \(parts.joined(separator: " "), privacy: .public) | property_values=\(pvCount) relations=\(relCount) assets=\(assetCount)")
    } catch {
        bootLog.error("census \(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
    }
}

/// Capture the on-disk state of `workspace.sqlite` (and its WAL/SHM
/// siblings + iCloud download status) so a session that loses data shows
/// whether the file was replaced/truncated/evicted while the app was
/// closed. Logs to `Keystone` subsystem under category `Boot`.
func logFileState(at url: URL, label: String) {
    let fm = FileManager.default
    let candidates: [URL] = [
        url,
        url.appendingPathExtension("wal"),
        url.appendingPathExtension("shm"),
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud"),
    ]

    for path in candidates {
        guard fm.fileExists(atPath: path.path) else { continue }
        let attrs = (try? fm.attributesOfItem(atPath: path.path)) ?? [:]
        let size = attrs[.size] as? UInt64 ?? 0
        let mtime = (attrs[.modificationDate] as? Date).map { $0.timeIntervalSince1970 } ?? 0

        var icloudInfo = ""
        if let values = try? path.resourceValues(forKeys: [
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemIsUploadingKey,
            .ubiquitousItemHasUnresolvedConflictsKey,
        ]) {
            let downloading = values.ubiquitousItemIsDownloading ?? false
            let uploading = values.ubiquitousItemIsUploading ?? false
            let conflicts = values.ubiquitousItemHasUnresolvedConflicts ?? false
            let status = values.ubiquitousItemDownloadingStatus?.rawValue ?? "n/a"
            icloudInfo = " icloud{status=\(status) dl=\(downloading) ul=\(uploading) conflicts=\(conflicts)}"
        }
        bootLog.notice("filestate \(label, privacy: .public) \(path.lastPathComponent, privacy: .public): size=\(size) mtime=\(String(format: "%.3f", mtime))\(icloudInfo, privacy: .public)")
    }
}

enum AppDatabase {
    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Folder that holds the user-visible workspace contents — `Inbox/`,
    /// `Assets/`, and the `README.md` users see in Finder. Resolves
    /// through `WorkspaceLocationManager` so the user can pick between
    /// the sandbox container, a custom folder, or iCloud Drive in
    /// Settings. Falls back to the container path if resolution fails
    /// so display-only callers (Settings text, sync footer) never crash;
    /// the actual database open path uses `make()` which surfaces
    /// resolution errors.
    ///
    /// **Note**: this folder does NOT hold `workspace.sqlite` anymore —
    /// see `databaseFolder` for that. The split exists because file-level
    /// sync engines (iCloud Drive, Dropbox, etc.) replace live SQLite
    /// files mid-session and corrupt or destroy data; the database must
    /// always live in a sandbox-private location regardless of where the
    /// user wants their files visible.
    static var workspaceFolder: URL {
        do {
            return try WorkspaceLocationManager.shared.resolve()
        } catch {
            os_log(
                .error,
                log: OSLog(subsystem: "Keystone", category: "Workspace"),
                "workspaceFolder resolution failed (%{public}@), falling back to container",
                error.localizedDescription
            )
            return WorkspaceLocationManager.containerWorkspaceFolder
        }
    }

    /// Folder that holds `workspace.sqlite` and its WAL/SHM siblings.
    /// **Always** the sandbox-local app-support directory — never iCloud
    /// Drive, never a user-picked folder, never any location a file-level
    /// sync engine can touch. The user-facing storage setting only
    /// affects `workspaceFolder` (where Inbox/Assets live); the database
    /// itself is private to this device, with cross-device sync handled
    /// at the row level by CloudKit `SyncEngine`.
    static var databaseFolder: URL {
        WorkspaceLocationManager.containerWorkspaceFolder
    }

    static var assetsFolder: URL {
        workspaceFolder.appendingPathComponent("Assets", isDirectory: true)
    }

    /// Resolve an asset's `relative_path` against the current workspace folder.
    static func absoluteURL(forRelativePath relativePath: String) -> URL {
        workspaceFolder.appendingPathComponent(relativePath)
    }

    /// Idempotent: creates the assets folder if missing and returns it.
    @discardableResult
    static func ensureAssetsFolder() throws -> URL {
        let folder = assetsFolder
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    /// Build the SQLite writer + run migrations + seed. Used by both the
    /// app's `bootstrapDatabase` dependency setup and by tests that want a
    /// scratch database.
    static func make() throws -> any DatabaseWriter {
        let fm = FileManager.default
        let folder = workspaceFolder
        if !fm.fileExists(atPath: folder.path) {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let dbFolder = databaseFolder
        if !fm.fileExists(atPath: dbFolder.path) {
            try fm.createDirectory(at: dbFolder, withIntermediateDirectories: true)
        }

        // Drop a README into the workspace folder so iCloud Drive's UI
        // surfaces the container in Finder + Files.app. Sonoma+ refuses to
        // expose third-party ubiquity containers that only contain user
        // assets; a recognizable user-document extension (.md / .txt / .rtf)
        // counts as "user content" and unsticks the listing.
        let readme = folder.appendingPathComponent("README.md")
        if !fm.fileExists(atPath: readme.path) {
            let body = """
            # Keystone workspace

            This folder holds your Keystone files (Inbox + Assets). The
            database itself (`workspace.sqlite`) lives privately in this
            device's app-support directory — never here, never in any
            file-syncing folder. Cross-device sync of records is handled
            at the row level by CloudKit, separately from these files.

            - `Inbox/` — drop files here from any device to import them as records
            - `Assets/` — every imported file (cover photos, attachments)

            Don't drop a copy of `workspace.sqlite` here yourself; the app
            ignores it.
            """
            try? body.data(using: .utf8)?.write(to: readme)
        }

        let url = dbFolder.appendingPathComponent("workspace.sqlite")

        // One-time migration: if a workspace.sqlite (and friends) sit in
        // the user-visible workspace folder from before this split, copy
        // them into the local database folder before opening the writer.
        // The old file is renamed (not deleted) so the user can recover
        // it if anything is wrong with the migration. iCloud Drive will
        // continue to back up the rename, but the live DB now reads/writes
        // only at `dbFolder/workspace.sqlite` — beyond iCloud's reach.
        let legacyURL = folder.appendingPathComponent("workspace.sqlite")
        if !fm.fileExists(atPath: url.path), fm.fileExists(atPath: legacyURL.path) {
            do {
                try fm.copyItem(at: legacyURL, to: url)
                for ext in ["wal", "shm"] {
                    let src = legacyURL.appendingPathExtension(ext)
                    let dst = url.appendingPathExtension(ext)
                    if fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) {
                        try? fm.copyItem(at: src, to: dst)
                    }
                }
                let renamed = legacyURL.deletingLastPathComponent()
                    .appendingPathComponent("workspace.sqlite.legacy-\(Int(Date().timeIntervalSince1970))")
                try? fm.moveItem(at: legacyURL, to: renamed)
                for ext in ["wal", "shm"] {
                    let src = legacyURL.appendingPathExtension(ext)
                    if fm.fileExists(atPath: src.path) {
                        let dst = renamed.appendingPathExtension(ext)
                        try? fm.moveItem(at: src, to: dst)
                    }
                }
                bootLog.notice("migrated workspace.sqlite from \(legacyURL.path, privacy: .public) → \(url.path, privacy: .public); old file renamed to .legacy")
            } catch {
                bootLog.error("failed migrating workspace.sqlite from old location: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }

        var config = Configuration()
        config.foreignKeysEnabled = true

        let writer: any DatabaseWriter = try defaultDatabase(
            path: url.path,
            configuration: config
        )

        var migrator = DatabaseMigrator()
        // Disable GRDB's per-migration deferred FK check. By default, GRDB
        // runs each migration with `PRAGMA foreign_keys = OFF`, then calls
        // `PRAGMA foreign_key_check` at the end of the migration's
        // transaction and aborts on any violation anywhere in the DB.
        // That blanket check trips on legacy demo-seed orphans (e.g.
        // `p1.relationship` from May 2026 builds) that get re-introduced
        // during a table-rebuild migration's `INSERT ... SELECT ...`
        // copy step — even though the migration itself didn't intend to
        // create them. We do our own orphan sweep after migrate via
        // `cleanupOrphansV12`, which is more targeted (deletes the
        // orphan rows) than GRDB's default (aborts the whole migration).
        migrator = migrator.disablingDeferredForeignKeyChecks()
        migrator.registerMigration("v1") { db in
            try Schema.createV1(db)
        }
        migrator.registerMigration("v2-blocks") { db in
            try Schema.createBlocksV2(db)
        }
        migrator.registerMigration("v3-eleanor-blocks") { db in
            try Schema.seedEleanorBlocksV3(db)
        }
        migrator.registerMigration("v4-relation-config") { db in
            try Schema.relationConfigV4(db)
        }
        migrator.registerMigration("v5-backfill-relations") { db in
            try Schema.backfillRelationsV5(db)
        }
        migrator.registerMigration("v6-assets") { db in
            try Schema.createAssetsV6(db)
        }
        migrator.registerMigration("v7-remove-demo-data") { db in
            try Schema.removeDemoDataV7(db)
        }
        migrator.registerMigration("v8-sweep-orphans") { db in
            try Schema.sweepOrphansV8(db)
        }
        migrator.registerMigration("v9-drop-blocks-self-fk") { db in
            try Schema.dropBlocksSelfFKV9(db)
        }
        migrator.registerMigration("v10-drop-unique-constraints") { db in
            try Schema.dropUniqueConstraintsV10(db)
        }
        migrator.registerMigration("v11-vehicle-maintenance") { db in
            try Schema.seedVehicleMaintenanceV11(db)
        }
        migrator.registerMigration("v12-cleanup-orphans") { db in
            try Schema.cleanupOrphansV12(db)
        }
        migrator.registerMigration("v13-regenerate-imported-blocks") { db in
            try Schema.regenerateImportedBlocksV13(db)
        }
        migrator.registerMigration("v14-regenerate-imported-blocks-2") { db in
            try Schema.regenerateImportedBlocksV14(db)
        }
        migrator.registerMigration("v15-regenerate-imported-blocks-3") { db in
            try Schema.regenerateImportedBlocksV15(db)
        }
        migrator.registerMigration("v17-regenerate-imported-blocks-4") { db in
            try Schema.regenerateImportedBlocksV17(db)
        }
        migrator.registerMigration("v18-vendors-database") { db in
            try Schema.seedVendorsAndPromoteRelationsV18(db)
        }
        migrator.registerMigration("v19-vendor-place-id") { db in
            try Schema.addVendorPlaceIDPropertyV19(db)
        }
        migrator.registerMigration("v20-vendor-locality") { db in
            try Schema.addVendorLocalityPropertyV20(db)
        }
        migrator.registerMigration("v21-remove-legacy-demo-orphans") { db in
            try Schema.removeLegacyDemoOrphansV21(db)
        }
        migrator.registerMigration("v22-travel-area") { db in
            try Schema.seedTravelAreaV22(db)
        }
        migrator.registerMigration("v23-flip-travel-date-tz") { db in
            try Schema.flipTravelDatePropertiesV23(db)
        }
        migrator.registerMigration("v24-collections-area") { db in
            try Schema.seedCollectionsAreaV24(db)
        }
        migrator.registerMigration("v25-flip-address-type") { db in
            try Schema.flipAddressPropertiesV25(db)
        }
        migrator.registerMigration("v16-relocate-assets") { db in
            try Schema.relocateAssetsV16(db)
        }

        try? writer.read { db in logDBCensus(db, label: "before-migrate") }
        bootLog.notice("workspace path: \(folder.path, privacy: .public)")
        logFileState(at: url, label: "before-migrate")

        // NO blanket pre-migrate FK sweep. Same hazard as the post-migrate
        // sweep: CloudKit-synced child rows whose parent hasn't arrived
        // yet would be flagged by `PRAGMA foreign_key_check` and deleted,
        // propagating the deletion to every other device via SyncEngine
        // triggers. We rely on `migrator.disablingDeferredForeignKeyChecks()`
        // (set above) so a transient FK violation during the migration
        // doesn't abort the whole transaction. Targeted orphan removal
        // for known stale IDs (e.g. legacy `p1`-style demo seeds) lives
        // in a numbered migration so it runs once per device.

        try migrator.migrate(writer)
        try? writer.read { db in logDBCensus(db, label: "after-migrate") }

        // Truncate the WAL after migrations so any stale demo-data pages
        // recovered from prior binaries can't reappear on a later open.
        try? writer.write { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        try? writer.read { db in logDBCensus(db, label: "after-checkpoint") }

        try writer.write { db in
            try Seed.runIfEmpty(db)
        }
        try? writer.read { db in logDBCensus(db, label: "after-seed") }

        // Promote any text-stored relation values into real relations rows
        // whenever the target record now exists. Idempotent — runs each
        // boot so newly created link targets pick up earlier imports.
        try? writer.write { db in
            let n = try DBWrites.backfillRelationsByTitle(db)
            if n > 0 { bootLog.notice("backfillRelationsByTitle promoted \(n) text values to relations") }
        }

        // Populate editor blocks for records that arrived with a .md
        // attachment but no body (e.g. records imported before the
        // markdown→blocks converter existed). Idempotent — only touches
        // records with zero existing blocks.
        try? writer.write { db in
            let n = try DBWrites.backfillBlocksFromMarkdownAssets(db)
            if n > 0 { bootLog.notice("backfillBlocksFromMarkdownAssets populated \(n) record bodies") }
        }

        // DO NOT run `cleanupOrphansV12` per-boot. CloudKit sync
        // replicates rows independently and out-of-order — assets
        // commonly arrive before their parent records. A blanket "child
        // with no parent → DELETE" sweep at boot interprets every
        // freshly-synced asset as an orphan, deletes it, and the
        // SyncEngine `afterDelete` triggers then push the deletion
        // back to CloudKit. Net effect: every boot of a freshly-installed
        // device wipes out hundreds of legitimate rows AND propagates
        // the wipe to every other device. Real data loss + CloudKit
        // rate-limit thrash.
        //
        // The cleanup remains as a one-time migration (`v12-cleanup-orphans`)
        // for the original bug it fixed. If genuine orphans accumulate
        // (e.g. local-only deletes that bypassed sync), they're cheap
        // to leave around — the row hasn't been seen as a violation by
        // SQLite's FK constraint because we made the constraint
        // tolerant. We can re-introduce a *time-gated* cleanup later
        // (e.g. "delete orphans that have been orphaned for >7 days"),
        // but a blanket per-boot pass is unsafe under CloudKit
        // semantics.
        try? writer.read { db in logDBCensus(db, label: "after-backfill") }
        logFileState(at: url, label: "after-backfill")

        installShutdownCheckpoint(writer: writer, url: url)

        return writer
    }
}

#if canImport(AppKit)
import AppKit
#endif

/// Subscribe to OS termination signals so we can force a WAL → main-file
/// checkpoint right before the app dies. Without this, SQLite leaves
/// recent commits in the WAL until autocheckpoint (every ~1000 pages),
/// and any file-level sync (e.g. iCloud Drive) that snapshots only
/// `workspace.sqlite` will see a stale view of the data. Belt-and-braces
/// fix for a known gotcha; safe to leave on permanently.
private nonisolated(unsafe) var shutdownObserverInstalled = false
private func installShutdownCheckpoint(writer: any DatabaseWriter, url: URL) {
    guard !shutdownObserverInstalled else { return }
    shutdownObserverInstalled = true

    let checkpoint: @Sendable () -> Void = {
        do {
            try writer.write { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
            logFileState(at: url, label: "shutdown-checkpoint")
            bootLog.notice("shutdown WAL checkpoint succeeded")
        } catch {
            bootLog.error("shutdown WAL checkpoint failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    #if canImport(AppKit)
    NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification,
        object: nil,
        queue: .main
    ) { _ in checkpoint() }
    #endif
    NotificationCenter.default.addObserver(
        forName: ProcessInfo.thermalStateDidChangeNotification,
        object: nil,
        queue: .main
    ) { _ in
        // Defensive — if the OS is stressed, force a checkpoint so a
        // possible imminent kill leaves the main file consistent.
        checkpoint()
    }
}
