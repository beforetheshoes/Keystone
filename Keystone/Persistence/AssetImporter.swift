import Foundation
import GRDB
import CryptoKit
import UniformTypeIdentifiers

enum AssetImporter {
    /// Attach `fileURL` to `recordID`, routing storage based on whether
    /// the record is sidecar-backed:
    ///
    /// - **Record has `sidecar_path`** (e.g. `vehicle_maintenance` and
    ///   any future sidecar-backed area like Home/, Pets/, Trips/):
    ///   copy the file into the record's sidecar bundle folder
    ///   (the parent of `sidecar_path`), then `registerInPlace` so
    ///   the asset row points at the bundle file. Everything the user
    ///   has attached to that record then lives in one Finder-visible
    ///   folder, alongside the canonical `.md` and the original scans.
    /// - **Record has no `sidecar_path`** (Books, Restaurants, etc.):
    ///   fall through to `importFile`, which copies into the
    ///   app-managed `Assets/<Database>/<Title>-<id>/…` tree.
    ///
    /// Single canonical entry point for "the user just attached a
    /// file" — picker, drag/drop, paste. Internal flows that have
    /// their own semantics (cover-image import, inbox import) keep
    /// using `importFile` directly.
    static func attachFile(
        _ db: Database,
        fileURL: URL,
        recordID: String?,
        workspaceID: String
    ) throws -> AssetRecord {
        // Orphan import (no record yet) goes straight to the Assets/
        // flat layout. Sidecar routing requires a record to look up
        // `sidecar_path` against.
        guard let recordID else {
            return try importFile(
                db, fileURL: fileURL, recordID: nil, workspaceID: workspaceID
            )
        }

        let sidecarPath = try String.fetchOne(
            db,
            sql: "SELECT sidecar_path FROM records WHERE id = ?",
            arguments: [recordID]
        ) ?? nil

        if let sidecarPath, !sidecarPath.isEmpty {
            return try attachIntoSidecarBundle(
                db, fileURL: fileURL, recordID: recordID,
                workspaceID: workspaceID, sidecarPath: sidecarPath
            )
        }
        return try importFile(
            db, fileURL: fileURL, recordID: recordID, workspaceID: workspaceID
        )
    }

    /// Copy `fileURL` into the record's sidecar bundle folder (the
    /// parent of its `sidecar_path`), with name disambiguation against
    /// any existing bundle contents, then register the asset in place.
    /// Caller must have already established that the record has a
    /// non-empty `sidecar_path`.
    private static func attachIntoSidecarBundle(
        _ db: Database,
        fileURL: URL,
        recordID: String,
        workspaceID: String,
        sidecarPath: String
    ) throws -> AssetRecord {
        let workspace = AppDatabase.workspaceFolder
        let bundleFolder = workspace
            .appendingPathComponent(sidecarPath)
            .deletingLastPathComponent()
        try FileManager.default.createDirectory(at: bundleFolder, withIntermediateDirectories: true)

        let resolvedFilename = AssetPathing.disambiguateFilename(
            fileURL.lastPathComponent, in: bundleFolder
        )
        let destination = bundleFolder.appendingPathComponent(resolvedFilename)

        // Copy bytes through `Data` rather than `FileManager.copyItem`
        // to dodge sandbox quirks around the source URL after a prior
        // read (mirrors what `importFile` does).
        let data = try Data(contentsOf: fileURL)
        try data.write(to: destination, options: .atomic)

        return try registerInPlace(
            db, fileURL: destination, recordID: recordID, workspaceID: workspaceID
        )
    }

    /// Register an existing in-workspace file as an asset of `recordID`
    /// **without copying its bytes**. Used for sidecar-bundle companions
    /// (the PDF/PNG/JPG that lives next to a `.pdf-processed-markdown.md`
    /// in `Cars/`): the file is already canonical at its location, so
    /// duplicating it under `Assets/` is wasted disk + iCloud bandwidth
    /// and creates two stores to keep in sync. The asset row points
    /// directly at the bundle file via a workspace-relative
    /// `relative_path`; the rest of the schema is identical to a copied
    /// asset (hash, byte size, mime).
    ///
    /// `fileURL` MUST resolve inside `AppDatabase.workspaceFolder` —
    /// throws otherwise. Asset paths outside the workspace would break
    /// the "store relative paths only" invariant the rest of the app
    /// relies on (cross-machine sync, workspace relocation).
    @discardableResult
    static func registerInPlace(
        _ db: Database,
        fileURL: URL,
        recordID: String,
        workspaceID: String
    ) throws -> AssetRecord {
        let workspaceRoot = AppDatabase.workspaceFolder.standardizedFileURL.path
        let absolutePath = fileURL.standardizedFileURL.path
        guard absolutePath.hasPrefix(workspaceRoot + "/") else {
            throw NSError(
                domain: "Keystone", code: 34,
                userInfo: [NSLocalizedDescriptionKey: "registerInPlace requires a path inside the workspace; got \(absolutePath)"]
            )
        }
        let relativePath = String(absolutePath.dropFirst(workspaceRoot.count + 1))

        let originalFilename = fileURL.lastPathComponent
        let ext = fileURL.pathExtension.lowercased()
        let data = try Data(contentsOf: fileURL)
        let byteSize = Int64(data.count)
        let hashHex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let mimeType: String? = {
            guard !ext.isEmpty,
                  let type = UTType(filenameExtension: ext) else { return nil }
            return type.preferredMIMEType
        }()

        let now = AppDatabase.isoFormatter.string(from: Date())
        let id = UUID().uuidString

        try db.execute(
            sql: """
                INSERT INTO assets (
                    id, workspace_id, record_id,
                    original_filename, stored_filename, relative_path,
                    mime_type, file_extension, byte_size, content_hash,
                    extracted_text, metadata_json, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, '{}', ?, ?)
            """,
            arguments: [
                id, workspaceID, recordID,
                originalFilename, originalFilename, relativePath,
                mimeType, ext.isEmpty ? nil : ext, byteSize, hashHex,
                now, now
            ]
        )

        return AssetRecord(
            id: id,
            recordID: recordID,
            originalFilename: originalFilename,
            storedFilename: originalFilename,
            relativePath: relativePath,
            mimeType: mimeType,
            fileExtension: ext.isEmpty ? nil : ext,
            byteSize: byteSize,
            contentHash: hashHex,
            createdAt: now
        )
    }

    /// Copy `fileURL` into the workspace's Assets folder using the
    /// per-record layout (`Assets/<Database>/<RecordTitle>-<shortID>/<original_filename>`),
    /// computing the file hash + mime, and inserting an `assets` row
    /// attached to `recordID`. Returns the new record. When `recordID`
    /// is nil (orphan import — rare), falls back to the legacy flat
    /// `Assets/<uuid>.<ext>` layout. Caller is responsible for
    /// security-scoped resource access on `fileURL` when needed.
    static func importFile(
        _ db: Database,
        fileURL: URL,
        recordID: String?,
        workspaceID: String
    ) throws -> AssetRecord {
        try AppDatabase.ensureAssetsFolder()

        let originalFilename = fileURL.lastPathComponent
        let ext = fileURL.pathExtension.lowercased()
        let data = try Data(contentsOf: fileURL)
        let byteSize = Int64(data.count)
        let hashHex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let mimeType: String? = {
            guard !ext.isEmpty,
                  let type = UTType(filenameExtension: ext) else { return nil }
            return type.preferredMIMEType
        }()

        let relativePath: String
        let storedFilename: String

        if let recordID,
           let row = try Row.fetchOne(db, sql: """
               SELECT r.title AS title, d.name AS db_name
               FROM records r
               JOIN databases d ON d.id = r.database_id
               WHERE r.id = ?
           """, arguments: [recordID]) {
            let title: String = row["title"]
            let dbName: String = row["db_name"]

            let dbDir = AssetPathing.sanitize(dbName)
            let recDir = AssetPathing.recordFolderName(title: title, recordID: recordID)
            let folderURL = AppDatabase.workspaceFolder
                .appendingPathComponent("Assets", isDirectory: true)
                .appendingPathComponent(dbDir, isDirectory: true)
                .appendingPathComponent(recDir, isDirectory: true)
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

            let resolved = AssetPathing.disambiguateFilename(originalFilename, in: folderURL)
            storedFilename = resolved
            relativePath = "Assets/\(dbDir)/\(recDir)/\(resolved)"
        } else {
            // Orphan / pre-record path. Old-style flat layout with a
            // UUID-named file so unrelated drops don't collide.
            let storedID = UUID().uuidString
            storedFilename = ext.isEmpty ? storedID : "\(storedID).\(ext)"
            relativePath = "Assets/\(storedFilename)"
        }

        let destination = AppDatabase.workspaceFolder.appendingPathComponent(relativePath)
        // Write rather than copy to dodge sandbox quirks around the
        // source URL after the prior read.
        try data.write(to: destination, options: .atomic)

        let now = AppDatabase.isoFormatter.string(from: Date())
        let id = UUID().uuidString

        try db.execute(
            sql: """
                INSERT INTO assets (
                    id, workspace_id, record_id,
                    original_filename, stored_filename, relative_path,
                    mime_type, file_extension, byte_size, content_hash,
                    extracted_text, metadata_json, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, '{}', ?, ?)
            """,
            arguments: [
                id, workspaceID, recordID,
                originalFilename, storedFilename, relativePath,
                mimeType, ext.isEmpty ? nil : ext, byteSize, hashHex,
                now, now
            ]
        )

        return AssetRecord(
            id: id,
            recordID: recordID,
            originalFilename: originalFilename,
            storedFilename: storedFilename,
            relativePath: relativePath,
            mimeType: mimeType,
            fileExtension: ext.isEmpty ? nil : ext,
            byteSize: byteSize,
            contentHash: hashHex,
            createdAt: now
        )
    }
}
