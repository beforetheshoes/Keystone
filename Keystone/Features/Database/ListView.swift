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
                    Text(meta).font(.kstText(size: 11.5)).foregroundStyle(KstColor.ink2)
                }
                Spacer(minLength: 0)
                if let dateValue {
                    Text(dateValue).font(.kstMono(size: 11)).foregroundStyle(KstColor.ink3)
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

    private var meta: String {
        properties.dropFirst().prefix(2)
            .compactMap { p -> String? in
                let v = record.values[p.key] ?? ""
                return (v.isEmpty || v == "—") ? nil : v
            }
            .joined(separator: " · ")
    }
    private var dateValue: String? {
        if let prop = properties.first(where: { $0.type == .date || $0.type == .dateTZ }) {
            let raw = record.values[prop.key] ?? ""
            guard !raw.isEmpty else { return nil }
            if prop.type == .dateTZ, let parsed = DateValueCodec.parseTZ(raw) {
                return DateValueCodec.compactEventLocal(parsed)
            }
            return raw
        }
        return nil
    }
}
