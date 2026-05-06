import SwiftUI

/// Block-level Markdown renderer for Keystone Help docs.
///
/// Supports: H1/H2/H3, paragraphs, bullet (`- ` or `* `) and numbered (`1. `)
/// lists, code blocks (fenced ` ``` `), dividers (`---`), blockquotes (`> `).
/// Inline content within a block (bold, italic, links, inline code) is parsed
/// via Foundation's `AttributedString(markdown:)`.
struct MarkdownView: View {
    let source: String

    private var blocks: [MarkdownBlock] {
        MarkdownParser.parse(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(text)
                .font(headingFont(level: level))
                .foregroundStyle(KstColor.ink0)
                .padding(.top, headingTopPadding(level: level))
                .padding(.bottom, 6)

        case let .paragraph(text):
            Text(text)
                .font(.kstText(size: 14))
                .foregroundStyle(KstColor.ink1)
                .lineSpacing(4)
                .padding(.bottom, 10)

        case let .bulletItem(text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .font(.kstText(size: 14))
                    .foregroundStyle(KstColor.ink2)
                    .frame(width: 12, alignment: .leading)
                Text(text)
                    .font(.kstText(size: 14))
                    .foregroundStyle(KstColor.ink1)
                    .lineSpacing(3)
            }
            .padding(.bottom, 4)

        case let .numberedItem(number, text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .font(.kstText(size: 14))
                    .foregroundStyle(KstColor.ink2)
                    .frame(width: 18, alignment: .leading)
                Text(text)
                    .font(.kstText(size: 14))
                    .foregroundStyle(KstColor.ink1)
                    .lineSpacing(3)
            }
            .padding(.bottom, 4)

        case let .codeBlock(code):
            Text(code)
                .font(.kstMono(size: 12))
                .foregroundStyle(KstColor.ink0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(KstColor.paper2)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.bottom, 12)

        case .divider:
            Rectangle()
                .fill(KstColor.ink4)
                .frame(height: 0.5)
                .padding(.vertical, 14)

        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(KstColor.ink4)
                    .frame(width: 2)
                Text(text)
                    .font(.kstText(size: 14).italic())
                    .foregroundStyle(KstColor.ink2)
                    .lineSpacing(4)
            }
            .padding(.bottom, 10)
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: .kstDisplay(size: 28, weight: .semibold)
        case 2: .kstDisplay(size: 20, weight: .semibold)
        default: .kstDisplay(size: 16, weight: .semibold)
        }
    }
    private func headingTopPadding(level: Int) -> CGFloat {
        switch level {
        case 1: 24
        case 2: 18
        default: 14
        }
    }
}

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case bulletItem(AttributedString)
    case numberedItem(number: Int, text: AttributedString)
    case codeBlock(String)
    case divider
    case quote(AttributedString)
}

enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MarkdownBlock] = []
        var paragraphBuffer: [String] = []
        var quoteBuffer: [String] = []
        var inCodeBlock = false
        var codeBuffer: [String] = []

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let joined = paragraphBuffer.joined(separator: " ")
            blocks.append(.paragraph(inline(joined)))
            paragraphBuffer.removeAll()
        }
        func flushQuote() {
            guard !quoteBuffer.isEmpty else { return }
            let joined = quoteBuffer.joined(separator: " ")
            blocks.append(.quote(inline(joined)))
            quoteBuffer.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inCodeBlock {
                if trimmed.hasPrefix("```") {
                    blocks.append(.codeBlock(codeBuffer.joined(separator: "\n")))
                    codeBuffer.removeAll()
                    inCodeBlock = false
                } else {
                    codeBuffer.append(line)
                }
                continue
            }

            // Code fence opens
            if trimmed.hasPrefix("```") {
                flushParagraph()
                flushQuote()
                inCodeBlock = true
                continue
            }

            // Blank line: paragraph/quote boundary
            if trimmed.isEmpty {
                flushParagraph()
                flushQuote()
                continue
            }

            // Divider
            if trimmed == "---" || trimmed == "***" {
                flushParagraph()
                flushQuote()
                blocks.append(.divider)
                continue
            }

            // Heading
            if let heading = parseHeading(trimmed) {
                flushParagraph()
                flushQuote()
                blocks.append(.heading(level: heading.level, text: inline(heading.text)))
                continue
            }

            // Bullet
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                flushQuote()
                let body = String(trimmed.dropFirst(2))
                blocks.append(.bulletItem(inline(body)))
                continue
            }

            // Numbered
            if let numbered = parseNumbered(trimmed) {
                flushParagraph()
                flushQuote()
                blocks.append(.numberedItem(number: numbered.number, text: inline(numbered.text)))
                continue
            }

            // Quote
            if trimmed.hasPrefix("> ") {
                flushParagraph()
                quoteBuffer.append(String(trimmed.dropFirst(2)))
                continue
            }
            if trimmed == ">" {
                flushParagraph()
                quoteBuffer.append("")
                continue
            }

            // Paragraph
            flushQuote()
            paragraphBuffer.append(trimmed)
        }

        flushParagraph()
        flushQuote()
        if inCodeBlock, !codeBuffer.isEmpty {
            blocks.append(.codeBlock(codeBuffer.joined(separator: "\n")))
        }

        return blocks
    }

    private static func parseHeading(_ s: String) -> (level: Int, text: String)? {
        for level in stride(from: 6, through: 1, by: -1) {
            let prefix = String(repeating: "#", count: level) + " "
            if s.hasPrefix(prefix) {
                return (level, String(s.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    private static func parseNumbered(_ s: String) -> (number: Int, text: String)? {
        // Match `<digits>. <rest>`
        var i = s.startIndex
        var digits = ""
        while i < s.endIndex, s[i].isASCII, s[i].isNumber {
            digits.append(s[i])
            i = s.index(after: i)
        }
        guard !digits.isEmpty,
              i < s.endIndex,
              s[i] == ".",
              s.index(after: i) < s.endIndex,
              s[s.index(after: i)] == " " else { return nil }
        let rest = String(s[s.index(i, offsetBy: 2)...])
        return (Int(digits) ?? 0, rest)
    }

    private static func inline(_ s: String) -> AttributedString {
        // Foundation's default Markdown parser handles bold, italic, links,
        // inline code, strikethrough.
        if let attr = try? AttributedString(
            markdown: s,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return attr
        }
        return AttributedString(s)
    }
}
