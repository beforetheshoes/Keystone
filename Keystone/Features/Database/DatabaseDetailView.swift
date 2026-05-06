import SwiftUI
import ComposableArchitecture

struct DatabaseDetailView: View {
    @Bindable var store: StoreOf<AppFeature>
    var db: DBRow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            KstToolbar(breadcrumb: [db.name]) {
                ViewSwitcher(selected: store.viewKind) { store.send(.setViewKind($0)) }
                KstButton(style: .primary, action: { store.send(.createBlankRecord(databaseID: db.id)) }) {
                    Text("+ New")
                }
            }

            // Subheader: title, count
            HStack(spacing: 10) {
                Glyph(tone: db.accent, text: db.icon, size: 26, radius: 7)
                Text(db.name)
                    .font(.kstDisplay(size: 26, weight: .semibold))
                    .foregroundStyle(KstColor.ink0)
                    .kerning(-0.4)
                Text("\(store.currentRecords.count)")
                    .font(.kstText(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(KstColor.ink2)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)
            .background(KstColor.paper0)
            .overlay(alignment: .bottom) { KstHairline() }

            switch store.viewKind {
            case .table:    TableView(db: db, properties: store.currentProperties, records: store.currentRecords, sortKey: store.sortKey, sortAscending: store.sortAscending) { rec in store.send(.setNav(.record(databaseID: db.id, recordID: rec.id))) } onSort: { store.send(.toggleSort($0)) }
            case .gallery:  GalleryView(db: db, properties: store.currentProperties, records: store.currentRecords) { rec in store.send(.setNav(.record(databaseID: db.id, recordID: rec.id))) }
            case .list:     ListView(db: db, properties: store.currentProperties, records: store.currentRecords) { rec in store.send(.setNav(.record(databaseID: db.id, recordID: rec.id))) }
            case .dashboard: DashboardView(db: db, properties: store.currentProperties, records: store.currentRecords)
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
    }

}
