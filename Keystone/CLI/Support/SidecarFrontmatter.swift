import Foundation

/// Order-preserving YAML-frontmatter parser/writer for the Cars sidecar
/// markdown files. The existing `FrontmatterParser` is read-only and
/// drops key order via its `[String: String]` field map; backfilling
/// would scramble the user's hand-curated frontmatter on round-trip,
/// so this file owns its own representation.
///
/// Only the narrow subset used by the sidecars is supported:
/// `key: value`, single/double-quoted scalars, and integer/decimal
/// numbers. Lists are written as JSON-style flow arrays
/// (`services: [a, b, c]`) and parsed back the same way. Anything more
/// exotic round-trips as an opaque string.
struct SidecarDocument: Equatable {
    struct Field: Equatable {
        var key: String
        var value: SidecarValue
    }

    /// Ordered field list. Re-emit in this order on write so the user's
    /// curated key order is preserved across backfill runs.
    var fields: [Field]
    /// The post-frontmatter Markdown body, including the leading `[scan]`
    /// link. Empty string when the file had no frontmatter.
    var body: String

    enum SidecarValue: Equatable {
        case string(String)
        case integer(Int)
        case stringList([String])

        var isEmpty: Bool {
            switch self {
            case .string(let s): return s.trimmingCharacters(in: .whitespaces).isEmpty
            case .integer: return false
            case .stringList(let xs): return xs.isEmpty
            }
        }
    }

    func value(for key: String) -> SidecarValue? {
        fields.first { $0.key == key }?.value
    }

    /// Set a field's value, replacing if present (in place) or appending
    /// at the end of the field list. The `replaceIfEmpty` flag (default
    /// true) preserves manually-set values: pass `false` to clobber.
    mutating func set(_ key: String, to value: SidecarValue, replaceIfEmpty: Bool = true) {
        if let idx = fields.firstIndex(where: { $0.key == key }) {
            if replaceIfEmpty, !fields[idx].value.isEmpty { return }
            fields[idx] = Field(key: key, value: value)
        } else {
            fields.append(Field(key: key, value: value))
        }
    }
}

enum SidecarFrontmatter {
    /// Parse a sidecar markdown file. Returns a document with empty
    /// frontmatter (and the entire input as `body`) if the file has no
    /// `---` block.
    static func parse(_ source: String) -> SidecarDocument {
        let lines = source.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return SidecarDocument(fields: [], body: source)
        }
        var closeIndex: Int?
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closeIndex = i
                break
            }
        }
        guard let closeIndex else {
            return SidecarDocument(fields: [], body: source)
        }

        var fields: [SidecarDocument.Field] = []
        for i in 1..<closeIndex {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            fields.append(SidecarDocument.Field(key: key, value: parseScalar(rawValue)))
        }

        let body = lines.suffix(from: closeIndex + 1).joined(separator: "\n")
        return SidecarDocument(fields: fields, body: body)
    }

    /// Re-emit the document as a markdown string with `---`-delimited
    /// frontmatter. Trailing newline matches the original-file
    /// convention. Stable across round-trips.
    static func write(_ doc: SidecarDocument) -> String {
        var out = "---\n"
        for field in doc.fields {
            out += "\(field.key): \(emitScalar(field.value))\n"
        }
        out += "---\n"
        out += doc.body
        // Preserve the trailing newline if the original had one.
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    // MARK: - Scalar handling

    private static func parseScalar(_ raw: String) -> SidecarDocument.SidecarValue {
        // Flow-style array: [a, b, "c d"]
        if raw.hasPrefix("["), raw.hasSuffix("]") {
            let inner = String(raw.dropFirst().dropLast())
            if inner.trimmingCharacters(in: .whitespaces).isEmpty {
                return .stringList([])
            }
            let parts = splitFlowList(inner).map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            return .stringList(parts)
        }
        // Plain integer (no decimal point, no leading zero unless "0").
        if let n = Int(raw), String(n) == raw {
            return .integer(n)
        }
        return .string(unquote(raw))
    }

    private static func splitFlowList(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        for ch in s {
            switch ch {
            case "'" where !inDouble: inSingle.toggle(); current.append(ch)
            case "\"" where !inSingle: inDouble.toggle(); current.append(ch)
            case "," where !inSingle && !inDouble:
                out.append(current); current = ""
            default:
                current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(current)
        }
        return out
    }

    private static func emitScalar(_ value: SidecarDocument.SidecarValue) -> String {
        switch value {
        case .integer(let n):
            return String(n)
        case .string(let s):
            return needsQuoting(s) ? "\"\(escape(s))\"" : s
        case .stringList(let xs):
            let parts = xs.map { needsQuoting($0) ? "\"\(escape($0))\"" : $0 }
            return "[\(parts.joined(separator: ", "))]"
        }
    }

    private static func needsQuoting(_ s: String) -> Bool {
        if s.isEmpty { return true }
        // Quote when the string contains punctuation that YAML would
        // interpret structurally, or when it could be parsed as another
        // scalar type (numbers, booleans). Conservative — quotes are
        // never wrong, just visually heavier.
        let unsafeCharacters: Set<Character> = [":", "#", "[", "]", "{", "}", ",", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`"]
        if s.contains(where: { unsafeCharacters.contains($0) }) { return true }
        if s.first == " " || s.last == " " { return true }
        if Double(s) != nil { return true }
        if ["true", "false", "yes", "no", "null", "~"].contains(s.lowercased()) { return true }
        return false
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
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
