#if !os(macOS)
import SwiftUI
import ComposableArchitecture

struct iPhoneTabsView: View {
    @Bindable var store: StoreOf<AppFeature>

    @State private var selection: Tab = .home
    @State private var lastNonAddSelection: Tab = .home

    enum Tab: Hashable {
        case home, browse, add, search, profile
    }

    var body: some View {
        TabView(selection: $selection) {
            iPhoneHomeView(store: store)
                .tag(Tab.home)
                .tabItem { Label("Home", systemImage: "house.fill") }

            iPhoneBrowseView(store: store)
                .tag(Tab.browse)
                .tabItem { Label("Browse", systemImage: "square.grid.2x2") }

            // Placeholder content for the `+` tab. Selecting this tab is
            // intercepted by `.onChange` below — we open Quick Capture and
            // bounce the selection back to the user's previous tab.
            Color.clear
                .tag(Tab.add)
                .tabItem { Label("Add", systemImage: "plus") }

            iPhoneSearchView(store: store)
                .tag(Tab.search)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            iPhoneProfileView(store: store)
                .tag(Tab.profile)
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
        }
        .tint(KstColor.ceruleanInk)
        .onChange(of: selection) { _, new in
            if new == .add {
                selection = lastNonAddSelection
                store.send(.openCapture)
            } else {
                lastNonAddSelection = new
            }
        }
    }
}
#endif
