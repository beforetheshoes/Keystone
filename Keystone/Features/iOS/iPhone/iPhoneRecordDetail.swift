#if !os(macOS)
import SwiftUI
import UIKit
import ComposableArchitecture
import Dependencies

struct iPhoneRecordDetail: View {
    @Bindable var store: StoreOf<AppFeature>
    var databaseID: String
    var recordID: String

    @Dependency(\.databaseClient) private var dbClient
    @State private var record: RecordRow?
    @State private var properties: [PropertyRow] = []
    @State private var outgoing: [RelationLink] = []
    @State private var incoming: [RelationLink] = []
    @State private var dbRow: DBRow?
    @State private var drafts: [String: String] = [:]

    var body: some View {
        scrollBody
            .background(KstColor.paper0)
            .navigationTitle(store.currentView?.name ?? dbRow?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task(id: recordID) {
                // Drive the TCA store's nav so the shared store-backed
                // sections (NOTES, FILES, TAGS, relations) all see the
                // right record.
                store.send(.setNav(.record(databaseID: databaseID, recordID: recordID)))
                await loadLocal()
            }
            .onChange(of: store.currentRecord) { _, new in
                if let new, new.id == recordID { record = new }
            }
            .onChange(of: store.currentOutgoingRelations) { _, new in outgoing = new }
            .onChange(of: store.currentIncomingRelations) { _, new in incoming = new }
            .onChange(of: store.currentProperties) { _, new in properties = new }
    }

    @ViewBuilder
    private var scrollBody: some View {
        ScrollView {
            VStack(spacing: 18) {
                hero
                actionRow
                propertiesCard
                relatedSection
                linkedFromSection
                notesSection
                filesSection
                tagsSection
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 32)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Delete record", role: .destructive) {
                    store.send(.deleteCurrentRecord)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        VStack(spacing: 12) {
            if let rec = record {
                CoverAvatar(store: store, record: rec, size: 176)
            } else {
                RoundedRectangle(cornerRadius: 39, style: .continuous)
                    .fill(KstColor.paper2)
                    .frame(width: 176, height: 176)
            }

            Text(record?.title ?? "")
                .font(.kstDisplay(size: 26, weight: .semibold))
                .kerning(-0.3)
                .foregroundStyle(KstColor.ink0)
                .multilineTextAlignment(.center)

            HStack(spacing: 6) {
                if let dbName = dbRow?.name {
                    KstPill(
                        text: dbName.hasSuffix("s") ? String(dbName.dropLast()) : dbName,
                        background: (record?.tone ?? .graphite).soft,
                        foreground: (record?.tone ?? .graphite).ink
                    )
                }
                if let rel = record?.values["relationship"], !rel.isEmpty, rel != "—" {
                    KstPill(text: rel)
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Action row

    @ViewBuilder
    private var actionRow: some View {
        let phone = (record?.values["phone"] ?? "").trimmingCharacters(in: .whitespaces)
        let email = (record?.values["email"] ?? "").trimmingCharacters(in: .whitespaces)
        let phoneOK = !phone.isEmpty && phone != "—"
        let emailOK = !email.isEmpty && email != "—"

        if phoneOK || emailOK {
            HStack(spacing: 8) {
                iOSActionTile(systemImage: "phone.fill", label: "Call", enabled: phoneOK) {
                    if let url = telURL(for: phone) { UIApplication.shared.open(url) }
                }
                iOSActionTile(systemImage: "message.fill", label: "Message", enabled: phoneOK) {
                    if let url = smsURL(for: phone) { UIApplication.shared.open(url) }
                }
                iOSActionTile(systemImage: "envelope.fill", label: "Email", enabled: emailOK) {
                    if let url = mailtoURL(for: email) { UIApplication.shared.open(url) }
                }
            }
        }
    }

    private func telURL(for raw: String) -> URL? {
        let digits = raw.filter { $0.isNumber || $0 == "+" }
        return digits.isEmpty ? nil : URL(string: "tel:\(digits)")
    }
    private func smsURL(for raw: String) -> URL? {
        let digits = raw.filter { $0.isNumber || $0 == "+" }
        return digits.isEmpty ? nil : URL(string: "sms:\(digits)")
    }
    private func mailtoURL(for raw: String) -> URL? {
        // Don't blindly open invalid placeholder text like `eleanor@…`
        guard raw.contains("@"), !raw.contains("…") else { return nil }
        return URL(string: "mailto:\(raw)")
    }

    // MARK: - Properties

    @ViewBuilder
    private var propertiesCard: some View {
        let visible = properties.filter {
            $0.type != .title
                && $0.type != .relation
                && !$0.config.isHidden
                // `notes` is rendered by the block editor below the
                // property card; hiding it here keeps the same kind
                // of text from appearing in two places.
                && $0.key != "notes"
        }
        if !visible.isEmpty, let rec = record {
            iOSCardList {
                ForEach(visible) { prop in
                    HStack(alignment: .center, spacing: 0) {
                        Text(prop.name)
                            .font(.kstText(size: 14))
                            .foregroundStyle(KstColor.ink2)
                            .frame(width: 100, alignment: .leading)
                        if isRestaurantHours(prop, record: rec) {
                            iPhoneHoursValueCell(
                                rawValue: drafts[prop.key] ?? rec.values[prop.key] ?? "",
                                draft: Binding(
                                    get: { drafts[prop.key] ?? rec.values[prop.key] ?? "" },
                                    set: { drafts[prop.key] = $0 }
                                ),
                                property: prop,
                                recordID: recordID,
                                onCommit: { commit(prop.key) }
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            PropertyValueField(
                                property: prop,
                                value: Binding(
                                    get: { drafts[prop.key] ?? rec.values[prop.key] ?? "" },
                                    set: { drafts[prop.key] = $0 }
                                ),
                                onCommit: { commit(prop.key) },
                                onAddOption: { option in
                                    store.send(.addPropertyOption(propertyID: prop.id, option: option))
                                },
                                onDeleteOption: { option in
                                    store.send(.removePropertyOption(propertyID: prop.id, option: option))
                                }
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                }
            }
        }
    }

    private func isRestaurantHours(_ prop: PropertyRow, record: RecordRow) -> Bool {
        guard prop.key == "hours" else { return false }
        let kind = record.values["kind"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return kind == "restaurant"
    }

    private func commit(_ key: String) {
        guard let draft = drafts[key] else { return }
        store.send(.updatePropertyValue(recordID: recordID, key: key, value: draft))
    }

    // MARK: - Related (canonical 4 quadrants, but rendered as a card list on iPhone)

    @ViewBuilder
    private var relatedSection: some View {
        let pairs: [(label: String, dbID: String, glyphFallback: String, tone: AccentTone, count: Int)] = [
            ("Pets", "pets", "Pe", .sage, outgoing.filter { $0.targetDatabaseID == "pets" && $0.propertyID == nil }.count),
            ("Vehicles", "vehicles", "V", .iris, outgoing.filter { $0.targetDatabaseID == "vehicles" && $0.propertyID == nil }.count),
            ("Homes", "homes", "H", .sage, outgoing.filter { $0.targetDatabaseID == "homes" && $0.propertyID == nil }.count),
            ("Documents", "documents", "D", .cerulean, outgoing.filter { $0.targetDatabaseID == "documents" && $0.propertyID == nil }.count),
        ]
        let nonEmpty = pairs.filter { $0.count > 0 }
        if !nonEmpty.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                iOSSectionTitle(title: "Related")
                iOSCardList {
                    ForEach(nonEmpty, id: \.dbID) { p in
                        let db = store.databases.first(where: { $0.id == p.dbID })
                        // Compute the route value once — single related
                        // record opens the detail page directly; multiple
                        // pushes the database listing.
                        let route: iPhoneRoute = {
                            if p.count == 1,
                               let only = outgoing.first(where: { $0.targetDatabaseID == p.dbID && $0.propertyID == nil }) {
                                return .record(databaseID: p.dbID, recordID: only.targetRecordID)
                            } else {
                                return .database(databaseID: p.dbID)
                            }
                        }()
                        iOSCardLinkRow(
                            value: route,
                            leading: { Glyph(tone: db?.accent ?? p.tone, text: db?.icon ?? p.glyphFallback, size: 26, radius: 7) },
                            title: p.label,
                            subtitle: nil,
                            trailing: {
                                HStack(spacing: 8) {
                                    Text("\(p.count)")
                                        .font(.kstText(size: 13))
                                        .monospacedDigit()
                                        .foregroundStyle(KstColor.ink2)
                                    iOSChevron()
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Linked from

    @ViewBuilder
    private var linkedFromSection: some View {
        if !incoming.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                iOSSectionTitle(title: "Linked from")
                iOSCardList {
                    ForEach(incoming) { link in
                        iOSCardLinkRow(
                            value: iPhoneRoute.record(databaseID: link.targetDatabaseID, recordID: link.sourceRecordID),
                            leading: { Glyph(tone: link.targetTone, text: link.targetGlyph, size: 26, radius: 7) },
                            title: link.targetTitle,
                            subtitle: link.targetDatabaseName,
                            trailing: { iOSChevron() }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Notes / Files / Tags (re-use cross-platform views)

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            iOSSectionTitle(title: "Notes")
            BlockListView(store: store)
        }
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            AssetsSection(store: store)
        }
    }

    private var tagsSection: some View {
        TagChipRow(store: store)
    }

    // MARK: - Loading

    private func loadLocal() async {
        dbRow = try? dbClient.database(databaseID)
    }
}
#endif
