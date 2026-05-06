#if !os(macOS)
import SwiftUI
import ComposableArchitecture

/// Routes pushed onto a NavigationStack on iPhone. Each tab manages its own
/// stack with this enum. The TCA store remains the source of truth for
/// per-record state — pushes here just drive presentation.
enum iPhoneRoute: Hashable {
    case database(databaseID: String)
    case record(databaseID: String, recordID: String)
    case tag(tagID: String)
    case helpTopic(id: String)
}

/// Shared dispatcher: render a route's destination view.
struct iPhoneRouteView: View {
    @Bindable var store: StoreOf<AppFeature>
    var route: iPhoneRoute

    var body: some View {
        switch route {
        case let .database(dbID):
            iPhoneDatabaseListView(store: store, databaseID: dbID)
        case let .record(dbID, recID):
            iPhoneRecordDetail(store: store, databaseID: dbID, recordID: recID)
        case let .tag(tagID):
            iPhoneTagListView(store: store, tagID: tagID)
        case let .helpTopic(id):
            iPhoneHelpTopicView(topicID: id)
        }
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
