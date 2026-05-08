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
            if block.tableData != nil {
                TableBlockBody(block: block, store: store)
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

/// Editable table renderer. Each cell is a SwiftUI `TextField` bound
/// to a local mirror of the block's `BlockTableData`; commits flow back
/// to the store via `.blockTableEdited`. Right-click any cell to
/// insert/delete rows and columns.
///
/// Cells size to their content (no mid-word wrapping). If the table's
/// natural width exceeds the page, the whole grid scrolls horizontally
/// inside the block. Why not wrap? SwiftUI's default behavior in a
/// `Grid` will break long words by character once a column gets
/// squeezed — VINs, dates, account numbers all end up shattered like
/// "01/16/202\n6". A soft per-cell cap (`maxCellWidth`) prevents one
/// giant cell from blowing up the row width.
private struct TableBlockBody: View {
    var block: BlockRow
    @Bindable var store: StoreOf<AppFeature>

    /// Local mirror of the block's table so each `TextField` has a
    /// stable, settable `Binding<String>`. Mirrored from `block` on
    /// appear and whenever the upstream block changes (CloudKit pull,
    /// CLI edit, etc.), and pushed back to the store on each commit.
    @State private var local: BlockTableData = BlockTableData(headers: [], rows: [])
    @FocusState private var focusedCell: CellCoord?

    /// (-1, n) addresses the header row's nth column.
    private struct CellCoord: Hashable {
        let row: Int
        let column: Int
    }

    private static let maxCellWidth: CGFloat = 320

    private var columnCount: Int {
        let dataMax = local.rows.map(\.count).max() ?? 0
        return max(local.headers.count, dataMax)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                if !local.headers.isEmpty {
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { col in
                            cellView(row: -1, column: col, isHeader: true)
                        }
                    }
                    .background(KstColor.paper2)
                }
                ForEach(Array(local.rows.enumerated()), id: \.offset) { rowIndex, _ in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { col in
                            cellView(row: rowIndex, column: col, isHeader: false)
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
        .onAppear { local = block.tableData ?? local }
        .onChange(of: block.tableData) { _, new in
            // Upstream change while no cell is focused — refresh the
            // local mirror. Don't clobber an in-progress edit if a cell
            // still owns focus; the user can re-fetch by clicking out.
            if focusedCell == nil, let new { local = new }
        }
    }

    @ViewBuilder
    private func cellView(row: Int, column: Int, isHeader: Bool) -> some View {
        let coord = CellCoord(row: row, column: column)
        // Single-line `TextField` (no `axis: .vertical`) so the system
        // handles Tab/Shift+Tab focus traversal natively across cells —
        // SwiftUI walks the focus chain in source order, which for a
        // Grid-of-rows-of-cells is left-to-right then top-to-bottom,
        // exactly what we want. With axis: .vertical, Tab would insert
        // a literal tab character into the cell content instead.
        TextField("", text: cellBinding(row: row, column: column))
            .textFieldStyle(.plain)
            .font(.kstText(size: 13, weight: isHeader ? .semibold : .regular))
            .foregroundStyle(isHeader ? KstColor.ink0 : KstColor.ink1)
            .focused($focusedCell, equals: coord)
            .onSubmit { commit() }
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
            .contextMenu {
                Button("Insert row above") { insertRow(at: max(row, 0)); commit() }
                Button("Insert row below") { insertRow(at: max(row, -1) + 1); commit() }
                Button("Insert column before") { insertColumn(at: column); commit() }
                Button("Insert column after") { insertColumn(at: column + 1); commit() }
                Divider()
                if local.headers.isEmpty {
                    if !local.rows.isEmpty {
                        Button("Promote first row to header") { promoteFirstRowToHeader(); commit() }
                    }
                    Button("Add empty header row") { addEmptyHeader(); commit() }
                } else {
                    Button("Demote header to row") { demoteHeaderToRow(); commit() }
                    Button("Remove header row", role: .destructive) { removeHeader(); commit() }
                }
                Divider()
                if row >= 0 {
                    Button("Delete row", role: .destructive) { deleteRow(at: row); commit() }
                }
                Button("Delete column", role: .destructive) { deleteColumn(at: column); commit() }
            }
    }

    /// Binding that reads/writes the cell at `(row, column)` from the
    /// local mirror, where `row == -1` addresses the header. Writes
    /// don't immediately push to the store — that happens on
    /// `onSubmit` via `commit()` so a busy edit doesn't fire a write
    /// per keystroke.
    private func cellBinding(row: Int, column: Int) -> Binding<String> {
        Binding(
            get: {
                if row < 0 {
                    return column < local.headers.count ? local.headers[column] : ""
                }
                guard row < local.rows.count else { return "" }
                let r = local.rows[row]
                return column < r.count ? r[column] : ""
            },
            set: { newValue in
                ensureWidth(at: column)
                if row < 0 {
                    while local.headers.count <= column { local.headers.append("") }
                    local.headers[column] = newValue
                } else {
                    while local.rows.count <= row { local.rows.append([]) }
                    while local.rows[row].count <= column { local.rows[row].append("") }
                    local.rows[row][column] = newValue
                }
            }
        )
    }

    /// Pad header + every existing row out to at least `column + 1` so
    /// writes to a virtual cell at the end of a ragged row materialize
    /// the missing columns in place.
    private func ensureWidth(at column: Int) {
        while local.headers.count <= column { local.headers.append("") }
        for i in local.rows.indices {
            while local.rows[i].count <= column { local.rows[i].append("") }
        }
    }

    /// Push `local` to the store. Called on every structural op + on
    /// `onSubmit` of a TextField. The reducer is idempotent for
    /// no-op updates (it diffs the resulting JSON), so calling more
    /// often than strictly necessary is fine.
    private func commit() {
        store.send(.blockTableEdited(blockID: block.id, table: local))
    }

    // MARK: - Structural ops

    private func insertRow(at index: Int) {
        let width = max(columnCount, 1)
        let blank = Array(repeating: "", count: width)
        let clamped = max(0, min(index, local.rows.count))
        local.rows.insert(blank, at: clamped)
    }

    private func deleteRow(at index: Int) {
        guard index >= 0, index < local.rows.count else { return }
        local.rows.remove(at: index)
    }

    private func insertColumn(at index: Int) {
        let clamped = max(0, min(index, columnCount))
        if clamped <= local.headers.count {
            local.headers.insert("", at: clamped)
        } else {
            local.headers.append("")
        }
        for i in local.rows.indices {
            // Pad ragged rows out to the insertion point first so the
            // new column lands at the right index for every row.
            while local.rows[i].count < clamped { local.rows[i].append("") }
            local.rows[i].insert("", at: min(clamped, local.rows[i].count))
        }
    }

    private func deleteColumn(at index: Int) {
        if index < local.headers.count {
            local.headers.remove(at: index)
        }
        for i in local.rows.indices {
            if index < local.rows[i].count {
                local.rows[i].remove(at: index)
            }
        }
    }

    // MARK: - Header toggling

    /// Lift `rows[0]` into the header. Useful when the import didn't
    /// recognize the first row of a CSV-style table as a header.
    private func promoteFirstRowToHeader() {
        guard local.headers.isEmpty, let first = local.rows.first else { return }
        local.headers = first
        local.rows.removeFirst()
    }

    /// Push the existing header row down to be the table's first data
    /// row. Non-destructive opposite of `promoteFirstRowToHeader`.
    private func demoteHeaderToRow() {
        guard !local.headers.isEmpty else { return }
        local.rows.insert(local.headers, at: 0)
        local.headers = []
    }

    /// Add a blank header row when the table currently has no header
    /// at all. Width matches the widest existing data row.
    private func addEmptyHeader() {
        guard local.headers.isEmpty else { return }
        let width = max(columnCount, 1)
        local.headers = Array(repeating: "", count: width)
    }

    /// Drop the header row entirely. Destructive — used when the
    /// header content is junk and the user wants it gone rather than
    /// preserved as a data row.
    private func removeHeader() {
        local.headers = []
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
