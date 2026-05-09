import SwiftUI
import ComposableArchitecture

struct DatabaseDetailView: View {
    @Bindable var store: StoreOf<AppFeature>
    var db: DBRow

    @State private var deleteAllConfirming: Bool = false

    /// Show the Calendar item in the view switcher only when the
    /// database has a column the calendar can plot against.
    private var hasDateProperty: Bool {
        store.currentProperties.contains { $0.type == .date || $0.type == .dateTZ }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            KstToolbar(breadcrumb: [db.name]) {
                ViewSwitcher(
                    selected: store.viewKind,
                    showsCalendar: hasDateProperty
                ) { store.send(.setViewKind($0)) }
                KstButton(style: .primary, action: {
                    store.send(.openLookup(databaseID: db.id, databaseName: db.name))
                }) {
                    Text("+ New")
                }
                Menu {
                    Button("Delete all records…", role: .destructive) {
                        deleteAllConfirming = true
                    }
                    .disabled(store.currentRecords.isEmpty)
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

            // Subheader: title, count
            HStack(spacing: 10) {
                Glyph(tone: db.accent, text: db.icon, size: 26, radius: 7)
                Text(db.name)
                    .font(.kstDisplay(size: 26, weight: .semibold))
                    .foregroundStyle(KstColor.ink0)
                    .kerning(-0.4)
                if (store.viewKind == .table || store.viewKind == .calendar) && !store.filters.isEmpty {
                    Text("\(store.filteredRecords.count) of \(store.currentRecords.count)")
                        .font(.kstText(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(KstColor.ink2)
                } else {
                    Text("\(store.currentRecords.count)")
                        .font(.kstText(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(KstColor.ink2)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)
            .background(KstColor.paper0)
            .overlay(alignment: .bottom) { KstHairline() }

            // Filter bar appears for table and calendar views — both read
            // `filteredRecords` so a relation filter ("Trip = Tokyo 2026")
            // narrows what's plotted on the calendar. Gallery / list /
            // dashboard render `currentRecords` and would need separate
            // wiring to honor filters.
            if store.viewKind == .table || store.viewKind == .calendar {
                FilterBar(
                    store: store,
                    properties: store.currentProperties,
                    unfilteredRecords: store.currentRecords
                )
            }

            switch store.viewKind {
            case .table:    TableView(
                db: db,
                properties: store.currentProperties,
                records: store.filteredRecords,
                sortKey: store.sortKey,
                sortAscending: store.sortAscending,
                onOpen: { rec in store.send(.setNav(.record(databaseID: db.id, recordID: rec.id))) },
                onSort: { store.send(.toggleSort($0)) },
                onOpenRelation: { targetDB, targetID in store.send(.setNav(.record(databaseID: targetDB, recordID: targetID))) },
                onSetAlignment: { propertyID, alignment in
                    store.send(.setColumnAlignment(propertyID: propertyID, alignment: alignment))
                }
            )
            case .gallery:  GalleryView(db: db, properties: store.currentProperties, records: store.currentRecords, onOpen: { rec in store.send(.setNav(.record(databaseID: db.id, recordID: rec.id))) }, store: store)
            case .list:     ListView(db: db, properties: store.currentProperties, records: store.currentRecords) { rec in store.send(.setNav(.record(databaseID: db.id, recordID: rec.id))) }
            case .dashboard: DashboardView(db: db, properties: store.currentProperties, records: store.currentRecords)
            case .calendar: CalendarView(
                db: db,
                properties: store.currentProperties,
                records: store.filteredRecords,
                onOpen: { rec in store.send(.setNav(.record(databaseID: db.id, recordID: rec.id))) }
            )
            default:
                Text("View not available")
                    .font(.kstText(size: 14))
                    .foregroundStyle(KstColor.ink2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(KstColor.paper0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(KstColor.paper0)
        .confirmationDialog(
            "Delete all records in \(db.name)?",
            isPresented: $deleteAllConfirming,
            titleVisibility: .visible
        ) {
            Button("Delete \(store.currentRecords.count) record\(store.currentRecords.count == 1 ? "" : "s")", role: .destructive) {
                store.send(.deleteAllRecordsInDatabase(databaseID: db.id))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every record (including attached files) and can't be undone.")
        }
    }

}
