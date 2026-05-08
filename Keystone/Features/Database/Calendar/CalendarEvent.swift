import Foundation

/// Renderable event projected from a record + an anchor date property.
/// Calendar views consume `[CalendarEvent]` rather than touching record
/// shape directly.
struct CalendarEvent: Equatable, Identifiable, Sendable {
    let id: String              // record id
    let title: String           // record title (pill label)
    let start: Date             // UTC instant
    let end: Date?              // optional UTC end (range events)
    let timezone: TimeZone      // event-local time zone (autoupdating for plain `date`)
    let isAllDay: Bool
}

enum CalendarEventBuilder {
    /// Project records into events using the chosen anchor property.
    /// When the anchor has a paired counterpart (e.g. `start` + `end`),
    /// records that have both produce range events; everything else is a
    /// one-day event.
    static func events(
        from records: [RecordRow],
        anchor: PropertyRow,
        in properties: [PropertyRow]
    ) -> [CalendarEvent] {
        let endKey = pairedEndKey(for: anchor, in: properties)
        return records.compactMap { record in
            event(from: record, anchorKey: anchor.key, anchorType: anchor.type, endKey: endKey)
        }
    }

    /// Returns the matching end-property key when one exists for the
    /// chosen anchor, by case-insensitive synonym match. Same-type only —
    /// pairing a `date` start with a `date_tz` end is refused (parsing
    /// rules would diverge).
    static func pairedEndKey(for anchor: PropertyRow, in props: [PropertyRow]) -> String? {
        let candidates: [String]
        switch anchor.key.lowercased() {
        case "start":     candidates = ["end"]
        case "begin":     candidates = ["end"]
        case "check_in":  candidates = ["check_out"]
        case "from":      candidates = ["to"]
        case "open":      candidates = ["close"]
        default:          return nil
        }
        for candidate in candidates {
            if let match = props.first(where: { $0.key.lowercased() == candidate && $0.type == anchor.type }) {
                return match.key
            }
        }
        return nil
    }

    /// True iff the event's event-local day intersects `day`. Single-day
    /// events check exact match in the event's tz; ranged events check
    /// interval intersection. `day` is treated as a calendar day in
    /// `evaluator` — typically the event's own tz so a 23:00 Paris event
    /// lands on Paris's day, not the viewer's day.
    static func event(
        _ event: CalendarEvent,
        intersects day: Date,
        evaluator calendarSource: Calendar = .current
    ) -> Bool {
        var calendar = calendarSource
        calendar.timeZone = event.timezone
        let eventStartDay = calendar.startOfDay(for: event.start)
        let eventEndDay = calendar.startOfDay(for: event.end ?? event.start)
        let probeDay = startOfDay(day, in: event.timezone)
        return probeDay >= eventStartDay && probeDay <= eventEndDay
    }

    /// Calendar day of the event in the event's own time zone. Used by
    /// month-grid placement so a 23:00 Paris event sits on May 8 even
    /// when the viewer is in PDT seeing it as 14:00.
    static func eventLocalDay(_ event: CalendarEvent) -> Date {
        startOfDay(event.start, in: event.timezone)
    }

    // MARK: - Private

    private static func event(
        from record: RecordRow,
        anchorKey: String,
        anchorType: PropertyType,
        endKey: String?
    ) -> CalendarEvent? {
        guard let raw = record.values[anchorKey], !raw.isEmpty else { return nil }
        guard let parsed = parse(raw, type: anchorType) else { return nil }
        var endComponent: (date: Date, isAllDay: Bool, timezone: TimeZone)? = nil
        if let endKey,
           let endRaw = record.values[endKey],
           !endRaw.isEmpty,
           let endParsed = parse(endRaw, type: anchorType) {
            endComponent = endParsed
        }
        let endDate = endComponent.map(\.date)
        return CalendarEvent(
            id: record.id,
            title: record.title,
            start: parsed.date,
            end: endDate,
            timezone: parsed.timezone,
            isAllDay: parsed.isAllDay
        )
    }

    /// Parse a property-values string into a (date, isAllDay, tz) triple.
    /// Returns nil when input is empty / malformed.
    private static func parse(_ raw: String, type: PropertyType) -> (date: Date, isAllDay: Bool, timezone: TimeZone)? {
        switch type {
        case .dateTZ:
            guard let parsed = DateValueCodec.parseTZ(raw) else { return nil }
            return (parsed.date, parsed.isAllDay, parsed.timezone)
        case .date:
            guard let parsed = DateValueCodec.parse(raw) else { return nil }
            return (parsed, true, .autoupdatingCurrent)
        default:
            return nil
        }
    }

    private static func startOfDay(_ date: Date, in tz: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return calendar.startOfDay(for: date)
    }
}
