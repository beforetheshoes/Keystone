import Foundation

/// Parsed YAML-style frontmatter from the head of a Markdown file.
struct Frontmatter: Equatable, Sendable {
    /// Lowercased value of the `type:` key. Used to route Inbox imports to a
    /// specific database. `nil` if the source had no `type:` line.
    var type: String?
    /// Value of the `title:` key, preserving original case. `nil` if absent.
    var title: String?
    /// Every other top-level key (lowercased) → its raw string value. Lists,
    /// nested mappings, and folded scalars are not supported and arrive here
    /// as the raw post-colon text.
    var fields: [String: String]
}

enum FrontmatterParser {
    /// Splits a Markdown source into its leading frontmatter block (if any)
    /// and the rest of the body. Intentionally narrow — handles `key: value`
    /// pairs, single/double-quoted strings, and `#` comments. Anything more
    /// exotic round-trips as an opaque string.
    static func parse(_ source: String) -> (frontmatter: Frontmatter?, body: String) {
        let lines = source.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return (nil, source)
        }

        var closeIndex: Int?
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closeIndex = i
                break
            }
        }
        guard let closeIndex else { return (nil, source) }

        var fm = Frontmatter(type: nil, title: nil, fields: [:])
        for i in 1..<closeIndex {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            value = unquote(value)
            guard !key.isEmpty else { continue }

            switch key {
            case "type":
                fm.type = value.lowercased()
            case "title":
                fm.title = value
            default:
                fm.fields[key] = value
            }
        }

        let bodyLines = lines.suffix(from: closeIndex + 1)
        let body = bodyLines.joined(separator: "\n")
        return (fm, body)
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let first = s.first!
        let last = s.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
