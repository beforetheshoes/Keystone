import SwiftUI
import ComposableArchitecture

struct AppView: View {
    @Bindable var store: StoreOf<AppFeature>

    var body: some View {
        ZStack {
            #if os(macOS)
            macLayout
            #else
            IOSShell(store: store)
            #endif

            if store.paletteOpen {
                CommandPaletteView(store: store)
                    .transition(.opacity)
                    .zIndex(1)
            }
            if store.captureOpen {
                QuickCaptureView(store: store)
                    .transition(.opacity)
                    .zIndex(2)
            }
            if let lookup = store.lookupSheet {
                RecordLookupSheet(
                    store: store,
                    databaseID: lookup.databaseID,
                    databaseName: lookup.databaseName,
                    lookupProviderKey: lookup.lookupProviderKey,
                    presetKind: lookup.presetKind,
                    existingRecordID: lookup.existingRecordID,
                    initialQuery: lookup.initialQuery
                )
                .transition(.opacity)
                .zIndex(3)
            }
            if let coverSheet = store.coverPickerSheet {
                CoverPickerSheet(store: store, state: coverSheet)
                    .transition(.opacity)
                    .zIndex(3)
            }
            // App-launch privacy lock. Sits above every other overlay so
            // a deep link / palette pre-fetch can never sneak protected
            // content under the prompt. The view itself blocks pass-
            // through clicks/keystrokes.
            if !store.appLockUnlocked {
                AppLockView(store: store)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .task { await store.send(.task).finish() }
        #if os(macOS)
        .background(WindowAccessory().allowsHitTesting(false))
        #endif
    }

    #if os(macOS)
    private var macLayout: some View {
        HStack(spacing: 0) {
            SidebarView(store: store)
            MacMainPane(store: store)
        }
        .background(KstColor.paper0)
        .ignoresSafeArea()
    }
    #endif
}

#if os(macOS)
private struct MacMainPane: View {
    @Bindable var store: StoreOf<AppFeature>

    var body: some View {
        switch store.nav {
        case .home:
            HomeView(store: store)
        case let .database(dbID):
            if let db = store.currentDB, db.id == dbID {
                DatabaseDetailView(store: store, db: db)
            } else {
                Color(KstColor.paper0)
            }
        case let .view(viewID):
            if let view = store.views.first(where: { $0.id == viewID }),
               let backing = store.currentDB,
               backing.id == view.databaseID {
                let header = DBRow(
                    id: view.id,
                    areaID: view.areaID,
                    name: view.name,
                    pluralName: view.pluralName,
                    icon: view.icon,
                    accent: view.accent,
                    defaultView: backing.defaultView,
                    sortIndex: view.sortIndex,
                    recordCount: store.derivedRecords.filteredSorted.count
                )
                DatabaseDetailView(store: store, db: header)
            } else {
                Color(KstColor.paper0)
            }
        case let .record(_, recordID):
            if store.hiddenRecordIDs.contains(recordID) {
                // Record exists but is currently hidden by the privacy
                // lock cascade. Inline placeholder offers a per-record
                // unlock prompt without leaking the title.
                RecordLockView(store: store, recordID: recordID, title: nil)
            } else if let rec = store.currentRecord, rec.id == recordID, let db = store.currentDB {
                RecordDetailView(store: store, db: db, record: rec)
            } else {
                Color(KstColor.paper0)
            }
        case .tag:
            TagFilterView(store: store)
        case let .help(topic):
            HelpView(store: store, topicID: topic)
        case .maintenanceSchedule:
            MaintenanceScheduleView(
                onOpenRecord: { databaseID, recordID in
                    store.send(.setNav(.record(databaseID: databaseID, recordID: recordID)))
                },
                onLogService: { vehicleID in
                    store.send(.logServiceForVehicle(vehicleID: vehicleID))
                }
            )
        case let .stats(dbID):
            if let db = store.currentDB, db.id == dbID {
                StatsDetailView(
                    store: store,
                    db: db,
                    properties: store.currentProperties,
                    records: store.currentRecords
                )
            } else {
                Color(KstColor.paper0)
            }
        }
    }
}
#endif

#if canImport(AppKit)
import AppKit

private struct WindowAccessory: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        // The NSView isn't attached to a window during makeNSView; we
        // must defer to the next runloop iteration for `v.window` to
        // resolve. `DispatchQueue.main.async` is the right tool for
        // runloop-precise deferral; `Task { @MainActor in }` schedules
        // on Swift's MainActor executor which may run within the
        // current frame and miss the window attachment.
        DispatchQueue.main.async { configure(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        // See `makeNSView` for the rationale on `DispatchQueue.main.async`
        // over Swift concurrency here.
        DispatchQueue.main.async { configure(nsView.window) }
    }
    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(KstColor.paper0)
        // System traffic lights (close / miniaturize / zoom) float at their
        // default positions in the top-left, sitting on top of the warm-paper
        // sidebar's reserved 38pt header row.
    }
}
#endif
