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

    var body: some View {
        switch property.type {
        case .date:
            DateField(value: $value, onCommit: onCommit)
        case .dateTZ:
            DateTimeZoneField(value: $value, onCommit: onCommit)
        case .address:
            AddressAutocompleteField(
                value: $value,
                recordID: recordID,
                propertyKey: property.key,
                onCommit: onCommit
            )
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
            SelectField(property: property, value: $value, onCommit: onCommit)
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

// MARK: - Phone

private struct PhoneField: View {
    @Binding var value: String
    var onCommit: () -> Void

    var body: some View {
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
/// - **With options**: renders a soft pill. Tapping cycles forward
///   through the list (wraps at the end). Right-click / long-press
///   opens a Menu listing every option plus a Clear item.
/// - **Without options**: free-form text field, identical to the
///   pre-#6 behavior so existing select columns keep working.
private struct SelectField: View {
    let property: PropertyRow
    @Binding var value: String
    var onCommit: () -> Void

    var body: some View {
        if let options = property.config.options, !options.isEmpty {
            optionPill(options: options)
        } else {
            TextField("—", text: $value)
                .textFieldStyle(.plain)
                .font(.kstText(size: 13))
                .foregroundStyle(value.isEmpty ? KstColor.ink3 : KstColor.ink0)
                .onSubmit(onCommit)
                .onChange(of: value) { _, _ in onCommit() }
        }
    }

    private func optionPill(options: [String]) -> some View {
        let labelText = value.isEmpty ? "—" : value
        return Button {
            value = SelectCycle.next(current: value, in: options)
            onCommit()
        } label: {
            Text(labelText)
                .font(.kstText(size: 12, weight: .medium))
                .foregroundStyle(value.isEmpty ? KstColor.ink3 : KstColor.ink0)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(value.isEmpty ? KstColor.paper2 : KstColor.paper2.opacity(0.8))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(KstColor.ink4, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            ForEach(options, id: \.self) { option in
                Button(option) {
                    value = option
                    onCommit()
                }
            }
            Divider()
            Button("Clear") {
                value = ""
                onCommit()
            }
        }
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

