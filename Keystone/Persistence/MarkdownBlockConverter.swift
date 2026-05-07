import Foundation

/// Convert a Markdown body (typically the post-frontmatter content of an
/// `.md` file imported from Inbox) into a sequence of `BlockKind` /
/// `AttributedString` pairs suitable for `DBWrites.createBlock`.
///
/// Intentionally narrow — handles the structural elements the in-app block
/// editor supports (headings, bulleted/numbered/checklist lists, blockquotes,
/// dividers, paragraphs). Markdown tables aren't a native block kind, so each
/// table row is emitted as its own paragraph with cells joined by `   ·   `
/// so the data is preserved and readable inline.
struct ParsedBlock {
    var kind: BlockKind
    var text: AttributedString
    var checked: Bool? = nil
    var tableData: BlockTableData? = nil
}

enum MarkdownBlockConverter {
    /// Plain-text projection of a parsed block, used for de-duplication.
    /// Strips inline markdown markers so two paragraphs that differ only
    /// in `**bold**` vs not still match.
    private static func plainKey(_ block: ParsedBlock) -> String {
        if block.kind == .table {
            // Tables are de-duped separately by their own data; never
            // collapse a table into a sibling paragraph by accident.
            return ""
        }
        let raw = String(block.text.characters)
        return raw
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "*",  with: "")
            .replacingOccurrences(of: "_",  with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drop two duplicate-shaped artifacts that show up in our PDF→MD
    /// source files:
    ///
    /// 1. Adjacent blocks with identical plain text (the source markdown
    ///    has each header line duplicated for some reason — see
    ///    `2026-01-16 - CR-V - Inspection` for the canonical example).
    /// 2. A paragraph immediately after a `.table` block whose text is
    ///    the same data flattened with `·` separators (the PDF→MD tool
    ///    emits the table *and* a stringified version of it, presumably
    ///    as fallback for renderers that don't support tables).
    private static func deduplicate(_ blocks: [ParsedBlock]) -> [ParsedBlock] {
        var out: [ParsedBlock] = []
        out.reserveCapacity(blocks.count)
        for block in blocks {
            // Rule 1: adjacent identical text.
            if let last = out.last,
               last.kind == block.kind,
               !plainKey(block).isEmpty,
               plainKey(last) == plainKey(block) {
                continue
            }
            // Rule 2: paragraph that flattens the prior table.
            if block.kind == .paragraph,
               let last = out.last,
               last.kind == .table,
               let table = last.tableData,
               isFlattenedTable(paragraph: String(block.text.characters), table: table) {
                continue
            }
            out.append(block)
        }
        return out
    }

    /// True when `paragraph` contains every data cell value of `table`
    /// joined with `·` separators (with or without inline `header:` labels).
    /// Used to detect the duplicate paragraph our source markdown emits
    /// after each table.
    private static func isFlattenedTable(paragraph: String, table: BlockTableData) -> Bool {
        guard !table.rows.isEmpty else { return false }
        let allCells = table.rows.flatMap { $0 }
        // Quick check: paragraph must contain a `·` separator; otherwise
        // it's not a flattened-row paragraph.
        guard paragraph.contains("·") else { return false }
        // High-confidence: ≥75% of distinct non-empty cell values appear
        // verbatim in the paragraph. This catches the PDF→MD tool's
        // output without false-positiving on a paragraph that legitimately
        // mentions one or two of the same values.
        let distinctCells = Set(allCells.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        guard !distinctCells.isEmpty else { return false }
        let hits = distinctCells.filter { paragraph.contains($0) }
        return Double(hits.count) / Double(distinctCells.count) >= 0.75
    }

    static func parse(_ source: String) -> [ParsedBlock] {
        // Strip the leading `[scan](file)` line we add at import time so
        // it doesn't show up in the record's notes.
        var body = source
        if let firstNewline = body.firstIndex(of: "\n") {
            let firstLine = body[..<firstNewline].trimmingCharacters(in: .whitespaces)
            if firstLine.hasPrefix("[scan](") {
                body = String(body[body.index(after: firstNewline)...])
            }
        }

        var blocks: [ParsedBlock] = []
        var paragraphLines: [String] = []
        let lines = body.components(separatedBy: "\n")

        // Group runs of non-soft-break lines into single paragraph blocks
        // (markdown spec: consecutive lines without `  ` form one paragraph),
        // and emit each line ending with `  ` (soft break) as its own
        // paragraph. This respects how the user's content is structured:
        // key:value lines end with `  ` and become per-line paragraphs;
        // flowing prose (no soft breaks) stays as one paragraph.
        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            var run: [String] = []
            func emitRun() {
                let joined = run
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                run.removeAll()
                if !joined.isEmpty {
                    blocks.append(.init(kind: .paragraph, text: attributed(joined), checked: nil))
                }
            }
            for raw in paragraphLines {
                if raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                run.append(raw)
                if raw.hasSuffix("  ") {
                    emitRun()
                }
            }
            emitRun()
            paragraphLines.removeAll()
        }

        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // Blank line → end paragraph
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.init(kind: .divider, text: AttributedString(), checked: nil))
                i += 1
                continue
            }

            // Heading
            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(.init(kind: heading.kind, text: attributed(heading.text), checked: nil))
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix("> ") {
                flushParagraph()
                let text = String(trimmed.dropFirst(2))
                blocks.append(.init(kind: .quote, text: attributed(text), checked: nil))
                i += 1
                continue
            }

            // Checklist item: "- [ ] foo" / "- [x] foo" (also `*` / `+`)
            if let checklist = parseChecklist(trimmed) {
                flushParagraph()
                blocks.append(.init(kind: .checklist, text: attributed(checklist.text), checked: checklist.checked))
                i += 1
                continue
            }

            // Bulleted list: "- item" / "* item" / "+ item"
            if let bullet = parseBullet(trimmed) {
                flushParagraph()
                blocks.append(.init(kind: .bulleted, text: attributed(bullet), checked: nil))
                i += 1
                continue
            }

            // Numbered list: "1. item"
            if let numbered = parseNumbered(trimmed) {
                flushParagraph()
                blocks.append(.init(kind: .numbered, text: attributed(numbered), checked: nil))
                i += 1
                continue
            }

            // Markdown table: line starts with `|` and a separator row exists
            // immediately below. Emit as a real `.table` block so the
            // editor can render it as an actual grid (rather than faking
            // it with paragraphs of separator-joined cells).
            if trimmed.hasPrefix("|"), i + 1 < lines.count,
               isTableSeparator(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph()
                let header = parseTableRow(trimmed)
                i += 2 // skip header + separator

                var rows: [[String]] = []
                while i < lines.count {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    guard row.hasPrefix("|") else { break }
                    let cells = parseTableRow(row)
                    if !cells.isEmpty { rows.append(cells) }
                    i += 1
                }

                let table = BlockTableData(headers: header, rows: rows)
                blocks.append(.init(
                    kind: .table,
                    text: AttributedString(),
                    checked: nil,
                    tableData: table
                ))
                continue
            }

            // Default: accumulate into the current paragraph. We strip
            // trailing markdown line-break markers (two spaces) since the
            // editor doesn't render them.
            paragraphLines.append(raw)
            i += 1
        }
        flushParagraph()
        return deduplicate(blocks)
    }

    // MARK: - Element parsers

    private static func parseHeading(_ line: String) -> (kind: BlockKind, text: String)? {
        if line.hasPrefix("### ") { return (.heading3, String(line.dropFirst(4))) }
        if line.hasPrefix("## ")  { return (.heading2, String(line.dropFirst(3))) }
        if line.hasPrefix("# ")   { return (.heading1, String(line.dropFirst(2))) }
        return nil
    }

    private static func parseChecklist(_ line: String) -> (text: String, checked: Bool)? {
        // Strip the bullet character first (`-`, `*`, `+`)
        guard let after = stripBulletPrefix(line) else { return nil }
        if after.hasPrefix("[ ] ") { return (String(after.dropFirst(4)), false) }
        if after.hasPrefix("[x] ") || after.hasPrefix("[X] ") { return (String(after.dropFirst(4)), true) }
        return nil
    }

    private static func parseBullet(_ line: String) -> String? {
        stripBulletPrefix(line)
    }

    private static func stripBulletPrefix(_ line: String) -> String? {
        guard line.count >= 2 else { return nil }
        let first = line.first!
        let second = line[line.index(after: line.startIndex)]
        guard (first == "-" || first == "*" || first == "+"), second == " " else { return nil }
        return String(line.dropFirst(2))
    }

    private static func parseNumbered(_ line: String) -> String? {
        // Accept `<digits>. ` or `<digits>) ` as the prefix.
        var idx = line.startIndex
        while idx < line.endIndex, line[idx].isNumber { idx = line.index(after: idx) }
        guard idx > line.startIndex, idx < line.endIndex else { return nil }
        let separator = line[idx]
        guard separator == "." || separator == ")" else { return nil }
        let after = line.index(after: idx)
        guard after < line.endIndex, line[after] == " " else { return nil }
        return String(line[line.index(after: after)...])
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.hasPrefix("|") else { return false }
        // Cells must be made entirely of `-`, `:`, `|`, and whitespace.
        let allowed: Set<Character> = ["-", ":", "|", " ", "\t"]
        return line.allSatisfy { allowed.contains($0) }
    }

    private static func parseTableRow(_ line: String) -> [String] {
        var s = line
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Build an `AttributedString` from a line that may contain inline
    /// Markdown (bold/italic/links). Falls back to plain text on parse
    /// failure so we never drop content.
    private static func attributed(_ text: String) -> AttributedString {
        // Strip trailing two-space "soft break" markers — they confuse the
        // SwiftUI renderer and we already handle line breaks at the block
        // level.
        var cleaned = text
        while cleaned.hasSuffix("  ") { cleaned.removeLast() }
        if let parsed = try? AttributedString(
            markdown: cleaned,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return parsed
        }
        return AttributedString(cleaned)
    }
}
