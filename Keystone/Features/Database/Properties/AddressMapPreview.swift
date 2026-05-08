import SwiftUI

#if canImport(MapKit)
import MapKit
import CoreLocation

/// Read-only inline map snippet for an `address` property. Mirrors
/// `VendorMapPreview` but takes an `AddressValue` rather than a
/// vendor-specific place_id.
///
/// - When `placeID` is set, re-resolves via `VendorLookupService.refresh`
///   and renders an `MKMapItem`-anchored map (so renames/moves track
///   Apple's latest data, same as the vendor preview).
/// - When only lat/lon are set, renders a region-centered map with a
///   marker.
/// - Otherwise renders nothing — free-form addresses don't auto-geocode
///   to avoid network on every render.
@available(iOS 26.0, macOS 26.0, *)
struct AddressMapPreview: View {
    let address: AddressValue

    @State private var resolvedItem: MKMapItem?
    @State private var loading: Bool = false

    var body: some View {
        Group {
            if let item = resolvedItem {
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
            } else if let lat = address.lat, let lon = address.lon {
                let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                let region = MKCoordinateRegion(
                    center: coord,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                )
                Map(initialPosition: .region(region)) {
                    Marker(coordinate: coord) { Text(address.display) }
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
            } else {
                EmptyView()
            }
        }
        .task(id: address.placeID ?? "") {
            await resolve()
        }
    }

    private func resolve() async {
        guard let placeID = address.placeID, !placeID.isEmpty else { return }
        loading = true
        let item = await VendorLookupService.refresh(placeID: placeID)
        await MainActor.run {
            self.resolvedItem = item
            self.loading = false
        }
    }
}

#endif
