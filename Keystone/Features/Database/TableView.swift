import SwiftUI

struct TableView: View {
    var db: DBRow
    var properties: [PropertyRow]
    var records: [RecordRow]
    var sortKey: String?
    var sortAscending: Bool
    var onOpen: (RecordRow) -> Void
    var onSort: (String) -> Void

    private let rowH: CGFloat = 34

    private static let columnWidths: [PropertyType: CGFloat] = [
        .title: 220, .select: 130, .date: 130, .text: 200, .number: 100,
        .phone: 140, .email: 160, .relation: 160,
    ]

    private func width(for prop: PropertyRow) -> CGFloat {
        Self.columnWidths[prop.type] ?? 140
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
                            .frame(width: width(for: p), height: 30, alignment: .leading)
                            .padding(.horizontal, 12)
                            .overlay(alignment: .trailing) {
                                Rectangle().fill(KstColor.ink4).frame(width: 0.5)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(height: 30)
                .background(KstColor.paper1)
                .overlay(alignment: .bottom) { KstHairline() }

                // Rows
                ForEach(sortedRecords) { r in
                    Button(action: { onOpen(r) }) {
                        HStack(spacing: 0) {
                            HStack { RecordAvatar(record: r, size: 18, radius: 5) }
                                .frame(width: 36, height: rowH)
                            ForEach(properties) { p in
                                TableCell(prop: p, value: cellValue(for: p, in: r), width: width(for: p))
                            }
                        }
                        .frame(height: rowH)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowHoverButtonStyle())
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

private struct TableCell: View {
    var prop: PropertyRow
    var value: String
    var width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            content
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: width - 24, alignment: .leading)
        }
        .frame(width: width, height: 34)
        .padding(.horizontal, 12)
        .overlay(alignment: .trailing) {
            Rectangle().fill(KstColor.paper3).frame(width: 0.5)
        }
    }

    @ViewBuilder
    private var content: some View {
        if prop.type == .select && !value.isEmpty && value != "—" {
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
        } else {
            Text(displayValue.isEmpty ? "—" : displayValue)
                .font(prop.type == .number || prop.type == .phone ? .kstMono(size: 13) : .kstText(size: 13))
                .monospacedDigit()
                .foregroundStyle(displayValue == "—" || displayValue.isEmpty ? KstColor.ink3 : KstColor.ink1)
        }
    }

    private var displayValue: String {
        // Render canonical wire formats nicely (ISO dates → "Mar 14, 1989").
        if prop.type == .date, let parsed = DateValueCodec.parse(value) {
            return DateValueCodec.display(parsed)
        }
        return value
    }
}

struct RowHoverButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering ? KstColor.paper1 : .clear)
            .onHover { hovering = $0 }
    }
}

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
