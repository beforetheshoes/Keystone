import SwiftUI
import ComposableArchitecture

struct RecordDetailView: View {
    @Bindable var store: StoreOf<AppFeature>
    var db: DBRow
    var record: RecordRow

    @State private var titleDraft: String = ""
    @State private var valueDrafts: [String: String] = [:]
    @State private var titleDraftDirty: Bool = false
    @State private var dirtyKeys: Set<String> = []
    @State private var lookupSheetOpen: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            KstToolbar(crumbs: [
                .init(label: db.name, action: { store.send(.setNav(.database(db.id))) }),
                .init(label: record.title, action: nil),
            ]) {
                KstButton(style: .ghost, action: { store.send(.setNav(.database(db.id))) }) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("Back")
                }
                Menu {
                    if db.id == "vendors" {
                        Button("Look up on Apple Maps") {
                            lookupSheetOpen = true
                        }
                        Divider()
                    }
                    Button("Delete record", role: .destructive) {
                        store.send(.deleteCurrentRecord)
                    }
                } label: {
                    Text("⋯")
                }
                #if os(macOS)
                .menuStyle(.button)
                .buttonStyle(.plain)
                .frame(height: 26).padding(.horizontal, 10)
                .background(KstColor.paper0)
                .overlay(
                    RoundedRectangle(cornerRadius: KstRadius.r2, style: .continuous)
                        .strokeBorder(KstColor.ink4, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: KstRadius.r2, style: .continuous))
                #endif
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Hero
                    HeroBlock(store: store, record: record, db: db, titleDraft: $titleDraft, onCommit: { commitTitle() })
                        .padding(.bottom, 28)

                    // Properties grid
                    PropertiesGrid(
                        store: store,
                        properties: store.currentProperties,
                        record: record,
                        drafts: $valueDrafts,
                        onChange: { key in commitProperty(key) },
                        onSubmit: { key in commitProperty(key) }
                    )
                    .padding(.bottom, 20)

                    // Tags
                    TagChipRow(store: store)
                        .padding(.bottom, 24)

                    #if canImport(MapKit)
                    if #available(iOS 26.0, macOS 26.0, *),
                       db.id == "vendors",
                       let placeID = record.values["place_id"], !placeID.isEmpty {
                        SectionHeader(title: "LOCATION", count: nil)
                        VendorMapPreview(placeID: placeID)
                            .padding(.bottom, 28)
                    }
                    #endif

                    if !relatedNonProperty.isEmpty {
                        SectionHeader(title: "RELATED", count: nil)
                        relationsGrid(links: relatedNonProperty)
                            .padding(.bottom, 28)
                    }

                    if !store.currentIncomingRelations.isEmpty {
                        SectionHeader(title: "LINKED FROM", count: nil)
                        incomingGrid(links: store.currentIncomingRelations)
                            .padding(.bottom, 28)
                    }

                    SectionHeader(title: "NOTES", count: nil)
                    BlockListView(store: store)
                        .padding(.bottom, 28)

                    AssetsSection(store: store)
                        .padding(.bottom, 28)
                }
                .frame(maxWidth: 920, alignment: .leading)
                .padding(.horizontal, 64)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(KstColor.paper0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KstColor.paper0)
        .onAppear { syncDrafts() }
        .onChange(of: record.id) { oldID, _ in
            // Flush previous record's drafts before retargeting
            flushAllDrafts(forRecordID: oldID)
            syncDrafts()
        }
        .onChange(of: record.title) { _, new in
            // Server-side change: update draft if user hasn't been typing
            if titleDraft != new && !titleDraftDirty { titleDraft = new }
        }
        .onChange(of: record.values) { _, new in
            for (k, v) in new where valueDrafts[k] != v && dirtyKeys.contains(k) == false {
                valueDrafts[k] = v
            }
        }
        .onDisappear { flushAllDrafts(forRecordID: record.id) }
        #if canImport(MapKit)
        .sheet(isPresented: $lookupSheetOpen) {
            if #available(iOS 26.0, macOS 26.0, *) {
                VendorLookupSheet(
                    store: store,
                    recordID: record.id,
                    currentName: record.title,
                    currentAddress: record.values["address"]
                )
            }
        }
        #endif
    }

    private func syncDrafts() {
        titleDraft = record.title
        titleDraftDirty = false
        var d: [String: String] = [:]
        for p in store.currentProperties where p.type != .title {
            d[p.key] = record.values[p.key] ?? ""
        }
        valueDrafts = d
        dirtyKeys.removeAll()
    }

    private func commitTitle() {
        titleDraftDirty = true
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != record.title else { return }
        store.send(.updateRecordTitle(recordID: record.id, title: trimmed))
    }

    private func commitProperty(_ key: String) {
        dirtyKeys.insert(key)
        let trimmed = (valueDrafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let current = record.values[key] ?? ""
        guard trimmed != current else { return }
        store.send(.updatePropertyValue(recordID: record.id, key: key, value: trimmed))
    }

    private func flushAllDrafts(forRecordID recordID: String) {
        let trimmedTitle = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty, trimmedTitle != record.title {
            store.send(.updateRecordTitle(recordID: recordID, title: trimmedTitle))
        }
        for (key, draft) in valueDrafts {
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            let current = record.values[key] ?? ""
            if trimmed != current {
                store.send(.updatePropertyValue(recordID: recordID, key: key, value: trimmed))
            }
        }
    }

    /// Outgoing relations that are NOT bound to a property — those show up
    /// inline in the property row already. This panel surfaces the rest
    /// (e.g., Eleanor's hand-curated `linked` relations).
    private var relatedNonProperty: [RelationLink] {
        store.currentOutgoingRelations.filter { $0.propertyID == nil }
    }

    @ViewBuilder
    private func relationsGrid(links: [RelationLink]) -> some View {
        // Fixed 2x2 quadrant layout for the four canonical life-management
        // databases. Matches the design prototype's RELATED panel. Any
        // links pointing at databases NOT in the canonical set are bucketed
        // into a fifth "Other" group rendered after the quadrants.
        let canonicalDatabases: [(id: String, label: String)] = [
            ("pets", "PETS"),
            ("vehicles", "VEHICLES"),
            ("homes", "HOMES"),
            ("documents", "DOCUMENTS"),
        ]
        let canonicalIDs = Set(canonicalDatabases.map(\.id))

        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                quadrant(forDatabaseID: canonicalDatabases[0].id, label: canonicalDatabases[0].label, links: links)
                quadrant(forDatabaseID: canonicalDatabases[1].id, label: canonicalDatabases[1].label, links: links)
            }
            GridRow {
                quadrant(forDatabaseID: canonicalDatabases[2].id, label: canonicalDatabases[2].label, links: links)
                quadrant(forDatabaseID: canonicalDatabases[3].id, label: canonicalDatabases[3].label, links: links)
            }
        }

        let otherLinks = links.filter { !canonicalIDs.contains($0.targetDatabaseID) }
        if !otherLinks.isEmpty {
            let otherGroups: [(databaseName: String, links: [RelationLink])] = Dictionary(grouping: otherLinks, by: \.targetDatabaseName)
                .map { ($0.key, $0.value) }
                .sorted { $0.databaseName < $1.databaseName }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                ForEach(Array(otherGroups.enumerated()), id: \.offset) { _, group in
                    RelationListCard(label: group.databaseName.uppercased(), links: group.links) { link in
                        store.send(.setNav(.record(databaseID: link.targetDatabaseID, recordID: link.targetRecordID)))
                    }
                }
            }
            .padding(.top, 12)
        }
    }

    @ViewBuilder
    private func quadrant(forDatabaseID dbID: String, label: String, links: [RelationLink]) -> some View {
        let bucketLinks = links.filter { $0.targetDatabaseID == dbID }
        RelationListCard(label: label, links: bucketLinks, emptyHint: "—") { link in
            store.send(.setNav(.record(databaseID: link.targetDatabaseID, recordID: link.targetRecordID)))
        }
    }

    @ViewBuilder
    private func incomingGrid(links: [RelationLink]) -> some View {
        let groups: [(databaseName: String, links: [RelationLink])] = Dictionary(grouping: links, by: \.targetDatabaseName)
            .map { ($0.key, $0.value) }
            .sorted { $0.databaseName < $1.databaseName }

        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                // For incoming, link's source* fields hold the linker; the
                // RelationLink we built actually flipped fields so target* in
                // the struct matches the SOURCE record (the one linking here).
                RelationListCard(label: group.databaseName.uppercased(), links: group.links) { link in
                    store.send(.setNav(.record(databaseID: link.targetDatabaseID, recordID: link.sourceRecordID)))
                }
            }
        }
    }
}

private struct RelationListCard: View {
    var label: String
    var links: [RelationLink]
    var emptyHint: String? = nil
    var onTap: (RelationLink) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.kstText(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(KstColor.ink2)
                Spacer(minLength: 0)
                if !links.isEmpty {
                    Text("\(links.count)")
                        .font(.kstText(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(KstColor.ink3)
                }
            }
            if links.isEmpty, let hint = emptyHint {
                Text(hint)
                    .font(.kstText(size: 13))
                    .foregroundStyle(KstColor.ink3)
                    .padding(.vertical, 4)
            } else {
                ForEach(links) { link in
                    Button(action: { onTap(link) }) {
                        HStack(spacing: 8) {
                            Glyph(tone: link.targetTone, text: link.targetGlyph, size: 16, radius: 4)
                            Text(link.targetTitle).font(.kstText(size: 13)).foregroundStyle(KstColor.ink1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KstColor.paper0)
        .overlay(
            RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous))
    }
}

private struct HeroBlock: View {
    var store: StoreOf<AppFeature>
    var record: RecordRow
    var db: DBRow
    @Binding var titleDraft: String
    var onCommit: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 18) {
            CoverAvatar(store: store, record: record, size: 144)
                .kstShadow2()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(store.databases) { other in
                            Button {
                                if other.id != db.id {
                                    store.send(.changeRecordDatabase(recordID: record.id, newDatabaseID: other.id))
                                }
                            } label: {
                                if other.id == db.id {
                                    Label(other.name, systemImage: "checkmark")
                                } else {
                                    Text(other.name)
                                }
                            }
                        }
                    } label: {
                        KstPill(text: db.name.hasSuffix("s") ? String(db.name.dropLast()) : db.name,
                                background: record.tone.soft,
                                foreground: record.tone.ink)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .help("Change type — properties not in the new type are dropped")

                    if let rel = record.values["relationship"], !rel.isEmpty, rel != "—" {
                        KstPill(text: rel)
                    }
                }
                TextField("Untitled", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.kstDisplay(size: 38, weight: .semibold))
                    .foregroundStyle(KstColor.ink0)
                    .kerning(-0.6)
                    .onChange(of: titleDraft) { _, _ in onCommit() }
                    .onSubmit(onCommit)
            }

            Spacer(minLength: 0)
        }
    }
}

private struct PropertiesGrid: View {
    @Bindable var store: StoreOf<AppFeature>
    var properties: [PropertyRow]
    var record: RecordRow
    @Binding var drafts: [String: String]
    var onChange: (String) -> Void
    var onSubmit: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            let visible = properties.filter { $0.type != .title }
            ForEach(Array(visible.enumerated()), id: \.element.id) { idx, p in
                HStack(alignment: .center, spacing: 0) {
                    HStack(spacing: 7) {
                        PropTypeIcon(type: p.type)
                        Text(p.name)
                            .font(.kstText(size: 13))
                            .foregroundStyle(KstColor.ink2)
                    }
                    .frame(width: 130, alignment: .leading)

                    if p.type == .relation {
                        RelationField(store: store, property: p)
                    } else {
                        PropertyValueField(
                            property: p,
                            value: Binding(
                                get: { drafts[p.key] ?? record.values[p.key] ?? "" },
                                set: { newValue in
                                    drafts[p.key] = newValue
                                }
                            ),
                            onCommit: { onSubmit(p.key) }
                        )
                    }

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) {
                    if idx < visible.count - 1 {
                        Rectangle().fill(KstColor.paper3).frame(height: 0.5)
                    }
                }
            }

        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(KstColor.paper1)
        .overlay(
            RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous))
    }
}

private struct SectionHeader: View {
    var title: String
    var count: Int?
    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.kstText(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(KstColor.ink2)
            if let count {
                Text("\(count)")
                    .font(.kstText(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(KstColor.ink3)
            }
        }
        .padding(.bottom, 10)
    }
}

private struct RelatedGroupCard: View {
    var label: String
    var icon: String
    var iconAccent: AccentTone
    var records: [RecordRow]
    var onOpen: (RecordRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Glyph(tone: iconAccent, text: icon, size: 14, radius: 3)
                Text(label)
                    .font(.kstText(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(KstColor.ink2)
                Spacer(minLength: 0)
                Text("\(records.count)")
                    .font(.kstText(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(KstColor.ink3)
            }
            .padding(.bottom, 8)

            if records.isEmpty {
                Text("—").font(.kstText(size: 13)).foregroundStyle(KstColor.ink3)
                    .padding(.vertical, 4)
            } else {
                ForEach(records) { r in
                    Button(action: { onOpen(r) }) {
                        HStack(spacing: 8) {
                            Glyph(tone: r.tone, text: r.glyph, size: 16, radius: 4)
                            Text(r.title).font(.kstText(size: 13)).foregroundStyle(KstColor.ink1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KstColor.paper0)
        .overlay(
            RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous))
    }
}

