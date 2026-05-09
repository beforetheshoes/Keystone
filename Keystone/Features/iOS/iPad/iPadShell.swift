#if !os(macOS)
import SwiftUI
import ComposableArchitecture

/// iPad layout: NavigationSplitView with the existing macOS-style sidebar +
/// detail. Re-uses the cross-platform feature views (HomeView,
/// DatabaseDetailView, RecordDetailView, TagFilterView, HelpView) since
/// iPad has the screen real estate to support them.
struct iPadShell: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
                .toolbar(.hidden, for: .navigationBar)
        } detail: {
            NavigationStack {
                detailContent
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { store.send(.openPalette) } label: {
                                Image(systemName: "magnifyingglass")
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { store.send(.openCapture) } label: {
                                Image(systemName: "plus")
                            }
                        }
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(KstColor.paper0)
    }

    @ViewBuilder
    private var detailContent: some View {
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
        case .maintenanceSchedule:
            MaintenanceScheduleView(
                onOpenRecord: { databaseID, recordID in
                    store.send(.setNav(.record(databaseID: databaseID, recordID: recordID)))
                },
                onLogService: { vehicleID in
                    store.send(.logServiceForVehicle(vehicleID: vehicleID))
                }
            )
        }
    }
}
#endif
