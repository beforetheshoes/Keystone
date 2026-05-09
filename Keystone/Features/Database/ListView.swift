import SwiftUI

struct ListView: View {
    var db: DBRow
    var properties: [PropertyRow]
    var records: [RecordRow]
    var onOpen: (RecordRow) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(records) { r in
                    ListRow(properties: properties, record: r) { onOpen(r) }
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(KstColor.paper3).frame(height: 0.5)
                        }
                }
            }
        }
        .background(KstColor.paper0)
    }
}

private struct ListRow: View {
    var properties: [PropertyRow]
    var record: RecordRow
    var onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                RecordAvatar(record: record, size: 26, radius: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title).font(.kstText(size: 13.5, weight: .semibold)).foregroundStyle(KstColor.ink0)
                    if !meta.isEmpty {
                        Text(meta).font(.kstText(size: 11.5)).foregroundStyle(KstColor.ink2)
                    }
                }
                Spacer(minLength: 0)
                if let dateValue {
                    // Use the same body font as the meta line so the
                    // date doesn't clash visually with the rest of the
                    // row — monospace for date values that are already
                    // human-formatted is misleading.
                    Text(dateValue).font(.kstText(size: 11.5)).foregroundStyle(KstColor.ink3)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? KstColor.paper1 : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// Property keys already covered by `dateValue` on the right side
    /// of the row — exclude them from the meta strip so we don't show
    /// the same field twice.
    private var dateKeysOnRight: Set<String> {
        guard let anchor = anchorDateProperty else { return [] }
        var keys: Set<String> = [anchor.key]
        if let endKey = CalendarEventBuilder.pairedEndKey(for: anchor, in: properties) {
            keys.insert(endKey)
        }
        return keys
    }

    private var anchorDateProperty: PropertyRow? {
        properties.first { $0.type == .date || $0.type == .dateTZ }
    }

    private var meta: String {
        properties.dropFirst()
            .filter { $0.type != .relation && !dateKeysOnRight.contains($0.key) }
            .prefix(2)
            .compactMap { p -> String? in
                let v = record.values[p.key] ?? ""
                return (v.isEmpty || v == "—") ? nil : v
            }
            .joined(separator: " · ")
    }

    /// Right-edge label. When the anchor date property has a paired
    /// end (trips' `start_date`+`end_date`, lodging's `check_in`+
    /// `check_out`, …), renders the full range: "Aug 20 – Aug 25, 2026".
    /// Otherwise falls back to a single human-formatted date.
    private var dateValue: String? {
        guard let anchor = anchorDateProperty else { return nil }
        let rawStart = record.values[anchor.key] ?? ""
        let endKey = CalendarEventBuilder.pairedEndKey(for: anchor, in: properties)
        let rawEnd = endKey.flatMap { record.values[$0] } ?? ""

        switch anchor.type {
        case .date:
            return formatPlainRange(start: rawStart, end: rawEnd)
        case .dateTZ:
            return formatTZRange(start: rawStart, end: rawEnd)
        default:
            return nil
        }
    }

    private func formatPlainRange(start: String, end: String) -> String? {
        let s = DateValueCodec.parse(start)
        let e = DateValueCodec.parse(end)
        switch (s, e) {
        case let (s?, e?) where Calendar.current.isDate(s, inSameDayAs: e):
            return DateValueCodec.display(s)
        case let (s?, e?):
            return "\(DateValueCodec.display(s)) – \(DateValueCodec.display(e))"
        case let (s?, nil):
            return DateValueCodec.display(s)
        case let (nil, e?):
            return DateValueCodec.display(e)
        case (nil, nil):
            return nil
        }
    }

    private func formatTZRange(start: String, end: String) -> String? {
        let s = DateValueCodec.parseTZ(start)
        let e = DateValueCodec.parseTZ(end)
        switch (s, e) {
        case let (s?, e?):
            return "\(DateValueCodec.compactEventLocal(s)) – \(DateValueCodec.compactEventLocal(e))"
        case let (s?, nil):
            return DateValueCodec.compactEventLocal(s)
        case let (nil, e?):
            return DateValueCodec.compactEventLocal(e)
        case (nil, nil):
            return nil
        }
    }
}
