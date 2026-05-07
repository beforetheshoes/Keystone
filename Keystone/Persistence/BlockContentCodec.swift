import Foundation

/// Tabular payload for `.table` blocks. Header row is optional; data
/// rows can be ragged (the renderer tolerates short rows by padding
/// with empty cells).
struct BlockTableData: Codable, Equatable, Sendable {
    var headers: [String]
    var rows: [[String]]
}

struct BlockContentJSON: Codable, Equatable, Sendable {
    var text: AttributedString?
    var checked: Bool?
    /// Set on `.table`-kind blocks. The `text` field on a table is
    /// ignored; this is the payload.
    var tableData: BlockTableData?
}

enum BlockContentCodec {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder = JSONDecoder()

    static func encode(text: AttributedString, checked: Bool?) -> String {
        let payload = BlockContentJSON(
            text: text.characters.isEmpty ? nil : text,
            checked: checked,
            tableData: nil
        )
        guard let data = try? encoder.encode(payload),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    /// Encode a table block. Tables don't carry editable text — the
    /// `text` slot is left empty and `tableData` carries the payload.
    static func encodeTable(_ table: BlockTableData) -> String {
        let payload = BlockContentJSON(text: nil, checked: nil, tableData: table)
        guard let data = try? encoder.encode(payload),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    static func decode(_ json: String) -> (text: AttributedString, checked: Bool?) {
        guard let data = json.data(using: .utf8),
              let payload = try? decoder.decode(BlockContentJSON.self, from: data) else {
            return (AttributedString(), nil)
        }
        return (payload.text ?? AttributedString(), payload.checked)
    }

    static func decodeTable(_ json: String) -> BlockTableData? {
        guard let data = json.data(using: .utf8),
              let payload = try? decoder.decode(BlockContentJSON.self, from: data) else {
            return nil
        }
        return payload.tableData
    }
}
