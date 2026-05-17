import Foundation

/// Shared text formatter for `{weekday → "HH:MM–HH:MM"}` maps so the
/// schema.org JSON-LD parser and the OSM `opening_hours` parser produce
/// identical-looking output for the user. Weekday indexes are
/// 0=Monday … 6=Sunday; missing days are treated as closed and elided.
enum WeekdayHoursFormatter {
    static let shortDayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// Collapse a `{day → label}` map into a compact summary. Consecutive
    /// days that share the same label fold into a range; everything else
    /// lands as a single-day entry. Closed days are omitted entirely.
    ///
    /// `"open 24h"` is a sentinel string we emit when opens == closes;
    /// `compress` doesn't interpret it specially — it's just another
    /// label that compresses by day.
    static func compress(_ byDay: [Int: String]) -> String {
        compress(byDay.mapValues { [$0] })
    }

    /// Multi-window variant: each day may carry one or more window
    /// labels (e.g. `["11:00–14:00", "17:00–22:00"]` for a venue that
    /// closes between lunch and dinner). Days that share the same
    /// ordered list compress into a range; within a day-group, the
    /// first window is emitted on the day line and each subsequent
    /// window is a digit-leading continuation chunk:
    ///
    ///     `"Mon–Fri 11:00–14:00, 17:00–22:00, Sat–Sun 09:00–23:00"`
    ///
    /// `RestaurantHoursParser` reverses this — a comma-separated chunk
    /// that starts with a digit is appended to the previous day-group's
    /// windows rather than opening a new one.
    static func compress(_ byDay: [Int: [String]]) -> String {
        var runs: [(start: Int, end: Int, windows: [String])] = []
        var i = 0
        while i < 7 {
            guard let windows = byDay[i], !windows.isEmpty else { i += 1; continue }
            var j = i
            while j + 1 < 7, byDay[j + 1] == windows {
                j += 1
            }
            runs.append((i, j, windows))
            i = j + 1
        }
        return runs.map { run in
            let dayPart: String
            if run.start == run.end {
                dayPart = shortDayNames[run.start]
            } else {
                dayPart = "\(shortDayNames[run.start])–\(shortDayNames[run.end])"
            }
            // First window sits on the day line; subsequent windows
            // join with the same `, ` separator that already divides
            // day-groups. The parser disambiguates the two roles
            // by looking at whether the chunk leads with a digit.
            return ([dayPart + " " + run.windows[0]] + run.windows.dropFirst())
                .joined(separator: ", ")
        }.joined(separator: ", ")
    }

    /// Format `(open, close)` into the same `"HH:MM–HH:MM"` shape used
    /// across the codebase, with `"open 24h"` as the sentinel when both
    /// times are identical (the schema.org and OSM convention for 24h
    /// venues).
    static func timeLabel(opens: String, closes: String) -> String {
        if opens == closes { return "open 24h" }
        return "\(opens)–\(closes)"
    }
}
