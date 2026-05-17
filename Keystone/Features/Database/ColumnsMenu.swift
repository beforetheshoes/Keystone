import SwiftUI

/// Toolbar Menu that lets the user toggle which columns appear in
/// the table view. Mirrors the visual treatment of `SortMenu` /
/// `GroupMenu` so the toolbar reads as a row of peer controls.
///
/// The title column is excluded — it's always shown (every record
/// needs *some* anchor in the table). Selection is persisted via
/// `database_view_prefs.hidden_columns_json`.
struct ColumnsMenu: View {
    var properties: [PropertyRow]
    var hidden: Set<String>
    /// `toggle(key, hidden)` — hidden is the desired new state.
    var toggle: (_ key: String, _ hidden: Bool) -> Void

    private var hiddenCount: Int {
        properties.filter { $0.type != .title && hidden.contains($0.key) }.count
    }

    private var label: String {
        hiddenCount == 0
            ? "Columns"
            : "Columns (\(hiddenCount) hidden)"
    }

    var body: some View {
        Menu {
            ForEach(properties.filter { $0.type != .title }) { p in
                let isHidden = hidden.contains(p.key)
                Button {
                    toggle(p.key, !isHidden)
                } label: {
                    HStack {
                        Text(p.name)
                        if !isHidden {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            if hiddenCount > 0 {
                Divider()
                Button("Show all columns") {
                    for p in properties where hidden.contains(p.key) {
                        toggle(p.key, false)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.kstText(size: 12, weight: hiddenCount == 0 ? .medium : .semibold))
            }
            .foregroundStyle(hiddenCount == 0 ? KstColor.ink2 : KstColor.ink0)
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
