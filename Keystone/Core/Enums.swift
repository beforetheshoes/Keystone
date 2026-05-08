import Foundation

public enum AccentTone: String, Codable, Sendable, CaseIterable, Hashable {
    case cerulean
    case iris
    case sage
    case amber
    case graphite
}

public enum PropertyType: String, Codable, Sendable, CaseIterable, Hashable {
    case title
    case text
    case richText
    case number
    case currency
    case date
    case dateRange
    case checkbox
    case select
    case multiSelect
    case tag
    case relation
    case file
    case url
    case email
    case phone
    case duration
    case status
    case location
    case computed
    case rollup
    case json
}

public enum ViewKind: String, Codable, Sendable, CaseIterable, Hashable {
    case table
    case list
    case gallery
    case calendar
    case timeline
    case kanban
    case dashboard
}

public enum BlockType: String, Codable, Sendable, CaseIterable, Hashable {
    case paragraph
    case heading
    case bulletedList
    case numberedList
    case checklist
    case quote
    case callout
    case divider
    case code
    case image
    case filePreview
    case pdfPreview
    case linkedRecord
    case databaseView
    case propertyDisplay
    case formulaResult
    case templateSection
    case embed
}
