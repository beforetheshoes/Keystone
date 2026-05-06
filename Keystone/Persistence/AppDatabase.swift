import Foundation
import GRDB
import os
@preconcurrency import SQLiteData

enum AppDatabase {
    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Folder that holds `workspace.sqlite` and the `Assets/` subfolder.
    /// Resolves through `WorkspaceLocationManager` so the user can pick
    /// between the sandbox container, a custom folder, or iCloud Drive
    /// in Settings without code changes elsewhere. Falls back to the
    /// container path if resolution fails so display-only callers
    /// (Settings text, sync footer) never crash; the actual database
    /// open path uses `make()` which surfaces resolution errors.
    static var workspaceFolder: URL {
        do {
            return try WorkspaceLocationManager.shared.resolve()
        } catch {
            // Log loudly so we notice silent fallbacks (e.g., iCloud Drive
            // selected but the ubiquity container is temporarily unreachable).
            // Production callers always see the container path in this case.
            os_log(
                .error,
                log: OSLog(subsystem: "Keystone", category: "Workspace"),
                "workspaceFolder resolution failed (%{public}@), falling back to container",
                error.localizedDescription
            )
            return WorkspaceLocationManager.containerWorkspaceFolder
        }
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

        // Drop a README into the workspace folder so iCloud Drive's UI
        // surfaces the container in Finder + Files.app. Sonoma+ refuses to
        // expose third-party ubiquity containers that only contain SQLite
        // files; a recognizable user-document extension (.md / .txt / .rtf)
        // counts as "user content" and unsticks the listing.
        let readme = folder.appendingPathComponent("README.md")
        if !fm.fileExists(atPath: readme.path) {
            let body = """
            # Keystone workspace

            This folder holds your Keystone data:

            - `workspace.sqlite` — the database (records, properties, blocks, tags, relations)
            - `Assets/` — every imported file (cover photos, attachments)

            You can drop files into `Assets/` from any device and they'll be available to Keystone, but **edit them through the app** rather than touching `workspace.sqlite` directly — it's a live SQLite database and may be open while you read this.

            Storage location is configured in Keystone → Settings → Storage.
            """
            try? body.data(using: .utf8)?.write(to: readme)
        }

        let url = folder.appendingPathComponent("workspace.sqlite")

        var config = Configuration()
        config.foreignKeysEnabled = true

        let writer: any DatabaseWriter = try defaultDatabase(
            path: url.path,
            configuration: config
        )

        var migrator = DatabaseMigrator()
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
        try migrator.migrate(writer)

        // Truncate the WAL after migrations so any stale demo-data pages
        // recovered from prior binaries can't reappear on a later open.
        try? writer.write { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }

        try writer.write { db in
            try Seed.runIfEmpty(db)
        }

        return writer
    }
}
