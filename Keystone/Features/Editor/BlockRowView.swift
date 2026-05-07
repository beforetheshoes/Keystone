import SwiftUI
import ComposableArchitecture

struct BlockRowView: View {
    @Bindable var store: StoreOf<AppFeature>
    var block: BlockRow
    @FocusState.Binding var focusedBlockID: String?
    var orderedListIndex: Int? = nil

    @State private var localText: AttributedString = AttributedString()
    @State private var localSelection = AttributedTextSelection()
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            gutter
            content
        }
        .onHover { hovering = $0 }
        .onAppear { localText = block.text }
        .onChange(of: block.id) { _, _ in localText = block.text }
        .onChange(of: block.text) { _, new in
            if !attributedEqual(localText, new) { localText = new }
        }
    }

    @ViewBuilder
    private var gutter: some View {
        // Only render the menu when the row is hovered AND it's currently
        // the focused block. Hover alone proved unreliable: rows containing
        // a TextEditor report hover-true even after the cursor leaves, so
        // every block ended up with a permanent `…` gutter. Coupling to
        // focus means the gutter only appears when the user is actively
        // editing a specific block.
        if hovering, focusedBlockID == block.id {
            Menu {
                Section("Change to") {
                    ForEach(BlockKind.allCases, id: \.self) { kind in
                        Button(kind.displayName) {
                            store.send(.blockKindChanged(blockID: block.id, kind: kind))
                        }
                    }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    store.send(.blockDeleted(blockID: block.id, focusPrevious: true))
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(KstColor.ink3)
                    .frame(width: 20, height: 20)
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif
            .menuIndicator(.hidden)
            .frame(width: 24, alignment: .center)
            .padding(.top, gutterTopPadding)
        } else {
            // Reserve the same horizontal slot so block content doesn't
            // shift left when the menu hides.
            Color.clear
                .frame(width: 24, height: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .divider:
            DividerBlockBody(block: block, store: store, focusedBlockID: $focusedBlockID)
        case .checklist:
            ChecklistBlockBody(
                block: block,
                store: store,
                focusedBlockID: $focusedBlockID,
                localText: $localText,
                localSelection: $localSelection,
                onSubmit: handleReturn,
                onBackspaceEmpty: handleBackspaceEmpty,
                onShortcut: handleShortcut
            )
        case .table:
            if let table = block.tableData {
                TableBlockBody(table: table)
            } else {
                EmptyView()
            }
        default:
            TextBlockBody(
                block: block,
                store: store,
                focusedBlockID: $focusedBlockID,
                localText: $localText,
                localSelection: $localSelection,
                onSubmit: handleReturn,
                onBackspaceEmpty: handleBackspaceEmpty,
                onShortcut: handleShortcut,
                orderedListIndex: orderedListIndex
            )
        }
    }

    private var gutterTopPadding: CGFloat {
        switch block.kind {
        case .heading1: 12
        case .heading2: 8
        case .heading3: 6
        default: 4
        }
    }

    private func handleReturn() {
        let (before, after) = splitAtCursor(localText, selection: localSelection)
        store.send(.blockReturnPressed(blockID: block.id, before: before, after: after))
    }

    private func handleBackspaceEmpty() {
        store.send(.blockBackspaceOnEmpty(blockID: block.id))
    }

    private func handleShortcut(newKind: BlockKind, remainder: AttributedString) {
        store.send(.blockShortcutTriggered(blockID: block.id, newKind: newKind, remainder: remainder))
    }
}

private struct TextBlockBody: View {
    var block: BlockRow
    @Bindable var store: StoreOf<AppFeature>
    @FocusState.Binding var focusedBlockID: String?
    @Binding var localText: AttributedString
    @Binding var localSelection: AttributedTextSelection
    var onSubmit: () -> Void
    var onBackspaceEmpty: () -> Void
    var onShortcut: (BlockKind, AttributedString) -> Void
    var orderedListIndex: Int? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            leadingDecoration
            TextEditor(text: $localText, selection: $localSelection)
                .font(blockFont)
                .fontWeight(blockWeight)
                .foregroundStyle(blockColor)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(minHeight: minHeight)
                .fixedSize(horizontal: false, vertical: true)
                .focused($focusedBlockID, equals: block.id)
                .onKeyPress(.return) {
                    onSubmit()
                    return .handled
                }
                .onKeyPress(.delete) {
                    if localText.characters.isEmpty {
                        onBackspaceEmpty()
                        return .handled
                    }
                    return .ignored
                }
                .onChange(of: localText) { old, new in
                    if let (kind, remainder) = detectMarkdownShortcut(in: new), block.kind == .paragraph {
                        onShortcut(kind, remainder)
                    } else if !attributedEqual(old, new) {
                        store.send(.blockTextChanged(blockID: block.id, text: new))
                    }
                }
        }
        .padding(.vertical, blockVerticalPadding)
    }

    @ViewBuilder
    private var leadingDecoration: some View {
        switch block.kind {
        case .bulleted:
            Text("•")
                .font(blockFont)
                .foregroundStyle(KstColor.ink2)
                .padding(.top, 2)
        case .numbered:
            Text("\(orderedListIndex ?? 1).")
                .font(blockFont)
                .foregroundStyle(KstColor.ink2)
                .monospacedDigit()
                .padding(.top, 2)
        case .quote:
            Rectangle()
                .fill(KstColor.ink4)
                .frame(width: 2)
                .padding(.vertical, 2)
        default:
            EmptyView()
        }
    }

    private var blockFont: Font {
        switch block.kind {
        case .heading1: .kstDisplay(size: 28, weight: .semibold)
        case .heading2: .kstDisplay(size: 22, weight: .semibold)
        case .heading3: .kstDisplay(size: 18, weight: .semibold)
        case .quote:    .kstText(size: 14)
        default:        .kstText(size: 14)
        }
    }
    private var blockWeight: Font.Weight {
        switch block.kind {
        case .heading1, .heading2, .heading3: .semibold
        default: .regular
        }
    }
    private var blockColor: Color {
        block.kind == .quote ? KstColor.ink2 : KstColor.ink0
    }
    private var blockVerticalPadding: CGFloat {
        switch block.kind {
        case .heading1: 10
        case .heading2: 8
        case .heading3: 6
        default: 2
        }
    }
    private var minHeight: CGFloat {
        switch block.kind {
        case .heading1: 36
        case .heading2: 30
        case .heading3: 26
        default: 22
        }
    }
}

private struct ChecklistBlockBody: View {
    var block: BlockRow
    @Bindable var store: StoreOf<AppFeature>
    @FocusState.Binding var focusedBlockID: String?
    @Binding var localText: AttributedString
    @Binding var localSelection: AttributedTextSelection
    var onSubmit: () -> Void
    var onBackspaceEmpty: () -> Void
    var onShortcut: (BlockKind, AttributedString) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { block.checked ?? false },
                set: { store.send(.blockCheckedChanged(blockID: block.id, checked: $0)) }
            ))
            .labelsHidden()
            #if os(macOS)
            .toggleStyle(.checkbox)
            #endif
            .padding(.top, 4)

            TextEditor(text: $localText, selection: $localSelection)
                .font(.kstText(size: 14))
                .foregroundStyle((block.checked ?? false) ? KstColor.ink3 : KstColor.ink0)
                .strikethrough(block.checked ?? false)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(minHeight: 22)
                .fixedSize(horizontal: false, vertical: true)
                .focused($focusedBlockID, equals: block.id)
                .onKeyPress(.return) {
                    onSubmit()
                    return .handled
                }
                .onKeyPress(.delete) {
                    if localText.characters.isEmpty {
                        onBackspaceEmpty()
                        return .handled
                    }
                    return .ignored
                }
                .onChange(of: localText) { old, new in
                    if !attributedEqual(old, new) {
                        store.send(.blockTextChanged(blockID: block.id, text: new))
                    }
                }
        }
        .padding(.vertical, 2)
    }
}

/// Read-only table renderer. Lays out cells in a `Grid` with a bold
/// header row and alternating row backgrounds. Each cell sizes to its
/// content (no mid-word wrapping); if the table's natural width exceeds
/// the page, the whole grid scrolls horizontally inside the block.
///
/// Why not let cells wrap? SwiftUI's default behavior in a `Grid` will
/// break long words by character once a column gets squeezed — VINs,
/// dates, account numbers all end up shattered like "01/16/202\n6".
/// Sizing cells to natural width and offering horizontal scroll
/// preserves the data's integrity at the cost of needing a swipe.
///
/// To modify a table, regenerate from its `.md` source or convert the
/// block to a paragraph via the gutter menu.
private struct TableBlockBody: View {
    var table: BlockTableData

    /// Soft cap on per-cell width so a single absurdly long cell
    /// doesn't push the whole table off the right edge of the page.
    /// Beyond this, cells wrap normally (across line breaks, not
    /// mid-word).
    private static let maxCellWidth: CGFloat = 320

    private var columnCount: Int {
        let dataMax = table.rows.map(\.count).max() ?? 0
        return max(table.headers.count, dataMax)
    }

    private func cell(_ row: [String], _ index: Int) -> String {
        index < row.count ? row[index] : ""
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                if !table.headers.isEmpty {
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { col in
                            cellView(text: cell(table.headers, col), isHeader: true)
                        }
                    }
                    .background(KstColor.paper2)
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { col in
                            cellView(text: cell(row, col), isHeader: false)
                        }
                    }
                    .background(rowIndex.isMultiple(of: 2) ? KstColor.paper0 : KstColor.paper1)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(KstColor.ink4, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.horizontal, 1) // breathing room for the stroke
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func cellView(text: String, isHeader: Bool) -> some View {
        Text(text)
            .font(.kstText(size: 13, weight: isHeader ? .semibold : .regular))
            .foregroundStyle(isHeader ? KstColor.ink0 : KstColor.ink1)
            .multilineTextAlignment(.leading)
            .lineLimit(nil)
            // Soft cap on natural width so one giant cell can't blow up
            // the whole row, but cells of normal length keep their full
            // width. `fixedSize(horizontal: false, vertical: true)`
            // tells SwiftUI to use ideal vertical size (allow wrapping
            // when we hit the cap) but not to compress horizontally
            // below the natural intrinsic width.
            .frame(maxWidth: Self.maxCellWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(alignment: .trailing) {
                Rectangle().fill(KstColor.ink4).frame(width: 0.5)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(KstColor.ink4).frame(height: 0.5)
            }
    }
}

private struct DividerBlockBody: View {
    var block: BlockRow
    @Bindable var store: StoreOf<AppFeature>
    @FocusState.Binding var focusedBlockID: String?

    var body: some View {
        Rectangle()
            .fill(KstColor.ink4)
            .frame(maxWidth: .infinity, minHeight: 0.5, maxHeight: 0.5)
            .padding(.vertical, 12)
            .focusable(true)
            .focused($focusedBlockID, equals: block.id)
            .onKeyPress(.delete) {
                store.send(.blockBackspaceOnEmpty(blockID: block.id))
                return .handled
            }
    }
}

// MARK: - Helpers

func attributedEqual(_ a: AttributedString, _ b: AttributedString) -> Bool {
    a == b
}

func splitAtCursor(_ text: AttributedString, selection: AttributedTextSelection) -> (before: AttributedString, after: AttributedString) {
    splitText(text, at: cursorIndex(for: selection, in: text))
}

/// Pure split at an `AttributedString.Index`. All inline attributes are
/// preserved in their respective halves.
func splitText(_ text: AttributedString, at cursor: AttributedString.Index) -> (before: AttributedString, after: AttributedString) {
    let before = AttributedString(text[text.startIndex..<cursor])
    let after = AttributedString(text[cursor..<text.endIndex])
    return (before, after)
}

/// Extracts a single cursor index from an `AttributedTextSelection`. For a
/// non-empty selection, this returns the start of the first selected range.
func cursorIndex(for selection: AttributedTextSelection, in text: AttributedString) -> AttributedString.Index {
    switch selection.indices(in: text) {
    case .insertionPoint(let idx):
        return idx
    case .ranges(let rangeSet):
        return rangeSet.ranges.first?.lowerBound ?? text.endIndex
    }
}

func detectMarkdownShortcut(in text: AttributedString) -> (BlockKind, AttributedString)? {
    let plain = String(text.characters)
    let triggers: [(String, BlockKind)] = [
        ("# ",   .heading1),
        ("## ",  .heading2),
        ("### ", .heading3),
        ("- ",   .bulleted),
        ("* ",   .bulleted),
        ("1. ",  .numbered),
        ("[] ",  .checklist),
        ("[ ] ", .checklist),
        ("> ",   .quote),
        ("--- ", .divider),
    ]
    for (prefix, kind) in triggers {
        if plain.hasPrefix(prefix) {
            // Strip prefix from the AttributedString
            guard let prefixEnd = text.characters.index(text.characters.startIndex, offsetBy: prefix.count, limitedBy: text.characters.endIndex) else { continue }
            let remainder = AttributedString(text[prefixEnd..<text.endIndex])
            return (kind, remainder)
        }
    }
    return nil
}
