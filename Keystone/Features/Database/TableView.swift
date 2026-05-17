import SwiftUI

struct TableView: View {
    var db: DBRow
    var properties: [PropertyRow]
    var records: [RecordRow]
    /// Optional pre-bucketed groups. When empty (or carries a single
    /// ungrouped bucket), the table renders a flat list of rows with
    /// no section headers.
    var groups: [RecordGroup] = []
    var sortKey: String?
    var sortAscending: Bool
    var onOpen: (RecordRow) -> Void
    var onSort: (String) -> Void
    /// Tapping a relation cell calls this with the linked record's
    /// (databaseID, recordID). When nil or unwired, the row's primary
    /// `onOpen` is used instead.
    var onOpenRelation: ((_ databaseID: String, _ recordID: String) -> Void)? = nil
    /// Right-click on a column header calls this with (propertyID,
    /// new alignment) when the user picks one. Persistence is the
    /// caller's job (typically routes to `AppFeature.setColumnAlignment`).
    var onSetAlignment: ((_ propertyID: String, _ alignment: PropertyAlignment?) -> Void)? = nil
    /// Inline-edit hook: a cell's editor calls this with the record
    /// id, property key, and new value when the user changes a select
    /// / number / date / currency directly in the table. Wired to
    /// `AppFeature.updatePropertyValue` by the caller.
    var onUpdateValue: ((_ recordID: String, _ key: String, _ value: String) -> Void)? = nil
    /// Register a brand-new option on a select / multiSelect property.
    /// Wired to `AppFeature.addPropertyOption`. Used by the "Add new…"
    /// affordance on the editable cells; nil disables the feature.
    var onAddPropertyOption: ((_ propertyID: String, _ option: String) -> Void)? = nil
    /// Remove an option from a select / multiSelect property AND
    /// strip the value off every record that carries it. Wired to
    /// `AppFeature.removePropertyOption`. Surfaces in the multi-
    /// select popover as a hover-revealed trash icon per option.
    var onRemovePropertyOption: ((_ propertyID: String, _ option: String) -> Void)? = nil

    private let rowH: CGFloat = 34

    private static let columnWidths: [PropertyType: CGFloat] = [
        .title: 220, .select: 130, .date: 130, .dateTZ: 200, .text: 200, .number: 100,
        .currency: 110, .phone: 130, .email: 160, .relation: 160, .address: 220,
        // URL cells render an icon-only "open link" affordance. The
        // header still needs to fit its name on one line, so we
        // leave enough room for "Website" / "Menu" labels.
        .url: 90,
    ]

    /// Per-key width overrides for properties whose natural type-based
    /// width is wrong. The hours column needs extra room for the
    /// multi-window today summary ("9:00 AM – 3:00 PM, 5:00 PM –
    /// 7:00 PM"); the default `.text` width truncates it.
    private static let keyWidthOverrides: [String: CGFloat] = [
        "hours": 250,
    ]

    private func width(for prop: PropertyRow) -> CGFloat {
        if let override = Self.keyWidthOverrides[prop.key] { return override }
        return Self.columnWidths[prop.type] ?? 140
    }

    /// Maps our `PropertyAlignment` model to SwiftUI's frame alignment.
    /// Internal so `TableCell` (file-private) can use it.
    static func swiftUIAlignment(_ a: PropertyAlignment) -> Alignment {
        switch a {
        case .leading: return .leading
        case .center:  return .center
        case .right:   return .trailing
        }
    }

    static func swiftUITextAlignment(_ a: PropertyAlignment) -> TextAlignment {
        switch a {
        case .leading: return .leading
        case .center:  return .center
        case .right:   return .trailing
        }
    }

    /// Records are pre-sorted by `SortEngine` before they reach this
    /// view. Kept the property to avoid renames downstream.
    private var sortedRecords: [RecordRow] { records }

    var body: some View {
        GeometryReader { geo in
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                HStack(spacing: 0) {
                    Color.clear.frame(width: 36, height: 30)
                    ForEach(properties) { p in
                        Button(action: { onSort(p.key) }) {
                            HStack(spacing: 5) {
                                PropTypeIcon(type: p.type)
                                Text(p.name)
                                    .font(.kstText(size: 11, weight: .semibold))
                                    .tracking(0.2)
                                if sortKey == p.key {
                                    Image(systemName: "triangle.fill")
                                        .font(.system(size: 7))
                                        .rotationEffect(.degrees(sortAscending ? 0 : 180))
                                }
                            }
                            .foregroundStyle(sortKey == p.key ? KstColor.ink0 : KstColor.ink2)
                            .frame(width: width(for: p), height: 30, alignment: Self.swiftUIAlignment(p.resolvedAlignment))
                            .padding(.horizontal, 12)
                            .overlay(alignment: .trailing) {
                                Rectangle().fill(KstColor.ink4).frame(width: 0.5)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if let onSetAlignment {
                                Section("Alignment") {
                                    Button("Left")   { onSetAlignment(p.id, .leading) }
                                    Button("Center") { onSetAlignment(p.id, .center) }
                                    Button("Right")  { onSetAlignment(p.id, .right) }
                                    Divider()
                                    Button("Reset to default") { onSetAlignment(p.id, nil) }
                                }
                            }
                        }
                    }
                }
                .frame(height: 30)
                .background(KstColor.paper1)
                .overlay(alignment: .bottom) { KstHairline() }

                // Rows. Implemented as an HStack with `.onTapGesture`
                // rather than a `Button` because relation cells contain
                // their own tappable regions for navigating to the
                // related record. Apple's HIG explicitly says don't
                // nest `Button`s: on iOS inside a scrollable
                // `ScrollView([.horizontal, .vertical])` the gesture
                // resolver can fail to route taps to *either* button,
                // leaving rows visually unresponsive. With per-region
                // `.onTapGesture`, the inner cell's gesture takes
                // precedence inside its bounds and the row's gesture
                // handles everything else.
                let buckets: [RecordGroup] = groups.isEmpty
                    ? [RecordGroup(label: "", key: "", rows: sortedRecords)]
                    : groups
                ForEach(Array(buckets.enumerated()), id: \.offset) { _, bucket in
                    if !bucket.label.isEmpty {
                        GroupSectionHeader(label: bucket.label, count: bucket.rows.count)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(KstColor.paper0)
                    }
                    ForEach(bucket.rows) { r in
                        TableRowView(
                            record: r,
                            properties: properties,
                            rowHeight: rowH,
                            cellValue: { cellValue(for: $0, in: r) },
                            cellWidth: { width(for: $0) },
                            onOpen: { onOpen(r) },
                            onOpenRelation: onOpenRelation,
                            onUpdateValue: onUpdateValue.map { handler in
                                { key, value in handler(r.id, key, value) }
                            },
                            onAddPropertyOption: onAddPropertyOption,
                            onRemovePropertyOption: onRemovePropertyOption
                        )
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(KstColor.paper3).frame(height: 0.5)
                        }
                    }
                }

                HStack {
                    Text("+ New \(db.name.lowercased().hasSuffix("s") ? String(db.name.dropLast()).lowercased() : db.name.lowercased())")
                        .font(.kstText(size: 13))
                        .foregroundStyle(KstColor.ink3)
                }
                .frame(height: rowH)
                .padding(.horizontal, 36)
            }
            .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
        }
        .background(KstColor.paper0)
        }
    }

    private func cellValue(for prop: PropertyRow, in record: RecordRow) -> String {
        if prop.type == .title { return record.title }
        return record.values[prop.key] ?? ""
    }
}

/// One row in the database table. Owns its own hover state and routes
/// taps directly via `.onTapGesture` to dodge the
/// nested-Button-in-ScrollView gesture-resolution bug on iOS.
private struct TableRowView: View {
    let record: RecordRow
    let properties: [PropertyRow]
    let rowHeight: CGFloat
    let cellValue: (PropertyRow) -> String
    let cellWidth: (PropertyRow) -> CGFloat
    let onOpen: () -> Void
    let onOpenRelation: ((_ databaseID: String, _ recordID: String) -> Void)?
    let onUpdateValue: ((_ key: String, _ value: String) -> Void)?
    let onAddPropertyOption: ((_ propertyID: String, _ option: String) -> Void)?
    let onRemovePropertyOption: ((_ propertyID: String, _ option: String) -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            HStack { RecordAvatar(record: record, size: 18, radius: 5) }
                .frame(width: 36, height: rowHeight)
            ForEach(properties) { p in
                TableCell(
                    prop: p,
                    value: cellValue(p),
                    width: cellWidth(p),
                    relationTargets: record.relationTargets[p.key],
                    onOpenRelation: onOpenRelation,
                    onUpdateValue: onUpdateValue,
                    onAddPropertyOption: onAddPropertyOption,
                    onRemovePropertyOption: onRemovePropertyOption
                )
            }
        }
        .frame(height: rowHeight)
        .background(hovering ? KstColor.paper1 : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onOpen() }
    }
}

private struct TableCell: View {
    var prop: PropertyRow
    var value: String
    var width: CGFloat
    /// Set when this cell is for a `.relation` property and the record
    /// has at least one outgoing link bound to that property. Lets the
    /// cell route taps to the linked record instead of the row's own.
    var relationTargets: [RelationTarget]? = nil
    var onOpenRelation: ((_ databaseID: String, _ recordID: String) -> Void)? = nil
    /// Inline-edit hook. Editable cell variants (select, number, date,
    /// currency) call this with the property key + new value when the
    /// user changes them in place. Static cells (title, text, address)
    /// ignore it.
    var onUpdateValue: ((_ key: String, _ value: String) -> Void)? = nil
    /// Register a new option on the property when the user types a
    /// fresh value via the "Add new…" affordance on a select /
    /// multiSelect cell.
    var onAddPropertyOption: ((_ propertyID: String, _ option: String) -> Void)? = nil
    /// Remove an option from the property and strip it off every
    /// record. Surfaces in the multiSelect cell's popover as a
    /// hover-revealed trash icon per option.
    var onRemovePropertyOption: ((_ propertyID: String, _ option: String) -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            content
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: width - 24, alignment: TableView.swiftUIAlignment(prop.resolvedAlignment))
        }
        .frame(width: width, height: 34)
        .padding(.horizontal, 12)
        .overlay(alignment: .trailing) {
            Rectangle().fill(KstColor.paper3).frame(width: 0.5)
        }
    }

    @ViewBuilder
    private var content: some View {
        if prop.type == .relation,
           let targets = relationTargets,
           let first = targets.first,
           let onOpenRelation
        {
            // Per-cell tap gesture intercepts the relation-glyph hit,
            // navigating to the linked record. The row's outer
            // `.onTapGesture` still handles taps elsewhere on the row.
            // Multi-target relations (rare in current schema) jump to
            // the first target; the rest appear in the comma-joined
            // display value.
            Text(displayValue.isEmpty ? "—" : displayValue)
                .font(.kstText(size: 13))
                .foregroundStyle(displayValue.isEmpty ? KstColor.ink3 : KstColor.ink0)
                .underline(hovering, color: KstColor.ink2)
                .multilineTextAlignment(TableView.swiftUITextAlignment(prop.resolvedAlignment))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .onTapGesture {
                    onOpenRelation(first.databaseID, first.recordID)
                }
        } else if prop.type == .select, let onUpdate = onUpdateValue {
            // Inline-editable select tailored for table density:
            // - filled value: small cerulean badge (matches the
            //   read-only fallback below)
            // - empty value: subtle "—" with no pill chrome
            // - hover: chevron fades in as a hint that the cell is
            //   editable, no chevron when idle so the column stays
            //   quiet for a long list of rows
            //
            // We render the cell even when `config.options` is empty
            // — the "Add new…" affordance lets the user seed the
            // option list from the menu itself.
            TableSelectCell(
                value: value,
                options: prop.config.options ?? [],
                hovering: hovering,
                onPick: { onUpdate(prop.key, $0) },
                onAddOption: onAddPropertyOption.map { handler in
                    { newOption in handler(prop.id, newOption) }
                }
            )
            .onHover { hovering = $0 }
        } else if prop.type == .multiSelect, let onUpdate = onUpdateValue {
            // Inline-editable multiSelect: chip strip for current
            // values plus a popover with checkboxes + a "New tag…"
            // text input. Mirrors the detail view's `MultiSelectField`
            // popover but tightened for table density.
            TableMultiSelectCell(
                value: value,
                options: prop.config.options ?? [],
                hovering: hovering,
                onUpdate: { onUpdate(prop.key, $0) },
                onAddOption: onAddPropertyOption.map { handler in
                    { newOption in handler(prop.id, newOption) }
                },
                onDeleteOption: onRemovePropertyOption.map { handler in
                    { dead in handler(prop.id, dead) }
                }
            )
            .onHover { hovering = $0 }
        } else if prop.type == .select && !value.isEmpty && value != "—" {
            // Fallback: read-only select (e.g. a kind-scoped view with
            // no options config) renders the capsule unchanged.
            Text(SelectOptionDisplay.format(value))
                .font(.kstText(size: 11, weight: .medium))
                .foregroundStyle(KstColor.ceruleanInk)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(KstColor.ceruleanSoft)
                .clipShape(Capsule())
        } else if (prop.type == .number || prop.type == .currency),
                  let onUpdate = onUpdateValue {
            TableEditablePopoverField(
                value: value,
                display: displayValue,
                alignment: TableView.swiftUITextAlignment(prop.resolvedAlignment),
                useMonoFont: true,
                onCommit: { onUpdate(prop.key, $0) }
            )
        } else if prop.type == .date, let onUpdate = onUpdateValue {
            TableEditableDateCell(
                value: value,
                display: displayValue,
                onCommit: { onUpdate(prop.key, $0) }
            )
        } else if prop.type == .phone {
            // Tighter US-domestic display (strips a leading "+1 "
            // before showing) and `monospacedDigit` for clean column
            // alignment. The underlying stored value still carries the
            // country code so the detail view's tel: link works.
            Text(value.isEmpty ? "—" : PhoneValueCodec.displayUS(value))
                .font(.kstText(size: 13))
                .monospacedDigit()
                .foregroundStyle(value.isEmpty ? KstColor.ink3 : KstColor.ink1)
                .lineLimit(1)
        } else if prop.type == .url {
            // URL cells render as a small "open link" affordance —
            // the column is just a yes/no signal that there's a link
            // to follow. Clicking the icon raises the same
            // confirmation dialog the detail-view URL field uses so
            // a stray click doesn't yank the user out of Keystone
            // into the browser. The Button consumes the tap so it
            // never falls through to the row's `onTapGesture` (which
            // would open the record).
            if let url = URLValueCodec.normalize(value) {
                ConfirmedURLAction(
                    url: url,
                    prompt: "Open this link?",
                    detail: url.absoluteString,
                    primaryLabel: "Open"
                ) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(KstColor.ink2)
                        .contentShape(Rectangle())
                }
                .help(url.absoluteString)
            } else {
                Text("—")
                    .font(.kstText(size: 13))
                    .foregroundStyle(KstColor.ink3)
            }
        } else if prop.type == .title {
            Text(value)
                .font(.kstText(size: 13, weight: .medium))
                .foregroundStyle(KstColor.ink0)
                .multilineTextAlignment(TableView.swiftUITextAlignment(prop.resolvedAlignment))
        } else {
            Text(displayValue.isEmpty ? "—" : displayValue)
                .font(useMonoFont ? .kstMono(size: 13) : .kstText(size: 13))
                .monospacedDigit()
                .foregroundStyle(displayValue == "—" || displayValue.isEmpty ? KstColor.ink3 : KstColor.ink1)
                .multilineTextAlignment(TableView.swiftUITextAlignment(prop.resolvedAlignment))
        }
    }

    /// Numbers, currency, and phone numbers want monospaced digits so
    /// columns line up cleanly when right-aligned. `hours` doesn't
    /// need the full mono font — its today-padded summary uses
    /// figure-space (U+2007) leading padding, and `.monospacedDigit()`
    /// applied to the default proportional font already gives those
    /// figure spaces digit-width metrics. The visual effect is the
    /// same dash alignment, without the "code editor" look of a full
    /// monospaced font.
    private var useMonoFont: Bool {
        switch prop.type {
        case .number, .currency, .phone: return true
        default: return false
        }
    }

    private var displayValue: String {
        // Render canonical wire formats nicely:
        // - ISO dates → "Mar 14, 1989"
        // - Currency-formatted numbers → "$1,234.50"
        if prop.type == .date, let parsed = DateValueCodec.parse(value) {
            return DateValueCodec.display(parsed)
        }
        if prop.type == .dateTZ, let parsed = DateValueCodec.parseTZ(value) {
            return DateValueCodec.compactEventLocal(parsed)
        }
        if shouldFormatAsCurrency, let number = Double(value) {
            let code = prop.config.currencyCode ?? "USD"
            return Self.currencyFormatter(code: code).string(from: NSNumber(value: number)) ?? value
        }
        // Suppress comma-only / leading-comma garbage that earlier
        // enrichment passes wrote to text columns (most visible on
        // the Restaurants table's `hours` column). The launch-time
        // cleanup pass will null these out, but until that's run we
        // don't want the table to display them.
        if prop.type == .text, RestaurantHoursCleanupPass.looksLikeGarbage(value) {
            return ""
        }
        // Restaurant hours: collapse the full 7-day schedule down to
        // today's windows. The detail view shows the full week; in
        // the table this column is just "what are the hours right
        // now" — a long compact string is hard to scan and the
        // information past today isn't actionable at a glance.
        //
        // The padded variant left-pads the open time with figure
        // spaces (U+2007) so " 3:00 PM" and "11:00 AM" both render
        // 8 character-widths wide. Combined with the `.monospacedDigit()`
        // modifier on the cell's Text, this lines the en-dash up
        // in the same column on every row without resorting to a
        // structured HStack (which proved fragile when the column
        // was narrowed or hidden alongside other columns).
        if prop.key == "hours", let today = RestaurantHoursSummary.todayShortPadded(value) {
            return today
        }
        return value
    }

    /// True when this cell should render as currency. Honors:
    /// - `.currency` property type (always currency)
    /// - `.number` type with `format: "currency"` in config
    /// - `.number` type with key/name containing "cost" or "price"
    ///   (heuristic so existing `vehicle_maintenance.cost` columns get
    ///   the right treatment without an explicit migration). The
    ///   heuristic only fires when no explicit `format` is set.
    private var shouldFormatAsCurrency: Bool {
        if prop.type == .currency { return true }
        if let f = prop.config.format { return f == .currency }
        if prop.type == .number {
            let lowered = (prop.key + " " + prop.name).lowercased()
            if lowered.contains("cost") || lowered.contains("price") { return true }
        }
        return false
    }

    /// Cached per-currency-code formatter. Reusing an instance is much
    /// cheaper than constructing one for every cell.
    private static func currencyFormatter(code: String) -> NumberFormatter {
        if let cached = formatterCache[code] { return cached }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 2
        formatterCache[code] = f
        return f
    }

    nonisolated(unsafe) private static var formatterCache: [String: NumberFormatter] = [:]
}

// `RowHoverButtonStyle` was removed when row taps were switched from
// `Button` to `.onTapGesture` to fix a nested-Button gesture-routing
// bug on iOS — hover state lives on `TableRowView` directly now.

struct PropTypeIcon: View {
    var type: PropertyType
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(KstColor.ink3)
            .frame(width: 12, height: 12)
    }
    private var symbol: String {
        switch type {
        case .title:  "textformat"
        case .select: "circle.dashed"
        case .date:   "calendar"
        case .dateTZ: "calendar.badge.clock"
        case .address: "mappin.and.ellipse"
        case .number: "number"
        case .text:   "text.alignleft"
        case .phone:  "phone"
        case .email:  "envelope"
        case .relation: "link"
        case .url:    "link"
        case .checkbox: "checkmark.square"
        default:      "doc"
        }
    }
}

// MARK: - Inline editors

/// Click-to-edit popover for numeric / currency cells. Renders the
/// stored value as plain text by default; tapping the cell opens a
/// small popover with a `TextField` that commits on submit or on
/// dismiss. The popover-based pattern keeps the row layout tight
/// (the cell doesn't expand into an inline editor) while still
/// letting the user click straight from the table to change a value.
private struct TableEditablePopoverField: View {
    let value: String
    let display: String
    let alignment: TextAlignment
    let useMonoFont: Bool
    let onCommit: (String) -> Void

    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        Button {
            draft = value
            editing = true
        } label: {
            Text(display.isEmpty ? "—" : display)
                .font(useMonoFont ? .kstMono(size: 13) : .kstText(size: 13))
                .monospacedDigit()
                .foregroundStyle(display.isEmpty ? KstColor.ink3 : KstColor.ink1)
                .multilineTextAlignment(alignment)
                .frame(maxWidth: .infinity, alignment: swiftUIFrameAlignment)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $editing) {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(useMonoFont ? .kstMono(size: 13) : .kstText(size: 13))
                .frame(width: 110)
                .padding(8)
                .onSubmit(commit)
                // Commit on popover dismiss too so a click-outside
                // doesn't lose the user's typed change.
                .onDisappear(perform: commit)
        }
    }

    private var swiftUIFrameAlignment: Alignment {
        switch alignment {
        case .leading: return .leading
        case .center:  return .center
        case .trailing: return .trailing
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != value else { return }
        onCommit(trimmed)
    }
}

/// Quiet table-cell variant of the select editor. Visually:
/// - a filled value renders as a small cerulean badge (same look the
///   read-only fallback uses, so the column is consistent across
///   editable and read-only rows)
/// - an empty value renders as a plain "—" without any pill chrome
/// - a chevron-down hint appears only on hover so a long list of
///   rows isn't visually noisy with edit affordances on every cell
///
/// Tapping anywhere on the cell opens a Menu with the option list
/// plus a "Clear" item. Picking writes directly via `onPick`.
private struct TableSelectCell: View {
    let value: String
    let options: [String]
    let hovering: Bool
    let onPick: (String) -> Void
    /// Called when the user types a fresh value via the "Add new…"
    /// menu item. Nil disables the affordance.
    let onAddOption: ((String) -> Void)?

    @State private var promptingNew = false
    @State private var draftNew = ""

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    onPick(option)
                } label: {
                    if value == option {
                        Label(SelectOptionDisplay.format(option), systemImage: "checkmark")
                    } else {
                        Text(SelectOptionDisplay.format(option))
                    }
                }
            }
            if onAddOption != nil {
                if !options.isEmpty { Divider() }
                Button("Add new…") {
                    draftNew = ""
                    promptingNew = true
                }
            }
            if !value.isEmpty {
                Divider()
                Button("Clear", role: .destructive) { onPick("") }
            }
        } label: {
            HStack(spacing: 4) {
                if value.isEmpty {
                    Text("—")
                        .font(.kstText(size: 13))
                        .foregroundStyle(KstColor.ink3)
                } else {
                    Text(SelectOptionDisplay.format(value))
                        .font(.kstText(size: 11, weight: .medium))
                        .foregroundStyle(KstColor.ceruleanInk)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(KstColor.ceruleanSoft)
                        .clipShape(Capsule())
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(KstColor.ink3)
                    .opacity(hovering ? 0.6 : 0)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .popover(isPresented: $promptingNew) {
            AddOptionPopover(
                title: "New option",
                draft: $draftNew,
                onCommit: { trimmed in
                    onAddOption?(trimmed)
                    onPick(trimmed)
                    promptingNew = false
                },
                onCancel: { promptingNew = false }
            )
        }
    }
}

/// Compact "type a new option" popover shared by `TableSelectCell`
/// and `TableMultiSelectCell`'s direct-add affordance. Validates
/// against whitespace-only input via the Add button.
private struct AddOptionPopover: View {
    let title: String
    @Binding var draft: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.kstText(size: 11, weight: .semibold))
                .foregroundStyle(KstColor.ink2)
            HStack(spacing: 6) {
                TextField("", text: $draft, onCommit: commit)
                    .textFieldStyle(.roundedBorder)
                    .font(.kstText(size: 12))
                    .frame(width: 160)
                Button("Add", action: commit)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(12)
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
    }
}

/// Multi-select counterpart to `TableSelectCell`. Compact chip strip
/// (up to two chips + "+N") on the cell itself; tapping opens a
/// popover with a scrollable checkbox list of known options and a
/// "New tag…" field. New tags are added to both the record's value
/// AND the property's options list (via `onAddOption`), so the next
/// row's popover offers them as suggestions.
private struct TableMultiSelectCell: View {
    let value: String
    let options: [String]
    let hovering: Bool
    let onUpdate: (String) -> Void
    let onAddOption: ((String) -> Void)?
    let onDeleteOption: ((String) -> Void)?

    @State private var popoverOpen = false
    @State private var draftTag = ""
    @State private var hoveringOption: String? = nil
    @State private var pendingDelete: String? = nil

    private var tags: [String] { MultiSelectValue.decode(value) }

    private var knownOptions: [String] {
        var seen = Set<String>()
        return (options + tags).filter { seen.insert($0.lowercased()).inserted }
    }

    var body: some View {
        Button {
            popoverOpen = true
        } label: {
            HStack(spacing: 4) {
                if tags.isEmpty {
                    Text("—")
                        .font(.kstText(size: 13))
                        .foregroundStyle(KstColor.ink3)
                } else {
                    ForEach(tags.prefix(2), id: \.self) { tag in
                        Text(tag)
                            .font(.kstText(size: 10, weight: .medium))
                            .foregroundStyle(KstColor.ink0)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(KstColor.paper2)
                            .clipShape(Capsule())
                    }
                    if tags.count > 2 {
                        Text("+\(tags.count - 2)")
                            .font(.kstText(size: 10, weight: .medium))
                            .foregroundStyle(KstColor.ink3)
                            .padding(.leading, 2)
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(KstColor.ink3)
                    .opacity(hovering ? 0.6 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $popoverOpen) {
            popoverBody
                .padding(12)
                .frame(minWidth: 220, idealWidth: 240)
        }
    }

    private var trimmedDraft: String {
        draftTag.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Filter the option list by the search query so typing an
    /// existing tag's name finds it instead of letting the user
    /// blindly create a duplicate.
    private var filteredOptions: [String] {
        let q = trimmedDraft.lowercased()
        guard !q.isEmpty else { return knownOptions }
        return knownOptions.filter { $0.lowercased().contains(q) }
    }

    private var draftMatchesExistingOption: Bool {
        let q = trimmedDraft.lowercased()
        guard !q.isEmpty else { return false }
        return knownOptions.contains { $0.lowercased() == q }
    }

    @ViewBuilder
    private var popoverBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search or add tag…", text: $draftTag, onCommit: commitDraftOrToggleExact)
                .textFieldStyle(.roundedBorder)
                .font(.kstText(size: 12))
            if !filteredOptions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(filteredOptions, id: \.self) { option in
                            optionRow(option)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            if !trimmedDraft.isEmpty, !draftMatchesExistingOption {
                if !filteredOptions.isEmpty { Divider() }
                Button(action: commitDraft) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Add \"\(trimmedDraft)\"")
                            .font(.kstText(size: 13, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(KstColor.ceruleanInk)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .confirmationDialog(
            "Delete tag \"\(pendingDelete ?? "")\"?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { option in
            Button("Delete", role: .destructive) {
                onDeleteOption?(option)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("Removes the tag from this and every other record that has it.")
        }
    }

    @ViewBuilder
    private func optionRow(_ option: String) -> some View {
        let isOn = tags.contains { $0.caseInsensitiveCompare(option) == .orderedSame }
        let isHovering = hoveringOption == option
        HStack(spacing: 6) {
            Button {
                toggle(option)
                draftTag = ""
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOn ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13))
                        .foregroundStyle(isOn ? KstColor.ink0 : KstColor.ink3)
                    Text(option)
                        .font(.kstText(size: 13))
                        .foregroundStyle(KstColor.ink0)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if onDeleteOption != nil {
                Button {
                    pendingDelete = option
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(KstColor.ink3)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Delete this tag everywhere")
                .opacity(isHovering ? 1 : 0)
            }
        }
        .contentShape(Rectangle())
        .onHover { hoveringOption = $0 ? option : (hoveringOption == option ? nil : hoveringOption) }
    }

    private func toggle(_ option: String) {
        var next = tags
        if let idx = next.firstIndex(where: { $0.caseInsensitiveCompare(option) == .orderedSame }) {
            next.remove(at: idx)
        } else {
            next.append(option)
        }
        onUpdate(MultiSelectValue.encode(next))
    }

    /// Pressing Enter in the search field: pick an existing matching
    /// option if one exists, otherwise add the draft as a new tag.
    private func commitDraftOrToggleExact() {
        let trimmed = trimmedDraft
        guard !trimmed.isEmpty else { return }
        if let match = knownOptions.first(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            toggle(match)
            draftTag = ""
        } else {
            commitDraft()
        }
    }

    private func commitDraft() {
        let trimmed = trimmedDraft
        guard !trimmed.isEmpty else { return }
        var next = tags
        if !next.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            next.append(trimmed)
        }
        onUpdate(MultiSelectValue.encode(next))
        // Register the new tag as a property option so future records'
        // popovers offer it in the suggestion list.
        onAddOption?(trimmed)
        draftTag = ""
    }
}

/// Click-to-edit popover for date cells. Tapping the cell opens a
/// `.graphical` `DatePicker` plus Clear / Done buttons. Picking a
/// date commits immediately (the popover stays open so the user
/// can see the new value); Clear writes an empty string and closes.
private struct TableEditableDateCell: View {
    let value: String
    let display: String
    let onCommit: (String) -> Void

    @State private var editing = false
    @State private var picked = Date()

    var body: some View {
        Button {
            if let parsed = DateValueCodec.parse(value) {
                picked = parsed
            } else {
                picked = Date()
            }
            editing = true
        } label: {
            Text(display.isEmpty ? "—" : display)
                .font(.kstText(size: 13))
                .foregroundStyle(display.isEmpty ? KstColor.ink3 : KstColor.ink1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $editing) {
            VStack(spacing: 8) {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { picked },
                        set: { newDate in
                            picked = newDate
                            onCommit(DateValueCodec.iso(newDate))
                        }
                    ),
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                HStack {
                    Button("Clear") {
                        onCommit("")
                        editing = false
                    }
                    Spacer()
                    Button("Done") { editing = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
            .frame(width: 280)
        }
    }
}

