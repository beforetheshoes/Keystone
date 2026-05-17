import SwiftUI

/// Type-aware input control for a property. Hands back the canonical string
/// that should be stored (ISO date for dates, digits-only-then-formatted for
/// phones, lowercased trimmed for email, etc.) so both the UI and the
/// persistence layer agree on what's saved.
struct PropertyValueField: View {
    var property: PropertyRow
    @Binding var value: String
    var onCommit: () -> Void
    /// The record being edited, when known. The address editor uses
    /// it to hydrate structured state via `DatabaseClient.propertyJSON`;
    /// other field kinds ignore it. Default-nil keeps existing call
    /// sites compiling unchanged.
    var recordID: String? = nil
    /// Optional hook for the select / multiSelect editors to register
    /// a brand-new option on the property when the user types one via
    /// the "Add new…" affordance. When nil, the affordance is hidden.
    var onAddOption: ((_ option: String) -> Void)? = nil
    /// Optional hook to remove an option from the property and strip
    /// it from every record that carries it. When nil, the per-option
    /// delete affordance in the multiSelect popover is hidden.
    var onDeleteOption: ((_ option: String) -> Void)? = nil

    var body: some View {
        switch property.type {
        case .date:
            DateField(value: $value, onCommit: onCommit)
        case .dateTZ:
            DateTimeZoneField(value: $value, onCommit: onCommit)
        case .address:
            HStack(spacing: 6) {
                AddressAutocompleteField(
                    value: $value,
                    recordID: recordID,
                    propertyKey: property.key,
                    onCommit: onCommit
                )
                DirectionsMenu(rawValue: value)
            }
        case .phone:
            PhoneField(value: $value, onCommit: onCommit)
        case .email:
            EmailField(value: $value, onCommit: onCommit)
        case .url:
            URLField(value: $value, onCommit: onCommit)
        case .number, .currency:
            NumberField(value: $value, onCommit: onCommit)
        case .checkbox:
            CheckboxField(value: $value, onCommit: onCommit)
        case .json:
            JSONField(value: $value, onCommit: onCommit)
        case .select:
            SelectField(property: property, value: $value, onCommit: onCommit, onAddOption: onAddOption)
        case .multiSelect:
            MultiSelectField(
                property: property,
                value: $value,
                onCommit: onCommit,
                onAddOption: onAddOption,
                onDeleteOption: onDeleteOption
            )
        default:
            TextField("—", text: $value)
                .textFieldStyle(.plain)
                .font(.kstText(size: 13))
                .foregroundStyle(value.isEmpty ? KstColor.ink3 : KstColor.ink0)
                .onSubmit(onCommit)
                .onChange(of: value) { _, _ in onCommit() }
        }
    }
}

// MARK: - Date

private struct DateField: View {
    @Binding var value: String
    var onCommit: () -> Void

    @State private var date: Date = Date()
    @State private var isPresentingPicker = false

    var body: some View {
        Button { isPresentingPicker.toggle() } label: {
            HStack(spacing: 6) {
                if let parsed = DateValueCodec.parse(value) {
                    Text(DateValueCodec.display(parsed))
                        .font(.kstText(size: 13))
                        .foregroundStyle(KstColor.ink0)
                } else if value.isEmpty {
                    Text("—")
                        .font(.kstText(size: 13))
                        .foregroundStyle(KstColor.ink3)
                } else {
                    Text(value)
                        .font(.kstText(size: 13))
                        .foregroundStyle(KstColor.ink2)
                        .italic()
                }
                Spacer(minLength: 0)
                Image(systemName: "calendar")
                    .font(.system(size: 11))
                    .foregroundStyle(KstColor.ink3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresentingPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                #if os(macOS)
                MonthYearJumpBar(date: $date)
                #endif
                DatePicker(
                    "Date",
                    selection: $date,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
                .labelsHidden()

                HStack {
                    Button("Clear") {
                        value = ""
                        onCommit()
                        isPresentingPicker = false
                    }
                    Spacer()
                    Button("Done") {
                        value = DateValueCodec.iso(date)
                        onCommit()
                        isPresentingPicker = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(minWidth: 280)
        }
        .onAppear {
            if let parsed = DateValueCodec.parse(value) { date = parsed }
        }
        .onChange(of: value) { _, new in
            if let parsed = DateValueCodec.parse(new) { date = parsed }
        }
    }
}

#if os(macOS)
/// Month + Year jump menus shown above a `.graphical` DatePicker on
/// macOS. The system header on that style is read-only on macOS, which
/// makes navigating to far-past years (birthdates) require dozens of
/// arrow clicks. This bar lets the user jump in one selection. iOS
/// already exposes a tappable year/month header on the graphical style,
/// so this is macOS-only.
private struct MonthYearJumpBar: View {
    @Binding var date: Date

    private static let yearRange: [Int] = {
        let now = Calendar.current.component(.year, from: Date())
        return Array(((now - 120)...(now + 10)).reversed())
    }()
    private static let monthSymbols = Calendar.current.standaloneMonthSymbols

    var body: some View {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        let monthBinding = Binding<Int>(
            get: { comps.month ?? 1 },
            set: { apply(year: comps.year ?? 1970, month: $0, day: comps.day ?? 1) }
        )
        let yearBinding = Binding<Int>(
            get: { comps.year ?? 1970 },
            set: { apply(year: $0, month: comps.month ?? 1, day: comps.day ?? 1) }
        )
        HStack(spacing: 8) {
            Picker("Month", selection: monthBinding) {
                ForEach(Array(Self.monthSymbols.enumerated()), id: \.offset) { idx, name in
                    Text(name).tag(idx + 1)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 110)

            Picker("Year", selection: yearBinding) {
                ForEach(Self.yearRange, id: \.self) { y in
                    Text(verbatim: String(y)).tag(y)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 84)

            Spacer(minLength: 0)
        }
    }

    private func apply(year: Int, month: Int, day: Int) {
        let cal = Calendar.current
        var probe = DateComponents(year: year, month: month, day: 1)
        guard let firstOfMonth = cal.date(from: probe),
              let range = cal.range(of: .day, in: .month, for: firstOfMonth)
        else { return }
        probe.day = min(max(day, 1), range.upperBound - 1)
        if let newDate = cal.date(from: probe) { date = newDate }
    }
}
#endif

// MARK: - Date range

/// Combined editor for two paired plain-`date` properties (e.g. trip
/// `start_date` + `end_date`). Inlines two macOS-native `.compact`
/// `DatePicker`s side by side — same chrome Calendar.app / Reminders.app
/// use for date-range fields. Each picker opens the system calendar
/// popover on click; we don't wrap them in a custom popover of our own.
///
/// Empty state: the row collapses to a single "Add dates" trigger so
/// unset trips don't display today/today as if pre-populated. Picking
/// a date materializes both pickers and persists them; the small ✕
/// button reverts to empty.
struct DateRangeField: View {
    @Binding var startValue: String
    @Binding var endValue: String
    var onCommitStart: () -> Void
    var onCommitEnd: () -> Void

    @State private var startDate: Date = Date()
    @State private var endDate: Date = Date()

    private var hasAnyValue: Bool { !startValue.isEmpty || !endValue.isEmpty }

    var body: some View {
        Group {
            if hasAnyValue {
                editor
            } else {
                addTrigger
            }
        }
        .onAppear { syncDates() }
        .onChange(of: startValue) { _, _ in syncDates() }
        .onChange(of: endValue) { _, _ in syncDates() }
    }

    private var addTrigger: some View {
        Button {
            // Materialize both ends with today as the default. The user
            // immediately adjusts via the inline pickers that replace
            // this trigger.
            let today = Date()
            startDate = today
            endDate = today
            startValue = DateValueCodec.iso(today)
            endValue = DateValueCodec.iso(today)
            onCommitStart()
            onCommitEnd()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 11))
                    .foregroundStyle(KstColor.ink3)
                Text("Add dates")
                    .font(.kstText(size: 13))
                    .foregroundStyle(KstColor.ink3)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var editor: some View {
        HStack(spacing: 8) {
            DatePicker(
                "Start",
                selection: $startDate,
                displayedComponents: [.date]
            )
            .datePickerStyle(.compact)
            .labelsHidden()
            .onChange(of: startDate) { _, newDate in
                let iso = DateValueCodec.iso(newDate)
                guard iso != startValue else { return }
                startValue = iso
                onCommitStart()
                // Keep end ≥ start: if the user moved start past the
                // existing end, snap end forward.
                if let parsedEnd = DateValueCodec.parse(endValue), parsedEnd < newDate {
                    endDate = newDate
                    endValue = iso
                    onCommitEnd()
                }
            }

            Text("–")
                .font(.kstText(size: 13))
                .foregroundStyle(KstColor.ink3)

            DatePicker(
                "End",
                selection: $endDate,
                in: startDate...,
                displayedComponents: [.date]
            )
            .datePickerStyle(.compact)
            .labelsHidden()
            .onChange(of: endDate) { _, newDate in
                let iso = DateValueCodec.iso(newDate)
                guard iso != endValue else { return }
                endValue = iso
                onCommitEnd()
            }

            Button {
                startValue = ""
                endValue = ""
                onCommitStart()
                onCommitEnd()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(KstColor.ink3)
            }
            .buttonStyle(.plain)
            .help("Clear dates")

            Spacer(minLength: 0)
        }
    }

    private func syncDates() {
        if let parsed = DateValueCodec.parse(startValue) { startDate = parsed }
        if let parsed = DateValueCodec.parse(endValue) { endDate = parsed }
    }
}

// MARK: - Phone

private struct PhoneField: View {
    @Binding var value: String
    var onCommit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            TextField("—", text: Binding(
                get: { value },
                set: { newValue in
                    value = PhoneValueCodec.format(newValue)
                }
            ))
            .textFieldStyle(.plain)
            .font(.kstMono(size: 13))
            .foregroundStyle(value.isEmpty ? KstColor.ink3 : KstColor.ink0)
            #if os(iOS)
            .keyboardType(.phonePad)
            .textContentType(.telephoneNumber)
            #endif
            .onSubmit(onCommit)
            .onChange(of: value) { _, _ in onCommit() }

            if let url = PhoneValueCodec.telURL(value) {
                ConfirmedURLAction(
                    url: url,
                    prompt: "Call \(value)?",
                    detail: nil,
                    primaryLabel: "Call"
                ) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(KstColor.ink2)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: KstRadius.r1, style: .continuous)
                                .fill(KstColor.paper1)
                        )
                }
                .help("Call \(value)")
            }
        }
    }
}

enum PhoneValueCodec {
    /// Reformat a phone string as the user types. Handles US-style 10/11-digit
    /// patterns; longer or non-numeric strings pass through unchanged so
    /// international numbers and extensions aren't mangled.
    static func format(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        switch digits.count {
        case 0:
            return ""
        case 1...3:
            return "(" + digits
        case 4...6:
            let area = digits.prefix(3)
            let mid = digits.dropFirst(3)
            return "(\(area)) \(mid)"
        case 7...10:
            let area = digits.prefix(3)
            let mid = digits.dropFirst(3).prefix(3)
            let last = digits.dropFirst(6)
            return "(\(area)) \(mid)-\(last)"
        case 11:
            // 1NNNNNNNNNN → +1 (NNN) NNN-NNNN
            let country = digits.prefix(1)
            let area = digits.dropFirst(1).prefix(3)
            let mid = digits.dropFirst(4).prefix(3)
            let last = digits.dropFirst(7)
            return "+\(country) (\(area)) \(mid)-\(last)"
        default:
            return raw
        }
    }

    /// Strip the US "+1 " country-code prefix when present. The
    /// stored value still carries the country code (so the detail
    /// view's `tel:` link dials correctly internationally), but
    /// table-cell display is tighter and more scannable without it
    /// when every row is a domestic number.
    static func displayUS(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("+1 ") {
            return String(trimmed.dropFirst(3))
        }
        return trimmed
    }

    /// Build a `tel:` URL for dialing. Strips punctuation but preserves
    /// the leading `+` for international numbers. Returns nil when
    /// `raw` has fewer than 4 digits (likely a typo, not a real
    /// dialable number).
    static func telURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let plus = trimmed.hasPrefix("+") ? "+" : ""
        let digits = trimmed.filter(\.isNumber)
        guard digits.count >= 4 else { return nil }
        return URL(string: "tel:\(plus)\(digits)")
    }
}

// MARK: - Email

private struct EmailField: View {
    @Binding var value: String
    var onCommit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        TextField("—", text: $value)
            .textFieldStyle(.plain)
            .font(.kstText(size: 13))
            .foregroundStyle(textColor)
            .focused($focused)
            #if os(iOS)
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
            .onSubmit(onCommit)
            .onChange(of: value) { _, _ in onCommit() }
    }

    private var textColor: Color {
        if value.isEmpty { return KstColor.ink3 }
        // Subtle invalid-state cue while not focused.
        if !focused, !isLikelyEmail(value) { return KstColor.dangerInk }
        return KstColor.ink0
    }

    private func isLikelyEmail(_ s: String) -> Bool {
        let r = s.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression)
        return r != nil
    }
}

// MARK: - URL

private struct URLField: View {
    @Binding var value: String
    var onCommit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            TextField("—", text: $value)
                .textFieldStyle(.plain)
                .font(.kstText(size: 13))
                .foregroundStyle(value.isEmpty ? KstColor.ink3 : KstColor.ink0)
                #if os(iOS)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
                .onSubmit(onCommit)
                .onChange(of: value) { _, _ in onCommit() }

            if let url = URLValueCodec.normalize(value) {
                ConfirmedURLAction(
                    url: url,
                    prompt: "Open this link?",
                    detail: url.absoluteString,
                    primaryLabel: "Open"
                ) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(KstColor.ink2)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: KstRadius.r1, style: .continuous)
                                .fill(KstColor.paper1)
                        )
                }
                .help("Open \(url.absoluteString)")
            }
        }
    }
}

enum URLValueCodec {
    /// Normalize a user-typed URL string into something `Link` will
    /// actually open: missing scheme gets `https://` slapped on, raw
    /// `mailto:` / `tel:` patterns pass through. Returns nil when the
    /// value can't be coerced into a valid URL.
    static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return URL(string: "https://\(trimmed)")
    }
}

// MARK: - Number

private struct NumberField: View {
    @Binding var value: String
    var onCommit: () -> Void

    var body: some View {
        TextField("—", text: Binding(
            get: { value },
            set: { newValue in
                // Permit only digits, decimal separator, and a leading minus.
                value = sanitize(newValue)
            }
        ))
        .textFieldStyle(.plain)
        .font(.kstMono(size: 13))
        .foregroundStyle(value.isEmpty ? KstColor.ink3 : KstColor.ink0)
        #if os(iOS)
        .keyboardType(.decimalPad)
        #endif
        .onSubmit(onCommit)
        .onChange(of: value) { _, _ in onCommit() }
    }

    private func sanitize(_ raw: String) -> String {
        var seenDot = false
        var out = ""
        for (i, ch) in raw.enumerated() {
            if i == 0, ch == "-" { out.append(ch); continue }
            if ch.isNumber { out.append(ch); continue }
            if ch == ".", !seenDot { out.append(ch); seenDot = true; continue }
        }
        return out
    }
}

// MARK: - JSON

private struct JSONField: View {
    @Binding var value: String
    var onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $value)
                .font(.kstMono(size: 12))
                .foregroundStyle(value.isEmpty ? KstColor.ink3 : KstColor.ink0)
                .frame(minHeight: 64, idealHeight: 96, maxHeight: 240)
                .scrollContentBackground(.hidden)
                .background(KstColor.paper1)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onChange(of: value) { _, _ in onCommit() }

            if !value.isEmpty && !isValidJSON {
                Text("Invalid JSON — value will be kept as text until corrected.")
                    .font(.kstText(size: 11))
                    .foregroundStyle(KstColor.ink2)
            }
        }
    }

    private var isValidJSON: Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    private var borderColor: Color {
        if value.isEmpty || isValidJSON { return KstColor.ink4 }
        return Color.orange.opacity(0.6)
    }
}

// MARK: - Date + Time Zone

/// Editor for `date_tz` properties. Display surface shows the parsed
/// event-local + viewer-local lines (`DateTimeZoneSection`) and opens a
/// popover with date / time / tz controls on tap. All-day toggle hides
/// the time picker and forces midnight-in-event-tz storage.
private struct DateTimeZoneField: View {
    @Binding var value: String
    var onCommit: () -> Void

    @State private var date: Date = Date()
    @State private var timezone: TimeZone = .autoupdatingCurrent
    @State private var isAllDay: Bool = false
    @State private var isPresentingPopover = false
    @State private var isPresentingTZSheet = false

    var body: some View {
        Button { isPresentingPopover.toggle() } label: {
            HStack(alignment: .center, spacing: 6) {
                if let parsed = DateValueCodec.parseTZ(value) {
                    DateTimeZoneSection(value: parsed)
                } else if value.isEmpty {
                    Text("—")
                        .font(.kstText(size: 13))
                        .foregroundStyle(KstColor.ink3)
                } else {
                    Text(value)
                        .font(.kstText(size: 13))
                        .foregroundStyle(KstColor.ink2)
                        .italic()
                }
                Spacer(minLength: 0)
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 11))
                    .foregroundStyle(KstColor.ink3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresentingPopover, arrowEdge: .bottom) {
            popoverContent
                .padding(14)
                .frame(minWidth: 320)
        }
        .onAppear { hydrate() }
        .onChange(of: value) { _, _ in hydrate() }
    }

    @ViewBuilder
    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if os(macOS)
            MonthYearJumpBar(date: $date)
            #endif
            DatePicker("Date", selection: $date, displayedComponents: [.date])
                .datePickerStyle(.graphical)
                .labelsHidden()

            Toggle("All day", isOn: $isAllDay)
                .toggleStyle(.switch)
                .font(.kstText(size: 13))

            if !isAllDay {
                DatePicker("Time", selection: $date, displayedComponents: [.hourAndMinute])
                    .datePickerStyle(.compact)
                    .labelsHidden()
            }

            Button {
                isPresentingTZSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .font(.system(size: 11))
                    Text(timezone.identifier)
                        .font(.kstText(size: 13))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(KstColor.ink3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)

            HStack {
                Button("Clear") {
                    value = ""
                    onCommit()
                    isPresentingPopover = false
                }
                Spacer()
                Button("Done") {
                    commit()
                    isPresentingPopover = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .sheet(isPresented: $isPresentingTZSheet) {
            TimeZonePickerSheet(current: timezone.identifier) { picked in
                if let tz = TimeZone(identifier: picked) { timezone = tz }
            }
        }
    }

    private func hydrate() {
        if let parsed = DateValueCodec.parseTZ(value) {
            date = parsed.date
            timezone = parsed.timezone
            isAllDay = parsed.isAllDay
        }
    }

    private func commit() {
        let parsed = DateTZValue(date: date, timezone: timezone, isAllDay: isAllDay)
        value = DateValueCodec.encodeTZ(parsed)
        onCommit()
    }
}

// MARK: - Select

/// Editor for `.select` properties. Two modes, decided by whether the
/// property's config_json carries an `options` list:
///
/// - **With options**: renders a soft pill that opens a Menu listing
///   every option (with a check next to the current value) plus a
///   "Clear" item. Tapping anywhere on the pill — including the
///   chevron — pops the menu. Old behavior (cycle on tap) was
///   discoverability-hostile and offered no way to clear the value
///   from the inline UI.
/// - **Without options**: free-form text field, identical to the
///   pre-#6 behavior so existing select columns keep working.
private struct SelectField: View {
    let property: PropertyRow
    @Binding var value: String
    var onCommit: () -> Void
    var onAddOption: ((_ option: String) -> Void)? = nil

    var body: some View {
        // Always show the pill when an `onAddOption` callback is
        // available — the "Add new…" affordance lets the user seed
        // an option list even on a property that ships with none.
        // Without the callback, fall back to the free-form text
        // editor for option-less properties so the existing
        // experience is preserved.
        if let options = property.config.options, !options.isEmpty {
            SelectPill(value: $value, options: options, onCommit: onCommit, onAddOption: onAddOption)
        } else if onAddOption != nil {
            SelectPill(value: $value, options: [], onCommit: onCommit, onAddOption: onAddOption)
        } else {
            TextField("—", text: $value)
                .textFieldStyle(.plain)
                .font(.kstText(size: 13))
                .foregroundStyle(value.isEmpty ? KstColor.ink3 : KstColor.ink0)
                .onSubmit(onCommit)
                .onChange(of: value) { _, _ in onCommit() }
        }
    }
}

/// Reusable select pill — same cycle-on-tap, right-click-for-menu UX
/// used by the detail view, the gallery card overlay, and anywhere
/// else a `select`-with-options needs to be edited inline. Extracted
/// out of `SelectField` so the gallery card can render an identical
/// pill on top of the cover image.
struct SelectPill: View {
    @Binding var value: String
    var options: [String]
    var onCommit: () -> Void
    /// Visual variant. `.standard` is the detail-view inline pill.
    /// `.overlay` is the gallery-card variant — slightly larger,
    /// opaque background so it reads against a busy cover image.
    var variant: Variant = .standard
    /// When non-nil, the menu includes an "Add new…" item that opens
    /// a small text-entry popover. Confirming the popover both
    /// selects the new value AND registers it on the property via
    /// this callback so future cells can pick it from their menus.
    var onAddOption: ((_ option: String) -> Void)? = nil

    enum Variant {
        case standard, overlay
    }

    @State private var promptingNew = false
    @State private var draftNew = ""

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    value = option
                    onCommit()
                } label: {
                    if value == option {
                        Label(SelectOptionDisplay.format(option), systemImage: "checkmark")
                    } else {
                        Text(SelectOptionDisplay.format(option))
                    }
                }
            }
            if onAddOption != nil {
                if !options.isEmpty { Divider() }
                Button("Add new…") {
                    draftNew = ""
                    promptingNew = true
                }
            }
            if !value.isEmpty {
                Divider()
                Button("Clear", role: .destructive) {
                    value = ""
                    onCommit()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(value.isEmpty ? "—" : SelectOptionDisplay.format(value))
                    .font(.kstText(size: variant == .overlay ? 11 : 12, weight: .medium))
                    .foregroundStyle(value.isEmpty ? KstColor.ink3 : KstColor.ink0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(KstColor.ink3)
            }
            .padding(.horizontal, variant == .overlay ? 8 : 10)
            .frame(height: variant == .overlay ? 20 : 22)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(KstColor.ink4, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .popover(isPresented: $promptingNew) {
            VStack(alignment: .leading, spacing: 8) {
                Text("New option")
                    .font(.kstText(size: 11, weight: .semibold))
                    .foregroundStyle(KstColor.ink2)
                HStack(spacing: 6) {
                    TextField("", text: $draftNew, onCommit: commitNewOption)
                        .textFieldStyle(.roundedBorder)
                        .font(.kstText(size: 12))
                        .frame(width: 160)
                    Button("Add", action: commitNewOption)
                        .disabled(draftNew.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.defaultAction)
                    Button("Cancel") { promptingNew = false }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(12)
        }
    }

    private func commitNewOption() {
        let trimmed = draftNew.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAddOption?(trimmed)
        value = trimmed
        onCommit()
        promptingNew = false
    }

    @ViewBuilder
    private var background: some View {
        switch variant {
        case .standard:
            (value.isEmpty ? KstColor.paper2 : KstColor.paper2.opacity(0.8))
        case .overlay:
            // The gallery card overlay sits on top of cover art, so
            // we render an opaque background even when the value is
            // present — the cover image would otherwise show through
            // the 0.8-alpha paper tone.
            KstColor.paper0
        }
    }
}

// MARK: - MultiSelect

/// Editor for `.multiSelect` properties — a row of removable chips
/// followed by a `+` button that opens a popover listing known options
/// (from the property's `config_json.options`) plus a "New tag…" field
/// for free-form additions. The on-disk shape is the delimited string
/// produced by `MultiSelectValue.encode`.
private struct MultiSelectField: View {
    let property: PropertyRow
    @Binding var value: String
    var onCommit: () -> Void
    /// Optional hook to register a brand-new tag as an option on the
    /// property. When set, the "New tag…" commit also registers the
    /// tag so subsequent records' popovers offer it as a suggestion.
    var onAddOption: ((_ option: String) -> Void)? = nil
    /// Optional hook to remove an option from the property and strip
    /// it off every record. When nil, the per-option delete button
    /// is hidden. Confirmation prompt is the caller's responsibility.
    var onDeleteOption: ((_ option: String) -> Void)? = nil

    @State private var popoverOpen = false
    @State private var draftTag = ""
    @State private var hoveringOption: String? = nil
    @State private var pendingDelete: String? = nil

    private var tags: [String] {
        MultiSelectValue.decode(value)
    }

    private var knownOptions: [String] {
        // Configured options union the values already in use on this
        // record so the user can re-pick a previously-typed tag.
        let configured = property.config.options ?? []
        let inUse = tags
        var seen = Set<String>()
        return (configured + inUse).filter { seen.insert($0.lowercased()).inserted }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                MultiSelectChip(tag: tag) {
                    var next = tags
                    next.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
                    value = MultiSelectValue.encode(next)
                    onCommit()
                }
            }
            Button {
                popoverOpen.toggle()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(KstColor.ink2)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(KstColor.paper1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(KstColor.ink4, lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $popoverOpen, arrowEdge: .bottom) {
                popoverBody
                    .padding(12)
                    .frame(minWidth: 220, idealWidth: 240)
            }
            Spacer(minLength: 0)
        }
    }

    /// Search-as-you-type: when the user types into the tag field,
    /// the option list shrinks to entries matching the query. An
    /// existing-tag match is preferred over creating a duplicate.
    private var filteredOptions: [String] {
        let q = draftTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return knownOptions }
        return knownOptions.filter { $0.lowercased().contains(q) }
    }

    private var draftMatchesExistingOption: Bool {
        let q = draftTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return false }
        return knownOptions.contains { $0.lowercased() == q }
    }

    private var trimmedDraft: String {
        draftTag.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var popoverBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search or add tag…", text: $draftTag, onCommit: commitDraftOrToggleExact)
                .textFieldStyle(.roundedBorder)
                .font(.kstText(size: 12))
            if !filteredOptions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(filteredOptions, id: \.self) { option in
                            optionRow(option)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            if !trimmedDraft.isEmpty, !draftMatchesExistingOption {
                if !filteredOptions.isEmpty { Divider() }
                Button(action: commitDraft) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Add \"\(trimmedDraft)\"")
                            .font(.kstText(size: 13, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(KstColor.ceruleanInk)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .confirmationDialog(
            "Delete tag \"\(pendingDelete ?? "")\"?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { option in
            Button("Delete", role: .destructive) {
                onDeleteOption?(option)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("Removes the tag from this and every other record that has it.")
        }
    }

    @ViewBuilder
    private func optionRow(_ option: String) -> some View {
        let isOn = tags.contains { $0.caseInsensitiveCompare(option) == .orderedSame }
        let isHovering = hoveringOption == option
        HStack(spacing: 6) {
            Button {
                toggle(option)
                // Clear the search so the next pick works against
                // the full list.
                draftTag = ""
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOn ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13))
                        .foregroundStyle(isOn ? KstColor.ink0 : KstColor.ink3)
                    Text(option)
                        .font(.kstText(size: 13))
                        .foregroundStyle(KstColor.ink0)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if onDeleteOption != nil {
                Button {
                    pendingDelete = option
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(KstColor.ink3)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Delete this tag everywhere")
                .opacity(isHovering ? 1 : 0)
            }
        }
        .contentShape(Rectangle())
        .onHover { hoveringOption = $0 ? option : (hoveringOption == option ? nil : hoveringOption) }
    }

    private func toggle(_ option: String) {
        var next = tags
        if let idx = next.firstIndex(where: { $0.caseInsensitiveCompare(option) == .orderedSame }) {
            next.remove(at: idx)
        } else {
            next.append(option)
        }
        value = MultiSelectValue.encode(next)
        onCommit()
    }

    /// Pressing Enter in the search field. If the draft exactly
    /// matches a known option (case-insensitive), toggle it. Otherwise
    /// add it as a new tag.
    private func commitDraftOrToggleExact() {
        let trimmed = trimmedDraft
        guard !trimmed.isEmpty else { return }
        if let match = knownOptions.first(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            toggle(match)
            draftTag = ""
        } else {
            commitDraft()
        }
    }

    private func commitDraft() {
        let trimmed = trimmedDraft
        guard !trimmed.isEmpty else { return }
        var next = tags
        if !next.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            next.append(trimmed)
        }
        value = MultiSelectValue.encode(next)
        draftTag = ""
        // Persist the new tag as a property option so subsequent
        // records' popovers offer it as a suggestion. Falls through
        // silently when no callback is wired.
        onAddOption?(trimmed)
        onCommit()
    }
}

private struct MultiSelectChip: View {
    let tag: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(tag)
                .font(.kstText(size: 11, weight: .medium))
                .foregroundStyle(KstColor.ink0)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(KstColor.ink3)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 20)
        .background(KstColor.paper2)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Pure helpers for the option-cycle UX. Extracted so unit tests can
/// pin the wrap-around + empty-value behavior without spinning up the
/// view layer.
enum SelectCycle {
    /// Advance to the next option. Empty value picks the first;
    /// last option wraps to the first; an unrecognized current value
    /// also picks the first (defensive).
    static func next(current: String, in options: [String]) -> String {
        guard !options.isEmpty else { return current }
        guard let idx = options.firstIndex(of: current) else { return options[0] }
        let nextIdx = (idx + 1) % options.count
        return options[nextIdx]
    }
}

// MARK: - Checkbox

private struct CheckboxField: View {
    @Binding var value: String
    var onCommit: () -> Void

    var body: some View {
        Toggle(isOn: Binding(
            get: { value == "true" || value == "1" || value.lowercased() == "yes" },
            set: { new in
                value = new ? "true" : ""
                onCommit()
            }
        )) {
            EmptyView()
        }
        .labelsHidden()
        #if os(macOS)
        .toggleStyle(.checkbox)
        #else
        .toggleStyle(.switch)
        #endif
    }
}

