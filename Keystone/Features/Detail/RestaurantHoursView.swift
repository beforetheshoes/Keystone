import SwiftUI
import ComposableArchitecture

/// Renders restaurant hours as a 7-row mini-table — Mon through Sun,
/// today bolded, with a status line ("Open now · closes at 10 PM" /
/// "Closed · opens Wed at 5 PM") on top. Replaces the dense
/// `PropertyValueField` text rendering for `vendors.hours` on
/// restaurant records.
///
/// When the stored string doesn't match the compact format we emit
/// from enrichment (e.g. the user pasted `"call ahead, closed
/// Tuesdays"`), parsing returns nil and we fall back to plain text so
/// nothing is lost.
struct RestaurantHoursView: View {
    let raw: String
    /// Today's weekday in `WeekdayHoursFormatter` indexing (0 = Mon).
    /// Injectable so previews and tests can pin a specific day.
    var todayIndex: Int = currentWeekdayIndex()
    /// Minutes since midnight — used for "Open now" calculation.
    /// Injectable for the same reason.
    var nowMinutes: Int = currentMinuteOfDay()

    private static let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    /// Longer label for the "Closed · Opens Wed at 5 PM" status line.
    private static let dayNamesLong = ["Monday", "Tuesday", "Wednesday", "Thursday",
                                       "Friday", "Saturday", "Sunday"]

    var body: some View {
        if let parsed = Self.parseWithFallback(raw) {
            VStack(alignment: .leading, spacing: 6) {
                statusLine(parsed: parsed)
                hoursGrid(parsed: parsed)
            }
        } else if Self.isGarbageOrEmpty(raw) {
            // Punctuation-only or empty strings render as "—" so an
            // existing record that was written with garbage (before
            // the enrichment-side validator landed) doesn't show a
            // line of commas. New writes are blocked upstream.
            Text("—")
                .font(.kstText(size: 13))
                .foregroundStyle(KstColor.ink3)
        } else {
            // Unrecognized but real text (e.g. "call ahead") — preserve
            // the user's original text verbatim.
            Text(raw)
                .font(.kstText(size: 13))
                .foregroundStyle(KstColor.ink1)
        }
    }

    /// Parse the stored hours string into the per-day window list. First
    /// tries our canonical compact form (`Mon–Fri 11:00–22:00, …`);
    /// when that fails, attempts an OSM-grammar translation via
    /// `OSMOpeningHoursParser` and re-parses the canonical translation.
    /// Records enriched via Overpass land in the DB with raw OSM
    /// grammar (`Mo 09:00-15:00, Mo 17:00-19:00, …`); without this
    /// fallback the detail view would show the raw string verbatim
    /// instead of the per-day grid the user expects.
    static func parseWithFallback(_ raw: String) -> [RestaurantHoursParser.DayHours]? {
        if let parsed = RestaurantHoursParser.parse(raw) {
            return parsed
        }
        if let translated = OSMOpeningHoursParser.parse(raw),
           let parsed = RestaurantHoursParser.parse(translated) {
            return parsed
        }
        return nil
    }

    /// True for empty strings, strings containing nothing but
    /// punctuation/whitespace, and strings that lead with a separator
    /// character (which is always the result of a parser bail-out,
    /// never legitimate hours data). Mirrors
    /// `RestaurantHoursCleanupPass.looksLikeGarbage` exactly so the
    /// table view, the detail view, and the cleanup pass all agree.
    static func isGarbageOrEmpty(_ s: String) -> Bool {
        RestaurantHoursCleanupPass.looksLikeGarbage(s)
    }

    // MARK: - Status line

    @ViewBuilder
    private func statusLine(parsed: [RestaurantHoursParser.DayHours]) -> some View {
        let status = computeStatus(parsed: parsed)
        HStack(spacing: 6) {
            Circle()
                .fill(status.isOpen ? KstColor.sage : KstColor.ink3)
                .frame(width: 7, height: 7)
            Text(status.summary)
                .font(.kstText(size: 12, weight: .semibold))
                .foregroundStyle(status.isOpen ? KstColor.ink1 : KstColor.ink2)
        }
    }

    private struct OpenStatus {
        var isOpen: Bool
        var summary: String
    }

    /// Compute the headline status. We don't track holidays, so this
    /// is a best-effort read of the regular schedule. Walks today's
    /// windows in order; the first match wins. A cross-midnight window
    /// from yesterday (close < open) is also considered, so 1 AM on
    /// Saturday correctly reads as "Open now" when Friday's hours
    /// were 18:00–02:00.
    private func computeStatus(parsed: [RestaurantHoursParser.DayHours]) -> OpenStatus {
        let today = parsed[todayIndex]
        if today.label == "open 24h" {
            return OpenStatus(isOpen: true, summary: "Open 24 hours")
        }
        // Check yesterday's wrap-into-today first — if any of
        // yesterday's windows crosses midnight and this minute is
        // still inside it, we're open.
        let yesterday = parsed[(todayIndex + 6) % 7]
        for label in yesterday.windows {
            guard let window = parseTimeWindow(label), window.crossesMidnight else { continue }
            if nowMinutes < window.closeMinutes {
                return OpenStatus(
                    isOpen: true,
                    summary: "Open now · closes at \(formatClockMinutes(window.closeMinutes))"
                )
            }
        }
        // Today's windows in order.
        var nextOpenInToday: Int?
        for label in today.windows {
            guard let window = parseTimeWindow(label) else { continue }
            if window.crossesMidnight {
                if nowMinutes >= window.openMinutes {
                    return OpenStatus(
                        isOpen: true,
                        summary: "Open now · closes at \(formatClockMinutes(window.closeMinutes))"
                    )
                }
            } else if nowMinutes >= window.openMinutes && nowMinutes < window.closeMinutes {
                return OpenStatus(
                    isOpen: true,
                    summary: "Open now · closes at \(formatClockMinutes(window.closeMinutes))"
                )
            }
            if nowMinutes < window.openMinutes,
               nextOpenInToday == nil || window.openMinutes < (nextOpenInToday ?? Int.max) {
                nextOpenInToday = window.openMinutes
            }
        }
        if let next = nextOpenInToday {
            return OpenStatus(
                isOpen: false,
                summary: "Closed · opens at \(formatClockMinutes(next))"
            )
        }
        // After today's last close — find the next open day.
        if let next = nextOpening(parsed: parsed) {
            return OpenStatus(
                isOpen: false,
                summary: "Closed · opens \(next)"
            )
        }
        return OpenStatus(isOpen: false, summary: "Closed")
    }

    private func nextOpening(parsed: [RestaurantHoursParser.DayHours]) -> String? {
        for offset in 1...7 {
            let idx = (todayIndex + offset) % 7
            let day = parsed[idx]
            if day.windows == ["open 24h"] {
                return "\(Self.dayNamesLong[idx]) all day"
            }
            // Earliest window of the day wins for the prompt — that's
            // when the venue first reopens after the gap.
            let opens = day.windows.compactMap { parseTimeWindow($0)?.openMinutes }.min()
            if let open = opens {
                return "\(Self.dayNamesLong[idx]) at \(formatClockMinutes(open))"
            }
        }
        return nil
    }

    // MARK: - Hours grid

    @ViewBuilder
    private func hoursGrid(parsed: [RestaurantHoursParser.DayHours]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(parsed, id: \.dayIndex) { day in
                HStack(alignment: .top, spacing: 12) {
                    Text(Self.dayNames[day.dayIndex])
                        .font(.kstText(
                            size: 13,
                            weight: day.dayIndex == todayIndex ? .semibold : .regular
                        ))
                        .foregroundStyle(day.dayIndex == todayIndex
                                         ? KstColor.ink1
                                         : KstColor.ink2)
                        .frame(width: 36, alignment: .leading)
                    // Multi-window days stack each window on its own
                    // line — keeps the lunch/dinner split readable at
                    // a glance. Single-window days look unchanged.
                    if day.windows.isEmpty {
                        Text("Closed")
                            .font(.kstText(size: 13, weight: day.dayIndex == todayIndex ? .semibold : .regular))
                            .foregroundStyle(KstColor.ink3)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(day.windows.enumerated()), id: \.offset) { _, label in
                                Text(formatLabel(label))
                                    .font(.kstText(
                                        size: 13,
                                        weight: day.dayIndex == todayIndex ? .semibold : .regular
                                    ))
                                    .foregroundStyle(KstColor.ink1)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Time formatting

    /// Translate a raw time range like `"17:00–22:00"` into the user's
    /// locale-preferred clock format. Pass-through values like
    /// `"Closed"` and `"open 24h"` get human labels.
    private func formatLabel(_ label: String) -> String {
        if label == "Closed" { return "Closed" }
        if label == "open 24h" { return "Open 24 hours" }
        if let window = parseTimeWindow(label) {
            return "\(formatClockMinutes(window.openMinutes)) – \(formatClockMinutes(window.closeMinutes))"
        }
        return label
    }

    private struct TimeWindow {
        var openMinutes: Int
        var closeMinutes: Int
        /// True when the window wraps past midnight (e.g. 18:00–02:00).
        /// `computeStatus` honors this for the "Open now" predicate.
        var crossesMidnight: Bool { closeMinutes < openMinutes }
    }

    /// Parse `"17:00–22:00"` (en-dash or hyphen) into total-minute
    /// pairs. Returns nil for any other label.
    private func parseTimeWindow(_ label: String) -> TimeWindow? {
        // Accept en-dash or hyphen — our writer uses en-dash, but
        // hand-typed input might use hyphens.
        let parts = label.split(whereSeparator: { $0 == "–" || $0 == "-" })
        guard parts.count == 2 else { return nil }
        guard let openMin = parseClockMinutes(String(parts[0])),
              let closeMin = parseClockMinutes(String(parts[1])) else { return nil }
        return TimeWindow(openMinutes: openMin, closeMinutes: closeMin)
    }

    private func parseClockMinutes(_ s: String) -> Int? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]),
              let m = Int(parts[1]),
              (0...24).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    /// Format `minutes-since-midnight` according to the user's locale.
    /// Reuses a static formatter so it sees the user's 12h/24h
    /// preference rather than hard-coding either.
    private static let displayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.timeStyle = .short
        df.dateStyle = .none
        return df
    }()

    private func formatClockMinutes(_ minutes: Int) -> String {
        var components = DateComponents()
        components.hour = (minutes / 60) % 24
        components.minute = minutes % 60
        // Anchor to today's date so DateFormatter has a real Date to work
        // with. Only the time portion is rendered.
        guard let date = Calendar.current.date(from: components) else {
            return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
        }
        return Self.displayFormatter.string(from: date)
    }

    // MARK: - "Today" / "Now" helpers

    /// Convert Calendar's 1=Sunday … 7=Saturday into Mon=0 … Sun=6.
    private static func currentWeekdayIndex() -> Int {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: Date()) // 1=Sun…7=Sat
        // Sunday (1) → 6; Monday (2) → 0; Saturday (7) → 5.
        return (weekday + 5) % 7
    }

    private static func currentMinuteOfDay() -> Int {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: Date())
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }
}

// MARK: - Detail view cell

/// Wraps `RestaurantHoursView` with an inline edit toggle so the user
/// can still hand-edit the underlying compact string when enrichment
/// got it wrong. Display mode is the default — editing is a click away
/// via a small pencil button so the dense raw text doesn't clutter the
/// record by default.
struct RestaurantHoursValueCell: View {
    var rawValue: String
    @Binding var editingDraft: String
    var property: PropertyRow
    var recordID: String
    var onCommit: () -> Void

    @State private var isEditing: Bool = false

    var body: some View {
        if isEditing {
            // Structured editor first; fall back to plain text when
            // the stored value isn't a shape we can round-trip
            // (e.g. a user-typed "call ahead" or a raw OSM passthrough).
            let canStructure = RestaurantHoursModel.parse(rawValue) != nil
                || rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Spacer()
                    KstButton(style: .ghost, action: { isEditing = false }) {
                        Text("Done")
                    }
                }
                if canStructure {
                    RestaurantHoursEditor(
                        rawValue: $editingDraft,
                        onCommit: onCommit
                    )
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Couldn't parse structured hours — editing as plain text.")
                            .font(.kstText(size: 11, weight: .medium))
                            .foregroundStyle(KstColor.ink3)
                        PropertyValueField(
                            property: property,
                            value: $editingDraft,
                            onCommit: onCommit,
                            recordID: recordID
                        )
                    }
                }
            }
        } else {
            HStack(alignment: .top, spacing: 6) {
                RestaurantHoursView(raw: rawValue)
                Spacer(minLength: 0)
                Button {
                    editingDraft = rawValue
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(KstColor.ink3)
                }
                .buttonStyle(.plain)
                .help("Edit hours")
            }
        }
    }
}
