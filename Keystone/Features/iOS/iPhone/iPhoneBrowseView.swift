#if !os(macOS)
import SwiftUI
import ComposableArchitecture

struct iPhoneBrowseView: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Browse")
                        .font(.kstDisplay(size: 32, weight: .semibold))
                        .kerning(-0.4)
                        .foregroundStyle(KstColor.ink0)
                        .padding(.top, 8)
                        .padding(.bottom, 12)

                    ForEach(store.areas) { area in
                        let items = sidebarItemsForArea(area.id)
                        if !items.isEmpty {
                            iOSSectionTitle(title: area.title)
                            iOSCardList {
                                ForEach(items, id: \.id) { item in
                                    switch item {
                                    case let .database(db):
                                        iOSCardRow(
                                            leading: { Glyph(tone: db.accent, text: db.icon, size: 26, radius: 7) },
                                            title: db.name,
                                            subtitle: nil,
                                            trailing: {
                                                HStack(spacing: 8) {
                                                    Text("\(db.recordCount)")
                                                        .font(.kstText(size: 13))
                                                        .monospacedDigit()
                                                        .foregroundStyle(KstColor.ink2)
                                                    iOSChevron()
                                                }
                                            }
                                        ) {
                                            path.append(iPhoneRoute.database(databaseID: db.id))
                                        }
                                    case let .view(view):
                                        iOSCardRow(
                                            leading: { Glyph(tone: view.accent, text: view.icon, size: 26, radius: 7) },
                                            title: view.name,
                                            subtitle: nil,
                                            trailing: { iOSChevron() }
                                        ) {
                                            path.append(iPhoneRoute.view(viewID: view.id))
                                        }
                                    }
                                }
                            }
                            .padding(.bottom, 8)
                        }
                    }

                    if !store.allTags.isEmpty {
                        iOSSectionTitle(title: "Tags")
                        iOSCardList {
                            ForEach(store.allTags) { tag in
                                iOSCardRow(
                                    leading: {
                                        Circle()
                                            .fill(tag.color.base)
                                            .frame(width: 12, height: 12)
                                            .frame(width: 26, height: 26)
                                    },
                                    title: tag.name,
                                    subtitle: nil,
                                    trailing: {
                                        HStack(spacing: 8) {
                                            Text("\(tag.recordCount)")
                                                .font(.kstText(size: 13))
                                                .monospacedDigit()
                                                .foregroundStyle(KstColor.ink2)
                                            iOSChevron()
                                        }
                                    }
                                ) {
                                    path.append(iPhoneRoute.tag(tagID: tag.id))
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            .background(KstColor.paper0)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: iPhoneRoute.self) { route in
                iPhoneRouteView(store: store, route: route)
            }
        }
    }

    private func databasesForArea(_ areaID: String) -> [DBRow] {
        store.databases.filter { $0.areaID == areaID }
    }

    /// Merged database + view list for an area, ordered by `sort_index`
    /// so a saved view (e.g. Restaurants over Vendors) lands in the
    /// right slot without browse-screen-specific layout logic.
    private func sidebarItemsForArea(_ areaID: String) -> [SidebarBrowseItem] {
        let dbItems: [SidebarBrowseItem] = store.databases
            .filter { $0.areaID == areaID }
            .map { .database($0) }
        let viewItems: [SidebarBrowseItem] = store.views
            .filter { $0.areaID == areaID }
            .map { .view($0) }
        return (dbItems + viewItems).sorted { $0.sortIndex < $1.sortIndex }
    }
}

private enum SidebarBrowseItem {
    case database(DBRow)
    case view(ViewRow)

    var id: String {
        switch self {
        case .database(let d): return "db:\(d.id)"
        case .view(let v):     return "view:\(v.id)"
        }
    }

    var sortIndex: Double {
        switch self {
        case .database(let d): return d.sortIndex
        case .view(let v):     return v.sortIndex
        }
    }
}
#endif
