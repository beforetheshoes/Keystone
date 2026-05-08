import SwiftUI
#if canImport(MapKit)
import MapKit
#endif
import Dependencies

/// Editor for `address` properties. Renders a one-line text field with
/// a debounced autocomplete popover backed by `MKLocalSearchCompleter`
/// (via `VendorLookupService.searchAutocomplete`). Picking a suggestion
/// resolves it to a full `MKMapItem`, projects into `AddressValue`, and
/// writes the encoded JSON back through the binding. Free-form typing
/// keeps working — the writes path treats unparseable strings as plain
/// text.
struct AddressAutocompleteField: View {
    @Binding var value: String
    /// The record being edited. Required to hydrate structured state
    /// (json_value) on first appear; absence falls back to the bound
    /// `value` as plain text only.
    let recordID: String?
    let propertyKey: String
    var onCommit: () -> Void

    @Dependency(\.databaseClient) private var databaseClient

    @State private var displayText: String = ""
    @State private var hydrated: Bool = false
    @State private var addressValue: AddressValue?
    @State private var suggestions: [SuggestionRow] = []
    @State private var showSuggestions = false
    @State private var debounceTask: Task<Void, Never>? = nil
    @State private var isResolving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("—", text: Binding(
                get: { displayText },
                set: { newValue in
                    displayText = newValue
                    // Free-form typing breaks structure: the binding is
                    // the raw text now. Writes treats this as plain text.
                    addressValue = nil
                    value = newValue
                    scheduleAutocomplete(for: newValue)
                }
            ))
            .textFieldStyle(.plain)
            .font(.kstText(size: 13))
            .foregroundStyle(displayText.isEmpty ? KstColor.ink3 : KstColor.ink0)
            .onSubmit { commit(displayText); showSuggestions = false }
            .onAppear {
                hydrate()
            }
            .onChange(of: value) { _, new in
                // External writes (e.g. from a Writes round-trip) refresh
                // the structured state without dropping the user's typing.
                if !hydrated || new != displayText { hydrate(forceFromValue: new) }
            }

            if showSuggestions && !suggestions.isEmpty {
                suggestionList
            }
        }
    }

    @ViewBuilder
    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions) { row in
                Button {
                    Task { await pick(row) }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title)
                            .font(.kstText(size: 13))
                            .foregroundStyle(KstColor.ink0)
                        if !row.subtitle.isEmpty {
                            Text(row.subtitle)
                                .font(.kstText(size: 11))
                                .foregroundStyle(KstColor.ink2)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(KstColor.paper0)
                .overlay(alignment: .bottom) { Rectangle().fill(KstColor.paper3).frame(height: 0.5) }
            }
        }
        .background(KstColor.paper0)
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .padding(.top, 4)
    }

    // MARK: - Autocomplete

    private func scheduleAutocomplete(for query: String) {
        debounceTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            suggestions = []
            showSuggestions = false
            return
        }
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            await fetchSuggestions(for: trimmed)
        }
    }

    private func fetchSuggestions(for query: String) async {
        #if canImport(MapKit)
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let completions = await VendorLookupService.searchAutocomplete(query: query)
        let rows = completions.prefix(8).map { c in
            SuggestionRow(id: "\(c.title)|\(c.subtitle)", title: c.title, subtitle: c.subtitle, completion: c)
        }
        await MainActor.run {
            suggestions = Array(rows)
            showSuggestions = !rows.isEmpty
        }
        #endif
    }

    private func pick(_ row: SuggestionRow) async {
        #if canImport(MapKit)
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        isResolving = true
        let request = MKLocalSearch.Request(completion: row.completion)
        let search = MKLocalSearch(request: request)
        guard let response = try? await search.start(),
              let item = response.mapItems.first else {
            await MainActor.run { isResolving = false; showSuggestions = false }
            return
        }
        let addr = AddressAutocompleteField.makeAddressValue(from: item)
        await MainActor.run {
            addressValue = addr
            displayText = addr.display
            value = AddressValueCodec.encode(addr)
            suggestions = []
            showSuggestions = false
            isResolving = false
            onCommit()
        }
        #endif
    }

    // MARK: - Hydration

    private func hydrate(forceFromValue override: String? = nil) {
        let raw = override ?? value
        if let parsed = AddressValueCodec.parse(raw) {
            addressValue = parsed
            displayText = parsed.display
            hydrated = true
            return
        }
        // Try fetching json_value from the DB (structured pick from a
        // prior session). Falls back to the bound value as plain text.
        if let recordID, !hydrated {
            if let stored = try? databaseClient.propertyJSON(recordID, propertyKey),
               let parsed = AddressValueCodec.parse(stored) {
                addressValue = parsed
                displayText = parsed.display
                hydrated = true
                return
            }
        }
        addressValue = nil
        displayText = raw
        hydrated = true
    }

    private func commit(_ raw: String) {
        // Writes treats parseable JSON as structured and raw strings as
        // plain text. Either way, write through and notify.
        value = raw
        onCommit()
    }

    // MARK: - MapKit projection

    #if canImport(MapKit)
    @available(iOS 26.0, macOS 26.0, *)
    static func makeAddressValue(from item: MKMapItem) -> AddressValue {
        var v = AddressValue(display: item.name ?? "")

        // Pull structured fields from the modern MKAddress API.
        if let address = item.address {
            v.street = address.shortAddress
            // fullAddress is multi-line; use it for the display when
            // we have nothing better.
            if v.display.isEmpty { v.display = address.fullAddress }
        }
        if let reps = item.addressRepresentations,
           v.display.isEmpty,
           let composed = reps.fullAddress(includingRegion: true, singleLine: true) {
            v.display = composed
        }
        // City / region / postal / country come from the structured
        // representation when available.
        if let reps = item.addressRepresentations {
            v.city = reps.cityWithContext(.short)
        }

        // Coordinate.
        let coord = item.location.coordinate
        v.lat = coord.latitude
        v.lon = coord.longitude

        // Place ID — same opaque identifier the vendor enrichment uses.
        v.placeID = item.identifier?.rawValue

        if v.display.isEmpty {
            v.display = AddressValueCodec.oneLine(from: v)
        }
        return v
    }
    #endif

    private struct SuggestionRow: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        #if canImport(MapKit)
        let completion: MKLocalSearchCompletion
        #else
        let completion: Void = ()
        #endif
    }
}
