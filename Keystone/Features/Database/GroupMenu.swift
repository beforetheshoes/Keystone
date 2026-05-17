import SwiftUI

/// Group-by affordance shown in `DatabaseDetailView`'s toolbar. Visible
/// in every view kind. Renders section headers in list / gallery /
/// table when active.
struct GroupMenu: View {
    var properties: [PropertyRow]
    var groupKey: String?
    var setGroupKey: (String?) -> Void

    private var groupableProperties: [PropertyRow] {
        properties.filter { p in
            switch p.type {
            case .select, .multiSelect, .status, .checkbox, .relation:
                return true
            case .text:
                // Locality ("City, ST") and similar short-string
                // columns make natural group buckets. Pure free-form
                // notes get ugly buckets but the user picks them
                // explicitly, so the noise is opt-in.
                return true
            case .address:
                // Buckets by parsed city, not the full address blob.
                // See `GroupEngine.bucketKeys`.
                return true
            default:
                return false
            }
        }
    }

    private var activeLabel: String {
        guard let groupKey else { return "Group" }
        if let p = properties.first(where: { $0.key == groupKey }) {
            return "Group: \(p.name)"
        }
        return "Group: \(groupKey)"
    }

    var body: some View {
        Menu {
            Button("None") {
                setGroupKey(nil)
            }
            if !groupableProperties.isEmpty { Divider() }
            ForEach(groupableProperties) { p in
                Button {
                    setGroupKey(p.key)
                } label: {
                    HStack {
                        Text(p.name)
                        if groupKey == p.key {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 10, weight: .semibold))
                Text(activeLabel)
                    .font(.kstText(size: 12, weight: groupKey == nil ? .medium : .semibold))
            }
            .foregroundStyle(groupKey == nil ? KstColor.ink2 : KstColor.ink0)
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
