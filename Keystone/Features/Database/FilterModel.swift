import Foundation

/// One row in the filter bar above a database table. Each filter binds
/// to a single property by key and carries a type-specific predicate.
struct Filter: Equatable, Sendable, Identifiable, Codable {
    let id: String
    var propertyKey: String
    var predicate: FilterPredicate

    init(propertyKey: String, predicate: FilterPredicate) {
        self.id = UUID().uuidString
        self.propertyKey = propertyKey
        self.predicate = predicate
    }

    /// Constructor used during decode so persisted filters keep their
    /// original id (so we don't trigger spurious re-renders on every
    /// app launch). Internal — callers building filters from scratch
    /// should use the public initializer above.
    init(id: String, propertyKey: String, predicate: FilterPredicate) {
        self.id = id
        self.propertyKey = propertyKey
        self.predicate = predicate
    }
}

/// Per-type predicate. Each case carries enough state to evaluate against
/// a record's cell value (`record.values[key]` or `record.relationTargets[key]`).
enum FilterPredicate: Equatable, Sendable, Codable {
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
    /// Open-now-against-weekly-hours predicate, applied to a property
    /// whose value is a `RestaurantHours` JSON blob (e.g.
    /// `vendors.hours`). `nil` is a no-op; `true` keeps records the
    /// engine evaluates as open at the current instant.
    ///
    /// The "Open Now" chip is intentionally a binary toggle — the
    /// hours data isn't auto-populated yet (see the help doc), so the
    /// predicate ships ahead of the editor / MapKit autofill. A record
    /// without a parseable hours payload never matches.
    case openNow(Bool?)

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
        case .openNow(let b):            return b == nil
        }
    }
}

/// Weekly hours schedule for restaurants (and any other vendor that
/// wants to declare opening hours). Stored as JSON in
/// `property_values.text_value` on the `vendors.hours` property.
///
/// Wire format (each weekday key is optional; an absent key means "we
/// don't know" rather than "closed", and yields no match):
///
/// ```json
/// {
///   "mon": [{"open": "08:00", "close": "22:00"}],
///   "tue": [{"open": "08:00", "close": "22:00"}],
///   "fri": [{"open": "11:00", "close": "23:30"}],
///   "sat": [{"open": "10:00", "close": "23:30"}]
/// }
/// ```
///
/// Times are local to the venue (no time-zone field) — the predicate
/// compares against the user's local clock, which is what "open now"
/// means in practice for someone glancing at the list. Multi-slot
/// days are supported for split-shift venues (e.g. lunch + dinner).
struct RestaurantHours: Equatable, Sendable {
    /// Per-weekday list of open intervals. Days outside this dict are
    /// treated as "unknown" — they neither open nor close the venue.
    var byWeekday: [Weekday: [Slot]]

    enum Weekday: String, CaseIterable, Sendable {
        case sun, mon, tue, wed, thu, fri, sat

        /// Maps `Calendar.current.component(.weekday, …)` (1-based with
        /// Sunday = 1) to this enum.
        static func from(calendarWeekday n: Int) -> Weekday? {
            switch n {
            case 1: return .sun
            case 2: return .mon
            case 3: return .tue
            case 4: return .wed
            case 5: return .thu
            case 6: return .fri
            case 7: return .sat
            default: return nil
            }
        }
    }

    /// Half-open interval `[openMinute, closeMinute)`, in minutes past
    /// midnight. `closeMinute > 1440` is allowed and represents a
    /// wrap-into-the-next-day venue (e.g. a bar that closes at 02:00).
    struct Slot: Equatable, Sendable {
        var openMinute: Int
        var closeMinute: Int
    }

    /// Parse the JSON blob written to `vendors.hours`. Returns nil for
    /// anything we can't make sense of — the predicate treats nil as
    /// "no hours known" and skips the record rather than matching.
    static func parse(_ json: String) -> RestaurantHours? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var byDay: [Weekday: [Slot]] = [:]
        for (rawDay, rawSlots) in obj {
            guard let day = Weekday(rawValue: rawDay.lowercased()),
                  let slotsArr = rawSlots as? [[String: Any]] else { continue }
            var slots: [Slot] = []
            for raw in slotsArr {
                guard let open = (raw["open"] as? String).flatMap(parseClock),
                      let close = (raw["close"] as? String).flatMap(parseClock) else { continue }
                slots.append(Slot(openMinute: open, closeMinute: close))
            }
            if !slots.isEmpty { byDay[day] = slots }
        }
        return byDay.isEmpty ? nil : RestaurantHours(byWeekday: byDay)
    }

    /// `"HH:MM"` → minutes past midnight. Returns nil for malformed
    /// strings. Accepts 24-hour format only (no AM/PM parsing).
    private static func parseClock(_ s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              h >= 0, h <= 47, m >= 0, m < 60 else { return nil }
        return h * 60 + m
    }

    /// True iff the venue is open at `instant`. Walks the day-of and
    /// the day-before (for venues that wrap past midnight). Uses the
    /// current calendar / time zone — "open now" is implicitly local.
    func isOpen(at instant: Date, calendar: Calendar = .current) -> Bool {
        let comps = calendar.dateComponents([.weekday, .hour, .minute], from: instant)
        guard let todayWD = Weekday.from(calendarWeekday: comps.weekday ?? 0),
              let hour = comps.hour, let minute = comps.minute else { return false }
        let nowMinutes = hour * 60 + minute

        if let today = byWeekday[todayWD] {
            for slot in today {
                if slot.openMinute <= nowMinutes && nowMinutes < min(slot.closeMinute, 24 * 60) {
                    return true
                }
            }
        }
        // Wrap-past-midnight: yesterday's slot whose close > 24*60 may
        // still cover us if we're in the early-AM window.
        let yesterdayWD: Weekday? = {
            switch todayWD {
            case .sun: return .sat
            case .mon: return .sun
            case .tue: return .mon
            case .wed: return .tue
            case .thu: return .wed
            case .fri: return .thu
            case .sat: return .fri
            }
        }()
        if let y = yesterdayWD, let yest = byWeekday[y] {
            for slot in yest where slot.closeMinute > 24 * 60 {
                if nowMinutes < slot.closeMinute - 24 * 60 {
                    return true
                }
            }
        }
        return false
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
            guard let raw = filter.propertyKey == "title" ? nil : record.values[filter.propertyKey] else { return false }
            // date_tz values come through as `<date>|<tz>`; prefer the
            // tz-aware parse so the instant comparison is correct.
            // Fall back to the plain-date parse for legacy / partial
            // values and for ordinary `date` properties.
            let instant: Date
            if let parsedTZ = DateValueCodec.parseTZ(raw) {
                instant = parsedTZ.date
            } else if let parsed = DateValueCodec.parse(raw) {
                instant = parsed
            } else {
                return false
            }
            if let from, instant < startOfDay(from) { return false }
            if let to, instant > endOfDay(to) { return false }
            return true

        case .selectIsAnyOf(let values):
            let raw = record.values[filter.propertyKey] ?? ""
            // `multiSelect` cells store delimiter-joined tags. Match if
            // any selected value appears in the cell's tag set.
            if prop?.type == .multiSelect {
                let tags = Set(MultiSelectValue.decode(raw))
                return !tags.isDisjoint(with: Set(values))
            }
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

        case .openNow(let want):
            guard let want else { return true }
            let raw = record.values[filter.propertyKey] ?? ""
            // No hours stored → record can't satisfy the filter when
            // the user is asking for "open now". Conversely, asking
            // for "closed now" (want == false) without hours info
            // would lie either way, so the same rule applies.
            guard let hours = RestaurantHours.parse(raw) else { return false }
            return hours.isOpen(at: Date()) == want
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
        case .date, .dateRange, .dateTZ:     return .dateRange(from: nil, to: nil)
        case .select, .multiSelect, .status: return .selectIsAnyOf([])
        case .number, .currency:             return .numberRange(min: nil, max: nil)
        case .checkbox:                      return .checkbox(nil)
        default:                             return .textContains("")
        }
    }

    /// Property-aware variant. Falls through to the type-based factory
    /// for everything except `vendors.hours`, which gets an Open Now
    /// toggle (its raw text would otherwise show as a "contains…"
    /// filter, which is useless against opaque JSON).
    static func empty(for property: PropertyRow) -> FilterPredicate {
        if property.key == "hours" { return .openNow(true) }
        return empty(for: property.type)
    }
}
