import Foundation

/// Inverse of `MarkdownBlockConverter.parse` — turns a sorted list of
/// editor blocks back into a Markdown body suitable for writing into
/// a sidecar `.md` file. The transform is intentionally lossy in only
/// one direction: AttributedString attributes that aren't part of the
/// supported inline-markdown set (font / paragraphStyle / custom
/// keys) are dropped, but all the inline markup the parser knows how
/// to read (bold, italic, code, links) is re-emitted faithfully so
/// that round-tripping the same block list produces stable output.
///
/// **Round-trip invariant**: for any blocks `B` produced by parsing
/// markdown `M`, `parse(serialize(B)) == B`. This is what makes the
/// DB-canonical / file-canonical bidirectional sync stable —
/// re-import after a write-back must not produce edits.
enum BlockMarkdownSerializer {
    /// Convert a sorted (by sort_index) list of blocks to a single
    /// Markdown string. Blocks are separated by exactly one blank
    /// line; consecutive bullets / numbered items / checklists stay
    /// adjacent as a single list block in the output (parser will
    /// re-group them automatically on read).
    static func serialize(_ blocks: [BlockRow]) -> String {
        var out: [String] = []
        var prevKind: BlockKind? = nil

        for (index, block) in blocks.enumerated() {
            let line = render(block, numberedIndex: numberedIndex(in: blocks, at: index))

            // Insert a blank-line separator BETWEEN distinct block
            // groups. Same-kind list blocks (bulleted/numbered/
            // checklist) coalesce in markdown without a blank line.
            if let prev = prevKind, !out.isEmpty {
                let listKinds: Set<BlockKind> = [.bulleted, .numbered, .checklist]
                let bothInSameListGroup = (prev == block.kind) && listKinds.contains(prev)
                if !bothInSameListGroup {
                    out.append("")
                }
            }
            out.append(line)
            prevKind = block.kind
        }
        var body = out.joined(separator: "\n")
        if !body.hasSuffix("\n") { body += "\n" }
        return body
    }

    /// 1-based ordinal of a numbered-list block within its consecutive
    /// run. Resets when the run is broken by any other block kind.
    /// Markdown auto-numbers, so technically every line could be `1.`
    /// and renderers would still number sequentially — but emitting
    /// the actual position keeps the source human-readable.
    private static func numberedIndex(in blocks: [BlockRow], at idx: Int) -> Int {
        guard blocks[idx].kind == .numbered else { return 1 }
        var n = 1
        var i = idx - 1
        while i >= 0, blocks[i].kind == .numbered {
            n += 1
            i -= 1
        }
        return n
    }

    private static func render(_ block: BlockRow, numberedIndex: Int) -> String {
        let text = inlineMarkdown(from: block.text)
        switch block.kind {
        case .heading1:  return "# \(text)"
        case .heading2:  return "## \(text)"
        case .heading3:  return "### \(text)"
        case .quote:     return "> \(text)"
        case .bulleted:  return "- \(text)"
        case .numbered:  return "\(numberedIndex). \(text)"
        case .checklist:
            let mark = (block.checked ?? false) ? "x" : " "
            return "- [\(mark)] \(text)"
        case .divider:   return "---"
        case .table:     return renderTable(block.tableData)
        case .paragraph: return text
        }
    }

    private static func renderTable(_ table: BlockTableData?) -> String {
        guard let table else { return "" }
        var lines: [String] = []
        // Header row + separator. SQLite rendering tolerates an empty
        // header row, so we still emit `| | | |` rather than skipping
        // when headers are blank — keeps the table parseable.
        let headerCells = table.headers.isEmpty
            ? Array(repeating: "", count: max(1, table.rows.first?.count ?? 1))
            : table.headers
        lines.append("| " + headerCells.map(escapeCell).joined(separator: " | ") + " |")
        lines.append("|" + String(repeating: " --- |", count: headerCells.count))
        for row in table.rows {
            // Pad ragged rows up to the header column count.
            var cells = row
            while cells.count < headerCells.count { cells.append("") }
            lines.append("| " + cells.map(escapeCell).joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    private static func escapeCell(_ s: String) -> String {
        // Pipes inside a cell would break the row split. Backslash-
        // escape per CommonMark / GFM table convention.
        s.replacingOccurrences(of: "|", with: "\\|")
    }

    /// Re-emit an `AttributedString` as inline-markdown text by
    /// walking runs and wrapping each run's characters with the
    /// markup that produced its attributes:
    ///   - `inlinePresentationIntent.code` → `` `…` ``
    ///   - `inlinePresentationIntent.stronglyEmphasized` → `**…**`
    ///   - `inlinePresentationIntent.emphasized` → `*…*`
    ///   - `link` → `[…](url)`
    /// Order is innermost → outermost so the result parses back to
    /// the same attribute set. Attributes outside this set are
    /// dropped silently (font/color/etc. don't have a canonical
    /// markdown source).
    static func inlineMarkdown(from attr: AttributedString) -> String {
        var out = ""
        for run in attr.runs {
            var chunk = String(attr[run.range].characters)
            if chunk.isEmpty { continue }
            if let presentation = run.inlinePresentationIntent {
                if presentation.contains(.code) {
                    chunk = "`\(chunk)`"
                }
                if presentation.contains(.emphasized) {
                    chunk = "*\(chunk)*"
                }
                if presentation.contains(.stronglyEmphasized) {
                    chunk = "**\(chunk)**"
                }
            }
            if let url = run.link {
                chunk = "[\(chunk)](\(url.absoluteString))"
            }
            out += chunk
        }
        return out
    }
}
