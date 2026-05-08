import Foundation

/// Parsing and formatting helpers for date-shaped property values.
///
/// Two storage shapes coexist:
///
/// - **`date`**: a single ISO short date `yyyy-MM-dd`. Whole-day, no time
///   component, no time zone. Used by `people.birthday`, `events.when`, etc.
/// - **`date_tz`**: a compound `<date>|<iana_tz>` string, where `<date>`
///   is either `yyyy-MM-dd` (all-day) or RFC3339 UTC `yyyy-MM-ddTHH:mm:ssZ`
///   (timed). The IANA tz id is required for non-empty values; legacy
///   partial values (just a `yyyy-MM-dd` with no `|`) read out as nil
///   from `parseTZ` and the renderer falls back to the plain-date path.
enum DateValueCodec {
    // MARK: - Plain date (yyyy-MM-dd)

    /// Canonical wire format for plain dates.
    static func iso(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Display format shown in detail rows ("Mar 14, 1989").
    static func display(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    /// Permissive parser. Tries ISO first, then several common human formats
    /// so existing free-form values like "Mar 14, 1989" or "04/14/1988"
    /// continue to work without manual migration.
    static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formats = [
            "yyyy-MM-dd",
            "MMM d, yyyy",
            "MMMM d, yyyy",
            "M/d/yyyy",
            "MM/dd/yyyy",
            "yyyy/MM/dd",
            "d MMM yyyy",
        ]
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in formats {
            f.dateFormat = fmt
            if let d = f.date(from: trimmed) { return d }
        }
        return nil
    }

    // MARK: - date_tz

    /// Parse the compound `<date>|<iana_tz>` representation. Returns nil
    /// for empty input, missing delimiter, unknown tz, or malformed date.
    static func parseTZ(_ raw: String) -> DateTZValue? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let pipe = trimmed.firstIndex(of: "|") else { return nil }
        let dateString = String(trimmed[..<pipe]).trimmingCharacters(in: .whitespaces)
        let tzID = String(trimmed[trimmed.index(after: pipe)...]).trimmingCharacters(in: .whitespaces)
        guard !dateString.isEmpty, !tzID.isEmpty else { return nil }
        guard let timezone = TimeZone(identifier: tzID) else { return nil }

        // All-day path: 10-char yyyy-MM-dd.
        if dateString.count == 10, let date = parseAllDay(dateString, in: timezone) {
            return DateTZValue(date: date, timezone: timezone, isAllDay: true)
        }
        // Timed path: RFC3339 UTC.
        if let date = parseUTC(dateString) {
            return DateTZValue(date: date, timezone: timezone, isAllDay: false)
        }
        return nil
    }

    /// Same as `parseTZ` but returns the raw split without parsing the
    /// date side. Used by `Writes.swift` so storage doesn't double-parse.
    static func parseTZRaw(_ raw: String) -> (dateString: String, tz: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let pipe = trimmed.firstIndex(of: "|") else { return nil }
        let dateString = String(trimmed[..<pipe]).trimmingCharacters(in: .whitespaces)
        let tzID = String(trimmed[trimmed.index(after: pipe)...]).trimmingCharacters(in: .whitespaces)
        guard !dateString.isEmpty, !tzID.isEmpty else { return nil }
        return (dateString, tzID)
    }

    /// Re-serialize a parsed value to the compound storage representation.
    static func encodeTZ(_ value: DateTZValue) -> String {
        let dateString: String
        if value.isAllDay {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = value.timezone
            let components = calendar.dateComponents([.year, .month, .day], from: value.date)
            dateString = String(
                format: "%04d-%02d-%02d",
                components.year ?? 0, components.month ?? 1, components.day ?? 1
            )
        } else {
            let formatter = utcFormatter()
            dateString = formatter.string(from: value.date)
        }
        return "\(dateString)|\(value.timezone.identifier)"
    }

    /// Event-local rendering — line 1 of the detail-row display.
    /// "May 8, 2026 · 2:00 PM CEST" or "May 8, 2026 · All day · Asia/Tokyo".
    static func displayEventLocal(_ value: DateTZValue) -> String {
        let dateString: String
        let dateFormatter = DateFormatter()
        dateFormatter.timeZone = value.timezone
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        dateString = dateFormatter.string(from: value.date)

        if value.isAllDay {
            return "\(dateString) · All day · \(value.timezone.identifier)"
        }
        let timeFormatter = DateFormatter()
        timeFormatter.timeZone = value.timezone
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        let timeString = timeFormatter.string(from: value.date)
        let tzAbbr = value.timezone.abbreviation(for: value.date) ?? value.timezone.identifier
        return "\(dateString) · \(timeString) \(tzAbbr)"
    }

    /// Viewer-local rendering — line 2 of the detail-row display. Returns
    /// nil when there's no need for a second line: all-day events, or
    /// when the viewer's tz already matches the event's tz.
    static func displayViewerLocal(_ value: DateTZValue, viewerTimezone: TimeZone = .autoupdatingCurrent) -> String? {
        if value.isAllDay { return nil }
        if viewerTimezone.identifier == value.timezone.identifier { return nil }

        let formatter = DateFormatter()
        formatter.timeZone = viewerTimezone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let baseString = formatter.string(from: value.date)
        let viewerAbbr = viewerTimezone.abbreviation(for: value.date) ?? viewerTimezone.identifier
        return "\(baseString) \(viewerAbbr)"
    }

    /// Compact event-local rendering for table cells: "May 8 · 2:00 PM CEST"
    /// or "May 8 · All day".
    static func compactEventLocal(_ value: DateTZValue) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.timeZone = value.timezone
        dateFormatter.dateFormat = "MMM d"
        let dateString = dateFormatter.string(from: value.date)
        if value.isAllDay { return "\(dateString) · All day" }
        let timeFormatter = DateFormatter()
        timeFormatter.timeZone = value.timezone
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        let timeString = timeFormatter.string(from: value.date)
        let tzAbbr = value.timezone.abbreviation(for: value.date) ?? ""
        return tzAbbr.isEmpty ? "\(dateString) · \(timeString)" : "\(dateString) · \(timeString) \(tzAbbr)"
    }

    // MARK: - Private parse helpers

    private static func parseAllDay(_ raw: String, in tz: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = tz
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }

    private static func parseUTC(_ raw: String) -> Date? {
        let formatter = utcFormatter()
        return formatter.date(from: raw)
    }

    private static func utcFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }
}

/// Parsed `date_tz` value.
struct DateTZValue: Equatable, Sendable {
    /// Absolute instant (UTC). For all-day values this is midnight in the
    /// event's tz, normalized to UTC.
    let date: Date
    /// Event-local time zone.
    let timezone: TimeZone
    /// True when the source had no time component (whole-day event).
    let isAllDay: Bool
}
