import SwiftUI

struct TableView: View {
    var db: DBRow
    var properties: [PropertyRow]
    var records: [RecordRow]
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

    private let rowH: CGFloat = 34

    private static let columnWidths: [PropertyType: CGFloat] = [
        .title: 220, .select: 130, .date: 130, .dateTZ: 200, .text: 200, .number: 100,
        .currency: 110, .phone: 140, .email: 160, .relation: 160,
    ]

    private func width(for prop: PropertyRow) -> CGFloat {
        Self.columnWidths[prop.type] ?? 140
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

    private var sortedRecords: [RecordRow] {
        guard let key = sortKey else { return records }
        return records.sorted { a, b in
            let av = (a.values[key] ?? a.title).lowercased()
            let bv = (b.values[key] ?? b.title).lowercased()
            return sortAscending ? av < bv : av > bv
        }
    }

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
                ForEach(sortedRecords) { r in
                    TableRowView(
                        record: r,
                        properties: properties,
                        rowHeight: rowH,
                        cellValue: { cellValue(for: $0, in: r) },
                        cellWidth: { width(for: $0) },
                        onOpen: { onOpen(r) },
                        onOpenRelation: onOpenRelation
                    )
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(KstColor.paper3).frame(height: 0.5)
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
                    onOpenRelation: onOpenRelation
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
        } else if prop.type == .select && !value.isEmpty && value != "—" {
            Text(value)
                .font(.kstText(size: 11, weight: .medium))
                .foregroundStyle(KstColor.ceruleanInk)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(KstColor.ceruleanSoft)
                .clipShape(Capsule())
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
    /// columns line up cleanly when right-aligned.
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
