import SwiftUI
import ComposableArchitecture

struct BlockListView: View {
    @Bindable var store: StoreOf<AppFeature>
    @FocusState private var focusedBlock: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if store.currentBlocks.isEmpty {
                emptyHint
            } else {
                let numberedIndices = computeNumberedIndices(store.currentBlocks)
                ForEach(Array(store.currentBlocks.enumerated()), id: \.element.id) { offset, block in
                    BlockRowView(
                        store: store,
                        block: block,
                        focusedBlockID: $focusedBlock,
                        orderedListIndex: numberedIndices[offset]
                    )
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
                // Clear the sentinel so future updates are detected.
                // Defer to the next runloop tick so SwiftUI has time to
                // commit the focusedBlock state before the store action
                // races against it.
                Task { @MainActor in
                    store.send(.clearFocusRequest)
                }
            }
        }
    }

    /// Compute the 1-based ordinal for each `.numbered` block in the
    /// list, restarting at 1 whenever a non-numbered block breaks the run.
    /// Returns an array parallel to `blocks` where non-numbered indices
    /// hold `nil`. Without this, every numbered block would render as
    /// `1.` because the block itself doesn't carry sequence info.
    private func computeNumberedIndices(_ blocks: [BlockRow]) -> [Int?] {
        var result: [Int?] = []
        result.reserveCapacity(blocks.count)
        var counter = 0
        for block in blocks {
            if block.kind == .numbered {
                counter += 1
                result.append(counter)
            } else {
                counter = 0
                result.append(nil)
            }
        }
        return result
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
