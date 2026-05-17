import Foundation

/// Convert a stored select / status option identifier into something
/// fit for a user-facing label.
///
/// Stored values are typically snake_case enum-style identifiers
/// (`want_to_try`, `to_read`, `in_progress`) so they're stable across
/// migrations, sync, and CSV imports. Showing those raw strings in
/// the UI ("want_to_try") looks like a bug.
///
/// The formatter:
/// - Replaces underscores and hyphens with spaces.
/// - Sentence-cases the result (first letter upper, rest as-is so an
///   intentional all-lowercase or mixed-case value carries through).
/// - Leaves non-identifier values alone — `"$$"`, `"3.5"`, `"⭐⭐⭐"`,
///   anything containing a space or non-ASCII letter — so display-
///   ready values aren't mangled.
enum SelectOptionDisplay {
    static func format(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        guard looksLikeIdentifier(trimmed) else { return trimmed }

        let withSpaces = trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        guard let first = withSpaces.first else { return withSpaces }
        return first.uppercased() + withSpaces.dropFirst()
    }

    /// True for ASCII-only identifier-shaped strings — `[a-zA-Z0-9_-]+`
    /// with at least one letter. Anything else (spaces, punctuation,
    /// non-ASCII letters like `é`, currency symbols) is treated as
    /// already display-ready and passes through unmodified.
    ///
    /// We scope to ASCII deliberately: snake_case identifiers are
    /// what enrichment writers and migrations emit, and accidentally
    /// title-casing a user-typed word like `"café"` would feel like
    /// the app rewriting their input.
    private static func looksLikeIdentifier(_ s: String) -> Bool {
        var sawLetter = false
        for scalar in s.unicodeScalars {
            let v = scalar.value
            let isASCIILetter = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
            let isASCIIDigit = v >= 0x30 && v <= 0x39
            let isSeparator = scalar == "_" || scalar == "-"
            guard isASCIILetter || isASCIIDigit || isSeparator else { return false }
            if isASCIILetter { sawLetter = true }
        }
        return sawLetter
    }
}
