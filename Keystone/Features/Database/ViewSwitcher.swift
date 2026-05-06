import SwiftUI

struct ViewSwitcher: View {
    var selected: ViewKind
    var setView: (ViewKind) -> Void

    private let items: [(kind: ViewKind, label: String, system: String)] = [
        (.table,     "Table",     "tablecells"),
        (.gallery,   "Gallery",   "rectangle.grid.2x2"),
        (.list,      "List",      "list.bullet"),
        (.dashboard, "Dashboard", "rectangle.split.3x1"),
    ]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(items, id: \.kind) { it in
                Button(action: { setView(it.kind) }) {
                    HStack(spacing: 5) {
                        Image(systemName: it.system)
                            .font(.system(size: 10, weight: .medium))
                        Text(it.label)
                    }
                    .font(.kstText(size: 12, weight: selected == it.kind ? .semibold : .medium))
                    .foregroundStyle(selected == it.kind ? KstColor.ink0 : KstColor.ink2)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(selected == it.kind ? KstColor.paper0 : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .modifier(SelectedTabShadow(active: selected == it.kind))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(KstColor.paper1)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
    }
}

private struct SelectedTabShadow: ViewModifier {
    var active: Bool
    func body(content: Content) -> some View {
        if active { AnyView(content.kstShadow1()) }
        else { AnyView(content) }
    }
}
