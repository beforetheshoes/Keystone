import Foundation
import GRDB

struct BlockRow: Equatable, Sendable, Identifiable {
    let id: String
    let recordID: String
    var kind: BlockKind
    var text: AttributedString
    var checked: Bool?
    var tableData: BlockTableData?
    var sortIndex: Double
}

enum BlockReads {
    /// Fetch blocks for a record. When `enc_content` is populated, the
    /// row was encrypted by the privacy-lock pass; we decrypt it back
    /// to the JSON the codec expects. If no encryptor is wired or the
    /// decrypt fails, the block surfaces with an `[encrypted]`
    /// paragraph body so the editor doesn't render stale content.
    static func blocks(
        _ db: Database,
        recordID: String,
        encryptor: ValueEncryptor? = nil
    ) throws -> [BlockRow] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, record_id, type, content_json, enc_content, sort_index
            FROM blocks
            WHERE record_id = ? AND deleted_at IS NULL
            ORDER BY sort_index
        """, arguments: [recordID])

        return rows.compactMap { row -> BlockRow? in
            guard let kind = BlockKind(rawValue: row["type"]) else { return nil }
            let json = resolveContentJSON(row: row, encryptor: encryptor)
            let (text, checked) = BlockContentCodec.decode(json)
            let tableData: BlockTableData? = (kind == .table) ? BlockContentCodec.decodeTable(json) : nil
            return BlockRow(
                id: row["id"],
                recordID: row["record_id"],
                kind: kind,
                text: text,
                checked: checked,
                tableData: tableData,
                sortIndex: row["sort_index"]
            )
        }
    }

    /// Returns the effective JSON for a block row, decrypting
    /// `enc_content` if present. Falls back to a literal `[encrypted]`
    /// placeholder body when the key is unavailable so the editor
    /// surface stays intact.
    private static func resolveContentJSON(row: Row, encryptor: ValueEncryptor?) -> String {
        if let enc: Data = row["enc_content"], !enc.isEmpty {
            if let encryptor, let plain = try? encryptor.decrypt(enc) {
                return plain
            }
            return BlockContentCodec.encode(
                text: AttributedString("[encrypted]"),
                checked: nil
            )
        }
        return row["content_json"] ?? "{}"
    }
}
