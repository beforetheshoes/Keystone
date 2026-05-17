import Foundation

/// Structured representation of a restaurant's weekly hours used by
/// `RestaurantHoursEditor`. The model holds exactly seven `DayHours`
/// entries in Mon→Sun order; each day carries a mode (closed, 24h,
/// scheduled) and — when scheduled — one or more `TimeWindow`s.
///
/// The serialized form is the same compact string already used by the
/// display layer and the enrichment writers (`WeekdayHoursFormatter`),
/// so the editor round-trips through the existing `hours` text
/// property without any schema change.
struct RestaurantHoursModel: Equatable {
    var days: [DayHours]

    enum DayMode: Equatable, Sendable { case closed, open24h, scheduled }

    struct DayHours: Equatable, Identifiable {
        /// 0 = Monday … 6 = Sunday — matches `WeekdayHoursFormatter`.
        let dayIndex: Int
        var mode: DayMode
        var windows: [TimeWindow]
        var id: Int { dayIndex }
    }

    struct TimeWindow: Equatable, Identifiable {
        let id: UUID
        /// Minute-of-day, 0…1439. (Exactly 1440 / "24:00" is canonicalized
        /// to "open 24h" at the day level rather than stored here.)
        var openMinutes: Int
        var closeMinutes: Int

        init(id: UUID = UUID(), openMinutes: Int, closeMinutes: Int) {
            self.id = id
            self.openMinutes = openMinutes
            self.closeMinutes = closeMinutes
        }

        /// True when `closeMinutes < openMinutes` — the window wraps
        /// past midnight (e.g. 18:00–02:00). The display layer's
        /// "Open now" predicate honors the wrap.
        var crossesMidnight: Bool { closeMinutes < openMinutes }
    }

    /// Empty schedule — every day closed. The editor opens to this
    /// state for a record whose stored value is empty.
    static var empty: RestaurantHoursModel {
        RestaurantHoursModel(days: (0..<7).map {
            DayHours(dayIndex: $0, mode: .closed, windows: [])
        })
    }

    // MARK: - Parse

    /// Round-trip the compact text format back into structured state.
    /// Returns nil when the value isn't recognized (e.g. a user-typed
    /// `"call ahead"`); the editor falls back to plain-text editing
    /// in that case rather than silently discarding the user's text.
    ///
    /// Falls back to `OSMOpeningHoursParser` when our compact parser
    /// can't read the input. Records enriched via the Overpass / OSM
    /// path store raw OSM grammar (`Mo 09:00-15:00, Mo 17:00-19:00,
    /// …`); without this fallback the editor would refuse to open a
    /// structured view of those records even though the OSM parser
    /// can translate them losslessly into our format.
    static func parse(_ raw: String) -> RestaurantHoursModel? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        var parsed = RestaurantHoursParser.parse(trimmed)
        if parsed == nil,
           let translated = OSMOpeningHoursParser.parse(trimmed) {
            parsed = RestaurantHoursParser.parse(translated)
        }
        guard let parsed else { return nil }
        var days: [DayHours] = []
        for entry in parsed {
            let day = decode(entry)
            days.append(day)
        }
        return RestaurantHoursModel(days: days)
    }

    private static func decode(_ entry: RestaurantHoursParser.DayHours) -> DayHours {
        if entry.windows.isEmpty {
            return DayHours(dayIndex: entry.dayIndex, mode: .closed, windows: [])
        }
        if entry.windows == ["open 24h"] {
            return DayHours(dayIndex: entry.dayIndex, mode: .open24h, windows: [])
        }
        let parsedWindows = entry.windows.compactMap(parseWindow)
        if parsedWindows.isEmpty {
            // Some entries weren't parseable as time ranges — treat
            // the day as closed rather than fabricating windows. The
            // user can re-add them in the editor.
            return DayHours(dayIndex: entry.dayIndex, mode: .closed, windows: [])
        }
        return DayHours(dayIndex: entry.dayIndex, mode: .scheduled, windows: parsedWindows)
    }

    private static func parseWindow(_ label: String) -> TimeWindow? {
        let parts = label.split(whereSeparator: { $0 == "–" || $0 == "-" })
        guard parts.count == 2 else { return nil }
        guard let open = parseClock(String(parts[0])),
              let close = parseClock(String(parts[1])) else { return nil }
        return TimeWindow(openMinutes: open, closeMinutes: close)
    }

    private static func parseClock(_ s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let bits = trimmed.split(separator: ":")
        guard bits.count == 2,
              let h = Int(bits[0]), let m = Int(bits[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    // MARK: - Serialize

    /// Render the model back to the compact text format. The output
    /// is the canonical form `WeekdayHoursFormatter.compress` would
    /// produce, so a parse(serialize(_:)) round-trip is the identity
    /// for any model the editor can build.
    func serialize() -> String {
        var byDay: [Int: [String]] = [:]
        for day in days {
            switch day.mode {
            case .closed:
                continue
            case .open24h:
                byDay[day.dayIndex] = ["open 24h"]
            case .scheduled:
                let labels = day.windows.map { Self.formatWindow($0) }
                guard !labels.isEmpty else { continue }
                byDay[day.dayIndex] = labels
            }
        }
        if byDay.isEmpty { return "Closed" }
        return WeekdayHoursFormatter.compress(byDay)
    }

    private static func formatWindow(_ w: TimeWindow) -> String {
        WeekdayHoursFormatter.timeLabel(opens: formatClock(w.openMinutes),
                                        closes: formatClock(w.closeMinutes))
    }

    private static func formatClock(_ minutes: Int) -> String {
        let h = (minutes / 60) % 24
        let m = minutes % 60
        return String(format: "%02d:%02d", h, m)
    }

    // MARK: - Mutations used by the editor

    /// Copy `source`'s mode + windows to every day index in `targets`.
    /// New window IDs are generated so each row keeps its own identity
    /// (SwiftUI ForEach needs unique IDs even for value-equal copies).
    mutating func applyDay(at source: Int, to targets: [Int]) {
        guard let template = days.first(where: { $0.dayIndex == source }) else { return }
        for target in targets where target != source {
            guard let idx = days.firstIndex(where: { $0.dayIndex == target }) else { continue }
            days[idx].mode = template.mode
            days[idx].windows = template.windows.map {
                TimeWindow(openMinutes: $0.openMinutes, closeMinutes: $0.closeMinutes)
            }
        }
    }

    /// Set every day in `targets` to the given mode/windows. Used by
    /// the header preset buttons ("Set weekdays…" etc.).
    mutating func applyPreset(mode: DayMode, windows: [TimeWindow], to targets: [Int]) {
        for target in targets {
            guard let idx = days.firstIndex(where: { $0.dayIndex == target }) else { continue }
            days[idx].mode = mode
            days[idx].windows = mode == .scheduled
                ? windows.map { TimeWindow(openMinutes: $0.openMinutes, closeMinutes: $0.closeMinutes) }
                : []
        }
    }

    static let weekdayIndexes: [Int] = [0, 1, 2, 3, 4]
    static let weekendIndexes: [Int] = [5, 6]
    static let allIndexes: [Int] = Array(0..<7)
}
