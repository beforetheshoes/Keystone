import Foundation
import ComposableArchitecture
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

@Reducer
struct AppFeature {
    @ObservableState
    struct State: Equatable {
        // Navigation
        var nav: Nav = .home

        // Sidebar / global data (loaded once)
        var areas: [AreaRow] = []
        var databases: [DBRow] = []
        var paletteItems: [PaletteItem] = []
        var bootstrapped = false

        // Database view state (reset on database change)
        var currentDB: DBRow?
        var currentProperties: [PropertyRow] = []
        var currentRecords: [RecordRow] = []
        var viewKind: ViewKind = .table
        var sortKey: String?
        var sortAscending: Bool = true

        // Record detail state (reset on record change)
        var currentRecord: RecordRow?
        var currentRecordRelated: [RecordRow] = []
        var currentBlocks: [BlockRow] = []
        var focusedBlockID: String? = nil      // sentinel — view consumes & resets via clearFocusRequest
        var currentRecordTags: [TagModel] = []
        var currentOutgoingRelations: [RelationLink] = []
        var currentIncomingRelations: [RelationLink] = []
        var currentRecordAssets: [AssetRecord] = []

        // Tags (workspace-wide)
        var allTags: [TagModel] = []

        // Tag-filter view (when nav == .tag)
        var tagFilterRecords: [TaggedRecord] = []
        var tagFilterTag: TagModel?

        // Sync status indicator
        var syncStatus: SyncStatus = .local

        // Overlays
        var paletteOpen: Bool = false
        var paletteQuery: String = ""
        var paletteSelectedIndex: Int = 0
        var captureOpen: Bool = false
        var captureKind: CaptureKind = .person
        var captureName: String = ""
    }

    enum Nav: Equatable {
        case home
        case database(String)
        case record(databaseID: String, recordID: String)
        case tag(tagID: String)
        case help(topic: String)
    }

    struct TaggedRecord: Equatable, Sendable, Identifiable {
        var id: String { record.id }
        var record: RecordRow
        var databaseName: String
    }

    enum SyncStatus: Equatable, Sendable {
        case local                          // sync disabled (no entitlements / not configured)
        case syncing
        case synced(lastAt: Date?)
    }

    enum CaptureKind: String, Equatable, Sendable, CaseIterable {
        case person, pet, vehicle, document, event, note

        var label: String {
            switch self {
            case .person: "Person"; case .pet: "Pet"; case .vehicle: "Vehicle"
            case .document: "Document"; case .event: "Event"; case .note: "Note"
            }
        }
        var accent: AccentTone {
            switch self {
            case .person, .document: .cerulean
            case .pet: .sage
            case .vehicle: .iris
            case .event: .amber
            case .note: .graphite
            }
        }
        var icon: String {
            switch self {
            case .person: "P"; case .pet: "Pe"; case .vehicle: "V"
            case .document: "D"; case .event: "E"; case .note: "N"
            }
        }
        var saveKind: String { rawValue + "s" }
        var databaseID: String {
            switch self {
            case .person:   "people"
            case .pet:      "pets"
            case .vehicle:  "vehicles"
            case .document: "documents"
            case .event:    "events"
            case .note:     "documents"
            }
        }
    }

    enum Action: Equatable, BindableAction {
        case binding(BindingAction<State>)
        case task
        case bootstrapLoaded(areas: [AreaRow], databases: [DBRow], palette: [PaletteItem])
        case setNav(Nav)
        case databaseLoaded(db: DBRow?, properties: [PropertyRow], records: [RecordRow])
        case databaseContextLoaded(db: DBRow?, properties: [PropertyRow])
        case recordLoaded(record: RecordRow?, related: [RecordRow])
        case setViewKind(ViewKind)
        case toggleSort(String)
        case openPalette
        case closePalette
        case palettePickIndex(Int)
        case palettePicked(PaletteItem)
        case openCapture
        case closeCapture
        case captureKindChanged(CaptureKind)
        case captureSubmit
        case createBlankRecord(databaseID: String)
        case recordCreated(record: RecordRow, openDetail: Bool)
        case updateRecordTitle(recordID: String, title: String)
        case updatePropertyValue(recordID: String, key: String, value: String)
        case deleteCurrentRecord
        case refreshSidebar
        case sidebarRefreshed(databases: [DBRow], palette: [PaletteItem])
        case refreshCurrentRecords

        case blocksLoaded([BlockRow])
        case blockTextChanged(blockID: String, text: AttributedString)
        case blockKindChanged(blockID: String, kind: BlockKind)
        case blockCheckedChanged(blockID: String, checked: Bool)
        case blockReturnPressed(blockID: String, before: AttributedString, after: AttributedString)
        case blockBackspaceOnEmpty(blockID: String)
        case blockShortcutTriggered(blockID: String, newKind: BlockKind, remainder: AttributedString)
        case createBlockAtEnd
        case blockCreated(BlockRow, focus: Bool)
        case blockDeleted(blockID: String, focusPrevious: Bool)
        case clearFocusRequest

        // Tags
        case allTagsLoaded([TagModel])
        case currentRecordTagsLoaded([TagModel])
        case attachTag(tagID: String)
        case detachTag(tagID: String)
        case createAndAttachTag(name: String, scope: TagScope, color: AccentTone)
        case tagFilterLoaded(tag: TagModel?, records: [TaggedRecord])

        // Relations
        case relationsLoaded(outgoing: [RelationLink], incoming: [RelationLink])
        case addRelation(propertyID: String?, targetRecordID: String)
        case removeRelation(relationID: String)

        // Sync
        case syncStatusChanged(SyncStatus)

        // Assets
        case assetsLoaded([AssetRecord])
        case importAsset(fileURL: URL)
        case assetImported(AssetRecord)
        case deleteAsset(assetID: String)
        case openAsset(assetID: String)

        // Cover image
        case setCoverImage(recordID: String, fileURL: URL)
        case clearCoverImage(recordID: String)
        case coverImageChanged(recordID: String)
    }

    @Dependency(\.databaseClient) var dbClient
    @Dependency(\.syncEngineClient) var syncClient

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .task:
                guard !state.bootstrapped else { return .none }
                state.bootstrapped = true
                return .merge(
                    .run { send in
                        let areas = (try? dbClient.areas()) ?? []
                        let dbs   = (try? dbClient.databases()) ?? []
                        let pal   = (try? dbClient.paletteItems()) ?? []
                        let tags  = (try? dbClient.allTags(Seed.workspaceID)) ?? []
                        await send(.bootstrapLoaded(areas: areas, databases: dbs, palette: pal))
                        await send(.allTagsLoaded(tags))
                    },
                    .run { send in
                        // Kick off CloudKit sync if it's been configured.
                        try? await syncClient.start()
                        for await status in syncClient.observeStatus() {
                            await send(.syncStatusChanged(status))
                        }
                    },
                    .run { send in
                        // Watch the Inbox folder. Any file dropped there
                        // gets auto-imported as a new Document record;
                        // the stream keeps the watcher alive for the
                        // effect's lifetime and tears it down on cancel.
                        let imports = AsyncStream<Void> { continuation in
                            InboxWatcher.shared.start {
                                continuation.yield(())
                            }
                            continuation.onTermination = { _ in
                                InboxWatcher.shared.stop()
                            }
                        }
                        for await _ in imports {
                            await send(.refreshSidebar)
                            await send(.refreshCurrentRecords)
                        }
                    }
                )

            case let .bootstrapLoaded(areas, databases, palette):
                state.areas = areas
                state.databases = databases
                state.paletteItems = palette
                return .none

            case let .setNav(nav):
                state.nav = nav
                state.sortKey = nil
                state.sortAscending = true
                switch nav {
                case .home, .help:
                    state.currentDB = nil
                    state.currentProperties = []
                    state.currentRecords = []
                    state.currentRecord = nil
                    state.currentRecordRelated = []
                    state.currentBlocks = []
                    return .none
                case let .database(dbID):
                    state.currentRecord = nil
                    state.currentRecordRelated = []
                    state.currentBlocks = []
                    return .run { send in
                        let db = try? dbClient.database(dbID)
                        let props = (try? dbClient.properties(dbID)) ?? []
                        let records = (try? dbClient.records(dbID)) ?? []
                        await send(.databaseLoaded(db: db, properties: props, records: records))
                    }
                case let .record(databaseID, recordID):
                    state.currentBlocks = []
                    state.currentRecordTags = []
                    state.currentOutgoingRelations = []
                    state.currentIncomingRelations = []
                    state.currentRecordAssets = []
                    return .run { send in
                        let rec = try? dbClient.record(recordID)
                        let related = (try? dbClient.relatedRecords(recordID)) ?? []
                        let blocks = (try? dbClient.blocks(recordID)) ?? []
                        let tags = (try? dbClient.tagsForRecord(recordID)) ?? []
                        let outgoing = (try? dbClient.outgoingRelations(recordID)) ?? []
                        let incoming = (try? dbClient.incomingRelations(recordID)) ?? []
                        let assets = (try? dbClient.assetsForRecord(recordID)) ?? []
                        if let db = try? dbClient.database(databaseID) {
                            let props = (try? dbClient.properties(databaseID)) ?? []
                            await send(.databaseContextLoaded(db: db, properties: props))
                        }
                        await send(.recordLoaded(record: rec, related: related))
                        await send(.blocksLoaded(blocks))
                        await send(.currentRecordTagsLoaded(tags))
                        await send(.relationsLoaded(outgoing: outgoing, incoming: incoming))
                        await send(.assetsLoaded(assets))
                    }
                case let .tag(tagID):
                    state.currentDB = nil
                    state.currentProperties = []
                    state.currentRecords = []
                    state.currentRecord = nil
                    state.currentRecordRelated = []
                    state.currentBlocks = []
                    state.currentRecordTags = []
                    state.currentOutgoingRelations = []
                    state.currentIncomingRelations = []
                    let knownTag = state.allTags.first(where: { $0.id == tagID })
                    return .run { send in
                        let tag = knownTag ?? (try? dbClient.allTags(Seed.workspaceID))?.first(where: { $0.id == tagID })
                        let pairs = (try? dbClient.recordsForTag(tagID)) ?? []
                        let mapped = pairs.map { TaggedRecord(record: $0.record, databaseName: $0.dbName) }
                        await send(.tagFilterLoaded(tag: tag, records: mapped))
                    }
                }

            case let .databaseLoaded(db, props, records):
                state.currentDB = db
                state.currentProperties = props
                state.currentRecords = records
                if let db {
                    state.viewKind = db.defaultView
                }
                return .none

            case let .databaseContextLoaded(db, props):
                state.currentDB = db
                state.currentProperties = props
                return .none

            case let .recordLoaded(record, related):
                state.currentRecord = record
                state.currentRecordRelated = related
                return .none

            case let .setViewKind(kind):
                state.viewKind = kind
                return .none

            case let .toggleSort(key):
                if state.sortKey == key {
                    if state.sortAscending {
                        state.sortAscending = false
                    } else {
                        state.sortKey = nil
                        state.sortAscending = true
                    }
                } else {
                    state.sortKey = key
                    state.sortAscending = true
                }
                return .none

            case .openPalette:
                state.paletteOpen = true
                state.paletteQuery = ""
                state.paletteSelectedIndex = 0
                return .none
            case .closePalette:
                state.paletteOpen = false
                return .none
            case let .palettePickIndex(i):
                state.paletteSelectedIndex = i
                return .none
            case let .palettePicked(item):
                state.paletteOpen = false
                switch item.kind {
                case .database:
                    if let dbID = item.dbID {
                        return .send(.setNav(.database(dbID)))
                    }
                    return .none
                case .record:
                    if let dbID = item.dbID {
                        let recID = String(item.id.dropFirst("rec-".count))
                        return .send(.setNav(.record(databaseID: dbID, recordID: recID)))
                    }
                    return .none
                case .action:
                    state.captureOpen = true
                    return .none
                }

            case .openCapture:
                state.captureOpen = true
                state.captureName = ""
                return .none
            case .closeCapture:
                state.captureOpen = false
                return .none
            case let .captureKindChanged(kind):
                state.captureKind = kind
                return .none

            case .captureSubmit:
                let trimmed = state.captureName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    state.captureOpen = false
                    return .none
                }
                let dbID = state.captureKind.databaseID
                state.captureOpen = false
                state.captureName = ""
                return .run { send in
                    guard let rec = try? dbClient.createRecord(dbID, trimmed) else { return }
                    await send(.recordCreated(record: rec, openDetail: true))
                }

            case let .createBlankRecord(databaseID):
                let title = "Untitled"
                return .run { send in
                    guard let rec = try? dbClient.createRecord(databaseID, title) else { return }
                    await send(.recordCreated(record: rec, openDetail: true))
                }

            case let .recordCreated(record, openDetail):
                if openDetail {
                    state.nav = .record(databaseID: record.databaseID, recordID: record.id)
                    state.currentRecord = record
                    state.currentRecordRelated = []
                    return .merge(
                        .send(.refreshSidebar),
                        .run { [dbID = record.databaseID] send in
                            let db = try? dbClient.database(dbID)
                            let props = (try? dbClient.properties(dbID)) ?? []
                            await send(.databaseContextLoaded(db: db, properties: props))
                        }
                    )
                }
                return .send(.refreshSidebar)

            case let .updateRecordTitle(recordID, title):
                if state.currentRecord?.id == recordID {
                    state.currentRecord?.title = title
                }
                if let idx = state.currentRecords.firstIndex(where: { $0.id == recordID }) {
                    state.currentRecords[idx].title = title
                }
                return .run { send in
                    try? dbClient.updateRecordTitle(recordID, title)
                    await send(.refreshSidebar)
                }

            case let .updatePropertyValue(recordID, key, value):
                if state.currentRecord?.id == recordID {
                    if value.isEmpty {
                        state.currentRecord?.values.removeValue(forKey: key)
                    } else {
                        state.currentRecord?.values[key] = value
                    }
                }
                if let idx = state.currentRecords.firstIndex(where: { $0.id == recordID }) {
                    if value.isEmpty {
                        state.currentRecords[idx].values.removeValue(forKey: key)
                    } else {
                        state.currentRecords[idx].values[key] = value
                    }
                }
                return .run { _ in
                    try? dbClient.updatePropertyValue(recordID, key, value)
                }

            case .deleteCurrentRecord:
                guard let rec = state.currentRecord else { return .none }
                let dbID = rec.databaseID
                let recID = rec.id
                state.nav = .database(dbID)
                state.currentRecord = nil
                state.currentRecordRelated = []
                state.currentRecords.removeAll { $0.id == recID }
                return .run { send in
                    try? dbClient.deleteRecord(recID)
                    await send(.refreshSidebar)
                    await send(.refreshCurrentRecords)
                }

            case .refreshSidebar:
                return .run { send in
                    let dbs = (try? dbClient.databases()) ?? []
                    let pal = (try? dbClient.paletteItems()) ?? []
                    await send(.sidebarRefreshed(databases: dbs, palette: pal))
                }

            case let .sidebarRefreshed(databases, palette):
                state.databases = databases
                state.paletteItems = palette
                return .none

            case .refreshCurrentRecords:
                if case let .database(dbID) = state.nav {
                    return .run { send in
                        let recs = (try? dbClient.records(dbID)) ?? []
                        let db = try? dbClient.database(dbID)
                        let props = (try? dbClient.properties(dbID)) ?? []
                        await send(.databaseLoaded(db: db, properties: props, records: recs))
                    }
                }
                return .none

            case let .blocksLoaded(blocks):
                state.currentBlocks = blocks
                return .none

            case let .blockTextChanged(blockID, text):
                if let idx = state.currentBlocks.firstIndex(where: { $0.id == blockID }) {
                    state.currentBlocks[idx].text = text
                }
                return .run { _ in
                    try? dbClient.updateBlockText(blockID, text)
                }

            case let .blockKindChanged(blockID, kind):
                if let idx = state.currentBlocks.firstIndex(where: { $0.id == blockID }) {
                    state.currentBlocks[idx].kind = kind
                    if kind == .checklist && state.currentBlocks[idx].checked == nil {
                        state.currentBlocks[idx].checked = false
                    }
                    if kind != .checklist {
                        state.currentBlocks[idx].checked = nil
                    }
                    if kind == .divider {
                        state.currentBlocks[idx].text = AttributedString()
                    }
                }
                return .run { [text = state.currentBlocks.first(where: { $0.id == blockID })?.text] _ in
                    try? dbClient.updateBlockKind(blockID, kind, text)
                }

            case let .blockCheckedChanged(blockID, checked):
                if let idx = state.currentBlocks.firstIndex(where: { $0.id == blockID }) {
                    state.currentBlocks[idx].checked = checked
                }
                return .run { _ in
                    try? dbClient.updateBlockChecked(blockID, checked)
                }

            case let .blockReturnPressed(blockID, before, after):
                guard let idx = state.currentBlocks.firstIndex(where: { $0.id == blockID }) else { return .none }
                let recordID = state.currentBlocks[idx].recordID
                state.currentBlocks[idx].text = before
                let kindOfNew: BlockKind = .paragraph
                return .run { send in
                    try? dbClient.updateBlockText(blockID, before)
                    if let new = try? dbClient.createBlock(recordID, blockID, kindOfNew, after, nil) {
                        await send(.blockCreated(new, focus: true))
                    }
                }

            case let .blockBackspaceOnEmpty(blockID):
                guard let idx = state.currentBlocks.firstIndex(where: { $0.id == blockID }) else { return .none }
                let previousID = idx > 0 ? state.currentBlocks[idx - 1].id : nil
                state.currentBlocks.remove(at: idx)
                state.focusedBlockID = previousID
                return .run { _ in
                    try? dbClient.deleteBlock(blockID)
                }

            case let .blockShortcutTriggered(blockID, newKind, remainder):
                guard let idx = state.currentBlocks.firstIndex(where: { $0.id == blockID }) else { return .none }
                state.currentBlocks[idx].kind = newKind
                state.currentBlocks[idx].text = remainder
                if newKind == .checklist && state.currentBlocks[idx].checked == nil {
                    state.currentBlocks[idx].checked = false
                }
                if newKind == .divider {
                    state.currentBlocks[idx].text = AttributedString()
                    let recordID = state.currentBlocks[idx].recordID
                    return .run { send in
                        try? dbClient.updateBlockKind(blockID, .divider, AttributedString())
                        if let new = try? dbClient.createBlock(recordID, blockID, .paragraph, AttributedString(), nil) {
                            await send(.blockCreated(new, focus: true))
                        }
                    }
                }
                return .run { _ in
                    try? dbClient.updateBlockKind(blockID, newKind, remainder)
                }

            case .createBlockAtEnd:
                guard case let .record(_, recordID) = state.nav else { return .none }
                let anchor = state.currentBlocks.last?.id
                return .run { send in
                    if let new = try? dbClient.createBlock(recordID, anchor, .paragraph, AttributedString(), nil) {
                        await send(.blockCreated(new, focus: true))
                    }
                }

            case let .blockCreated(block, focus):
                let insertIdx = state.currentBlocks.firstIndex(where: { $0.sortIndex > block.sortIndex }) ?? state.currentBlocks.count
                state.currentBlocks.insert(block, at: insertIdx)
                if focus { state.focusedBlockID = block.id }
                return .none

            case let .blockDeleted(blockID, focusPrevious):
                if let idx = state.currentBlocks.firstIndex(where: { $0.id == blockID }) {
                    let previousID = idx > 0 ? state.currentBlocks[idx - 1].id : nil
                    state.currentBlocks.remove(at: idx)
                    if focusPrevious { state.focusedBlockID = previousID }
                }
                return .run { _ in
                    try? dbClient.deleteBlock(blockID)
                }

            case .clearFocusRequest:
                state.focusedBlockID = nil
                return .none

            case let .allTagsLoaded(tags):
                state.allTags = tags
                return .none

            case let .currentRecordTagsLoaded(tags):
                state.currentRecordTags = tags
                return .none

            case let .attachTag(tagID):
                guard let recID = state.currentRecord?.id else { return .none }
                if let tag = state.allTags.first(where: { $0.id == tagID }),
                   !state.currentRecordTags.contains(where: { $0.id == tagID }) {
                    state.currentRecordTags.append(tag)
                }
                return .run { send in
                    try? dbClient.attachTag(recID, tagID)
                    let tags = (try? dbClient.allTags(Seed.workspaceID)) ?? []
                    await send(.allTagsLoaded(tags))
                }

            case let .detachTag(tagID):
                guard let recID = state.currentRecord?.id else { return .none }
                state.currentRecordTags.removeAll { $0.id == tagID }
                return .run { send in
                    try? dbClient.detachTag(recID, tagID)
                    let tags = (try? dbClient.allTags(Seed.workspaceID)) ?? []
                    await send(.allTagsLoaded(tags))
                }

            case let .createAndAttachTag(name, scope, color):
                guard let recID = state.currentRecord?.id, let dbID = state.currentDB?.id else { return .none }
                let scopeID: String? = scope == .database ? dbID : nil
                return .run { send in
                    if let tag = try? dbClient.createTag(Seed.workspaceID, name, scope, scopeID, color) {
                        try? dbClient.attachTag(recID, tag.id)
                    }
                    let tags = (try? dbClient.allTags(Seed.workspaceID)) ?? []
                    let recordTags = (try? dbClient.tagsForRecord(recID)) ?? []
                    await send(.allTagsLoaded(tags))
                    await send(.currentRecordTagsLoaded(recordTags))
                }

            case let .tagFilterLoaded(tag, records):
                state.tagFilterTag = tag
                state.tagFilterRecords = records
                return .none

            case let .relationsLoaded(outgoing, incoming):
                state.currentOutgoingRelations = outgoing
                state.currentIncomingRelations = incoming
                return .none

            case let .addRelation(propertyID, targetRecordID):
                guard let sourceID = state.currentRecord?.id else { return .none }
                return .run { send in
                    _ = try? dbClient.addRelation(sourceID, targetRecordID, propertyID)
                    let outgoing = (try? dbClient.outgoingRelations(sourceID)) ?? []
                    let incoming = (try? dbClient.incomingRelations(sourceID)) ?? []
                    await send(.relationsLoaded(outgoing: outgoing, incoming: incoming))
                }

            case let .removeRelation(relationID):
                guard let sourceID = state.currentRecord?.id else { return .none }
                state.currentOutgoingRelations.removeAll { $0.id == relationID }
                return .run { send in
                    try? dbClient.removeRelation(relationID)
                    let outgoing = (try? dbClient.outgoingRelations(sourceID)) ?? []
                    let incoming = (try? dbClient.incomingRelations(sourceID)) ?? []
                    await send(.relationsLoaded(outgoing: outgoing, incoming: incoming))
                }

            case let .syncStatusChanged(status):
                state.syncStatus = status
                return .none

            case let .assetsLoaded(assets):
                state.currentRecordAssets = assets
                return .none

            case let .importAsset(fileURL):
                guard let recID = state.currentRecord?.id else { return .none }
                return .run { send in
                    // Honor security-scoped resource access for sandboxed drops.
                    let didStart = fileURL.startAccessingSecurityScopedResource()
                    defer { if didStart { fileURL.stopAccessingSecurityScopedResource() } }

                    if let asset = try? dbClient.importAsset(fileURL, recID, Seed.workspaceID) {
                        await send(.assetImported(asset))
                    }
                    let assets = (try? dbClient.assetsForRecord(recID)) ?? []
                    await send(.assetsLoaded(assets))
                }

            case let .assetImported(asset):
                if !state.currentRecordAssets.contains(where: { $0.id == asset.id }) {
                    state.currentRecordAssets.insert(asset, at: 0)
                }
                return .none

            case let .deleteAsset(assetID):
                state.currentRecordAssets.removeAll { $0.id == assetID }
                let recID = state.currentRecord?.id
                return .run { send in
                    try? dbClient.deleteAsset(assetID)
                    if let recID {
                        let assets = (try? dbClient.assetsForRecord(recID)) ?? []
                        await send(.assetsLoaded(assets))
                    }
                }

            case let .openAsset(assetID):
                guard let asset = state.currentRecordAssets.first(where: { $0.id == assetID }) else { return .none }
                let url = asset.absoluteURL
                return .run { _ in
                    await MainActor.run {
                        #if canImport(AppKit)
                        _ = NSWorkspace.shared.open(url)
                        #elseif canImport(UIKit)
                        UIApplication.shared.open(url)
                        #endif
                    }
                }

            case let .setCoverImage(recordID, fileURL):
                return .run { send in
                    let didStart = fileURL.startAccessingSecurityScopedResource()
                    defer { if didStart { fileURL.stopAccessingSecurityScopedResource() } }
                    _ = try? dbClient.importCoverImage(fileURL, recordID, Seed.workspaceID)
                    await send(.coverImageChanged(recordID: recordID))
                }

            case let .clearCoverImage(recordID):
                return .run { send in
                    try? dbClient.setRecordCover(recordID, nil)
                    await send(.coverImageChanged(recordID: recordID))
                }

            case let .coverImageChanged(recordID):
                return .merge(
                    .send(.refreshCurrentRecords),
                    .run { send in
                        let rec = try? dbClient.record(recordID)
                        let related = (try? dbClient.relatedRecords(recordID)) ?? []
                        await send(.recordLoaded(record: rec, related: related))
                        let assets = (try? dbClient.assetsForRecord(recordID)) ?? []
                        await send(.assetsLoaded(assets))
                    }
                )
            }
        }
    }
}
