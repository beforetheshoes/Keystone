import SwiftUI

/// Cover-size segmented control shown only when the active view is the
/// gallery. The selected size persists per-database via
/// `database_view_prefs.gallery_cover_size`.
struct GallerySizeControl: View {
    var size: GalleryCoverSize
    var onChange: (GalleryCoverSize) -> Void

    private struct Item: Identifiable {
        let id: GalleryCoverSize
        let symbol: String
    }
    private let items: [Item] = [
        Item(id: .small,  symbol: "square.grid.3x3"),
        Item(id: .medium, symbol: "square.grid.2x2"),
        Item(id: .large,  symbol: "square.grid.2x1"),
    ]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(items) { item in
                Button {
                    onChange(item.id)
                } label: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 11, weight: size == item.id ? .semibold : .medium))
                        .foregroundStyle(size == item.id ? KstColor.ink0 : KstColor.ink2)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(size == item.id ? KstColor.paper0 : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("\(item.id.rawValue.capitalized) covers")
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
