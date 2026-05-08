import Foundation

/// One row in the filter bar above a database table. Each filter binds
/// to a single property by key and carries a type-specific predicate.
struct Filter: Equatable, Sendable, Identifiable {
    let id: String
    var propertyKey: String
    var predicate: FilterPredicate

    init(propertyKey: String, predicate: FilterPredicate) {
        self.id = UUID().uuidString
        self.propertyKey = propertyKey
        self.predicate = predicate
    }
}

/// Per-type predicate. Each case carries enough state to evaluate against
/// a record's cell value (`record.values[key]` or `record.relationTargets[key]`).
enum FilterPredicate: Equatable, Sendable {
    /// `relation` — record matches if the record's outgoing relations on
    /// this property include any of these target record IDs. Empty array
    /// means "no filter applied" (predicate is a no-op).
    case relationIsAnyOf([String])
    /// `date` — inclusive range. Either bound may be `nil` for an
    /// open-ended range. Both `nil` is a no-op.
    case dateRange(from: Date?, to: Date?)
    /// `select` — record matches if its value is in the given set. Empty
    /// set is a no-op.
    case selectIsAnyOf([String])
    /// `text` / `title` — case-insensitive substring match. Empty string
    /// is a no-op.
    case textContains(String)
    /// `number` / `currency` — inclusive numeric range. Either bound
    /// may be `nil`. Both `nil` is a no-op.
    case numberRange(min: Double?, max: Double?)
    /// `checkbox` — `nil` is a no-op; `true`/`false` matches the value.
    case checkbox(Bool?)

    /// True when this predicate should be ignored (no filtering effect).
    /// Used so an "empty filter" still appears in the UI for editing
    /// without filtering anything out.
    var isNoOp: Bool {
        switch self {
        case .relationIsAnyOf(let ids):  return ids.isEmpty
        case .dateRange(let f, let t):   return f == nil && t == nil
        case .selectIsAnyOf(let v):      return v.isEmpty
        case .textContains(let s):       return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .numberRange(let mn, let mx): return mn == nil && mx == nil
        case .checkbox(let b):           return b == nil
        }
    }
}

/// Apply every active filter to a record set, AND-combined.
enum FilterEngine {
    static func apply(_ filters: [Filter], to records: [RecordRow], properties: [PropertyRow]) -> [RecordRow] {
        let active = filters.filter { !$0.predicate.isNoOp }
        guard !active.isEmpty else { return records }
        let propsByKey: [String: PropertyRow] = Dictionary(uniqueKeysWithValues: properties.map { ($0.key, $0) })
        return records.filter { record in
            active.allSatisfy { match($0, record: record, prop: propsByKey[$0.propertyKey]) }
        }
    }

    private static func match(_ filter: Filter, record: RecordRow, prop: PropertyRow?) -> Bool {
        switch filter.predicate {
        case .relationIsAnyOf(let ids):
            let targets = record.relationTargets[filter.propertyKey] ?? []
            let targetIDs = Set(targets.map(\.recordID))
            return !targetIDs.isDisjoint(with: ids)

        case .dateRange(let from, let to):
            guard let raw = filter.propertyKey == "title" ? nil : record.values[filter.propertyKey],
                  let parsed = DateValueCodec.parse(raw)
            else { return false }
            if let from, parsed < startOfDay(from) { return false }
            if let to, parsed > endOfDay(to) { return false }
            return true

        case .selectIsAnyOf(let values):
            let raw = record.values[filter.propertyKey] ?? ""
            return values.contains(raw)

        case .textContains(let needle):
            let haystack = filter.propertyKey == "title"
                ? record.title
                : (record.values[filter.propertyKey] ?? "")
            return haystack.range(of: needle, options: .caseInsensitive) != nil

        case .numberRange(let lower, let upper):
            guard let raw = record.values[filter.propertyKey], let value = Double(raw)
            else { return false }
            if let lower, value < lower { return false }
            if let upper, value > upper { return false }
            return true

        case .checkbox(let want):
            guard let want else { return true }
            let raw = (record.values[filter.propertyKey] ?? "").lowercased()
            let isOn = (raw == "true" || raw == "1" || raw == "yes")
            return want == isOn
        }
    }

    private static func startOfDay(_ d: Date) -> Date {
        Calendar.current.startOfDay(for: d)
    }
    private static func endOfDay(_ d: Date) -> Date {
        Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: startOfDay(d)) ?? d
    }
}

/// Build a fresh empty predicate appropriate for the property type.
/// Used when the user picks a column from the "+ Filter" menu.
enum FilterPredicateFactory {
    static func empty(for type: PropertyType) -> FilterPredicate {
        switch type {
        case .relation:                      return .relationIsAnyOf([])
        case .date, .dateRange:              return .dateRange(from: nil, to: nil)
        case .select, .multiSelect, .status: return .selectIsAnyOf([])
        case .number, .currency:             return .numberRange(min: nil, max: nil)
        case .checkbox:                      return .checkbox(nil)
        default:                             return .textContains("")
        }
    }
}
