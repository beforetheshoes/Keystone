#if !os(macOS)
import SwiftUI
import ComposableArchitecture
import Dependencies

struct iPhoneDatabaseListView: View {
    @Bindable var store: StoreOf<AppFeature>
    var databaseID: String

    @Dependency(\.databaseClient) private var dbClient
    @State private var records: [RecordRow] = []
    @State private var dbRow: DBRow?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 10) {
                    if let db = dbRow {
                        Glyph(tone: db.accent, text: db.icon, size: 28, radius: 7)
                    }
                    Text(dbRow?.name ?? "")
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
                            // `iOSCardLinkRow` wires a `NavigationLink`
                            // to the enclosing `NavigationStack` (the
                            // one in `iPhoneHomeView`/`iPhoneSearchView`
                            // declaring `.navigationDestination(for:
                            // iPhoneRoute.self)`). Tapping the row
                            // pushes the record-detail destination
                            // automatically. The previous code called
                            // `store.send(.setNav(...))`, which mutates
                            // TCA state but doesn't append to the
                            // local `@State path`, so the detail page
                            // never appeared.
                            iOSCardLinkRow(
                                value: iPhoneRoute.record(databaseID: databaseID, recordID: rec.id),
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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.send(.createBlankRecord(databaseID: databaseID))
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task(id: databaseID) {
            dbRow = try? dbClient.database(databaseID)
            records = (try? dbClient.records(databaseID)) ?? []
        }
        .onChange(of: store.currentRecords) { _, new in
            if case .database(let id) = store.nav, id == databaseID {
                records = new
            }
        }
    }

    private func recordSubtitle(_ rec: RecordRow) -> String? {
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
            rows = (try? dbClient.recordsForTag(tagID)) ?? []
        }
    }
}
#endif
