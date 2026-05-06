import SwiftUI
import ComposableArchitecture

struct BlockListView: View {
    @Bindable var store: StoreOf<AppFeature>
    @FocusState private var focusedBlock: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if store.currentBlocks.isEmpty {
                emptyHint
            } else {
                ForEach(store.currentBlocks) { block in
                    BlockRowView(store: store, block: block, focusedBlockID: $focusedBlock)
                }
            }

            // Trailing tap area for "create new paragraph at end"
            Color.clear
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, minHeight: 60)
                .onTapGesture {
                    store.send(.createBlockAtEnd)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .attributedTextFormattingDefinition(KeystoneFormattingDefinition())
        .onChange(of: store.focusedBlockID) { _, new in
            if let new {
                focusedBlock = new
                // Clear the sentinel so future updates are detected
                DispatchQueue.main.async {
                    store.send(.clearFocusRequest)
                }
            }
        }
    }

    private var emptyHint: some View {
        Text("Click anywhere to start writing.")
            .font(.kstText(size: 14))
            .foregroundStyle(KstColor.ink3)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .onTapGesture { store.send(.createBlockAtEnd) }
    }
}
