import Foundation

/// Today-only renderer for the restaurant `hours` value, used by the
/// table / gallery / list views where a full 7-day schedule is too
/// dense to scan. Returns nil for values that don't match our compact
/// hours format — the caller falls back to whatever else it would
/// have rendered (truncated raw string in the table column, etc.).
///
/// The full schedule lives on the record-detail page, rendered by
/// `RestaurantHoursView`. This helper is intentionally narrower: just
/// "what does today look like at a glance".
enum RestaurantHoursSummary {
    /// Examples (formatted via the user's locale 12h/24h preference):
    /// - `"11:00 AM – 10:00 PM"` (single window)
    /// - `"11:00 AM – 2:00 PM, 5:00 PM – 10:00 PM"` (lunch + dinner)
    /// - `"Closed today"`
    /// - `"Open 24 hours"`
    static func todayShort(_ raw: String, now: Date = Date()) -> String? {
        // Primary: our compact format (what enrichment writes today).
        var parsed = RestaurantHoursParser.parse(raw)
        // Fallback: the stored value might be raw OSM grammar left
        // over from an earlier enrichment that wrote raw-on-failure.
        // Round-trip it through the OSM parser (which emits our
        // format) and re-try. This is read-only: nothing gets
        // re-written to the DB, the user just sees a sensible
        // today-line until they explicitly Re-enrich the record.
        if parsed == nil,
           let translated = OSMOpeningHoursParser.parse(raw) {
            parsed = RestaurantHoursParser.parse(translated)
        }
        guard let parsed else { return nil }
        let today = parsed[currentWeekdayIndex(at: now)]
        if today.windows.isEmpty { return "Closed today" }
        if today.windows == ["open 24h"] { return "Open 24 hours" }
        let labels = today.windows.compactMap(formatWindow)
        if labels.isEmpty { return "Closed today" }
        return labels.joined(separator: ", ")
    }

    /// Same as `todayShort` but left-pads the open time with figure
    /// spaces (U+2007) so every single-window summary is the same
    /// character-width up to the en-dash. Used by the table column
    /// where consistent dash X-position across rows matters; the
    /// caller renders it with a monospaced font so the figure-space
    /// + digit + colon glyphs all share tabular metrics.
    ///
    /// Sentinel strings ("Closed today", "Open 24 hours") and
    /// multi-window summaries pass through unpadded — there's no
    /// dash to align in those cases.
    static func todayShortPadded(_ raw: String, now: Date = Date()) -> String? {
        guard let summary = todayShort(raw, now: now) else { return nil }
        guard let dashIndex = summary.firstIndex(where: { $0 == "–" || $0 == "-" }) else {
            return summary
        }
        let open = summary[..<dashIndex].trimmingCharacters(in: .whitespaces)
        let close = summary[summary.index(after: dashIndex)...]
            .trimmingCharacters(in: .whitespaces)
        // Multi-window — let the caller's text renderer handle it
        // verbatim (no useful single dash to align around).
        if open.contains(",") || close.contains(",") { return summary }
        // Widest plausible open is "12:00 AM" / "10:00 PM" = 8 chars
        // for US 12h locale, or "23:00" = 5 chars for 24h locales.
        // We pad to the longer of the two so a mixed-locale workspace
        // still aligns consistently.
        let widest = max(8, open.count)
        let padCount = max(0, widest - open.count)
        let padding = String(repeating: "\u{2007}", count: padCount)
        return "\(padding)\(open) – \(close)"
    }

    /// Open/closed status for the *current* moment in the user's
    /// locale, based on the same parse path as `todayShort`. Returns
    /// one of `"Open now"`, `"Closed"`, `"Open 24 hours"`, or nil when
    /// the raw value doesn't parse.
    ///
    /// Handles cross-midnight windows (yesterday's `18:00–02:00` is
    /// still "Open now" at 01:30 today). Multi-window days (lunch +
    /// dinner) match if `now` falls in any window.
    static func todayStatus(_ raw: String, now: Date = Date()) -> String? {
        var parsed = RestaurantHoursParser.parse(raw)
        if parsed == nil, let translated = OSMOpeningHoursParser.parse(raw) {
            parsed = RestaurantHoursParser.parse(translated)
        }
        guard let parsed else { return nil }

        let todayIndex = currentWeekdayIndex(at: now)
        let today = parsed[todayIndex]
        if today.windows == ["open 24h"] { return "Open 24 hours" }

        let nowMinutes = minutesSinceMidnight(at: now)

        // Yesterday's cross-midnight wrap into today wins first — at
        // 01:30 today, Friday's 18:00–02:00 is still keeping us open.
        let yesterday = parsed[(todayIndex + 6) % 7]
        for label in yesterday.windows {
            guard let window = parseWindowMinutes(label),
                  window.close < window.open else { continue }
            if nowMinutes < window.close { return "Open now" }
        }

        for label in today.windows {
            guard let window = parseWindowMinutes(label) else { continue }
            if window.close < window.open {
                // Today's wrap window — open from `open` through midnight.
                if nowMinutes >= window.open { return "Open now" }
            } else if nowMinutes >= window.open && nowMinutes < window.close {
                return "Open now"
            }
        }
        return "Closed"
    }

    private static func minutesSinceMidnight(at date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    private static func parseWindowMinutes(_ label: String) -> (open: Int, close: Int)? {
        let parts = label.split(whereSeparator: { $0 == "–" || $0 == "-" })
        guard parts.count == 2,
              let open = parseClock(String(parts[0])),
              let close = parseClock(String(parts[1])) else { return nil }
        return (open, close)
    }

    // MARK: - Internals

    /// Convert Calendar's 1=Sunday … 7=Saturday to Mon=0 … Sun=6 so
    /// indexing into `RestaurantHoursParser` results lines up.
    private static func currentWeekdayIndex(at date: Date) -> Int {
        let weekday = Calendar.current.component(.weekday, from: date)
        return (weekday + 5) % 7
    }

    private static func formatWindow(_ label: String) -> String? {
        let parts = label.split(whereSeparator: { $0 == "–" || $0 == "-" })
        guard parts.count == 2 else { return nil }
        guard let openMin = parseClock(String(parts[0])),
              let closeMin = parseClock(String(parts[1])) else { return nil }
        return "\(formatMinutes(openMin)) – \(formatMinutes(closeMin))"
    }

    private static func parseClock(_ s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let bits = trimmed.split(separator: ":")
        guard bits.count == 2,
              let h = Int(bits[0]), let m = Int(bits[1]),
              (0...24).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    /// Shared formatter — `DateFormatter.timeStyle = .short` follows the
    /// user's 12h/24h preference, same idiom used in `RestaurantHoursView`.
    private static let displayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.timeStyle = .short
        df.dateStyle = .none
        return df
    }()

    private static func formatMinutes(_ minutes: Int) -> String {
        var comps = DateComponents()
        comps.hour = (minutes / 60) % 24
        comps.minute = minutes % 60
        guard let date = Calendar.current.date(from: comps) else {
            return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
        }
        return displayFormatter.string(from: date)
    }
}
