import SwiftUI
import ComposableArchitecture

struct TagPicker: View {
    @Bindable var store: StoreOf<AppFeature>
    var onClose: () -> Void

    @State private var query: String = ""
    @State private var selectedScope: TagScope = .global
    @State private var selectedColor: AccentTone = .cerulean
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(KstColor.ink3)
                TextField("Find or create tag…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.kstText(size: 13))
                    .focused($focused)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(KstColor.paper3).frame(height: 0.5) }

            // Available tags
            ScrollView {
                VStack(spacing: 0) {
                    let already = Set(store.currentRecordTags.map(\.id))
                    let candidates = filteredAvailable.filter { !already.contains($0.id) }
                    ForEach(candidates) { tag in
                        Button(action: {
                            store.send(.attachTag(tagID: tag.id))
                            onClose()
                        }) {
                            HStack(spacing: 8) {
                                Circle().fill(tag.color.base).frame(width: 8, height: 8)
                                Text(tag.name).font(.kstText(size: 13)).foregroundStyle(KstColor.ink0)
                                Spacer()
                                if tag.scopeType == .database {
                                    Text(tag.scopeID ?? "")
                                        .font(.kstText(size: 10))
                                        .foregroundStyle(KstColor.ink3)
                                }
                                Text("\(tag.recordCount)")
                                    .font(.kstText(size: 10))
                                    .monospacedDigit()
                                    .foregroundStyle(KstColor.ink3)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    // Create-new row
                    if shouldShowCreateRow {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text("Create").font(.kstText(size: 11)).foregroundStyle(KstColor.ink2)
                                Text("\"\(query)\"").font(.kstText(size: 13, weight: .semibold)).foregroundStyle(KstColor.ink0)
                            }
                            HStack(spacing: 8) {
                                Picker("Scope", selection: $selectedScope) {
                                    Text("Global").tag(TagScope.global)
                                    if store.currentDB != nil {
                                        Text("This DB").tag(TagScope.database)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(maxWidth: 180)

                                Spacer()

                                ForEach([AccentTone.cerulean, .iris, .sage, .amber, .graphite], id: \.self) { tone in
                                    Button {
                                        selectedColor = tone
                                    } label: {
                                        Circle()
                                            .fill(tone.base)
                                            .frame(width: 14, height: 14)
                                            .overlay {
                                                if selectedColor == tone {
                                                    Circle().stroke(KstColor.ink0, lineWidth: 1.5).padding(-2)
                                                }
                                            }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            Button(action: {
                                store.send(.createAndAttachTag(name: query, scope: selectedScope, color: selectedColor))
                                onClose()
                            }) {
                                Text("Create and attach")
                                    .font(.kstText(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(KstColor.cerulean)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(12)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 320)
        .background(KstColor.paper0)
        .onAppear { focused = true }
    }

    private var filteredAvailable: [TagModel] {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let dbID = store.currentDB?.id
        let pool = store.allTags.filter { tag in
            tag.scopeType == .global || tag.scopeID == dbID
        }
        if q.isEmpty { return pool }
        return pool.filter { $0.name.lowercased().contains(q) }
    }

    private var shouldShowCreateRow: Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        return !store.allTags.contains(where: { $0.name.caseInsensitiveCompare(q) == .orderedSame })
    }
}
