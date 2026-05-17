#if !os(macOS)
import SwiftUI
import ComposableArchitecture
import Dependencies

struct iPhoneDatabaseListView: View {
    @Bindable var store: StoreOf<AppFeature>
    /// Backing database the records list reads from. When the route is
    /// a saved view (`viewID != nil`), this is the *view's* backing
    /// database (e.g. `vendors` for the Restaurants view).
    var databaseID: String
    /// Set when the route is a saved view. Drives the header label and
    /// the view's pinned query filter for record narrowing.
    var viewID: String?

    init(store: StoreOf<AppFeature>, databaseID: String) {
        self.store = store
        self.databaseID = databaseID
        self.viewID = nil
    }

    init(store: StoreOf<AppFeature>, viewID: String) {
        self.store = store
        self.viewID = viewID
        // Backing database is resolved at task-time; the placeholder
        // empty string never lasts past one tick (the `.task` block
        // re-reads `dbRow` + `records` from the view).
        self.databaseID = ""
    }

    @Dependency(\.databaseClient) private var dbClient
    @State private var records: [RecordRow] = []
    @State private var dbRow: DBRow?
    @State private var view: ViewRow?
    @State private var resolvedDatabaseID: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header — view-defined label/icon when we're rendering
                // a saved view; otherwise the backing database's.
                HStack(spacing: 10) {
                    if let view {
                        Glyph(tone: view.accent, text: view.icon, size: 28, radius: 7)
                    } else if let db = dbRow {
                        Glyph(tone: db.accent, text: db.icon, size: 28, radius: 7)
                    }
                    Text(view?.name ?? dbRow?.name ?? "")
                        .font(.kstDisplay(size: 28, weight: .semibold))
                        .kerning(-0.4)
                        .foregroundStyle(KstColor.ink0)
                    Text("\(records.count)")
                        .font(.kstText(size: 14))
                        .monospacedDigit()
                        .foregroundStyle(KstColor.ink2)
                    Spacer()
                }
                .padding(.top, 8)
                .padding(.bottom, 14)

                if records.isEmpty {
                    Text("No records yet. Tap + to create one.")
                        .font(.kstText(size: 14))
                        .foregroundStyle(KstColor.ink3)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    iOSCardList {
                        ForEach(records) { rec in
                            iOSCardLinkRow(
                                value: iPhoneRoute.record(databaseID: resolvedDatabaseID, recordID: rec.id),
                                leading: { RecordAvatar(record: rec, size: 30, radius: 8) },
                                title: rec.title,
                                subtitle: recordSubtitle(rec),
                                trailing: { iOSChevron() }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .background(KstColor.paper0)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // "Stats" entry — Collections databases only. Pushes the
            // shared `StatsDetailView` onto the navigation stack via
            // `iPhoneRoute.stats`. Hidden on saved-view routes since
            // their stats would be ambiguous (Restaurants doesn't have
            // its own stats — it'd be Vendors' stats filtered).
            if statsAvailable {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: iPhoneRoute.stats(databaseID: resolvedDatabaseID)) {
                        Image(systemName: "chart.bar.xaxis")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if let v = view {
                        store.send(.openLookup(databaseID: v.databaseID, databaseName: v.name))
                    } else {
                        store.send(.openLookup(databaseID: resolvedDatabaseID, databaseName: dbRow?.name ?? ""))
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task(id: taskKey) {
            await reload()
        }
        .onChange(of: store.currentRecords) { _, _ in
            reloadFromState()
        }
        .onChange(of: store.hiddenRecordIDs) { _, _ in
            Task { await reload() }
        }
    }

    private var taskKey: String { viewID ?? databaseID }

    /// Only Collections databases get the stats button on iPhone.
    /// Saved-view routes opt out — their stats would be the backing
    /// database's, which the user reached separately via the parent
    /// db.
    private var statsAvailable: Bool {
        guard viewID == nil else { return false }
        return ["books", "movies", "tv_shows"].contains(resolvedDatabaseID)
    }

    private func reload() async {
        if let viewID {
            let v = try? dbClient.view(viewID)
            view = v
            if let v {
                resolvedDatabaseID = v.databaseID
                dbRow = try? dbClient.database(v.databaseID)
                let all = (try? dbClient.records(v.databaseID, store.hiddenRecordIDs)) ?? []
                records = applyViewFilter(all, view: v)
            }
        } else {
            resolvedDatabaseID = databaseID
            dbRow = try? dbClient.database(databaseID)
            records = (try? dbClient.records(databaseID, store.hiddenRecordIDs)) ?? []
        }
    }

    private func reloadFromState() {
        if let viewID, let v = store.views.first(where: { $0.id == viewID }) {
            // Re-derive from store.currentRecords when the store is
            // already pointing at this view's backing database.
            if store.nav == .view(viewID) {
                records = applyViewFilter(store.currentRecords, view: v)
            }
        } else if case .database(let id) = store.nav, id == databaseID {
            records = store.currentRecords
        }
    }

    /// Apply the view's `queryFilters` (currently a simple
    /// `key ∈ values` shape, e.g. `{"kind": ["restaurant"]}`) to the
    /// raw record list. AND-combines across keys; OR within each.
    private func applyViewFilter(_ rows: [RecordRow], view: ViewRow) -> [RecordRow] {
        guard !view.queryFilters.isEmpty else { return rows }
        return rows.filter { row in
            for (key, allowed) in view.queryFilters {
                let v = row.values[key] ?? ""
                if !allowed.contains(v) { return false }
            }
            return true
        }
    }

    private func recordSubtitle(_ rec: RecordRow) -> String? {
        // Restaurants get the status + today's hours instead of the
        // generic kind/address pair — both are noisy on a list that's
        // already scoped to restaurants ("kind" is always "restaurant",
        // the full address eats two lines).
        let kind = rec.values["kind"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if kind == "restaurant",
           let rawHours = rec.values["hours"],
           !rawHours.isEmpty {
            let status = RestaurantHoursSummary.todayStatus(rawHours)
            let today = RestaurantHoursSummary.todayShort(rawHours)
            let parts = [status, today].compactMap { $0 }.filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: " · ") }
            // Fall through to the generic subtitle if hours don't parse.
        }

        let parts = ["relationship", "kind", "make", "model", "species", "address", "when"]
            .compactMap { key -> String? in
                guard let v = rec.values[key], !v.isEmpty, v != "—" else { return nil }
                return v
            }
        let joined = parts.prefix(2).joined(separator: " · ")
        return joined.isEmpty ? nil : joined
    }
}

struct iPhoneTagListView: View {
    @Bindable var store: StoreOf<AppFeature>
    var tagID: String

    @Dependency(\.databaseClient) private var dbClient
    @State private var tag: TagModel?
    @State private var rows: [(record: RecordRow, dbName: String)] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    if let tag {
                        Circle().fill(tag.color.base).frame(width: 12, height: 12)
                    }
                    Text(tag?.name ?? "Tag")
                        .font(.kstDisplay(size: 28, weight: .semibold))
                        .kerning(-0.4)
                        .foregroundStyle(KstColor.ink0)
                    Text("\(rows.count)")
                        .font(.kstText(size: 14))
                        .monospacedDigit()
                        .foregroundStyle(KstColor.ink2)
                    Spacer()
                }
                .padding(.top, 8)
                .padding(.bottom, 14)

                if rows.isEmpty {
                    Text("No records have this tag.")
                        .font(.kstText(size: 14))
                        .foregroundStyle(KstColor.ink3)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    iOSCardList {
                        ForEach(rows, id: \.record.id) { item in
                            iOSCardLinkRow(
                                value: iPhoneRoute.record(databaseID: item.record.databaseID, recordID: item.record.id),
                                leading: { RecordAvatar(record: item.record, size: 30, radius: 8) },
                                title: item.record.title,
                                subtitle: item.dbName,
                                trailing: { iOSChevron() }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .background(KstColor.paper0)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: tagID) {
            tag = (try? dbClient.allTags(Seed.workspaceID))?.first { $0.id == tagID }
            rows = (try? dbClient.recordsForTag(tagID, store.hiddenRecordIDs)) ?? []
        }
        .onChange(of: store.hiddenRecordIDs) { _, _ in
            rows = (try? dbClient.recordsForTag(tagID, store.hiddenRecordIDs)) ?? []
        }
    }
}
#endif
