#if !os(macOS)
import SwiftUI
import ComposableArchitecture

/// Routes pushed onto a NavigationStack on iPhone. Each tab manages its own
/// stack with this enum. The TCA store remains the source of truth for
/// per-record state — pushes here just drive presentation.
enum iPhoneRoute: Hashable {
    case database(databaseID: String)
    /// Saved-view route. Renders the same list/table UI as a database
    /// route, but loads the view's backing database with its pinned
    /// filters applied (e.g. Restaurants → Vendors filtered to
    /// kind=restaurant).
    case view(viewID: String)
    case record(databaseID: String, recordID: String)
    case tag(tagID: String)
    case helpTopic(id: String)
    case settings
    /// Dedicated statistics page for Collections databases. Pushed
    /// onto the navigation stack from a toolbar button on
    /// `iPhoneDatabaseListView` when the db is books / movies /
    /// tv_shows. Renders the shared `StatsDetailView`.
    case stats(databaseID: String)
}

/// Shared dispatcher: render a route's destination view.
struct iPhoneRouteView: View {
    @Bindable var store: StoreOf<AppFeature>
    var route: iPhoneRoute

    var body: some View {
        switch route {
        case let .database(dbID):
            iPhoneDatabaseListView(store: store, databaseID: dbID)
        case let .view(viewID):
            iPhoneDatabaseListView(store: store, viewID: viewID)
        case let .record(dbID, recID):
            iPhoneRecordDetail(store: store, databaseID: dbID, recordID: recID)
        case let .tag(tagID):
            iPhoneTagListView(store: store, tagID: tagID)
        case let .helpTopic(id):
            iPhoneHelpTopicView(topicID: id)
        case .settings:
            // Reuse the cross-platform SettingsView. Its `Form { Section … }`
            // body renders natively as a grouped iOS list, and its
            // `#if os(iOS)` branches handle the document-picker folder
            // chooser in place of macOS's NSOpenPanel. Nesting it in a
            // pushed NavigationStack means the back chevron and tab bar
            // both work as users expect.
            SettingsView()
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
        case let .stats(dbID):
            iPhoneStatsHost(store: store, databaseID: dbID)
        }
    }
}

/// iPhone wrapper around `StatsDetailView`. Loads the backing db /
/// properties / records (mirrors `iPhoneDatabaseListView.reload`) and
/// renders the stats page in chrome that fits the navigation stack
/// — title only, no breadcrumb toolbar (the back chevron is supplied
/// by NavigationStack itself).
struct iPhoneStatsHost: View {
    @Bindable var store: StoreOf<AppFeature>
    var databaseID: String

    @Dependency(\.databaseClient) private var dbClient
    @State private var dbRow: DBRow?
    @State private var properties: [PropertyRow] = []
    @State private var records: [RecordRow] = []

    var body: some View {
        Group {
            if let dbRow {
                StatsDetailView(
                    store: store,
                    db: dbRow,
                    properties: properties,
                    records: records
                )
            } else {
                Color(KstColor.paper0)
            }
        }
        .navigationTitle(dbRow?.name ?? "Stats")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: databaseID) {
            await reload()
        }
        .onChange(of: store.hiddenRecordIDs) { _, _ in
            Task { await reload() }
        }
    }

    private func reload() async {
        dbRow = try? dbClient.database(databaseID)
        properties = (try? dbClient.properties(databaseID)) ?? []
        records = (try? dbClient.records(databaseID, store.hiddenRecordIDs)) ?? []
    }
}

/// Renders a single Help topic's markdown inside a NavigationStack on iPhone.
struct iPhoneHelpTopicView: View {
    var topicID: String
    var body: some View {
        ScrollView {
            MarkdownView(source: HelpTopics.loadMarkdown(topicID: topicID))
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(KstColor.paper0)
        .navigationTitle(HelpTopics.topic(id: topicID)?.title ?? topicID)
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
