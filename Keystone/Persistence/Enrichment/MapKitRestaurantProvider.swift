import Foundation

#if canImport(MapKit)
import MapKit

/// `LookupProvider` variant of `MapKitVendorProvider` that filters
/// Apple Maps results down to food / drink POIs and pre-sets
/// `kind = "restaurant"` on the payload.
///
/// Registered under the lookup key `"restaurant"` (not `"vendors"`),
/// because the Restaurants sidebar entry is a *view* over vendors and
/// the same vendors database serves multiple "+ New" flavors. The
/// view's `presentation_json.lookupProvider` names this one.
@available(iOS 26.0, macOS 26.0, *)
struct MapKitRestaurantProvider: LookupProvider {
    /// The Restaurants view's `presentation_json.lookupProvider` value.
    /// Records created via this provider land in the `vendors`
    /// database — we just want the registry to route here when the
    /// view asks for "restaurant".
    let databaseKey = "restaurant"

    func isAvailable() async -> Bool { true }

    func searchCandidates(query: String) async -> [LookupCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.resultTypes = [.pointOfInterest]
        request.pointOfInterestFilter = MKPointOfInterestFilter(
            including: Array(VendorLookupService.foodAndDrinkCategories)
        )
        let search = MKLocalSearch(request: request)
        guard let response = try? await search.start() else { return [] }
        return response.mapItems.prefix(10).compactMap { item in
            guard let placeID = item.identifier?.rawValue else { return nil }
            let enrichment = VendorLookupService.extract(from: item)
            let apply = Self.apply(from: enrichment)
            let displayName = item.name ?? trimmed
            return LookupCandidate(
                id: placeID,
                title: displayName,
                subtitle: enrichment.address ?? enrichment.locality,
                coverURL: nil,
                apply: apply
            )
        }
    }

    /// Project the MapKit-shaped `VendorEnrichment` into an
    /// `EnrichmentApply` payload that forces `kind = "restaurant"`,
    /// even when MapKit's category mapper returned something more
    /// general. The Restaurants view's category filter has already
    /// narrowed the result set to food/drink venues, so this is the
    /// honest label for what the user picked.
    private static func apply(from enrichment: VendorEnrichment) -> EnrichmentApply {
        var updates: [String: String] = [:]
        let pairs: [(String, String?)] = [
            ("phone",    enrichment.phone),
            ("website",  enrichment.website),
            ("address",  enrichment.address),
            ("locality", enrichment.locality),
            ("place_id", enrichment.placeID),
        ]
        for (key, value) in pairs {
            guard let value, !value.isEmpty else { continue }
            updates[key] = value
        }
        updates["kind"] = "restaurant"
        return EnrichmentApply(
            propertyUpdates: updates,
            coverImageURL: nil,
            previewLabel: enrichment.address
        )
    }
}

#endif
