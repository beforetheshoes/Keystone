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
                    existingRecordID: lookup.existingRecordID,
                    initialQuery: lookup.initialQuery
                )
                .transition(.opacity)
                .zIndex(3)
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
        case let .record(_, recordID):
            if let rec = store.currentRecord, rec.id == recordID, let db = store.currentDB {
                RecordDetailView(store: store, db: db, record: rec)
            } else {
                Color(KstColor.paper0)
            }
        case .tag:
            TagFilterView(store: store)
        case let .help(topic):
            HelpView(store: store, topicID: topic)
        }
    }
}
#endif

#if canImport(AppKit)
import AppKit

private struct WindowAccessory: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { configure(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
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
