import Foundation

/// Sort `records` by the value at a single property key. Mirrors the
/// table column-header sort, but pulled out so the gallery, list, and
/// table views can share a single implementation.
///
/// Numbers and dates compare numerically; selects compare by their
/// position in the property's option list (so "to_read → reading → read"
/// sorts that way, not alphabetically); everything else compares
/// case-insensitively as text. Records whose cell is empty sort to the
/// end of an ascending list (and the front of a descending list — the
/// caller would reverse if it wanted them grouped together).
enum SortEngine {
    static func apply(
        _ records: [RecordRow],
        key: String?,
        ascending: Bool,
        properties: [PropertyRow]
    ) -> [RecordRow] {
        guard let key, !key.isEmpty else { return records }
        let prop = properties.first { $0.key == key }
        let comparator = comparator(for: prop, key: key)
        let sorted = records.sorted { a, b in
            switch comparator(a, b) {
            case .orderedAscending:  return ascending
            case .orderedDescending: return !ascending
            case .orderedSame:       return false
            }
        }
        return sorted
    }

    private static func comparator(
        for property: PropertyRow?,
        key: String
    ) -> (RecordRow, RecordRow) -> ComparisonResult {
        // Title is special — its value lives on `RecordRow.title`,
        // not in `values`. Match on either the literal key "title"
        // (legacy) or any property whose type is `.title` so a
        // property keyed `"name"` (as seeded for every database)
        // still sorts on the record's actual title.
        if key == "title" || property?.type == .title {
            return { a, b in
                textCompare(a.title, b.title)
            }
        }

        guard let property else {
            return { a, b in
                textCompare(a.values[key] ?? "", b.values[key] ?? "")
            }
        }

        switch property.type {
        case .number, .currency:
            return { a, b in
                let av = Double(a.values[key] ?? "")
                let bv = Double(b.values[key] ?? "")
                return numericCompare(av, bv)
            }

        case .date, .dateTZ, .dateRange:
            return { a, b in
                let av = parseDate(a.values[key] ?? "")
                let bv = parseDate(b.values[key] ?? "")
                return numericCompare(av, bv)
            }

        case .checkbox:
            return { a, b in
                let av = boolValue(a.values[key])
                let bv = boolValue(b.values[key])
                if av == bv { return .orderedSame }
                return av ? .orderedDescending : .orderedAscending
            }

        case .select, .status:
            let options = property.config.options ?? []
            let indexOf: (String) -> Int = { value in
                if value.isEmpty { return Int.max }
                return options.firstIndex(of: value) ?? Int.max - 1
            }
            return { a, b in
                let ai = indexOf(a.values[key] ?? "")
                let bi = indexOf(b.values[key] ?? "")
                if ai == bi { return textCompare(a.values[key] ?? "", b.values[key] ?? "") }
                return ai < bi ? .orderedAscending : .orderedDescending
            }

        default:
            return { a, b in
                textCompare(a.values[key] ?? "", b.values[key] ?? "")
            }
        }
    }

    private static func textCompare(_ a: String, _ b: String) -> ComparisonResult {
        let aEmpty = a.trimmingCharacters(in: .whitespaces).isEmpty
        let bEmpty = b.trimmingCharacters(in: .whitespaces).isEmpty
        if aEmpty && bEmpty { return .orderedSame }
        if aEmpty { return .orderedDescending }   // empty sorts after
        if bEmpty { return .orderedAscending }
        return a.localizedCaseInsensitiveCompare(b)
    }

    private static func numericCompare(_ a: Double?, _ b: Double?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _):   return .orderedDescending     // empty sorts after
        case (_, nil):   return .orderedAscending
        case let (av?, bv?):
            if av == bv { return .orderedSame }
            return av < bv ? .orderedAscending : .orderedDescending
        }
    }

    private static func parseDate(_ raw: String) -> Double? {
        if let tz = DateValueCodec.parseTZ(raw) {
            return tz.date.timeIntervalSince1970
        }
        if let plain = DateValueCodec.parse(raw) {
            return plain.timeIntervalSince1970
        }
        return nil
    }

    private static func boolValue(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.lowercased() {
        case "true", "1", "yes": return true
        default: return false
        }
    }
}
