import Foundation
import GRDB
import CryptoKit
import UniformTypeIdentifiers

enum AssetImporter {
    /// Copy `fileURL` into the workspace's Assets folder, compute hash + mime,
    /// insert an `assets` row attached to `recordID`. Returns the new record.
    /// Caller is responsible for security-scoped resource access on `fileURL`
    /// when needed.
    static func importFile(
        _ db: Database,
        fileURL: URL,
        recordID: String?,
        workspaceID: String
    ) throws -> AssetRecord {
        try AppDatabase.ensureAssetsFolder()

        // Original filename + extension (lowercased for filesystem hygiene)
        let originalFilename = fileURL.lastPathComponent
        let ext = fileURL.pathExtension.lowercased()

        // Byte size + content hash (SHA-256). For typical attachments this
        // reads the whole file into memory; OK for documents/photos.
        let data = try Data(contentsOf: fileURL)
        let byteSize = Int64(data.count)
        let hashDigest = SHA256.hash(data: data)
        let hashHex = hashDigest.map { String(format: "%02x", $0) }.joined()

        // MIME type via UTI
        let mimeType: String? = {
            guard !ext.isEmpty,
                  let type = UTType(filenameExtension: ext) else { return nil }
            return type.preferredMIMEType
        }()

        // Stored filename: <uuid>[.ext]
        let storedID = UUID().uuidString
        let storedFilename: String = ext.isEmpty ? storedID : "\(storedID).\(ext)"
        let relativePath = "Assets/\(storedFilename)"
        let destination = AppDatabase.assetsFolder.appendingPathComponent(storedFilename)

        // Copy file (data is in-memory; write rather than copy to dodge any
        // sandbox quirks around the source URL after the read).
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
