import SwiftUI

/// Structured per-day editor for a restaurant's `hours` property.
///
/// Layout: a strip of bulk-preset buttons across the top, then seven
/// day rows (Mon→Sun). Each row carries a three-way mode selector
/// (Closed / 24h / Hours), a list of time-range pickers when the day
/// is scheduled, an "Add window" button for split shifts, and a
/// per-day "Apply to…" menu for copying the day's value to weekdays,
/// weekends, or all seven days.
///
/// Every change live-writes through `binding` and fires `onCommit`,
/// matching the idiom of `PropertyValueField` and the rest of the
/// detail view. There is no explicit Save / Cancel; the parent
/// `RestaurantHoursValueCell` provides a "Done" button that flips
/// back to display mode (it doesn't commit anything — every edit
/// already flushed live).
struct RestaurantHoursEditor: View {
    @Binding var rawValue: String
    var onCommit: () -> Void

    @State private var model: RestaurantHoursModel = .empty
    /// True for stored values we can round-trip (parse → model →
    /// serialize → equivalent string). For unparseable inputs the
    /// caller falls back to plain-text editing.
    @State private var didLoadFromBinding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            presetRow
            // Single Grid drives all 7 days so columns lock across
            // rows: day-label, mode-selector, time-pickers, +, ⋯ all
            // sit at the same X regardless of which trailing
            // affordances are visible on a given row, and a
            // continuation window's time pickers align under the
            // first window's pickers.
            Grid(alignment: .leadingFirstTextBaseline,
                 horizontalSpacing: 8,
                 verticalSpacing: 4) {
                ForEach($model.days) { $day in
                    DayRows(day: $day, hoveringRow: $hoveringRow, onApply: { targets in
                        model.applyDay(at: day.dayIndex, to: targets)
                    })
                }
            }
        }
        .onAppear(perform: loadFromBindingIfNeeded)
        .onChange(of: model) { _, _ in
            // Skip the first sync — `loadFromBindingIfNeeded`'s seed
            // shouldn't write back to the property and overwrite the
            // canonical compact form (e.g. trim whitespace) before the
            // user has touched anything.
            guard didLoadFromBinding else { return }
            let serialized = model.serialize()
            guard serialized != rawValue else { return }
            rawValue = serialized
            onCommit()
        }
    }

    /// Day-index of the row the pointer is currently over. Lifted to
    /// the editor level so the per-day hover affordances ( + and ⋯ )
    /// and per-window delete X resolve to a single hovered row
    /// instead of fighting over multiple `@State` slots.
    @State private var hoveringRow: Int? = nil

    private func loadFromBindingIfNeeded() {
        guard !didLoadFromBinding else { return }
        if let parsed = RestaurantHoursModel.parse(rawValue) {
            model = parsed
            // If the stored value was raw OSM grammar (or any other
            // shape that round-trips through our parsers but doesn't
            // match our canonical compact form), rewrite the storage
            // to the canonical form now. This is a one-time cleanup
            // triggered by the user explicitly opening the editor;
            // no data loss (the model is byte-for-byte equivalent),
            // and subsequent reads from the display layer no longer
            // need the OSM-fallback path for this record.
            let canonical = parsed.serialize()
            if canonical != rawValue {
                rawValue = canonical
                onCommit()
            }
        } else {
            // Unparseable — start from empty so the editor isn't
            // visually broken. The parent cell handles the fallback
            // path; this is just a safety net.
            model = .empty
        }
        didLoadFromBinding = true
    }

    // MARK: - Header preset row

    @State private var presetTarget: PresetTarget?

    private enum PresetTarget: Identifiable {
        case weekdays, weekends, every
        var id: Int {
            switch self {
            case .weekdays: return 0
            case .weekends: return 1
            case .every: return 2
            }
        }
        var label: String {
            switch self {
            case .weekdays: return "Set weekdays…"
            case .weekends: return "Set weekends…"
            case .every: return "Set every day…"
            }
        }
        var indexes: [Int] {
            switch self {
            case .weekdays: return RestaurantHoursModel.weekdayIndexes
            case .weekends: return RestaurantHoursModel.weekendIndexes
            case .every: return RestaurantHoursModel.allIndexes
            }
        }
    }

    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach([PresetTarget.weekdays, .weekends, .every]) { target in
                KstButton(style: .standard, action: { presetTarget = target }) {
                    Text(target.label)
                }
            }
        }
        .sheet(item: $presetTarget) { target in
            PresetSheet(title: target.label, onApply: { mode, windows in
                model.applyPreset(mode: mode, windows: windows, to: target.indexes)
                presetTarget = nil
            }, onCancel: { presetTarget = nil })
        }
    }
}

// MARK: - Day rows

/// Emits the GridRows for one day — always a primary row, plus a
/// continuation row for each extra window when the day is in
/// `.scheduled` mode with multi-windows.
private struct DayRows: View {
    @Binding var day: RestaurantHoursModel.DayHours
    @Binding var hoveringRow: Int?
    var onApply: (_ targets: [Int]) -> Void

    private static let dayLabels = [
        "Monday", "Tuesday", "Wednesday", "Thursday",
        "Friday", "Saturday", "Sunday"
    ]

    private var isHovering: Bool { hoveringRow == day.dayIndex }
    private func hoverBinding() -> Binding<Bool> {
        Binding(
            get: { hoveringRow == day.dayIndex },
            set: { hoveringRow = $0 ? day.dayIndex : (hoveringRow == day.dayIndex ? nil : hoveringRow) }
        )
    }

    var body: some View {
        // Primary row.
        GridRow(alignment: .center) {
            Text(Self.dayLabels[day.dayIndex])
                .font(.kstText(size: 12, weight: .medium))
                .foregroundStyle(KstColor.ink1)
                .frame(width: 78, alignment: .leading)
                .gridColumnAlignment(.leading)

            modeSelector

            // Time-pickers column. Closed/24h days render an invisible
            // placeholder so the Grid still tracks a column slot at
            // this position — keeps `+` and `⋯` from sliding leftward
            // on days without pickers.
            Group {
                if day.mode == .scheduled, let first = day.windows.first {
                    WindowRow(
                        window: bindingForWindow(id: first.id),
                        hovering: hoverBinding(),
                        onDelete: { removeWindow(id: first.id) }
                    )
                } else {
                    Color.clear.frame(width: 1, height: 1)
                }
            }
            .gridColumnAlignment(.leading)

            // `+ Add window` slot. Always rendered as a fixed-width
            // cell so the next column (`⋯`) doesn't drift when the
            // button hides on non-scheduled days.
            Group {
                if day.mode == .scheduled {
                    Button(action: appendWindow) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(KstColor.ink2)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .help("Add another window")
                    .opacity(isHovering ? 1 : 0.55)
                } else {
                    Color.clear.frame(width: 18, height: 18)
                }
            }
            .gridColumnAlignment(.center)

            applyMenu
                .gridColumnAlignment(.center)
        }
        .frame(minHeight: 28)
        .contentShape(Rectangle())
        .onHover { hoveringRow = $0 ? day.dayIndex : (hoveringRow == day.dayIndex ? nil : hoveringRow) }

        // Continuation rows for extra windows. Day-label and
        // mode-selector columns get tiny placeholders; the time-
        // pickers column shares an X with the primary row so
        // `5:00 PM – 10:00 PM` sits exactly under
        // `9:00 AM – 5:00 PM`.
        if day.mode == .scheduled, day.windows.count > 1 {
            ForEach(day.windows.dropFirst()) { window in
                GridRow(alignment: .center) {
                    Color.clear.frame(width: 78, height: 1)
                    Color.clear.frame(width: Self.modeSelectorWidth, height: 1)
                    WindowRow(
                        window: bindingForWindow(id: window.id),
                        hovering: hoverBinding(),
                        onDelete: { removeWindow(id: window.id) }
                    )
                    .gridColumnAlignment(.leading)
                    Color.clear.frame(width: 18, height: 1)
                    Color.clear.frame(width: 18, height: 1)
                }
                .frame(minHeight: 26)
                .onHover { hoveringRow = $0 ? day.dayIndex : (hoveringRow == day.dayIndex ? nil : hoveringRow) }
            }
        }
    }

    /// Width the segmented mode selector consumes — pinned so
    /// continuation rows can pad to the same X position.
    static let modeSelectorWidth: CGFloat = 158

    private var modeSelector: some View {
        HStack(spacing: 0) {
            modeButton(.closed, label: "Closed")
            modeButton(.open24h, label: "24h")
            modeButton(.scheduled, label: "Hours")
        }
        .frame(width: Self.modeSelectorWidth, height: 22)
        .background(
            RoundedRectangle(cornerRadius: KstRadius.r2, style: .continuous)
                .fill(KstColor.paper1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: KstRadius.r2, style: .continuous)
                .strokeBorder(KstColor.ink4.opacity(0.5), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: KstRadius.r2, style: .continuous))
    }

    private func modeButton(_ mode: RestaurantHoursModel.DayMode, label: String) -> some View {
        Button {
            switch mode {
            case .scheduled:
                if day.windows.isEmpty {
                    day.windows = [.init(openMinutes: 9 * 60, closeMinutes: 17 * 60)]
                }
            case .closed, .open24h:
                day.windows = []
            }
            day.mode = mode
        } label: {
            Text(label)
                .font(.kstText(size: 11, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if day.mode == mode {
                        RoundedRectangle(cornerRadius: KstRadius.r1, style: .continuous)
                            .fill(KstColor.paper0)
                            .padding(2)
                    }
                }
                .foregroundStyle(day.mode == mode ? KstColor.ink0 : KstColor.ink2)
        }
        .buttonStyle(.plain)
    }

    private func bindingForWindow(id: UUID) -> Binding<RestaurantHoursModel.TimeWindow> {
        Binding(
            get: {
                day.windows.first(where: { $0.id == id })
                    ?? .init(openMinutes: 9 * 60, closeMinutes: 17 * 60)
            },
            set: { newValue in
                guard let idx = day.windows.firstIndex(where: { $0.id == id }) else { return }
                day.windows[idx] = newValue
            }
        )
    }

    private func removeWindow(id: UUID) {
        day.windows.removeAll { $0.id == id }
        if day.windows.isEmpty { day.mode = .closed }
    }

    private func appendWindow() {
        let last = day.windows.last
        let suggestedOpen = last.map { $0.closeMinutes } ?? (17 * 60)
        let suggestedClose = min(suggestedOpen + 5 * 60, 23 * 60 + 59)
        day.windows.append(.init(
            openMinutes: suggestedOpen,
            closeMinutes: suggestedClose
        ))
    }

    private var applyMenu: some View {
        Menu {
            Button("Apply to weekdays") {
                onApply(RestaurantHoursModel.weekdayIndexes)
            }
            Button("Apply to weekends") {
                onApply(RestaurantHoursModel.weekendIndexes)
            }
            Button("Apply to every day") {
                onApply(RestaurantHoursModel.allIndexes)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(KstColor.ink3)
                .frame(width: 18, height: 18)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Apply this day's hours to…")
        .opacity(isHovering ? 1 : 0.55)
    }
}

// MARK: - Window row

private struct WindowRow: View {
    @Binding var window: RestaurantHoursModel.TimeWindow
    @Binding var hovering: Bool
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            TimePicker(minutes: $window.openMinutes)
            Text("–")
                .font(.kstText(size: 11))
                .foregroundStyle(KstColor.ink3)
            TimePicker(minutes: $window.closeMinutes)
            if window.crossesMidnight {
                Text("next day")
                    .font(.kstText(size: 10, weight: .medium))
                    .foregroundStyle(KstColor.ink3)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(KstColor.paper2)
                    )
            }
            // Always allocate the X slot so the time-pickers column
            // doesn't widen on hover. Only the icon fades in.
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(KstColor.ink3)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("Remove this window")
            .opacity(hovering ? 1 : 0)
        }
    }
}

// MARK: - Time picker

/// Minute-of-day picker. On macOS we render a tight click-to-edit
/// button with a popover (SwiftUI's `.compact` DatePicker for
/// `.hourAndMinute` falls back to `.field` with steppers on macOS,
/// which adds significant visual noise). On iOS we keep the system
/// `.compact` style — it pops a wheel and looks native.
private struct TimePicker: View {
    @Binding var minutes: Int

    var body: some View {
        #if os(macOS)
        MacTimePicker(minutes: $minutes)
        #else
        DatePicker("", selection: Binding(
            get: { Self.date(forMinutes: minutes) },
            set: { newDate in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                let newMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
                if newMinutes != minutes { minutes = newMinutes }
            }
        ), displayedComponents: [.hourAndMinute])
        .datePickerStyle(.compact)
        .labelsHidden()
        #endif
    }

    fileprivate static func date(forMinutes minutes: Int) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = (minutes / 60) % 24
        comps.minute = minutes % 60
        return Calendar.current.date(from: comps) ?? Date()
    }
}

#if os(macOS)
/// macOS-only click-to-edit time button. Shows the formatted time
/// (locale-aware AM/PM or 24h) in a small pill; clicking opens a
/// popover with a graphical wheel picker. No stepper arrows.
private struct MacTimePicker: View {
    @Binding var minutes: Int

    @State private var showingPopover = false
    @State private var hovering = false

    private static let formatter: DateFormatter = {
        let df = DateFormatter()
        df.timeStyle = .short
        df.dateStyle = .none
        return df
    }()

    var body: some View {
        Button {
            showingPopover = true
        } label: {
            Text(Self.formatter.string(from: TimePicker.date(forMinutes: minutes)))
                .font(.kstText(size: 12, weight: .medium))
                .foregroundStyle(KstColor.ink0)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: KstRadius.r1, style: .continuous)
                        .fill(hovering ? KstColor.paper2 : KstColor.paper1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: KstRadius.r1, style: .continuous)
                        .strokeBorder(KstColor.ink4.opacity(0.4), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            // `.field` is the familiar Mac type-or-step time field
            // (the one Calendar.app uses). `.graphical` for
            // `.hourAndMinute` on macOS is the analog clock, which is
            // precision hell — dragging hands to hit "9:00" exactly is
            // fiddly. The field style lets you click and type, tab
            // between hour/minute, or use the steppers.
            DatePicker("", selection: Binding(
                get: { TimePicker.date(forMinutes: minutes) },
                set: { newDate in
                    let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                    let newMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
                    if newMinutes != minutes { minutes = newMinutes }
                }
            ), displayedComponents: [.hourAndMinute])
            .datePickerStyle(.field)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }
}
#endif

// MARK: - Preset sheet

private struct PresetSheet: View {
    var title: String
    var onApply: (RestaurantHoursModel.DayMode, [RestaurantHoursModel.TimeWindow]) -> Void
    var onCancel: () -> Void

    @State private var mode: RestaurantHoursModel.DayMode = .scheduled
    @State private var openMinutes: Int = 9 * 60
    @State private var closeMinutes: Int = 17 * 60

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.kstText(size: 14, weight: .semibold))
                .foregroundStyle(KstColor.ink0)

            HStack(spacing: 6) {
                presetModeButton(.closed, label: "Closed")
                presetModeButton(.open24h, label: "24h")
                presetModeButton(.scheduled, label: "Hours")
            }

            if mode == .scheduled {
                HStack(spacing: 6) {
                    TimePicker(minutes: $openMinutes)
                    Text("–")
                    TimePicker(minutes: $closeMinutes)
                    if closeMinutes < openMinutes {
                        Text("(next day)")
                            .font(.kstText(size: 11, weight: .medium))
                            .foregroundStyle(KstColor.ink3)
                    }
                }
            }

            HStack {
                Spacer()
                KstButton(style: .ghost, action: onCancel) { Text("Cancel") }
                KstButton(style: .primary, action: applyAction) { Text("Apply") }
            }
        }
        .padding(18)
        .frame(width: 340)
    }

    private func presetModeButton(_ value: RestaurantHoursModel.DayMode, label: String) -> some View {
        Button {
            mode = value
        } label: {
            Text(label)
                .font(.kstText(size: 12, weight: .medium))
                .frame(height: 26)
                .padding(.horizontal, 14)
                .background {
                    RoundedRectangle(cornerRadius: KstRadius.r2, style: .continuous)
                        .fill(mode == value ? KstColor.paper0 : KstColor.paper1)
                        .overlay(
                            RoundedRectangle(cornerRadius: KstRadius.r2, style: .continuous)
                                .strokeBorder(
                                    mode == value ? KstColor.ink2.opacity(0.4) : Color.clear,
                                    lineWidth: 0.5
                                )
                        )
                }
                .foregroundStyle(KstColor.ink0)
        }
        .buttonStyle(.plain)
    }

    private func applyAction() {
        switch mode {
        case .closed, .open24h:
            onApply(mode, [])
        case .scheduled:
            onApply(.scheduled, [
                .init(openMinutes: openMinutes, closeMinutes: closeMinutes)
            ])
        }
    }
}
