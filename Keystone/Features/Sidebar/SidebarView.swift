import SwiftUI
import ComposableArchitecture

struct SidebarView: View {
    @Bindable var store: StoreOf<AppFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Traffic-light row
            HStack(spacing: 12) {
                // Reserve the height of the system traffic-light row on macOS.
                Spacer()
            }
            .padding(.horizontal, 14)
            #if os(macOS)
            .frame(height: 38)
            #else
            .frame(height: 0)
            #endif

            // Brand
            HStack(spacing: 9) {
                KeystoneLogo(size: 24, radius: 6)
                Text("Keystone")
                    .font(.kstDisplay(size: 16, weight: .semibold))
                    .foregroundStyle(KstColor.ink0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 14)

            // Search + quick add
            HStack(spacing: 6) {
                KstButton(action: { store.send(.openPalette) }) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                    Text("Search")
                    Spacer(minLength: 0)
                    Text("⌘K")
                        .font(.kstMono(size: 10.5))
                        .foregroundStyle(KstColor.ink3)
                }
                .frame(maxWidth: .infinity)

                KstButton(action: { store.send(.openCapture) }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .frame(width: 28)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            // Groups
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    SidebarRowView(
                        icon: .system("house"),
                        label: "Home",
                        count: nil,
                        isActive: store.nav == .home
                    ) { store.send(.setNav(.home)) }
                    .padding(.top, 4)
                    .padding(.bottom, 6)

                    ForEach(store.areas) { area in
                        SidebarGroup(title: area.title) {
                            ForEach(sidebarItemsForArea(area.id), id: \.id) { item in
                                switch item {
                                case let .database(db):
                                    SidebarRowView(
                                        icon: .glyph(db.icon, db.accent),
                                        label: db.name,
                                        count: db.recordCount,
                                        isActive: store.nav == .database(db.id)
                                    ) { store.send(.setNav(.database(db.id))) }
                                case let .view(view):
                                    SidebarRowView(
                                        icon: .glyph(view.icon, view.accent),
                                        label: view.name,
                                        count: view.recordCount,
                                        isActive: store.nav == .view(view.id)
                                    ) { store.send(.setNav(.view(view.id))) }
                                }
                            }
                            // The Mobility area gets a derived "what's
                            // due" report alongside its databases —
                            // not a record list, so it lives next to
                            // them instead of inside one. When more
                            // sidecar-backed areas land (Home, Pets),
                            // each one gets its own equivalent.
                            if area.id == "area-mobility" {
                                SidebarRowView(
                                    icon: .system("wrench.and.screwdriver"),
                                    label: "Maintenance Schedule",
                                    count: nil,
                                    isActive: store.nav == .maintenanceSchedule
                                ) { store.send(.setNav(.maintenanceSchedule)) }
                            }
                        }
                    }

                    if !store.allTags.isEmpty {
                        SidebarGroup(title: "Tags", defaultOpen: false) {
                            ForEach(store.allTags) { tag in
                                SidebarRowView(
                                    icon: .dot(tag.color),
                                    label: tag.name,
                                    count: tag.recordCount,
                                    isActive: store.nav == .tag(tagID: tag.id)
                                ) { store.send(.setNav(.tag(tagID: tag.id))) }
                            }
                        }
                    }

                    SidebarRowView(
                        icon: .system("questionmark.circle"),
                        label: "Help",
                        count: nil,
                        isActive: { if case .help = store.nav { return true } else { return false } }()
                    ) { store.send(.setNav(.help(topic: HelpTopics.defaultTopicID))) }
                    .padding(.top, 6)

                    Spacer().frame(height: 12)
                }
            }

            // Footer — sync status indicator
            VStack(spacing: 0) {
                KstHairline()
                SyncStatusBadge(status: store.syncStatus)
            }
        }
        #if os(macOS)
        .frame(width: 232)
        #else
        .frame(maxWidth: .infinity)
        #endif
        .background(KstColor.paper1)
        #if os(macOS)
        .overlay(alignment: .trailing) {
            Rectangle().fill(KstColor.ink4).frame(width: 0.5)
        }
        #endif
    }

    private func databasesForArea(_ areaID: String) -> [DBRow] {
        store.databases.filter { $0.areaID == areaID }
    }

    /// Merged + sorted sidebar items for the area: real databases and
    /// saved views interleave by `sort_index` so the Restaurants view
    /// can sit between Movies (8.1) and TV Shows (8.2) without the
    /// sidebar code caring whether it's a view or a database.
    private func sidebarItemsForArea(_ areaID: String) -> [SidebarItem] {
        let dbItems: [SidebarItem] = store.databases
            .filter { $0.areaID == areaID }
            .map { .database($0) }
        let viewItems: [SidebarItem] = store.views
            .filter { $0.areaID == areaID }
            .map { .view($0) }
        return (dbItems + viewItems).sorted { $0.sortIndex < $1.sortIndex }
    }
}

private enum SidebarItem {
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

private struct SidebarGroup<Content: View>: View {
    var title: String
    var defaultOpen: Bool = true
    @ViewBuilder var content: () -> Content
    @State private var open: Bool

    init(title: String, defaultOpen: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.defaultOpen = defaultOpen
        self.content = content
        _open = State(initialValue: defaultOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.12)) { open.toggle() } }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(open ? 0 : -90))
                    Text(title.uppercased())
                        .font(.kstText(size: 11, weight: .semibold))
                        .tracking(0.4)
                }
                .foregroundStyle(KstColor.ink3)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
            .buttonStyle(.plain)

            if open {
                content()
            }
        }
        .padding(.bottom, 4)
    }
}

private enum SidebarIcon {
    case system(String)
    case glyph(String, AccentTone)
    case dot(AccentTone)
}

private struct SidebarRowView: View {
    var icon: SidebarIcon
    var label: String
    var count: Int?
    var isActive: Bool
    var indent: Int = 0
    var tone: AccentTone = .graphite
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                switch icon {
                case let .system(name):
                    Image(systemName: name)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(KstColor.ink2)
                        .frame(width: 16)
                case let .glyph(text, accent):
                    Glyph(tone: accent, text: text, size: 16, radius: 4)
                case let .dot(accent):
                    Circle()
                        .fill(accent.base)
                        .frame(width: 8, height: 8)
                        .frame(width: 16)
                }
                Text(label)
                    .font(.kstText(size: 13, weight: isActive ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let count {
                    Text("\(count)")
                        .font(.kstText(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(KstColor.ink3)
                }
            }
            .foregroundStyle(isActive ? KstColor.ink0 : KstColor.ink1)
            .padding(.leading, CGFloat(8 + indent * 14))
            .padding(.trailing, 8)
            .frame(height: 26)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var rowBackground: Color {
        if isActive { return Color.black.opacity(0.07) }
        if hovering { return Color.black.opacity(0.04) }
        return .clear
    }
}
