import Foundation
import GRDB

struct AssetRecord: Equatable, Sendable, Identifiable {
    let id: String
    let recordID: String?
    let originalFilename: String
    let storedFilename: String
    let relativePath: String
    let mimeType: String?
    let fileExtension: String?
    let byteSize: Int64?
    let contentHash: String?
    let createdAt: String
    /// True when the file at `relativePath` contains AES-GCM ciphertext
    /// rather than the original bytes. Open/Quick Look paths must
    /// decrypt to a temp file before handing the URL to NSWorkspace.
    let isEncrypted: Bool

    var absoluteURL: URL {
        AppDatabase.absoluteURL(forRelativePath: relativePath)
    }
}

enum AssetReads {
    static func assets(_ db: Database, recordID: String) throws -> [AssetRecord] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, record_id, original_filename, stored_filename, relative_path,
                   mime_type, file_extension, byte_size, content_hash, created_at, is_encrypted
            FROM assets
            WHERE record_id = ?
            ORDER BY created_at DESC
        """, arguments: [recordID])
        return rows.map(rowToAsset)
    }

    static func asset(_ db: Database, id: String) throws -> AssetRecord? {
        try Row.fetchOne(db, sql: """
            SELECT id, record_id, original_filename, stored_filename, relative_path,
                   mime_type, file_extension, byte_size, content_hash, created_at, is_encrypted
            FROM assets WHERE id = ?
        """, arguments: [id]).map(rowToAsset)
    }

    private static func rowToAsset(_ row: Row) -> AssetRecord {
        AssetRecord(
            id: row["id"],
            recordID: row["record_id"],
            originalFilename: row["original_filename"],
            storedFilename: row["stored_filename"],
            relativePath: row["relative_path"],
            mimeType: row["mime_type"],
            fileExtension: row["file_extension"],
            byteSize: row["byte_size"],
            contentHash: row["content_hash"],
            createdAt: row["created_at"],
            isEncrypted: (row["is_encrypted"] as Int?) == 1
        )
    }
}
