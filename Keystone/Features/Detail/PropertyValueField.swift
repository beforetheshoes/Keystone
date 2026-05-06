import SwiftUI

/// Type-aware input control for a property. Hands back the canonical string
/// that should be stored (ISO date for dates, digits-only-then-formatted for
/// phones, lowercased trimmed for email, etc.) so both the UI and the
/// persistence layer agree on what's saved.
struct PropertyValueField: View {
    var property: PropertyRow
    @Binding var value: String
    var onCommit: () -> Void

    var body: some View {
        switch property.type {
        case .date:
            DateField(value: $value, onCommit: onCommit)
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
        case .select:
            // Free-form for now; once per-property options are stored in
            // properties.config_json this will become a Menu picker.
            TextField("—", text: $value)
                .textFieldStyle(.plain)
                .font(.kstText(size: 13))
                .foregroundStyle(value.isEmpty ? KstColor.ink3 : KstColor.ink0)
                .onSubmit(onCommit)
                .onChange(of: value) { _, _ in onCommit() }
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

enum DateValueCodec {
    /// Canonical wire format: ISO short date (yyyy-MM-dd).
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
