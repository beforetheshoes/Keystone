import SwiftUI

/// Sort affordance shown in `DatabaseDetailView`'s toolbar. Available in
/// every view kind, not just table — the table column-header tap still
/// dispatches `toggleSort` and lights this menu up the same way.
struct SortMenu: View {
    var properties: [PropertyRow]
    var sortKey: String?
    var sortAscending: Bool
    var onSort: (String) -> Void
    var onSetAscending: (Bool) -> Void
    var onClear: () -> Void

    private var sortableProperties: [PropertyRow] {
        properties.filter { p in
            switch p.type {
            case .title, .text, .number, .currency, .date, .dateTZ, .dateRange,
                 .select, .multiSelect, .status, .checkbox, .email,
                 .phone, .url, .duration:
                return true
            default:
                return false
            }
        }
    }

    private var activeLabel: String {
        guard let sortKey else { return "Sort" }
        if sortKey == "title" { return "Sort: Title" }
        if let p = properties.first(where: { $0.key == sortKey }) {
            return "Sort: \(p.name)"
        }
        return "Sort: \(sortKey)"
    }

    var body: some View {
        Menu {
            ForEach(sortableProperties) { p in
                Button {
                    onSort(p.key)
                } label: {
                    HStack {
                        Text(p.name)
                        if sortKey == p.key {
                            Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        }
                    }
                }
            }
            if sortKey != nil {
                Divider()
                Button(sortAscending ? "Descending" : "Ascending") {
                    onSetAscending(!sortAscending)
                }
                Button("Clear sort", role: .destructive, action: onClear)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                Text(activeLabel)
                    .font(.kstText(size: 12, weight: sortKey == nil ? .medium : .semibold))
                if sortKey != nil {
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(sortKey == nil ? KstColor.ink2 : KstColor.ink0)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(KstColor.paper1)
            .overlay(
                RoundedRectangle(cornerRadius: KstRadius.r2, style: .continuous)
                    .strokeBorder(KstColor.ink4, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: KstRadius.r2, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
