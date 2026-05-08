import SwiftUI

/// Sheet for picking an IANA time-zone identifier. Search-first across the
/// ~600 known IDs plus their localized names; recently picked tz's pinned
/// at the top so frequent choices don't require typing.
struct TimeZonePickerSheet: View {
    /// Currently-selected identifier, used to highlight the matching row.
    let current: String?
    /// Called with the chosen IANA id. The sheet writes through
    /// `KeystoneSettings.bumpRecentTimeZone` before invoking this.
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @State private var allIdentifiers: [String] = TimeZone.knownTimeZoneIdentifiers.sorted()
    @State private var recents: [String] = KeystoneSettings.recentTimeZones

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(KstColor.ink3)
                TextField("Search time zones", text: $query)
                    .textFieldStyle(.plain)
                    .font(.kstText(size: 13))
                #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                #endif
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(KstColor.ink3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(KstColor.paper1)

            Divider()

            List {
                if query.isEmpty && !recents.isEmpty {
                    Section("Recent") {
                        ForEach(recents, id: \.self) { id in
                            row(for: id)
                        }
                    }
                }
                Section(query.isEmpty && !recents.isEmpty ? "All time zones" : "Time zones") {
                    ForEach(filtered, id: \.self) { id in
                        row(for: id)
                    }
                }
            }
            .listStyle(.plain)
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 460)
        #endif
        .navigationTitle("Time zone")
    }

    private var filtered: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return allIdentifiers }
        return allIdentifiers.filter { id in
            if id.lowercased().contains(trimmed) { return true }
            if let tz = TimeZone(identifier: id),
               let localized = tz.localizedName(for: .standard, locale: .current),
               localized.lowercased().contains(trimmed) {
                return true
            }
            return false
        }
    }

    @ViewBuilder
    private func row(for id: String) -> some View {
        Button {
            KeystoneSettings.bumpRecentTimeZone(id)
            recents = KeystoneSettings.recentTimeZones
            onPick(id)
            dismiss()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(id)
                        .font(.kstText(size: 13))
                        .foregroundStyle(KstColor.ink0)
                    if let tz = TimeZone(identifier: id) {
                        let abbr = tz.abbreviation() ?? ""
                        let offset = offsetString(for: tz)
                        Text(abbr.isEmpty ? offset : "\(abbr) · \(offset)")
                            .font(.kstText(size: 11))
                            .foregroundStyle(KstColor.ink3)
                    }
                }
                Spacer(minLength: 0)
                if id == current {
                    Image(systemName: "checkmark")
                        .foregroundStyle(KstColor.cerulean)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func offsetString(for tz: TimeZone) -> String {
        let seconds = tz.secondsFromGMT()
        let sign = seconds >= 0 ? "+" : "-"
        let absSeconds = abs(seconds)
        let hours = absSeconds / 3600
        let minutes = (absSeconds % 3600) / 60
        return String(format: "GMT%@%02d:%02d", sign, hours, minutes)
    }
}
