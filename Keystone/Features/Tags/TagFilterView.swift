import SwiftUI
import ComposableArchitecture

struct TagFilterView: View {
    @Bindable var store: StoreOf<AppFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            KstToolbar(breadcrumb: ["Tag", store.tagFilterTag?.name ?? "—"]) {
                EmptyView()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    if let tag = store.tagFilterTag {
                        HStack(spacing: 10) {
                            Circle().fill(tag.color.base).frame(width: 10, height: 10)
                            Text(tag.name)
                                .font(.kstDisplay(size: 26, weight: .semibold))
                                .foregroundStyle(KstColor.ink0)
                                .kerning(-0.4)
                            Text("\(store.tagFilterRecords.count)")
                                .font(.kstText(size: 13))
                                .monospacedDigit()
                                .foregroundStyle(KstColor.ink2)
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 20)
                        .padding(.bottom, 14)
                    }

                    // Records
                    VStack(spacing: 0) {
                        ForEach(store.tagFilterRecords) { item in
                            Button(action: {
                                store.send(.setNav(.record(databaseID: item.record.databaseID, recordID: item.record.id)))
                            }) {
                                HStack(spacing: 12) {
                                    Glyph(tone: item.record.tone, text: item.record.glyph, size: 22, radius: 5)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.record.title)
                                            .font(.kstText(size: 13.5, weight: .semibold))
                                            .foregroundStyle(KstColor.ink0)
                                        Text(item.databaseName)
                                            .font(.kstText(size: 11))
                                            .foregroundStyle(KstColor.ink2)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 24).padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(KstColor.paper3).frame(height: 0.5)
                            }
                        }
                    }
                }
            }
            .background(KstColor.paper0)
        }
        .background(KstColor.paper0)
    }
}
