#if !os(macOS)
import SwiftUI
import ComposableArchitecture
import Dependencies

struct iPhoneHomeView: View {
    @Bindable var store: StoreOf<AppFeature>
    @Dependency(\.databaseClient) private var dbClient

    @State private var people: [RecordRow] = []
    @State private var pets: [RecordRow] = []
    @State private var vehicles: [RecordRow] = []
    @State private var documents: [RecordRow] = []
    @State private var events: [RecordRow] = []
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    searchRow
                    thisWeekSection
                    databasesSection
                    familySection
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            .background(KstColor.paper0)
            .navigationDestination(for: iPhoneRoute.self) { route in
                iPhoneRouteView(store: store, route: route)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { await reload() }
        .onChange(of: store.databases) { _, _ in
            Task { await reload() }
        }
        .onChange(of: store.hiddenRecordIDs) { _, _ in
            Task { await reload() }
        }
    }

    private func reload() async {
        let hidden = store.hiddenRecordIDs
        people = (try? dbClient.records("people", hidden)) ?? []
        pets = (try? dbClient.records("pets", hidden)) ?? []
        vehicles = (try? dbClient.records("vehicles", hidden)) ?? []
        documents = (try? dbClient.records("documents", hidden)) ?? []
        events = (try? dbClient.records("events", hidden)) ?? []
    }

    private var header: some View {
        HStack(spacing: 10) {
            KeystoneLogo(size: 28, radius: 7)
            Text("Keystone")
                .font(.kstDisplay(size: 28, weight: .semibold))
                .kerning(-0.4)
                .foregroundStyle(KstColor.ink0)
            Spacer()
        }
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var searchRow: some View {
        Button(action: { store.send(.openPalette) }) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(KstColor.ink2)
                Text("Search anything")
                    .font(.kstText(size: 15))
                    .foregroundStyle(KstColor.ink3)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(KstColor.paper1)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 12)
    }

    private var thisWeekSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            iOSSectionTitle(title: "This week")
            iOSCardList {
                ForEach(events.prefix(3)) { e in
                    iOSCardRow(
                        leading: { DateBadgeMobile(date: e.values["when"] ?? "") },
                        title: e.title,
                        subtitle: e.values["where"],
                        trailing: { iOSChevron() }
                    ) {
                        path.append(iPhoneRoute.record(databaseID: e.databaseID, recordID: e.id))
                    }
                }
            }
            .padding(.bottom, 10)
        }
    }

    private var databasesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            iOSSectionTitle(title: "Databases")
            let tiles: [(id: String, title: String, count: Int)] = [
                ("people", "People", people.count),
                ("pets", "Pets", pets.count),
                ("vehicles", "Vehicles", vehicles.count),
                ("documents", "Documents", documents.count),
            ]
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                ForEach(tiles, id: \.id) { tile in
                    Button {
                        path.append(iPhoneRoute.database(databaseID: tile.id))
                    } label: {
                        databaseTile(id: tile.id, title: tile.title, count: tile.count)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func databaseTile(id: String, title: String, count: Int) -> some View {
        let db = store.databases.first(where: { $0.id == id })
        VStack(alignment: .leading, spacing: 0) {
            Glyph(tone: db?.accent ?? .graphite, text: db?.icon ?? title.prefix(1).uppercased(), size: 28, radius: 7)
                .padding(.bottom, 10)
            Text(title)
                .font(.kstText(size: 15, weight: .semibold))
                .foregroundStyle(KstColor.ink0)
            Text("\(count) records")
                .font(.kstText(size: 12))
                .foregroundStyle(KstColor.ink2)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(KstColor.paper0)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var familySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            iOSSectionTitle(title: "Family")
            iOSCardList {
                ForEach(people.prefix(4)) { p in
                    iOSCardRow(
                        leading: { RecordAvatar(record: p, size: 32, radius: 9) },
                        title: p.title,
                        subtitle: subtitleForPerson(p),
                        trailing: { iOSChevron() }
                    ) {
                        path.append(iPhoneRoute.record(databaseID: "people", recordID: p.id))
                    }
                }
            }
        }
    }

    private func subtitleForPerson(_ p: RecordRow) -> String? {
        let rel = p.values["relationship"] ?? ""
        let last = p.values["lastSeen"] ?? ""
        if rel.isEmpty && last.isEmpty { return nil }
        return [rel, last].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
#endif
