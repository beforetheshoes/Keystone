import Foundation

/// Encode / decode the on-disk representation of a `multiSelect` property
/// value. We store the list as a single delimiter-separated string in
/// `property_values.text_value`, e.g. `"fiction|mystery|noir"`.
///
/// Why not JSON: the filter / search layers already do case-insensitive
/// substring searches against `text_value`; a JSON blob would defeat them
/// without adding any expressiveness for what is just a list of strings.
/// The delimiter is `|` because it doesn't appear in any real-world
/// genre / category we've seen from TMDB or Google Books.
enum MultiSelectValue {
    static let delimiter: Character = "|"

    static func encode(_ tags: [String]) -> String {
        tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            // De-dup while preserving order.
            .reduce(into: [String]()) { acc, tag in
                if !acc.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                    acc.append(tag)
                }
            }
            .joined(separator: String(delimiter))
    }

    static func decode(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return trimmed
            .split(separator: delimiter, omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
