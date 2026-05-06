#if !os(macOS)
import SwiftUI
import ComposableArchitecture

/// Native iPhone search view. Searches across records, databases, and quick
/// actions using the same data the macOS Command Palette uses
/// (`store.paletteItems`), but rendered as a full-screen, keyboard-friendly
/// view rather than a fixed-width overlay.
struct iPhoneSearchView: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var query: String = ""
    @State private var path = NavigationPath()
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Text("Search")
                    .font(.kstDisplay(size: 32, weight: .semibold))
                    .kerning(-0.4)
                    .foregroundStyle(KstColor.ink0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundStyle(KstColor.ink2)
                    TextField("Search records, databases, tags…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.kstText(size: 15))
                        .focused($fieldFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !query.isEmpty {
                        Button {
                            query = ""
                            fieldFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(KstColor.ink3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(KstColor.paper1)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 18)
                .padding(.bottom, 12)

                ScrollView {
                    if filtered.isEmpty {
                        emptyState
                    } else {
                        iOSCardList {
                            ForEach(filtered) { item in
                                iOSCardRow(
                                    leading: { Glyph(tone: item.tone, text: item.glyph, size: 26, radius: 7) },
                                    title: item.label,
                                    subtitle: item.sub,
                                    trailing: { iOSChevron() }
                                ) {
                                    pick(item)
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 24)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(KstColor.paper0)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: iPhoneRoute.self) { route in
                iPhoneRouteView(store: store, route: route)
            }
        }
        .onAppear { fieldFocused = true }
    }

    private var filtered: [PaletteItem] {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return Array(store.paletteItems.prefix(20)) }
        return store.paletteItems.filter {
            $0.label.lowercased().contains(q) || $0.sub.lowercased().contains(q)
        }
    }

    private func pick(_ item: PaletteItem) {
        switch item.kind {
        case .database:
            if let dbID = item.dbID {
                path.append(iPhoneRoute.database(databaseID: dbID))
            }
        case .record:
            if let dbID = item.dbID {
                let recID = String(item.id.dropFirst("rec-".count))
                path.append(iPhoneRoute.record(databaseID: dbID, recordID: recID))
            }
        case .action:
            store.send(.openCapture)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(KstColor.ink3)
            Text(query.isEmpty ? "Find any record, database, or tag." : "No matches for “\(query)”")
                .font(.kstText(size: 14))
                .foregroundStyle(KstColor.ink2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}
#endif
