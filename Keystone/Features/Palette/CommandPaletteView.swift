import SwiftUI
import ComposableArchitecture

struct CommandPaletteView: View {
    @Bindable var store: StoreOf<AppFeature>
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { store.send(.closePalette) }

            VStack {
                Spacer().frame(height: 80)
                paletteCard
                    .frame(width: 560)
                Spacer()
            }
        }
        .onAppear { focused = true }
        #if os(macOS)
        .onExitCommand { store.send(.closePalette) }
        #endif
    }

    private var paletteCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(KstColor.ink2)
                TextField("Search records, databases, files…", text: $store.paletteQuery)
                    .textFieldStyle(.plain)
                    .font(.kstText(size: 16))
                    .focused($focused)
                    .onSubmit {
                        if let item = filteredItems[safe: store.paletteSelectedIndex] {
                            store.send(.palettePicked(item))
                        }
                    }
                Text("esc")
                    .font(.kstMono(size: 10.5))
                    .foregroundStyle(KstColor.ink3)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) {
                Rectangle().fill(KstColor.paper3).frame(height: 0.5)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if filteredItems.isEmpty {
                        Text("No matches for “\(store.paletteQuery)”")
                            .font(.kstText(size: 13))
                            .foregroundStyle(KstColor.ink3)
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        ForEach(Array(filteredItems.enumerated()), id: \.element.id) { idx, item in
                            ResultRow(
                                item: item,
                                isSelected: idx == store.paletteSelectedIndex,
                                onHover: { store.send(.palettePickIndex(idx)) },
                                onTap: { store.send(.palettePicked(item)) }
                            )
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 380)

            HStack(spacing: 14) {
                Text("↑↓ navigate").font(.kstMono(size: 10.5))
                Text("↵ open").font(.kstMono(size: 10.5))
                Text("⌘N capture").font(.kstMono(size: 10.5))
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(KstColor.sage).frame(width: 5, height: 5)
                    Text("Local search")
                }
            }
            .font(.kstText(size: 10.5))
            .foregroundStyle(KstColor.ink2)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KstColor.paper1)
            .overlay(alignment: .top) { Rectangle().fill(KstColor.paper3).frame(height: 0.5) }
        }
        .background(KstColor.paper0)
        .overlay(
            RoundedRectangle(cornerRadius: KstRadius.r4, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: KstRadius.r4, style: .continuous))
        .kstShadowPop()
    }

    private var filteredItems: [PaletteItem] {
        let q = store.paletteQuery.lowercased()
        let items = store.paletteItems
        if q.isEmpty { return Array(items.prefix(8)) }
        return items.filter {
            $0.label.lowercased().contains(q) || $0.sub.lowercased().contains(q)
        }.prefix(12).map { $0 }
    }
}

private struct ResultRow: View {
    var item: PaletteItem
    var isSelected: Bool
    var onHover: () -> Void
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Glyph(tone: item.tone, text: item.glyph, size: 20, radius: 5)
                Text(item.label).font(.kstText(size: 13.5, weight: .medium)).foregroundStyle(KstColor.ink0)
                Spacer(minLength: 0)
                Text(item.sub).font(.kstText(size: 11)).foregroundStyle(KstColor.ink2)
                if isSelected {
                    Text("↵").font(.kstMono(size: 10.5)).foregroundStyle(KstColor.ink3)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(isSelected ? KstColor.paper2 : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in if hovering { onHover() } }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
