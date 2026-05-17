import Foundation
import ComposableArchitecture
@preconcurrency import SQLiteData
#if canImport(CloudKit)
import CloudKit
#endif
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
        /// Saved views (filtered presentations over a backing database).
        /// Surfaced in the sidebar next to real databases. The
        /// Restaurants entry, for example, is a view over `vendors`
        /// with `kind = "restaurant"` pinned. See `ViewRow`.
        var views: [ViewRow] = []
        var paletteItems: [PaletteItem] = []
        var bootstrapped = false

        // Database view state (reset on database change)
        var currentDB: DBRow?
        var currentProperties: [PropertyRow] = []
        var currentRecords: [RecordRow] = []
        var viewKind: ViewKind = .table
        var sortKey: String?
        var sortAscending: Bool = true
        /// Property key to bucket records by in list / gallery / table.
        /// `nil` means "no grouping" — the previous behavior. Persisted
        /// per-database via `database_view_prefs`.
        var groupKey: String? = nil
        /// Cover-size preset for the gallery view. Persisted per-database
        /// so "Books in large covers" survives relaunch.
        var galleryCoverSize: GalleryCoverSize = .medium
        /// Property keys the user has hidden from the table view's
        /// column set. Drives both the toolbar "Columns" picker's
        /// checkbox state and the column filter inside `TableView`.
        var hiddenColumns: Set<String> = []
        /// The `database_view_prefs.database_id` whose prefs are currently
        /// loaded into `sortKey` / `groupKey` / `galleryCoverSize` /
        /// `filters`. Used so a stale .saveViewPrefs effect doesn't
        /// overwrite the next database's row when the user switches.
        var viewPrefsDatabaseID: String? = nil
        /// Non-nil when the active route is a saved view (Nav.view).
        /// Drives the "+ New" lookup-provider override, the pinned
        /// filter set, and the kind-scoping passed to list/table column
        /// visibility filtering.
        var currentView: ViewRow?
        /// Filters baked into the active view (Nav.view) — non-removable
        /// from the UI, applied alongside user-added `filters`. Empty
        /// when the route is a plain database.
        var pinnedFilters: [Filter] = []
        /// Filters applied to `currentRecords`. Reset on database
        /// switch (handled in `setNav`) so each database starts with a
        /// clean slate. Persistence to `views.config_json` is a future
        /// extension — these are session-only for now.
        var filters: [Filter] = []
        /// Convenience: records after filtering. SwiftUI re-derives this
        /// when `filters` or `currentRecords` change. Pinned filters
        /// (from `currentView`) are combined with user-added filters
        /// before evaluation.
        var filteredRecords: [RecordRow] {
            FilterEngine.apply(pinnedFilters + filters, to: currentRecords, properties: currentProperties)
        }

        // Record detail state (reset on record change)
        var currentRecord: RecordRow?
        var currentRecordRelated: [RecordRow] = []
        var currentBlocks: [BlockRow] = []
        var focusedBlockID: String? = nil      // sentinel — view consumes & resets via clearFocusRequest
        var currentRecordTags: [TagModel] = []
        var currentOutgoingRelations: [RelationLink] = []
        var currentIncomingRelations: [RelationLink] = []
        var currentRecordAssets: [AssetRecord] = []

        /// Record IDs currently being re-enriched (user clicked
        /// "Re-enrich…"). Detail and gallery views read this to render
        /// a spinner so the action doesn't feel like it did nothing.
        var enrichingRecordIDs: Set<String> = []

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

        /// Lookup-first creation state. Non-nil when the sheet is open;
        /// carries the database id + display name for the picker. Reset
        /// to nil on close, on candidate pick, or on database/nav change.
        var lookupSheet: LookupSheetState?

        /// Cover-only picker state. Non-nil when the cover sheet is
        /// open. Distinct from `lookupSheet` (full enrichment) — a pick
        /// here writes only `cover_asset_id`, leaving other properties
        /// untouched. Books fan out to Google Books + Open Library;
        /// movies / TV use TMDB.
        var coverPickerSheet: CoverPickerSheetState?

        // MARK: - Privacy lock

        /// True when the app-launch lock has been satisfied (or is
        /// disabled). When false, `AppView` overlays `AppLockView` and
        /// blocks the underlying UI.
        ///
        /// On bootstrap we set this to `false` if
        /// `KeystoneSettings.appLockEnabled` is on, then run the
        /// biometric prompt. Defaults to `true` so workspaces with the
        /// lock disabled (the common case) never see a prompt.
        var appLockUnlocked: Bool = true

        /// In-memory allow-list of records the user has already
        /// authenticated for during this session. Never persisted —
        /// quitting the app clears it. Includes both individually-
        /// unlocked records (per-record prompt) and the full set after
        /// "Show all protected" has been used.
        var unlockedRecordIDs: Set<String> = []

        /// Cached output of `ProtectedReads.hiddenRecordIDs` —
        /// recomputed on bootstrap, on every protection toggle, on
        /// relation create/delete (cascade depends on relations), and
        /// after each unlock/lock action.
        var hiddenRecordIDs: Set<String> = []

        /// Cached output of `ProtectedReads.allProtectedSeedIDs` —
        /// the literal set of records flagged `is_protected = true`.
        /// Used by the "N protected hidden" footer, the "Show all
        /// protected" affordance, and the lock-now button's enabled
        /// state. Recomputed alongside `hiddenRecordIDs`.
        var protectedSeedIDs: Set<String> = []

        /// True when an auth challenge is currently in flight.
        /// Suppresses duplicate prompts if the user double-taps the
        /// unlock button. Cleared on completion / cancel.
        var authInFlight: Bool = false

        // Sharing (#14)

        /// Non-nil when the user has tapped "Share record…" and the
        /// CKShare prep is in flight. Drives the busy spinner in the
        /// menu and dedupes double-taps.
        var sharePreparingRecordID: String? = nil

        /// Non-nil when a `SharedRecord` has been minted and is ready
        /// for the platform-specific sharing controller to present.
        /// The view observes this and binds it to a sheet — clearing
        /// the value (via `.shareSheetDismissed`) closes the sheet.
        var sharePresentingSharedRecord: SharedRecordWrapper? = nil

        /// Non-nil after a share-create error so the user sees what
        /// went wrong. Cleared when they dismiss the alert / re-try.
        var shareErrorMessage: String? = nil
    }

    /// Tiny wrapper around sqlite-data's `SharedRecord` so it satisfies
    /// `Equatable + Sendable` for `@ObservableState`. `SharedRecord` is
    /// already `Hashable + Sendable`, but the `@ObservableState` macro
    /// expansion needs a wrapper around CloudKit-vended types so the
    /// state remains structurally simple.
    struct SharedRecordWrapper: Equatable, Sendable, Identifiable {
        let recordID: String
        let sharedRecord: SharedRecord
        var id: String { recordID }
        static func == (lhs: SharedRecordWrapper, rhs: SharedRecordWrapper) -> Bool {
            lhs.recordID == rhs.recordID && lhs.sharedRecord == rhs.sharedRecord
        }
    }

    /// State for the cover-only picker sheet. `query` is editable by
    /// the user (initialized to the record's title); the candidate
    /// list reloads when they hit Enter / tap Search.
    struct CoverPickerSheetState: Equatable, Sendable {
        var databaseID: String
        var recordID: String
        /// Display title shown in the sheet header. Stays fixed even
        /// as the user refines the query.
        var recordTitle: String
        var query: String
        var loading: Bool = false
        var candidates: [CoverCandidate] = []
        /// Per-source outcome of the most recent search — `ok`,
        /// `unavailable`, or `errored`. Lets the picker surface a
        /// "Google Books temporarily unavailable" hint when the user
        /// is looking at OL-only results because Google rate-limited.
        var sources: [CoverSearchSourceStatus] = []
        /// True while the picked candidate is being downloaded +
        /// attached. Used to disable further selections in the picker.
        var applying: Bool = false
    }

    struct LookupSheetState: Equatable {
        var databaseID: String
        var databaseName: String
        /// Provider-registry key override. `nil` (the default) means
        /// look up under `databaseID` — the pre-views behavior. A
        /// saved view sets this so its "+ New" uses a view-specific
        /// candidate source (Restaurants view → `"restaurant"`).
        var lookupProviderKey: String?
        /// Kind value to stamp onto the newly-created record. `nil`
        /// when no kind is pinned. The Restaurants view passes
        /// `"restaurant"` so a fresh "Create blank" fallback still
        /// surfaces in the right place.
        var presetKind: String?
        /// When non-nil, picks apply to this existing record (the
        /// "re-enrich" flow) instead of creating a new one.
        var existingRecordID: String?
        /// Pre-filled query — the existing record's title for re-enrich,
        /// empty for fresh creation.
        var initialQuery: String

        init(
            databaseID: String,
            databaseName: String,
            lookupProviderKey: String? = nil,
            presetKind: String? = nil,
            existingRecordID: String? = nil,
            initialQuery: String = ""
        ) {
            self.databaseID = databaseID
            self.databaseName = databaseName
            self.lookupProviderKey = lookupProviderKey
            self.presetKind = presetKind
            self.existingRecordID = existingRecordID
            self.initialQuery = initialQuery
        }
    }

    enum Nav: Equatable {
        case home
        case database(String)
        case record(databaseID: String, recordID: String)
        case tag(tagID: String)
        case help(topic: String)
        /// Saved view of an underlying database (rows from `views`,
        /// e.g. Restaurants over Vendors with kind pinned). Loads the
        /// view's backing database and applies its `queryFilters` as a
        /// pinned non-removable filter set.
        case view(String)
        /// Cross-database derived view: per-vehicle "what's due / overdue"
        /// computed from `service_catalog` items joined against
        /// `vehicle_maintenance` events. Not a database route — this
        /// is a report, not a record list.
        case maintenanceSchedule
        /// Dedicated statistics page for a Collections database
        /// (books / movies / tv_shows). Loads `currentDB` +
        /// `currentProperties` + `currentRecords` the same way
        /// `.database` does, but without filter chips or view-prefs
        /// persistence — stats reads the full record set directly.
        case stats(databaseID: String)
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
        case bootstrapLoaded(areas: [AreaRow], databases: [DBRow], views: [ViewRow], palette: [PaletteItem])
        case setNav(Nav)
        /// Navigate from the deep stats page back to a database with a
        /// preset `multiSelect` filter (e.g. tap a tag on the Top Tags
        /// chart → land on Books filtered by that tag). Distinct from
        /// `setNav(.database)` because that path clears every filter
        /// and reloads view prefs; this one writes the preset filter
        /// after the database loads and intentionally skips view-prefs
        /// hydration so the persisted filters don't clobber it.
        case navigateAndPresetTagFilter(databaseID: String, propertyKey: String, value: String)
        case databaseLoaded(db: DBRow?, properties: [PropertyRow], records: [RecordRow])
        case databaseContextLoaded(db: DBRow?, properties: [PropertyRow])
        case recordLoaded(record: RecordRow?, related: [RecordRow])
        case setViewKind(ViewKind)
        case toggleSort(String)
        /// Set / clear the property used to bucket the current
        /// database's records in list / gallery / table.
        case setGroupKey(String?)
        /// Change the gallery cover-size preset for the current database.
        case setGalleryCoverSize(GalleryCoverSize)
        /// Toggle a column's visibility in the table view. Persisted
        /// via `database_view_prefs.hidden_columns_json`.
        case setColumnHidden(key: String, hidden: Bool)
        /// Internal — fired when persisted view prefs have been loaded
        /// for the database the user just opened.
        case viewPrefsLoaded(databaseID: String, prefs: DatabaseViewPrefs)
        /// Persist a per-column alignment override on the property's
        /// `config_json`. Pass `nil` for `alignment` to clear the
        /// override and fall back to the type-aware default.
        case setColumnAlignment(propertyID: String, alignment: PropertyAlignment?)
        /// Append a brand-new option to a `select` / `multiSelect`
        /// property's options list. Surfaces via the "Add new…"
        /// affordance in the select pill, the table multi-select
        /// cell's popover, and the multi-select chip editor. The
        /// reducer updates `currentProperties` optimistically so the
        /// new option is immediately available in the same picker
        /// the user typed into.
        case addPropertyOption(propertyID: String, option: String)
        /// Remove an option from a `select` / `multiSelect` property
        /// AND strip the value from every record that carries it.
        /// Confirmation gating is the caller's responsibility (the
        /// popover already prompts before sending). The reducer
        /// updates `currentProperties` optimistically and refreshes
        /// the record list so the chips / capsules in the table
        /// re-render without the dropped value.
        case removePropertyOption(propertyID: String, option: String)
        /// Add a fresh empty filter for the given property. The
        /// predicate type is derived from the property's type.
        case addFilter(propertyKey: String)
        /// Replace a filter's predicate (typically called as the user
        /// edits the filter in the UI).
        case updateFilter(id: String, predicate: FilterPredicate)
        /// Remove an active filter by id.
        case removeFilter(id: String)
        /// Clear every active filter.
        case clearFilters
        case openPalette
        case closePalette
        case palettePickIndex(Int)
        case palettePicked(PaletteItem)
        case openCapture
        case closeCapture
        case captureKindChanged(CaptureKind)
        case captureSubmit
        case createBlankRecord(databaseID: String, presets: [String: String] = [:])
        /// "+ Log service" from the maintenance schedule view. Creates
        /// a blank `vehicle_maintenance` record, immediately wires the
        /// `vehicle` relation to the chosen vehicle, and opens the
        /// detail page for the user to fill in date / mileage /
        /// services. The new record is otherwise identical to one
        /// created via the standard "+ New" affordance — same fields,
        /// same sidecar materialization, same downstream behavior.
        case logServiceForVehicle(vehicleID: String)
        /// Open the lookup-first creation sheet for a database with a
        /// registered `LookupProvider`. Falls through to
        /// `createBlankRecord` if no provider is available right now.
        case openLookup(databaseID: String, databaseName: String)
        /// Fired when the Re-enrich pass for a record finishes, success
        /// or failure. Clears the record's spinner.
        case enrichmentFinished(recordID: String)
        /// Bulk Re-enrich every record currently visible in the active
        /// database / view route. Pre-clears source-only fields on each
        /// then runs the provider pass record-by-record so spinners
        /// drain progressively.
        case reenrichAllVisibleRecords
        /// Re-enrich an existing record via the lookup sheet, with the
        /// record's current title pre-filled as the search query.
        case openReenrichLookup(databaseID: String, databaseName: String, recordID: String, currentTitle: String)
        /// Internal — fired by `openLookup` / `openReenrichLookup` after
        /// it resolves provider availability. State mutation is split
        /// out from the async availability check so the reducer stays
        /// straightforward.
        case presentLookupSheet(state: LookupSheetState)
        case closeLookup
        case lookupCandidatePicked(databaseID: String, candidate: LookupCandidate)
        case lookupCandidatePickedForExisting(databaseID: String, recordID: String, candidate: LookupCandidate)

        // Cover-only picker (Search covers…)
        case openCoverPicker(databaseID: String, recordID: String, currentTitle: String)
        case coverPickerQueryChanged(String)
        case coverPickerSearchRequested
        case coverPickerCandidatesLoaded(query: String, result: CoverSearchResult)
        case coverPickerCandidatePicked(CoverCandidate)
        case coverPickerCoverAttached
        case closeCoverPicker
        case recordCreated(record: RecordRow, openDetail: Bool)
        case updateRecordTitle(recordID: String, title: String)
        case updatePropertyValue(recordID: String, key: String, value: String)
        case deleteCurrentRecord
        case deleteAllRecordsInDatabase(databaseID: String)
        case changeRecordDatabase(recordID: String, newDatabaseID: String)
        case refreshSidebar
        case sidebarRefreshed(databases: [DBRow], views: [ViewRow], palette: [PaletteItem])
        case refreshCurrentRecords
        /// Reload the currently-displayed record's properties, related
        /// records, blocks, tags, relations, and assets without changing
        /// nav. Fired after a background pass (enrichment, cover import)
        /// writes new property values so the detail view doesn't go
        /// stale until the user navigates away and back.
        case refreshCurrentRecord

        case blocksLoaded([BlockRow])
        case blockTextChanged(blockID: String, text: AttributedString)
        case blockKindChanged(blockID: String, kind: BlockKind)
        case blockCheckedChanged(blockID: String, checked: Bool)
        case blockTableEdited(blockID: String, table: BlockTableData)
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
        case quickLookAsset(assetID: String)

        // Cover image
        case setCoverImage(recordID: String, fileURL: URL)
        case clearCoverImage(recordID: String)
        case coverImageChanged(recordID: String)

        // Privacy lock
        /// Recompute `hiddenRecordIDs` + `protectedSeedIDs` from the
        /// current DB + unlock allow-list. Fired on bootstrap and after
        /// any write that could change cascade membership (is_protected
        /// toggle, relation create/delete).
        case recomputeHiddenSet
        case hiddenSetLoaded(hidden: Set<String>, seeds: Set<String>)
        /// User pressed the lock-screen authenticate button (or app
        /// just bootstrapped with `appLockEnabled` on).
        case unlockAppRequested
        /// User-facing "Lock now" — clears `unlockedRecordIDs` and
        /// re-engages the launch lock when enabled. Independent of OS
        /// session lifecycle.
        case lockAppRequested
        /// User tapped the per-record auth prompt.
        case unlockRecordRequested(recordID: String)
        /// User tapped the "N protected — Show" footer / "Show all
        /// protected" toolbar button.
        case unlockAllProtectedRequested
        /// Internal — auth finished. `success=true` flips the relevant
        /// state slot; `false` only clears `authInFlight`.
        case authCompleted(scope: AuthScope, success: Bool)

        // Sharing (#14)
        /// User picked "Share record…" from the record toolbar. Kicks
        /// off the CKShare prep effect.
        case shareRecordRequested(recordID: String)
        /// CKShare ready — view binds to the wrapper and presents the
        /// platform sharing controller.
        case shareRecordReady(recordID: String, sharedRecord: SharedRecord)
        /// Share creation failed. Surfaces in an alert.
        case shareRecordFailed(message: String)
        /// View dismissed the sharing controller — clear the wrapper
        /// so the next share attempt starts fresh.
        case shareSheetDismissed
        /// User dismissed the share-error alert.
        case shareErrorDismissed
        /// User accepted an incoming CKShare via the OS share-handoff
        /// hooks (NSApplication on macOS, scene delegate on iOS).
        case shareAccepted(metadata: CKShare.Metadata)
        /// Internal — `acceptShare` finished. Logged + ignored at the
        /// reducer level; the SyncEngine starts pulling the shared row.
        case shareAcceptCompleted(success: Bool)
    }

    /// Distinguishes which auth challenge a result is responding to,
    /// so a single `.authCompleted` action can route to the correct
    /// state mutation.
    enum AuthScope: Equatable, Sendable {
        case appLaunch
        case singleRecord(id: String)
        case allProtected
    }

    @Dependency(\.databaseClient) var dbClient
    @Dependency(\.syncEngineClient) var syncClient
    @Dependency(\.biometricAuthClient) var authClient

    /// True when the prior status was already a settled sync state. Used
    /// to gate the sidebar refresh on `.synced` so we only do work on the
    /// transition from "syncing/local" → "synced", not on every poll.
    private func isAlreadySynced(_ status: AppFeature.SyncStatus) -> Bool {
        if case .synced = status { return true }
        return false
    }

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .task:
                guard !state.bootstrapped else { return .none }
                state.bootstrapped = true
                // Decide initial lock state immediately so the AppView
                // overlay decision doesn't flicker on launch. The actual
                // biometric prompt fires from .unlockAppRequested below
                // once the hidden-set has been computed.
                let appLockEnabled = KeystoneSettings.appLockEnabled
                state.appLockUnlocked = !appLockEnabled
                return .merge(
                    .run { send in
                        // Hidden set must load BEFORE the area/database
                        // fetch result reaches the UI, otherwise the
                        // sidebar/palette flash protected items for one
                        // tick. Computing it first keeps that gap shut.
                        await send(.recomputeHiddenSet)
                        let areas = (try? dbClient.areas()) ?? []
                        let dbs   = (try? dbClient.databases()) ?? []
                        let vws   = (try? dbClient.views()) ?? []
                        let pal   = (try? dbClient.paletteItems([])) ?? []
                        let tags  = (try? dbClient.allTags(Seed.workspaceID)) ?? []
                        await send(.bootstrapLoaded(areas: areas, databases: dbs, views: vws, palette: pal))
                        await send(.allTagsLoaded(tags))
                        // If the user enabled app lock, kick the prompt
                        // now. The AppView overlay is already on screen.
                        if appLockEnabled {
                            await send(.unlockAppRequested)
                        }
                    },
                    .run { send in
                        // Kick off CloudKit sync if it's been configured.
                        try? await syncClient.start()
                        for await status in syncClient.observeStatus() {
                            await send(.syncStatusChanged(status))
                        }
                    },
                    .run { _ in
                        // Sync diagnostics observer — writes lifecycle
                        // and item-loss events into `sync_events` for
                        // the Settings → Sync Diagnostics panel and
                        // `--cli sync-diagnose`. No-op when CloudKit
                        // isn't configured (observeStatus yields one
                        // .local and ends).
                        await AppSyncEngineDelegate.run()
                    },
                    .run { _ in
                        // Diagnostic: periodic census so we can see in the
                        // log whether records vanish after boot (e.g. due
                        // to SyncEngine pulling tombstones from CloudKit
                        // or iCloud Drive replacing the SQLite file).
                        // Snapshots at 0/5/15/30/60s, then every 5min.
                        let snapshots: [UInt64] = [
                            0, 5, 15, 30, 60, 300, 600, 1200,
                        ]
                        let url = AppDatabase.databaseFolder
                            .appendingPathComponent("workspace.sqlite")
                        for delay in snapshots {
                            if delay > 0 {
                                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                            }
                            @Dependency(\.defaultDatabase) var database
                            try? await database.read { db in
                                logDBCensus(db, label: "runtime+\(delay)s")
                            }
                            logFileState(at: url, label: "runtime+\(delay)s")
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
                            // An Inbox import may have auto-created
                            // records that registered providers can
                            // enrich (vendor stubs from `vendor: <name>`
                            // frontmatter; books from `type: books`
                            // markdown; etc.). Run a pass across every
                            // available provider so they don't have to
                            // wait until next launch.
                            await EnrichmentService.shared.enrichPending()
                            // Propagate the newly-written property
                            // values into whatever view the user is
                            // currently on — without this, an inbox
                            // import that just enriched a vendor only
                            // becomes visible at the next launch.
                            await send(.refreshSidebar)
                            await send(.refreshCurrentRecords)
                            await send(.refreshCurrentRecord)
                        }
                    },
                    .run { send in
                        // Initial enrichment pass on launch — catches
                        // records that arrived via CloudKit, were
                        // created while the app was offline, or were
                        // left ambiguous on a previous run that the
                        // user has since resolved manually. Each
                        // provider self-gates on availability (e.g.
                        // TMDB providers no-op without an API key).
                        //
                        // Run inside the reducer's effect (rather than
                        // `EnrichmentService.start()`'s detached task)
                        // so that on completion we can dispatch the
                        // refresh actions that propagate newly-written
                        // property values into the visible UI. Before
                        // this, freshly-enriched data only became
                        // visible after the user quit and re-opened
                        // the app.
                        try? await Task.sleep(for: .seconds(8))
                        await EnrichmentService.shared.enrichPending()
                        await send(.refreshSidebar)
                        await send(.refreshCurrentRecords)
                        await send(.refreshCurrentRecord)
                        // One-shot at-boot compaction of pre-existing
                        // cover assets to HEIC/800-px. Idempotent +
                        // guarded by a UserDefaults flag, so this is a
                        // no-op after the first successful run.
                        CoverCompactionPass.start()
                        // One-shot cleanup of garbage restaurant
                        // `hours` values left by the earlier
                        // enrichment passes (empty-array JSON-LD
                        // bug, parser bail-out passthroughs). Also
                        // UserDefaults-gated; runs once per device.
                        RestaurantHoursCleanupPass.start()
                    },
                    .run { _ in
                        // Watch <workspace>/Cars/ for external edits
                        // to sidecar `.md` files. SidecarWriter writes
                        // are recognized via the SidecarHashCache and
                        // ignored, so this only fires on real
                        // out-of-band edits (Finder, another device's
                        // iCloud sync, a text editor outside Keystone).
                        CarsWatcher.shared.start()
                    }
                )

            case let .bootstrapLoaded(areas, databases, views, palette):
                state.areas = areas
                state.databases = databases
                state.views = views
                state.paletteItems = palette
                return .none

            case let .setNav(nav):
                // Preserve the originating saved view across record nav
                // so the record detail can show the view's breadcrumb
                // (e.g. "Restaurants > Joe's Diner" instead of the
                // backing database's name). Only preserved when the
                // record actually belongs to the view's backing DB —
                // a cross-database relation hop drops the context.
                let preservedView: ViewRow? = {
                    guard case let .record(targetDB, _) = nav,
                          let v = state.currentView,
                          v.databaseID == targetDB else { return nil }
                    return v
                }()
                state.nav = nav
                state.sortKey = nil
                state.sortAscending = true
                state.groupKey = nil
                state.galleryCoverSize = .medium
                state.viewPrefsDatabaseID = nil
                state.filters = []
                state.pinnedFilters = []
                state.hiddenColumns = []
                state.currentView = preservedView
                switch nav {
                case .home, .help, .maintenanceSchedule:
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
                    let hidden = state.hiddenRecordIDs
                    return .run { send in
                        let db = try? dbClient.database(dbID)
                        let props = (try? dbClient.properties(dbID)) ?? []
                        let records = (try? dbClient.records(dbID, hidden)) ?? []
                        await send(.databaseLoaded(db: db, properties: props, records: records))
                        let prefs = (try? dbClient.loadViewPrefs(dbID)) ?? .default
                        await send(.viewPrefsLoaded(databaseID: dbID, prefs: prefs))
                    }
                case let .stats(dbID):
                    // Reuses the same loader as `.database` minus
                    // view-prefs persistence — stats reads the full
                    // record set and doesn't carry filter chips.
                    state.currentRecord = nil
                    state.currentRecordRelated = []
                    state.currentBlocks = []
                    let hidden = state.hiddenRecordIDs
                    return .run { send in
                        let db = try? dbClient.database(dbID)
                        let props = (try? dbClient.properties(dbID)) ?? []
                        let records = (try? dbClient.records(dbID, hidden)) ?? []
                        await send(.databaseLoaded(db: db, properties: props, records: records))
                    }
                case let .view(viewID):
                    state.currentRecord = nil
                    state.currentRecordRelated = []
                    state.currentBlocks = []
                    guard let view = state.views.first(where: { $0.id == viewID }) else {
                        // Unknown view id (stale sidebar tap after a sync
                        // collision deleted the row). Land on home rather
                        // than a blank database screen.
                        state.currentDB = nil
                        state.currentProperties = []
                        state.currentRecords = []
                        return .send(.setNav(.home))
                    }
                    state.currentView = view
                    // Materialize the view's pinned filters. Property
                    // lookups happen after the properties load, so the
                    // pinned filter is built with placeholder type info
                    // — `selectIsAnyOf` works for any select-typed
                    // column (kind is select) and the engine reads the
                    // string value directly without re-checking type.
                    state.pinnedFilters = view.queryFilters.map { (key, values) in
                        Filter(propertyKey: key, predicate: .selectIsAnyOf(values))
                    }
                    let backing = view.databaseID
                    let prefsKey = viewID                 // saved-view keyed prefs
                    let hidden = state.hiddenRecordIDs
                    return .run { send in
                        let db = try? dbClient.database(backing)
                        let props = (try? dbClient.properties(backing)) ?? []
                        let records = (try? dbClient.records(backing, hidden)) ?? []
                        await send(.databaseLoaded(db: db, properties: props, records: records))
                        let prefs = (try? dbClient.loadViewPrefs(prefsKey)) ?? .default
                        await send(.viewPrefsLoaded(databaseID: prefsKey, prefs: prefs))
                    }
                case let .record(databaseID, recordID):
                    state.currentBlocks = []
                    state.currentRecordTags = []
                    state.currentOutgoingRelations = []
                    state.currentIncomingRelations = []
                    state.currentRecordAssets = []
                    let hidden = state.hiddenRecordIDs
                    return .run { send in
                        let rec = try? dbClient.record(recordID)
                        let related = (try? dbClient.relatedRecords(recordID, hidden)) ?? []
                        let blocks = (try? dbClient.blocks(recordID)) ?? []
                        let tags = (try? dbClient.tagsForRecord(recordID)) ?? []
                        let outgoing = (try? dbClient.outgoingRelations(recordID, hidden)) ?? []
                        let incoming = (try? dbClient.incomingRelations(recordID, hidden)) ?? []
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
                    let hidden = state.hiddenRecordIDs
                    return .run { send in
                        let tag = knownTag ?? (try? dbClient.allTags(Seed.workspaceID))?.first(where: { $0.id == tagID })
                        let pairs = (try? dbClient.recordsForTag(tagID, hidden)) ?? []
                        let mapped = pairs.map { TaggedRecord(record: $0.record, databaseName: $0.dbName) }
                        await send(.tagFilterLoaded(tag: tag, records: mapped))
                    }
                }

            case let .databaseLoaded(db, props, records):
                state.currentDB = db
                state.currentProperties = props
                state.currentRecords = records
                if let db {
                    // Calendar requires a date / date_tz property to plot
                    // against. Fall back to table when the database
                    // doesn't have one — avoids landing on a "View not
                    // available" screen.
                    let hasDateProp = props.contains { $0.type == .date || $0.type == .dateTZ }
                    if db.defaultView == .calendar && !hasDateProp {
                        state.viewKind = .table
                    } else {
                        state.viewKind = db.defaultView
                    }
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

            case let .navigateAndPresetTagFilter(dbID, propertyKey, value):
                // Reset every nav-touching slot the way `.setNav` does
                // — except we DON'T blank `filters`; we preset them.
                state.nav = .database(dbID)
                state.sortKey = nil
                state.sortAscending = true
                state.groupKey = nil
                state.galleryCoverSize = .medium
                state.viewPrefsDatabaseID = nil
                state.pinnedFilters = []
                state.currentView = nil
                state.currentRecord = nil
                state.currentRecordRelated = []
                state.currentBlocks = []
                state.filters = [Filter(
                    propertyKey: propertyKey,
                    predicate: .selectIsAnyOf([value])
                )]
                let hidden = state.hiddenRecordIDs
                return .run { send in
                    let db = try? dbClient.database(dbID)
                    let props = (try? dbClient.properties(dbID)) ?? []
                    let records = (try? dbClient.records(dbID, hidden)) ?? []
                    await send(.databaseLoaded(db: db, properties: props, records: records))
                    // Deliberately NOT loading view prefs — they
                    // would overwrite our preset filter.
                }

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
                return persistViewPrefsEffect(from: state)

            case let .setGroupKey(key):
                state.groupKey = key
                return persistViewPrefsEffect(from: state)

            case let .setGalleryCoverSize(size):
                state.galleryCoverSize = size
                return persistViewPrefsEffect(from: state)

            case let .setColumnHidden(key, hidden):
                if hidden {
                    state.hiddenColumns.insert(key)
                } else {
                    state.hiddenColumns.remove(key)
                }
                return persistViewPrefsEffect(from: state)

            case let .viewPrefsLoaded(databaseID, prefs):
                // A stale `viewPrefsLoaded` can arrive after the user has
                // navigated away — apply only when it matches the route
                // we'd next want to persist *back* to.
                let expectedID = viewPrefsKey(for: state)
                guard expectedID == databaseID else { return .none }
                state.sortKey = prefs.sortKey
                state.sortAscending = prefs.sortAscending
                state.groupKey = prefs.groupKey
                state.galleryCoverSize = prefs.galleryCoverSize
                state.filters = prefs.filters
                state.hiddenColumns = prefs.hiddenColumns
                state.viewPrefsDatabaseID = databaseID
                return .none

            case let .setColumnAlignment(propertyID, alignment):
                // Optimistic local update so the column re-aligns
                // immediately, then persist via the property writer.
                if let idx = state.currentProperties.firstIndex(where: { $0.id == propertyID }) {
                    var newConfig = state.currentProperties[idx].config
                    newConfig.alignment = alignment
                    let newJSON = newConfig.encoded()
                    state.currentProperties[idx] = PropertyRow(
                        id: state.currentProperties[idx].id,
                        key: state.currentProperties[idx].key,
                        name: state.currentProperties[idx].name,
                        type: state.currentProperties[idx].type,
                        sortIndex: state.currentProperties[idx].sortIndex,
                        configJSON: newJSON
                    )
                }
                return .run { _ in
                    try? dbClient.setPropertyAlignment(propertyID, alignment)
                }

            case let .addPropertyOption(propertyID, option):
                let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return .none }
                // Optimistic local update: append to the in-memory
                // PropertyRow so the menu that triggered the add
                // immediately reflects the new option, then persist.
                if let idx = state.currentProperties.firstIndex(where: { $0.id == propertyID }) {
                    var newConfig = state.currentProperties[idx].config
                    var options = newConfig.options ?? []
                    if !options.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                        options.append(trimmed)
                        newConfig.options = options
                        let newJSON = newConfig.encoded()
                        state.currentProperties[idx] = PropertyRow(
                            id: state.currentProperties[idx].id,
                            key: state.currentProperties[idx].key,
                            name: state.currentProperties[idx].name,
                            type: state.currentProperties[idx].type,
                            sortIndex: state.currentProperties[idx].sortIndex,
                            configJSON: newJSON
                        )
                    }
                }
                return .run { _ in
                    try? dbClient.addPropertyOption(propertyID, trimmed)
                }

            case let .removePropertyOption(propertyID, option):
                let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return .none }
                // Optimistic local update: drop the option from the
                // in-memory PropertyRow so the popover hides it
                // immediately. The records list refresh below picks
                // up the stripped values on the DB side.
                if let idx = state.currentProperties.firstIndex(where: { $0.id == propertyID }) {
                    var newConfig = state.currentProperties[idx].config
                    var options = newConfig.options ?? []
                    options.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
                    newConfig.options = options
                    let newJSON = newConfig.encoded()
                    state.currentProperties[idx] = PropertyRow(
                        id: state.currentProperties[idx].id,
                        key: state.currentProperties[idx].key,
                        name: state.currentProperties[idx].name,
                        type: state.currentProperties[idx].type,
                        sortIndex: state.currentProperties[idx].sortIndex,
                        configJSON: newJSON
                    )
                }
                return .run { send in
                    try? dbClient.removePropertyOption(propertyID, trimmed)
                    // Refresh records so the value disappears from
                    // chip strips and select capsules in the table.
                    await send(.refreshCurrentRecords)
                    await send(.refreshCurrentRecord)
                }

            case let .addFilter(propertyKey):
                guard let prop = state.currentProperties.first(where: { $0.key == propertyKey })
                else { return .none }
                // Don't double-add — if a filter already exists for this
                // column, reuse it (and let the user edit it). Keeps the
                // bar tidy and avoids duplicate-AND chains.
                if state.filters.contains(where: { $0.propertyKey == propertyKey }) {
                    return .none
                }
                let predicate = FilterPredicateFactory.empty(for: prop)
                state.filters.append(Filter(propertyKey: propertyKey, predicate: predicate))
                return persistViewPrefsEffect(from: state)

            case let .updateFilter(id, predicate):
                if let idx = state.filters.firstIndex(where: { $0.id == id }) {
                    state.filters[idx].predicate = predicate
                }
                return persistViewPrefsEffect(from: state)

            case let .removeFilter(id):
                state.filters.removeAll { $0.id == id }
                return persistViewPrefsEffect(from: state)

            case .clearFilters:
                state.filters = []
                return persistViewPrefsEffect(from: state)

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
                case .view:
                    if let viewID = item.dbID {
                        return .send(.setNav(.view(viewID)))
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

            case let .createBlankRecord(databaseID, presets):
                let title = "Untitled"
                return .run { send in
                    guard let rec = try? dbClient.createRecord(databaseID, title) else { return }
                    // Apply any view-pinned defaults (e.g. kind="restaurant"
                    // when "Create blank" was clicked from the Restaurants
                    // lookup sheet) so the new record lands where the user
                    // expects it. Best-effort: a write failure on a single
                    // preset doesn't block the navigation.
                    for (key, value) in presets where !value.isEmpty {
                        _ = try? dbClient.updatePropertyValue(rec.id, key, value)
                    }
                    await send(.recordCreated(record: rec, openDetail: true))
                }

            case let .logServiceForVehicle(vehicleID):
                return .run { send in
                    guard let rec = try? dbClient.createRecord("vehicle_maintenance", "Untitled") else { return }
                    // Wire the vehicle relation immediately so the
                    // user lands on a record that already knows which
                    // car it's for. Best-effort: failure here doesn't
                    // block the navigation.
                    _ = try? dbClient.addRelation(rec.id, vehicleID, "vehicle_maintenance.vehicle")
                    await send(.recordCreated(record: rec, openDetail: true))
                }

            case let .openLookup(databaseID, databaseName):
                // Fall through to blank-create if there's no provider
                // registered, or the provider isn't available right now
                // (e.g. TMDB key not set). The button is the same shape
                // either way, so the user doesn't need to learn two paths.
                //
                // When the active route is a view (Nav.view), the view
                // can override which lookup provider serves "+ New" —
                // e.g. Restaurants view picks the food-only MapKit
                // variant even though records still land in the
                // Vendors database. Resolve the effective backing
                // database here so the create call always targets a
                // real database id.
                let backingDatabaseID = state.currentView?.databaseID ?? databaseID
                let providerKey = state.currentView?.lookupProviderKey ?? backingDatabaseID
                let pinnedKind = state.currentView?.pinnedKind
                return .run { send in
                    let available = await LookupRegistry.hasAvailableProvider(for: providerKey)
                    if available {
                        await send(.presentLookupSheet(state: LookupSheetState(
                            databaseID: backingDatabaseID,
                            databaseName: databaseName,
                            lookupProviderKey: providerKey,
                            presetKind: pinnedKind
                        )))
                    } else {
                        let presets: [String: String] = pinnedKind.map { ["kind": $0] } ?? [:]
                        await send(.createBlankRecord(databaseID: backingDatabaseID, presets: presets))
                    }
                }

            case let .openReenrichLookup(databaseID, databaseName, recordID, currentTitle):
                // Right-click "Re-enrich…" path. Open the same sheet
                // pre-populated with the record's current title; on pick,
                // the existing record is updated instead of a new one
                // being created. Silently no-ops if no provider is wired
                // up for this database.
                //
                // Honor the active view's `lookupProviderKey` when set
                // (e.g. Restaurants view pins `"restaurant"` so the
                // re-enrich sheet shows only food/drink POIs instead of
                // every Vendor candidate in the area).
                let providerKey = state.currentView?.lookupProviderKey ?? databaseID
                return .run { send in
                    let available = await LookupRegistry.hasAvailableProvider(for: providerKey)
                    guard available else { return }
                    await send(.presentLookupSheet(state: LookupSheetState(
                        databaseID: databaseID,
                        databaseName: databaseName,
                        lookupProviderKey: providerKey,
                        existingRecordID: recordID,
                        initialQuery: currentTitle
                    )))
                }

            case let .presentLookupSheet(sheetState):
                state.lookupSheet = sheetState
                return .none

            case .closeLookup:
                state.lookupSheet = nil
                return .none

            case let .openCoverPicker(databaseID, recordID, currentTitle):
                let initialQuery = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                state.coverPickerSheet = CoverPickerSheetState(
                    databaseID: databaseID,
                    recordID: recordID,
                    recordTitle: currentTitle,
                    query: initialQuery,
                    loading: true,
                    candidates: []
                )
                // Capture the author hint up-front so the search task
                // doesn't have to round-trip through the database.
                let hints = coverSearchHints(for: recordID, in: state)
                return .run { send in
                    let result = await CoverProviderRegistry.searchAll(
                        databaseKey: databaseID,
                        query: initialQuery,
                        hints: hints
                    )
                    await send(.coverPickerCandidatesLoaded(
                        query: initialQuery, result: result
                    ))
                }

            case let .coverPickerQueryChanged(query):
                state.coverPickerSheet?.query = query
                return .none

            case .coverPickerSearchRequested:
                guard let sheet = state.coverPickerSheet else { return .none }
                let query = sheet.query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else { return .none }
                state.coverPickerSheet?.loading = true
                state.coverPickerSheet?.candidates = []
                state.coverPickerSheet?.sources = []
                let dbID = sheet.databaseID
                let hints = coverSearchHints(for: sheet.recordID, in: state)
                return .run { send in
                    let result = await CoverProviderRegistry.searchAll(
                        databaseKey: dbID,
                        query: query,
                        hints: hints
                    )
                    await send(.coverPickerCandidatesLoaded(
                        query: query, result: result
                    ))
                }

            case let .coverPickerCandidatesLoaded(query, result):
                // Drop late replies for an outdated query — the user
                // may have already re-searched. The query field on the
                // sheet is the source of truth.
                guard let sheet = state.coverPickerSheet,
                      sheet.query.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
                    return .none
                }
                state.coverPickerSheet?.loading = false
                state.coverPickerSheet?.candidates = result.candidates
                state.coverPickerSheet?.sources = result.sources
                return .none

            case let .coverPickerCandidatePicked(candidate):
                guard let sheet = state.coverPickerSheet else { return .none }
                state.coverPickerSheet?.applying = true
                let recordID = sheet.recordID
                let url = candidate.coverURL
                return .run { send in
                    await CoverImageImporter.attachAsCover(url, to: recordID)
                    await send(.coverPickerCoverAttached)
                }

            case .coverPickerCoverAttached:
                state.coverPickerSheet = nil
                // The detail / list / gallery views read `cover_asset_id`
                // off the record row; the easiest way to refresh them
                // is the same refresh path the asset-import flow uses.
                return .send(.refreshCurrentRecords)

            case .closeCoverPicker:
                state.coverPickerSheet = nil
                return .none

            case let .lookupCandidatePicked(databaseID, candidate):
                state.lookupSheet = nil
                let openDetail = KeystoneSettings.openInDetailAfterAdd
                return .run { send in
                    guard let blank = try? dbClient.createRecord(databaseID, candidate.title) else { return }
                    // Apply the payload (property writes + cover download)
                    // BEFORE moving on so the freshly-written record is
                    // visible to whichever view loads next.
                    await EnrichmentService.shared.applyForLookup(
                        candidate.apply,
                        databaseID: databaseID,
                        recordID: blank.id,
                        title: candidate.title
                    )
                    await send(.refreshSidebar)
                    if openDetail {
                        // Going through `setNav(.record(...))` (rather
                        // than `recordCreated`, which stores the pre-
                        // apply RecordRow snapshot) is what guarantees
                        // the detail view loads the populated row.
                        await send(.setNav(.record(databaseID: databaseID, recordID: blank.id)))
                    } else {
                        // Default: stay on the gallery / list so the
                        // user can add another record without a back
                        // trip. Refresh the records grid so the new
                        // card appears with its cover + populated meta.
                        await send(.refreshCurrentRecords)
                    }
                    // Pick up second-pass enrichment (e.g. restaurants
                    // get a website scrape + OSM hours lookup after
                    // MapKit fills the basics) without waiting for the
                    // next launch. Refresh again once it finishes so
                    // the newly-written values land in the visible UI.
                    await EnrichmentService.shared.enrichPending()
                    await send(.refreshSidebar)
                    await send(.refreshCurrentRecords)
                    await send(.refreshCurrentRecord)
                }

            case let .lookupCandidatePickedForExisting(databaseID, recordID, candidate):
                state.lookupSheet = nil
                state.enrichingRecordIDs.insert(recordID)
                let onRecordDetail = state.nav == .record(databaseID: databaseID, recordID: recordID)
                return .run { send in
                    // Update the record's title to match the picked
                    // candidate so e.g. a wrong-edition match becomes
                    // the user's stored title, not the bad guess.
                    try? dbClient.updateRecordTitle(recordID, candidate.title)
                    // Overwrite mode: the user is explicitly asking for
                    // fresh data; provider-owned columns get rewritten,
                    // but keys the provider doesn't return (notes,
                    // status, rating, started_date, …) are untouched.
                    await EnrichmentService.shared.applyForLookup(
                        candidate.apply,
                        databaseID: databaseID,
                        recordID: recordID,
                        title: candidate.title,
                        overwrite: true
                    )
                    // Clear source-only fields before re-running the
                    // providers. The provider pass writes fresh values
                    // when it has them, but it does NOT clear stale
                    // entries on its own — so without this step, an
                    // existing garbage `hours` string (e.g. the
                    // empty-array commas bug) would survive a
                    // Re-enrich because the new pass's sanitizer
                    // rejected the upstream value and never wrote
                    // anything to overwrite the old junk.
                    //
                    // `rating` and `price_range` are deliberately
                    // omitted — those are commonly hand-edited and a
                    // failed re-fetch shouldn't blow away user input.
                    for key in ["hours", "menu_url", "web_enriched_at"] {
                        try? dbClient.updatePropertyValue(recordID, key, "")
                    }
                    // Targeted re-run of every applicable provider
                    // against this specific record in overwrite mode.
                    // Bypasses the trigger-property gate (so e.g. the
                    // restaurant website provider doesn't skip just
                    // because `web_enriched_at` was already set) and
                    // the in-flight coalescing gate (so a launch-time
                    // pass in progress doesn't silently swallow this
                    // call).
                    await EnrichmentService.shared.enrichSingleRecord(
                        recordID: recordID,
                        databaseID: databaseID
                    )
                    await send(.refreshSidebar)
                    if onRecordDetail {
                        await send(.refreshCurrentRecord)
                    } else {
                        await send(.refreshCurrentRecords)
                    }
                    // Always clear the spinner last so the UI flips
                    // out of the "Enriching…" state only after every
                    // write + refresh has flushed.
                    await send(.enrichmentFinished(recordID: recordID))
                }

            case let .enrichmentFinished(recordID):
                state.enrichingRecordIDs.remove(recordID)
                return .none

            case .reenrichAllVisibleRecords:
                // Bulk variant of the lookup-pickedForExisting path.
                // Walks the currently-visible records one at a time,
                // pre-clearing source-only fields then running the
                // provider pass in overwrite mode. The spinner set
                // drains progressively so the toolbar can show
                // remaining-count progress.
                let backingDB = state.currentView?.databaseID ?? state.currentDB?.id
                guard let dbID = backingDB else { return .none }
                let recordIDs = state.filteredRecords.map(\.id)
                guard !recordIDs.isEmpty else { return .none }
                state.enrichingRecordIDs.formUnion(recordIDs)
                return .run { send in
                    for recordID in recordIDs {
                        for key in ["hours", "menu_url", "web_enriched_at"] {
                            try? dbClient.updatePropertyValue(recordID, key, "")
                        }
                        await EnrichmentService.shared.enrichSingleRecord(
                            recordID: recordID,
                            databaseID: dbID
                        )
                        await send(.enrichmentFinished(recordID: recordID))
                    }
                    // Final refresh once every record has been
                    // touched so the table view reflects the new
                    // property values in one shot.
                    await send(.refreshSidebar)
                    await send(.refreshCurrentRecords)
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
                // Auto-status nudge for books: when current_page first
                // crosses from 0 → >0 on a `to_read` book, advance to
                // `reading`. When current_page reaches readable_pages,
                // advance to `read` and stamp finished_date if blank.
                // Hidden behind a "is this actually a books record?"
                // check via the database id.
                let autoStatusEffect = BookStatusNudge.effectAfterUpdate(
                    state: state,
                    recordID: recordID,
                    changedKey: key,
                    newValue: value
                )
                // is_protected toggles change the cascade — recompute
                // the hidden set so the UI hides/reveals dependents in
                // the same tick. For relation properties, the write
                // path itself emits a relations row; recompute too so
                // newly-attached children fall under cascade
                // immediately when their parent is protected.
                let touchedProtection = (key == "is_protected")
                let touchedRelation = state.currentProperties
                    .first(where: { $0.key == key })?.type == .relation
                let recompute: Effect<Action> = (touchedProtection || touchedRelation)
                    ? .send(.recomputeHiddenSet)
                    : .none
                let valueLowered = value.lowercased()
                let toggledOn = touchedProtection
                    && (valueLowered == "true" || valueLowered == "1" || valueLowered == "yes")
                let toggledOff = touchedProtection && !toggledOn
                return .merge(
                    autoStatusEffect,
                    .run { _ in
                        try? dbClient.updatePropertyValue(recordID, key, value)
                        // After the plaintext write lands, decide whether
                        // we owe an encryption pass:
                        //   • toggledOn → run the bulk encryptor over
                        //     the toggled record AND every cascade
                        //     dependent (children, grandchildren, …)
                        //     so an Activity referencing a freshly-
                        //     protected Trip gets encrypted in the
                        //     same tick.
                        //   • toggledOff → decrypt back to plaintext,
                        //     same cascade.
                        //   • otherwise: re-encrypt this row only,
                        //     so a normal edit to a protected record
                        //     re-tightens its storage.
                        if toggledOn {
                            let cascade = (try? dbClient.cascadeFromSeed(recordID)) ?? Set([recordID])
                            for r in cascade { try? dbClient.encryptRecord(r) }
                        } else if toggledOff {
                            let cascade = (try? dbClient.cascadeFromSeed(recordID)) ?? Set([recordID])
                            for r in cascade { try? dbClient.decryptRecord(r) }
                        } else if (try? dbClient.recordIsEncrypted(recordID)) == true {
                            try? dbClient.encryptRecord(recordID)
                        }
                    },
                    recompute
                )

            case let .changeRecordDatabase(recordID, newDatabaseID):
                guard state.currentRecord?.id == recordID,
                      state.currentRecord?.databaseID != newDatabaseID else { return .none }
                return .run { send in
                    try? dbClient.changeRecordDatabase(recordID, newDatabaseID)
                    await send(.refreshSidebar)
                    await send(.setNav(.record(databaseID: newDatabaseID, recordID: recordID)))
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

            case let .deleteAllRecordsInDatabase(databaseID):
                // Optimistically clear the in-memory record list when
                // we're currently viewing the database the user is
                // wiping. The DB write happens async; the next
                // refreshCurrentRecords reconciles state.
                if case .database(let viewing) = state.nav, viewing == databaseID {
                    state.currentRecords = []
                }
                return .run { send in
                    _ = try? dbClient.deleteAllRecordsInDatabase(databaseID)
                    await send(.refreshSidebar)
                    await send(.refreshCurrentRecords)
                }

            case .refreshSidebar:
                let hidden = state.hiddenRecordIDs
                return .run { send in
                    let dbs = (try? dbClient.databases()) ?? []
                    let vws = (try? dbClient.views()) ?? []
                    let pal = (try? dbClient.paletteItems(hidden)) ?? []
                    await send(.sidebarRefreshed(databases: dbs, views: vws, palette: pal))
                }

            case let .sidebarRefreshed(databases, views, palette):
                state.databases = databases
                state.views = views
                state.paletteItems = palette
                return .none

            case .refreshCurrentRecord:
                // Reload the record-detail slot without changing nav.
                // Mirrors the per-record loader in `.setNav(.record)`
                // so a background write (e.g. enrichment) propagates
                // into the visible detail view immediately.
                if case let .record(databaseID, recordID) = state.nav {
                    let hidden = state.hiddenRecordIDs
                    return .run { send in
                        let rec = try? dbClient.record(recordID)
                        let related = (try? dbClient.relatedRecords(recordID, hidden)) ?? []
                        let blocks = (try? dbClient.blocks(recordID)) ?? []
                        let tags = (try? dbClient.tagsForRecord(recordID)) ?? []
                        let outgoing = (try? dbClient.outgoingRelations(recordID, hidden)) ?? []
                        let incoming = (try? dbClient.incomingRelations(recordID, hidden)) ?? []
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
                }
                return .none

            case .refreshCurrentRecords:
                if case let .database(dbID) = state.nav {
                    let hidden = state.hiddenRecordIDs
                    return .run { send in
                        let recs = (try? dbClient.records(dbID, hidden)) ?? []
                        let db = try? dbClient.database(dbID)
                        let props = (try? dbClient.properties(dbID)) ?? []
                        await send(.databaseLoaded(db: db, properties: props, records: recs))
                    }
                }
                if case let .view(viewID) = state.nav,
                   let view = state.views.first(where: { $0.id == viewID }) {
                    let backing = view.databaseID
                    let hidden = state.hiddenRecordIDs
                    return .run { send in
                        let recs = (try? dbClient.records(backing, hidden)) ?? []
                        let db = try? dbClient.database(backing)
                        let props = (try? dbClient.properties(backing)) ?? []
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

            case let .blockTableEdited(blockID, table):
                // Optimistic update of the loaded record's blocks so the
                // UI reflects the cell/row/column edit immediately, then
                // persist to disk in a background effect. Mirrors the
                // pattern used for text/checked edits.
                if let idx = state.currentBlocks.firstIndex(where: { $0.id == blockID }) {
                    state.currentBlocks[idx].tableData = table
                }
                return .run { _ in
                    try? dbClient.updateBlockTable(blockID, table)
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
                let hidden = state.hiddenRecordIDs
                return .merge(
                    .send(.recomputeHiddenSet),
                    .run { send in
                        _ = try? dbClient.addRelation(sourceID, targetRecordID, propertyID)
                        let outgoing = (try? dbClient.outgoingRelations(sourceID, hidden)) ?? []
                        let incoming = (try? dbClient.incomingRelations(sourceID, hidden)) ?? []
                        await send(.relationsLoaded(outgoing: outgoing, incoming: incoming))
                    }
                )

            case let .removeRelation(relationID):
                guard let sourceID = state.currentRecord?.id else { return .none }
                state.currentOutgoingRelations.removeAll { $0.id == relationID }
                let hidden = state.hiddenRecordIDs
                return .merge(
                    .send(.recomputeHiddenSet),
                    .run { send in
                        try? dbClient.removeRelation(relationID)
                        let outgoing = (try? dbClient.outgoingRelations(sourceID, hidden)) ?? []
                        let incoming = (try? dbClient.incomingRelations(sourceID, hidden)) ?? []
                        await send(.relationsLoaded(outgoing: outgoing, incoming: incoming))
                    }
                )

            case let .syncStatusChanged(status):
                let prior = state.syncStatus
                state.syncStatus = status
                // When sync finishes a fetch/push cycle, the local DB may
                // have new rows that didn't exist at boot — refresh the
                // sidebar counts and the currently-visible record list so
                // the UI matches reality without forcing a relaunch.
                if case .synced = status, !isAlreadySynced(prior) {
                    return .merge(
                        .send(.refreshSidebar),
                        .send(.refreshCurrentRecords)
                    )
                }
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
                return .run { _ in
                    // Encrypted assets resolve through the dependency
                    // so the on-disk ciphertext doesn't leak to a
                    // viewer that expects original bytes; plaintext
                    // assets short-circuit to their actual URL with
                    // no copy.
                    let resolved = (try? dbClient.assetDecryptedURL(assetID)) ?? asset.absoluteURL
                    await MainActor.run {
                        #if canImport(AppKit)
                        _ = NSWorkspace.shared.open(resolved)
                        #elseif canImport(UIKit)
                        UIApplication.shared.open(resolved)
                        #endif
                    }
                }

            case let .quickLookAsset(assetID):
                // macOS-only: pop a Quick Look floating panel beside the
                // app so the user can reference the file while editing.
                // iOS doesn't have an equivalent floating preview, so
                // fall back to the regular open path.
                guard let asset = state.currentRecordAssets.first(where: { $0.id == assetID }) else { return .none }
                return .run { _ in
                    let resolved = (try? dbClient.assetDecryptedURL(assetID)) ?? asset.absoluteURL
                    await MainActor.run {
                        #if canImport(AppKit)
                        QuickLookManager.shared.present(urls: [resolved])
                        #elseif canImport(UIKit)
                        UIApplication.shared.open(resolved)
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
                let hidden = state.hiddenRecordIDs
                return .merge(
                    .send(.refreshCurrentRecords),
                    .run { send in
                        let rec = try? dbClient.record(recordID)
                        let related = (try? dbClient.relatedRecords(recordID, hidden)) ?? []
                        await send(.recordLoaded(record: rec, related: related))
                        let assets = (try? dbClient.assetsForRecord(recordID)) ?? []
                        await send(.assetsLoaded(assets))
                    }
                )

            // MARK: - Privacy lock

            case .recomputeHiddenSet:
                let unlocked = state.unlockedRecordIDs
                let active = KeystoneSettings.protectionFilteringActive
                return .run { send in
                    let hidden = (try? dbClient.protectedHiddenIDs(unlocked, active)) ?? []
                    let seeds = (try? dbClient.allProtectedSeedIDs()) ?? []
                    await send(.hiddenSetLoaded(hidden: hidden, seeds: seeds))
                }

            case let .hiddenSetLoaded(hidden, seeds):
                let oldHidden = state.hiddenRecordIDs
                state.hiddenRecordIDs = hidden
                state.protectedSeedIDs = seeds
                // Drop any in-memory record snapshot that just became
                // hidden — otherwise the detail view keeps showing it
                // until the user navigates away.
                state.currentRecords.removeAll { hidden.contains($0.id) }
                state.currentRecordRelated.removeAll { hidden.contains($0.id) }
                state.currentOutgoingRelations.removeAll { hidden.contains($0.targetRecordID) }
                state.currentIncomingRelations.removeAll { hidden.contains($0.sourceRecordID) }
                if let curr = state.currentRecord, hidden.contains(curr.id) {
                    state.currentRecord = nil
                }
                // If the hidden set actually changed and we're sitting
                // on a database, refresh that view so newly-revealed
                // records reappear (or newly-hidden ones drop out).
                if oldHidden != hidden, case .database = state.nav {
                    return .send(.refreshCurrentRecords)
                }
                return .none

            case .unlockAppRequested:
                guard !state.authInFlight else { return .none }
                state.authInFlight = true
                return .run { send in
                    let ok = await authClient.authenticate("Unlock Keystone")
                    await send(.authCompleted(scope: .appLaunch, success: ok))
                }

            case .lockAppRequested:
                state.unlockedRecordIDs = []
                state.appLockUnlocked = !KeystoneSettings.appLockEnabled
                return .send(.recomputeHiddenSet)

            case let .unlockRecordRequested(recordID):
                guard !state.authInFlight else { return .none }
                state.authInFlight = true
                return .run { send in
                    let ok = await authClient.authenticate("Unlock this record")
                    await send(.authCompleted(scope: .singleRecord(id: recordID), success: ok))
                }

            case .unlockAllProtectedRequested:
                guard !state.authInFlight else { return .none }
                state.authInFlight = true
                return .run { send in
                    let ok = await authClient.authenticate("Show all protected records")
                    await send(.authCompleted(scope: .allProtected, success: ok))
                }

            case let .authCompleted(scope, success):
                state.authInFlight = false
                guard success else { return .none }
                switch scope {
                case .appLaunch:
                    state.appLockUnlocked = true
                    return .none
                case let .singleRecord(id):
                    state.unlockedRecordIDs.insert(id)
                    return .send(.recomputeHiddenSet)
                case .allProtected:
                    state.unlockedRecordIDs.formUnion(state.protectedSeedIDs)
                    return .send(.recomputeHiddenSet)
                }

            case let .shareRecordRequested(recordID):
                guard state.sharePreparingRecordID == nil else { return .none }
                state.sharePreparingRecordID = recordID
                state.shareErrorMessage = nil
                return .run { [syncClient] send in
                    do {
                        let shared = try await syncClient.shareRecord(recordID)
                        await send(.shareRecordReady(recordID: recordID, sharedRecord: shared))
                    } catch {
                        await send(.shareRecordFailed(message: error.localizedDescription))
                    }
                }

            case let .shareRecordReady(recordID, sharedRecord):
                state.sharePreparingRecordID = nil
                state.sharePresentingSharedRecord = SharedRecordWrapper(
                    recordID: recordID,
                    sharedRecord: sharedRecord
                )
                return .none

            case let .shareRecordFailed(message):
                state.sharePreparingRecordID = nil
                state.shareErrorMessage = message
                return .none

            case .shareSheetDismissed:
                state.sharePresentingSharedRecord = nil
                return .none

            case .shareErrorDismissed:
                state.shareErrorMessage = nil
                return .none

            case let .shareAccepted(metadata):
                return .run { [syncClient] send in
                    do {
                        try await syncClient.acceptShare(metadata)
                        await send(.shareAcceptCompleted(success: true))
                    } catch {
                        await send(.shareAcceptCompleted(success: false))
                    }
                }

            case .shareAcceptCompleted:
                // No state mutation — the SyncEngine starts pulling
                // the shared record asynchronously and the existing
                // sync-status observation surfaces it. Logged via the
                // CloudKit subsystem.
                return .none
            }
        }
    }

    /// Pull hints out of the active record for the cover-search query.
    /// Right now this is just the `author` property (books) so the
    /// Google Books / Open Library queries can scope to the right
    /// author. Movies / TV don't have a structured hint analog.
    private func coverSearchHints(for recordID: String, in state: State) -> [String: String] {
        let record: RecordRow? = {
            if state.currentRecord?.id == recordID { return state.currentRecord }
            return state.currentRecords.first { $0.id == recordID }
        }()
        guard let record else { return [:] }
        var hints: [String: String] = [:]
        if let author = record.values["author"], !author.isEmpty {
            hints["author"] = author
        }
        return hints
    }

    /// Stable id used to persist the currently-active database's view
    /// ergonomics. Saved views (Restaurants) and plain databases each
    /// get their own slot — switching between the Restaurants view and
    /// the underlying Vendors page keeps their respective sorts /
    /// filters / cover sizes distinct.
    private func viewPrefsKey(for state: State) -> String? {
        switch state.nav {
        case let .view(viewID):       return viewID
        case let .database(dbID):     return dbID
        case let .record(dbID, _):    return dbID
        default:                       return nil
        }
    }

    /// Fire-and-forget write of the current view prefs back to
    /// `database_view_prefs`. Skips when no database is active *and*
    /// when the loaded-from-disk id doesn't match the current route
    /// (e.g. the user navigated mid-debounce; the load effect hasn't
    /// landed yet). The "loaded matches current" guard prevents the
    /// default-init state from clobbering a freshly-opened database's
    /// stored prefs before the load reply has arrived.
    private func persistViewPrefsEffect(from state: State) -> Effect<Action> {
        guard let key = viewPrefsKey(for: state),
              state.viewPrefsDatabaseID == key else { return .none }
        let prefs = DatabaseViewPrefs(
            sortKey: state.sortKey,
            sortAscending: state.sortAscending,
            groupKey: state.groupKey,
            galleryCoverSize: state.galleryCoverSize,
            filters: state.filters,
            hiddenColumns: state.hiddenColumns
        )
        return .run { _ in
            @Dependency(\.databaseClient) var dbClient
            try? dbClient.saveViewPrefs(key, prefs)
        }
    }
}
