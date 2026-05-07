import Foundation

enum BlockKind: String, Codable, Sendable, CaseIterable, Hashable {
    case paragraph
    case heading1
    case heading2
    case heading3
    case bulleted
    case numbered
    case checklist
    case quote
    case divider
    case table

    var displayName: String {
        switch self {
        case .paragraph: "Paragraph"
        case .heading1:  "Heading 1"
        case .heading2:  "Heading 2"
        case .heading3:  "Heading 3"
        case .bulleted:  "Bulleted list"
        case .numbered:  "Numbered list"
        case .checklist: "Checklist"
        case .quote:     "Quote"
        case .divider:   "Divider"
        case .table:     "Table"
        }
    }

    /// True for blocks whose primary payload is the AttributedString
    /// `text`. Tables and dividers carry their content elsewhere
    /// (`tableData` and nothing, respectively).
    var hasTextContent: Bool {
        switch self {
        case .divider, .table: false
        default: true
        }
    }
}
