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
                        let dbs = databasesForArea(area.id)
                        if !dbs.isEmpty {
                            iOSSectionTitle(title: area.title)
                            iOSCardList {
                                ForEach(dbs) { db in
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
}
#endif
