import SwiftUI

#if canImport(MapKit)
import MapKit

/// Compact map preview for a vendor record. Resolves the stored
/// `place_id` to a fresh `MKMapItem` (so renames/moves track Apple's
/// latest data) and renders a static map tile plus an "Open in Maps"
/// button that hands off to the Maps app.
///
/// Re-resolves on `place_id` change so swapping vendors via the picker
/// produces the right tile without holding a stale reference.
@available(iOS 26.0, macOS 26.0, *)
struct VendorMapPreview: View {
    let placeID: String

    @State private var mapItem: MKMapItem?
    @State private var loading: Bool = true
    @State private var failedLookup: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            mapBody
            if let item = mapItem {
                HStack(spacing: 8) {
                    Button(action: { _ = item.openInMaps() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Open in Maps")
                                .font(.kstText(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(KstColor.ink0)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(KstColor.paper2)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
        }
        .task(id: placeID) {
            await resolve()
        }
    }

    @ViewBuilder
    private var mapBody: some View {
        if let item = mapItem {
            Map(initialPosition: .item(item)) {
                Marker(item: item)
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(KstColor.ink4, lineWidth: 0.5)
            )
            .allowsHitTesting(false)
        } else if loading {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(KstColor.paper2)
                .frame(height: 160)
                .overlay(ProgressView().controlSize(.small))
        } else if failedLookup {
            // Place ID couldn't be resolved (rare — happens when a place
            // permanently closes in Apple Maps' database). Don't take up
            // visual space; let the user re-look-up if they care.
            EmptyView()
        }
    }

    private func resolve() async {
        loading = true
        let item = await VendorLookupService.refresh(placeID: placeID)
        await MainActor.run {
            self.mapItem = item
            self.failedLookup = (item == nil)
            self.loading = false
        }
    }
}

#endif
