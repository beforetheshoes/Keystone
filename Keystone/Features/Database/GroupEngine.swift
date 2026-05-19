import Foundation

/// A bucketed view of records, produced by `GroupEngine.group`. The
/// bucket label is rendered as a section header; `rows` are the records
/// in that bucket in their input order (group preserves the caller's
/// sort).
struct RecordGroup: Equatable, Sendable {
    /// Display label for the section header. Empty / missing values land
    /// in `"—"`.
    let label: String
    /// Raw property-value key for the bucket (so callers can persist
    /// collapsed state by key, not by display label).
    let key: String
    let rows: [RecordRow]
}

enum GroupEngine {
    /// Bucket `records` by their value at `key`. When `key` is nil or
    /// no property matches, returns a single ungrouped bucket. The order
    /// of buckets follows the property's option list (for `.select` /
    /// `.status`) or alphabetical (for everything else), with an "—"
    /// bucket at the end for records whose value is missing.
    static func group(
        _ records: [RecordRow],
        key: String?,
        properties: [PropertyRow]
    ) -> [RecordGroup] {
        guard let key, !key.isEmpty else {
            return [RecordGroup(label: "", key: "", rows: records)]
        }
        let property = properties.first { $0.key == key }

        var byBucket: [String: [RecordRow]] = [:]
        var firstSeen: [String: Int] = [:]
        for (i, rec) in records.enumerated() {
            let buckets = bucketKeys(for: rec, key: key, property: property)
            for b in buckets {
                byBucket[b, default: []].append(rec)
                if firstSeen[b] == nil { firstSeen[b] = i }
            }
        }

        let bucketOrder = orderedBuckets(byBucket.keys, property: property, firstSeen: firstSeen)
        return bucketOrder.map { bucketKey in
            RecordGroup(
                label: displayLabel(forBucket: bucketKey, property: property),
                key: bucketKey,
                rows: byBucket[bucketKey] ?? []
            )
        }
    }

    /// One record may produce more than one bucket when the property is
    /// `multiSelect` (a book tagged "fiction|mystery" appears in both
    /// groups). Other types produce exactly one bucket.
    private static func bucketKeys(
        for record: RecordRow,
        key: String,
        property: PropertyRow?
    ) -> [String] {
        let raw = record.values[key] ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [emptyBucket] }

        if property?.type == .multiSelect {
            let parts = MultiSelectValue.decode(trimmed)
            return parts.isEmpty ? [emptyBucket] : parts
        }
        if property?.type == .address {
            // Address values are stored as JSON. Bucket by the parsed
            // city so "Restaurants grouped by Address" reads as
            // "Mebane, NC" / "Boulder, CO" instead of one bucket per
            // distinct street address. Fall back to the trimmed JSON
            // (effectively one bucket per record) when the value
            // isn't structured — that's still better than dropping
            // the bucket.
            if let parsed = AddressValueCodec.parse(trimmed) {
                if let city = parsed.city, !city.isEmpty {
                    if let region = parsed.region, !region.isEmpty {
                        return ["\(city), \(region)"]
                    }
                    return [city]
                }
                return [parsed.display]
            }
            return [trimmed]
        }
        return [trimmed]
    }

    private static let emptyBucket = "\u{0001}empty"

    private static func displayLabel(forBucket bucket: String, property: PropertyRow?) -> String {
        if bucket == emptyBucket { return "—" }
        // Route select / multiSelect buckets through the display
        // formatter so `"want_to_try"` reads as "Want to try" in the
        // section header. Other property types (raw text, dates,
        // numbers grouped by exact value) stay verbatim.
        switch property?.type {
        case .select, .multiSelect, .status:
            return SelectOptionDisplay.format(bucket)
        default:
            return bucket
        }
    }

    private static func orderedBuckets(
        _ keys: Dictionary<String, [RecordRow]>.Keys,
        property: PropertyRow?,
        firstSeen: [String: Int]
    ) -> [String] {
        var others = keys.filter { $0 != emptyBucket }

        if let options = property?.config.options, !options.isEmpty {
            // Stable: known options in declared order, then any other
            // values in first-seen order, then the empty bucket.
            let known = options.filter { others.contains($0) }
            let unknown = others
                .filter { !options.contains($0) }
                .sorted { (firstSeen[$0] ?? 0) < (firstSeen[$1] ?? 0) }
            others = known + unknown
        } else {
            others = others.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }

        if keys.contains(emptyBucket) { others.append(emptyBucket) }
        return others
    }
}
