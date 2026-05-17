import Foundation

/// Re-expands the compact `hours` text we store (e.g.
/// `"Mon–Fri 11:00–22:00, Sat–Sun 09:00–23:00"`) back into a 7-row map
/// so the detail view can render each day on its own line with today
/// highlighted.
///
/// This is the inverse of `WeekdayHoursFormatter.compress`. When input
/// doesn't match the expected shape (e.g. a user hand-typed
/// `"call ahead"`), parsing returns nil and the caller renders the raw
/// text unchanged.
///
/// Supports multi-window per day. A comma-separated chunk that starts
/// with a day name (`Mon`, `Tue`, …) opens a new day-group; a chunk
/// that starts with a digit is a continuation window appended to the
/// most recent day-group. So
/// `"Mon–Fri 11:00–14:00, 17:00–22:00, Sat–Sun 09:00–23:00"`
/// parses Mon–Fri with two windows + Sat–Sun with one.
enum RestaurantHoursParser {

    /// One day's hours. `windows` is the ordered list of time labels
    /// for the day — `[]` means closed (rendered as `"Closed"`), a
    /// single `"open 24h"` entry means 24-hour, otherwise each entry
    /// is a `"HH:MM–HH:MM"` range string.
    struct DayHours: Equatable {
        /// 0 = Monday, 6 = Sunday — matches `WeekdayHoursFormatter`.
        var dayIndex: Int
        var windows: [String]

        /// Display sugar — first window or the literal `"Closed"`
        /// sentinel when the day has no windows. Existing call sites
        /// that only render a single window (the display view's
        /// "Open now" status pill, older tests) read this; multi-
        /// window-aware call sites read `windows` directly.
        var label: String { windows.first ?? "Closed" }
    }

    /// Parse the compact string into 7 entries (one per weekday, in
    /// Mon→Sun order). Days the input didn't cover get an empty
    /// `windows` array (rendered as Closed). Returns nil when the
    /// input doesn't match our format at all — the caller falls back
    /// to displaying the raw text.
    static func parse(_ raw: String) -> [DayHours]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased() == "closed" {
            return (0..<7).map { DayHours(dayIndex: $0, windows: []) }
        }

        var byDay: [Int: [String]] = [:]
        /// Days touched by the most recent day-group segment — a
        /// digit-leading continuation chunk appends to these.
        var lastDays: [Int] = []
        var sawAnyDayGroup = false

        let segments = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !segments.isEmpty else { return nil }
        for segment in segments where !segment.isEmpty {
            if Self.startsWithDigit(segment) {
                // Continuation window for the previous day-group.
                // Stand-alone digit-leading input (no preceding day
                // group) is malformed — bail out.
                guard !lastDays.isEmpty else { return nil }
                guard isTimeRange(segment) else { return nil }
                for d in lastDays {
                    byDay[d, default: []].append(segment)
                }
            } else {
                guard let (days, label) = parseSegment(segment) else { return nil }
                sawAnyDayGroup = true
                lastDays = days
                // First-group-wins for any day we've already seen so
                // duplicate-day inputs like `"Mon 11:00, Mon 09:00"`
                // keep the first reading rather than silently
                // overwriting it.
                for d in days where byDay[d] == nil {
                    byDay[d] = [label]
                }
            }
        }
        guard sawAnyDayGroup else { return nil }
        return (0..<7).map { DayHours(dayIndex: $0, windows: byDay[$0] ?? []) }
    }

    // MARK: - Segment parsing

    private static let dayLookup: [String: Int] = [
        "mon": 0, "tue": 1, "wed": 2, "thu": 3,
        "fri": 4, "sat": 5, "sun": 6,
    ]

    /// Match the leading day spec — either `Mon` or `Mon–Fri` (with an
    /// en-dash, the character `WeekdayHoursFormatter.compress` emits).
    /// Everything after the matched span is the time label.
    private static func parseSegment(_ segment: String) -> ([Int], String)? {
        guard let firstSpace = segment.firstIndex(of: " ") else { return nil }
        let dayPart = segment[..<firstSpace].lowercased()
        let labelPart = segment[segment.index(after: firstSpace)...]
            .trimmingCharacters(in: .whitespaces)
        guard !labelPart.isEmpty else { return nil }

        let days: [Int]
        // Day range via en-dash (–, U+2013) — our canonical separator —
        // or hyphen (-) as a forgiving fallback when the user pasted a
        // hand-written string from elsewhere.
        if let rangeSplit = dayPart.split(whereSeparator: { $0 == "–" || $0 == "-" })
            .map(String.init)
            .nilWhenEmpty(),
           rangeSplit.count == 2,
           let lo = dayLookup[rangeSplit[0]],
           let hi = dayLookup[rangeSplit[1]],
           lo <= hi {
            days = Array(lo...hi)
        } else if let single = dayLookup[dayPart] {
            days = [single]
        } else {
            return nil
        }
        return (days, labelPart)
    }

    private static func startsWithDigit(_ s: String) -> Bool {
        guard let first = s.first else { return false }
        return first.isNumber
    }

    /// Cheap shape-check for continuation chunks. Permissive on the
    /// exact format — the display layer's `parseTimeWindow` does the
    /// real validation. We just want to reject obvious junk like
    /// `"17"` standing alone.
    private static func isTimeRange(_ s: String) -> Bool {
        // Look for a `HH:MM` chunk somewhere in the segment.
        return s.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil
    }
}

private extension Array {
    /// Returns nil for an empty array, otherwise self. Lets us chain
    /// the day-range parse into an `if let` without an extra guard.
    func nilWhenEmpty() -> Self? { isEmpty ? nil : self }
}
