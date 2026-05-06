import Foundation

struct BlockContentJSON: Codable, Equatable, Sendable {
    var text: AttributedString?
    var checked: Bool?
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
            checked: checked
        )
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
}
