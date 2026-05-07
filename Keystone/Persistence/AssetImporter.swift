import Foundation
import GRDB
import CryptoKit
import UniformTypeIdentifiers

enum AssetImporter {
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
