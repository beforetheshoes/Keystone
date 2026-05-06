import SwiftUI
import ComposableArchitecture

struct HelpView: View {
    @Bindable var store: StoreOf<AppFeature>
    var topicID: String

    private var topic: HelpTopics.Topic {
        HelpTopics.topic(id: topicID) ?? HelpTopics.all[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            KstToolbar(breadcrumb: ["Help", topic.title]) { EmptyView() }

            HStack(spacing: 0) {
                // TOC rail
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("CONTENTS")
                            .font(.kstText(size: 11, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(KstColor.ink2)
                            .padding(.horizontal, 14)
                            .padding(.top, 16)
                            .padding(.bottom, 8)

                        ForEach(HelpTopics.all) { t in
                            Button(action: {
                                store.send(.setNav(.help(topic: t.id)))
                            }) {
                                Text(t.title)
                                    .font(.kstText(size: 13, weight: t.id == topicID ? .semibold : .regular))
                                    .foregroundStyle(t.id == topicID ? KstColor.ink0 : KstColor.ink1)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(t.id == topicID ? Color.black.opacity(0.07) : .clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .padding(.horizontal, 6)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer().frame(height: 24)
                    }
                }
                .frame(width: 200)
                .background(KstColor.paper1)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(KstColor.ink4).frame(width: 0.5)
                }

                // Content pane
                ScrollView {
                    MarkdownView(source: HelpTopics.loadMarkdown(topicID: topic.id))
                        .frame(maxWidth: 720, alignment: .leading)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .background(KstColor.paper0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KstColor.paper0)
    }
}
