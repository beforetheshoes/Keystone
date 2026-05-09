import SwiftUI

/// Calendar view for any database whose schema includes at least one
/// `date` or `date_tz` property. Self-contained — owns its mode / anchor
/// / chosen date property as `@State` rather than threading through the
/// root reducer (matches Gallery / List / Dashboard).
struct CalendarView: View {
    var db: DBRow
    var properties: [PropertyRow]
    var records: [RecordRow]
    var onOpen: (RecordRow) -> Void
    /// Initial display mode. The user can switch via the toolbar.
    var initialMode: CalendarMode = .month
    /// Initial anchor date. Defaults to "now" so a fresh open lands on
    /// today; embedders that want to focus a specific window (e.g. the
    /// Trip detail's mini-calendar landing on the trip's start date)
    /// override here.
    var initialAnchor: Date? = nil
    /// When non-nil, events whose start instant falls outside this range
    /// are filtered out before rendering. Used by the Trip detail
    /// augmentation to scope the embedded calendar to the trip's window.
    var dateRangeFilter: ClosedRange<Date>? = nil

    @State private var mode: CalendarMode
    @State private var anchor: Date
    @State private var anchorPropKey: String?

    init(
        db: DBRow,
        properties: [PropertyRow],
        records: [RecordRow],
        onOpen: @escaping (RecordRow) -> Void,
        initialMode: CalendarMode = .month,
        initialAnchor: Date? = nil,
        dateRangeFilter: ClosedRange<Date>? = nil
    ) {
        self.db = db
        self.properties = properties
        self.records = records
        self.onOpen = onOpen
        self.initialMode = initialMode
        self.initialAnchor = initialAnchor
        self.dateRangeFilter = dateRangeFilter
        _mode = State(initialValue: initialMode)
        _anchor = State(initialValue: initialAnchor ?? .now)
    }

    var body: some View {
        VStack(spacing: 0) {
            CalendarToolbar(
                mode: $mode,
                anchor: $anchor,
                dateProperties: dateProperties,
                anchorPropKey: $anchorPropKey
            )
            content
        }
        .background(KstColor.paper0)
    }

    private var dateProperties: [PropertyRow] {
        properties.filter { $0.type == .date || $0.type == .dateTZ }
    }

    private var anchorProperty: PropertyRow? {
        if let key = anchorPropKey { return dateProperties.first { $0.key == key } }
        return dateProperties.first
    }

    private var events: [CalendarEvent] {
        guard let prop = anchorProperty else { return [] }
        let all = CalendarEventBuilder.events(from: records, anchor: prop, in: properties)
        guard let range = dateRangeFilter else { return all }
        return all.filter { range.contains($0.start) }
    }

    private func openEvent(_ event: CalendarEvent) {
        if let record = records.first(where: { $0.id == event.id }) {
            onOpen(record)
        }
    }

    @ViewBuilder
    private var content: some View {
        if anchorProperty == nil {
            VStack(spacing: 8) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 32))
                    .foregroundStyle(KstColor.ink3)
                Text("No date column")
                    .font(.kstText(size: 14, weight: .medium))
                    .foregroundStyle(KstColor.ink1)
                Text("Add a date or date+time-zone property to see records on the calendar.")
                    .font(.kstText(size: 12))
                    .foregroundStyle(KstColor.ink3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch mode {
            case .month:
                CalendarMonthView(anchor: anchor, events: events, accent: db.accent, onOpen: openEvent)
            case .week:
                CalendarWeekView(anchor: anchor, events: events, accent: db.accent, onOpen: openEvent)
            case .day:
                CalendarDayView(anchor: anchor, events: events, accent: db.accent, onOpen: openEvent)
            case .compact:
                CalendarCompactView(anchor: $anchor, events: events, accent: db.accent, onOpen: openEvent)
            }
        }
    }
}

// MARK: - Toolbar

private struct CalendarToolbar: View {
    @Binding var mode: CalendarMode
    @Binding var anchor: Date
    let dateProperties: [PropertyRow]
    @Binding var anchorPropKey: String?

    var body: some View {
        HStack(spacing: 12) {
            modeSwitcher
            navigationCluster
            Spacer()
            anchorPropMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(KstColor.paper1)
        .overlay(alignment: .bottom) { KstHairline() }
    }

    private var modeSwitcher: some View {
        HStack(spacing: 1) {
            ForEach(CalendarMode.allCases, id: \.self) { m in
                Button { mode = m } label: {
                    Text(label(for: m))
                        .font(.kstText(size: 12, weight: mode == m ? .semibold : .medium))
                        .foregroundStyle(mode == m ? KstColor.ink0 : KstColor.ink2)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(mode == m ? KstColor.paper0 : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(KstColor.paper2)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
    }

    private var navigationCluster: some View {
        HStack(spacing: 6) {
            Button { anchor = CalendarLayout.step(anchor, by: -1, mode: mode) } label: {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)

            Button("Today") { anchor = Date() }
                .buttonStyle(.bordered)
                .font(.kstText(size: 12))

            Button { anchor = CalendarLayout.step(anchor, by: +1, mode: mode) } label: {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)

            Text(headerLabel)
                .font(.kstText(size: 13, weight: .semibold))
                .foregroundStyle(KstColor.ink0)
                .padding(.leading, 6)
        }
    }

    @ViewBuilder
    private var anchorPropMenu: some View {
        if dateProperties.count > 1 {
            Menu {
                ForEach(dateProperties) { prop in
                    Button(prop.name) { anchorPropKey = prop.key }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 11))
                    Text(currentPropName)
                        .font(.kstText(size: 12))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var currentPropName: String {
        if let key = anchorPropKey,
           let match = dateProperties.first(where: { $0.key == key }) {
            return match.name
        }
        return dateProperties.first?.name ?? ""
    }

    private var headerLabel: String {
        switch mode {
        case .month, .compact: return CalendarLayout.monthLabel(for: anchor)
        case .week:            return CalendarLayout.weekLabel(for: CalendarLayout.week(containing: anchor))
        case .day:             return CalendarLayout.dayLabel(for: anchor)
        }
    }

    private func label(for m: CalendarMode) -> String {
        switch m {
        case .month: return "Month"
        case .week: return "Week"
        case .day: return "Day"
        case .compact: return "Compact"
        }
    }
}
