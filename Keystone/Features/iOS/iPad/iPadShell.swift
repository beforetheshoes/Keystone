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
    /// iPad has no `Settings { … }` scene (that's a macOS-only menu
    /// hook), so Settings is presented as a sheet from a toolbar gear.
    /// Sheet over push to keep navigation state clean across tab/route
    /// changes — Settings is incidental to whatever you're looking at.
    @State private var settingsSheetOpen = false

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
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { settingsSheetOpen = true } label: {
                                Image(systemName: "gearshape")
                            }
                        }
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(KstColor.paper0)
        .sheet(isPresented: $settingsSheetOpen) {
            NavigationStack {
                SettingsView()
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { settingsSheetOpen = false }
                        }
                    }
            }
        }
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
        case let .view(viewID):
            // Saved view: render with the same detail UI as a database
            // route, but synthesize a header DBRow from the view so the
            // breadcrumb and accent match what the user tapped in the
            // sidebar (the underlying database is "Vendors" but the
            // page is titled "Restaurants").
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
                    recordCount: store.filteredRecords.count
                )
                DatabaseDetailView(store: store, db: header)
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
