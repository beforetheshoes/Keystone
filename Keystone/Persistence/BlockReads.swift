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
    static func blocks(_ db: Database, recordID: String) throws -> [BlockRow] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, record_id, type, content_json, sort_index
            FROM blocks
            WHERE record_id = ? AND deleted_at IS NULL
            ORDER BY sort_index
        """, arguments: [recordID])

        return rows.compactMap { row -> BlockRow? in
            guard let kind = BlockKind(rawValue: row["type"]) else { return nil }
            let json: String = row["content_json"] ?? "{}"
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
}
