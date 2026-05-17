import Foundation

#if canImport(MapKit)
import MapKit
import CoreLocation
import GeoToolbox

/// Set of fields a MapKit lookup can fill on a vendor record.
struct VendorEnrichment: Equatable {
    var phone: String?
    var website: String?
    var address: String?
    /// Compact "City, ST" string suitable for table-cell display. Sourced
    /// from `MKAddressRepresentations.cityWithContext(.short)`.
    var locality: String?
    var kind: String?
    var placeID: String?

    var isEmpty: Bool {
        phone == nil && website == nil && address == nil
            && locality == nil && kind == nil && placeID == nil
    }
}

/// Wraps the iOS/macOS 26 MapKit + GeoToolbox APIs we use to look up
/// vendor information from Apple Maps.
///
/// Three entry points:
/// - `refresh(placeID:)` — re-resolve a vendor we've previously
///   enriched. Uses the durable `MKMapItem.identifier` that `enrich`
///   records.
/// - `enrich(name:address:)` — first-time lookup for a vendor with at
///   least a name. Builds a `PlaceDescriptor` when an address is
///   present (high-confidence path); falls back to `MKLocalSearch` by
///   name otherwise.
/// - `searchAutocomplete(query:region:)` — interactive picker support
///   via `MKLocalSearchCompleter`.
@available(iOS 26.0, macOS 26.0, *)
enum VendorLookupService {

    // MARK: - Refresh from a stored Place ID

    /// Re-resolve a vendor from its previously-saved `place_id`.
    /// Returns `nil` if the place no longer exists in Apple Maps
    /// (rare — happens when a place permanently closes).
    static func refresh(placeID: String) async -> MKMapItem? {
        guard let identifier = MKMapItem.Identifier(rawValue: placeID) else { return nil }
        let request = MKMapItemRequest(mapItemIdentifier: identifier)
        do {
            return try await request.mapItem
        } catch {
            return nil
        }
    }

    // MARK: - First-time enrichment

    /// Enrich a vendor by name (and optional address). Strategy:
    ///
    /// 1. If `address` is non-empty, build a `PlaceDescriptor` from it
    ///    plus the name and ask `MKMapItemRequest` to resolve it. This
    ///    is the high-confidence path — Apple's matcher uses the
    ///    structured representation rather than full-text search.
    /// 2. Otherwise, fall back to `MKLocalSearch` with the name as the
    ///    query. We only auto-apply when there's an exact (case-
    ///    insensitive) name match in the top result; ambiguous matches
    ///    return `.ambiguous` so the caller can defer to the user.
    static func enrich(name: String, address: String?) async -> EnrichmentOutcome {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return .notFound }

        // Path 1: PlaceDescriptor when we have an address.
        if let address, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let descriptor = PlaceDescriptor(
                representations: [.address(address)],
                commonName: trimmedName
            )
            let request = MKMapItemRequest(placeDescriptor: descriptor)
            if let item = try? await request.mapItem {
                return .resolved(extract(from: item))
            }
            // Fall through to local search if PlaceDescriptor didn't resolve.
        }

        // Path 2: Local search by name.
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmedName
        request.resultTypes = [.pointOfInterest]
        let search = MKLocalSearch(request: request)
        guard let response = try? await search.start() else { return .notFound }
        let items = response.mapItems
        guard !items.isEmpty else { return .notFound }

        // Only auto-apply when the top result's name matches what we
        // asked for. "East Coast Honda" matching to a result named
        // "East Coast Honda Service" should still pass; exact
        // case-insensitive prefix is the bar.
        let top = items[0]
        let topName = (top.name ?? "").lowercased()
        let wanted = trimmedName.lowercased()
        if topName == wanted || topName.hasPrefix(wanted) {
            return .resolved(extract(from: top))
        }
        return .ambiguous(items.prefix(5).map(extract(from:)))
    }

    // MARK: - Autocomplete

    /// Wrapper for `MKLocalSearchCompleter` so callers can fire
    /// search-as-you-type without managing the delegate dance directly.
    /// Returns at most 10 completions per call.
    static func searchAutocomplete(query: String, region: MKCoordinateRegion? = nil) async -> [MKLocalSearchCompletion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            let coordinator = AutocompleteCoordinator(continuation: continuation)
            coordinator.start(query: trimmed, region: region)
        }
    }

    // MARK: - Result extraction

    /// Pull every MapKit field we care about into a `VendorEnrichment`.
    /// Suitable for direct application via `set-property` on the
    /// vendor record.
    static func extract(from item: MKMapItem) -> VendorEnrichment {
        var result = VendorEnrichment()
        result.placeID = item.identifier?.rawValue
        result.phone = item.phoneNumber
        result.website = item.url?.absoluteString
        result.address = formattedAddress(from: item)
        result.locality = compactLocality(from: item)
        result.kind = mapPOICategory(item.pointOfInterestCategory)
        return result
    }

    /// Pull a "Springfield, IL" / "Brooklyn, NY" / "Paris, France" string
    /// out of `MKAddressRepresentations`. Uses the `.short` context style,
    /// which Apple's docs describe as "the short context style" — for
    /// US addresses that's typically state-level disambiguation; for
    /// international, country.
    private static func compactLocality(from item: MKMapItem) -> String? {
        guard let reps = item.addressRepresentations,
              let value = reps.cityWithContext(.short) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Internals

    /// Read a single readable address line out of an `MKMapItem`,
    /// preferring the most-structured iOS/macOS 26 source available.
    /// Order of preference:
    ///
    /// 1. `MKAddress.fullAddress` — pre-formatted multi-line string,
    ///    what Apple Maps shows on the place card.
    /// 2. `MKAddressRepresentations.fullAddress(includingRegion:singleLine:)`
    ///    — composes from structured fields when `MKAddress` itself is
    ///    absent (some lookups return one but not the other).
    /// 3. `MKAddress.shortAddress` — street + city only, last resort.
    ///
    /// All three are iOS/macOS 26 surfaces; we don't fall back to the
    /// pre-26 deprecated `placemark` API since the entire enclosing type
    /// is already gated to 26+.
    private static func formattedAddress(from item: MKMapItem) -> String? {
        if let address = item.address {
            let full = address.fullAddress
            if !full.isEmpty { return full }
        }
        if let reps = item.addressRepresentations,
           let composed = reps.fullAddress(includingRegion: true, singleLine: false),
           !composed.isEmpty {
            return composed
        }
        if let address = item.address, let short = address.shortAddress, !short.isEmpty {
            return short
        }
        return nil
    }

    /// Map `MKPointOfInterestCategory` to one of the vendor `kind`
    /// select values we already use in the rest of the app. Unknown
    /// categories return `nil` so the migration leaves `kind` alone.
    private static func mapPOICategory(_ category: MKPointOfInterestCategory?) -> String? {
        guard let category else { return nil }
        if Self.foodAndDrinkCategories.contains(category) {
            return "restaurant"
        }
        switch category {
        // Auto / repair
        case .gasStation, .carRental, .evCharger:
            return "shop"
        case .automotiveRepair where true:
            return "shop"
        // Government
        case .police, .fireStation, .postOffice:
            return "government"
        // Financial / lender
        case .atm, .bank:
            return "lender"
        // Default mapping for anything else
        default:
            return nil
        }
    }

    /// POI categories the Restaurants view treats as "kind = restaurant".
    /// Used both by `mapPOICategory` (so freshly-enriched MapKit hits
    /// land with the right kind) and by `MapKitRestaurantProvider` when
    /// it filters local-search results to dining venues.
    static let foodAndDrinkCategories: Set<MKPointOfInterestCategory> = [
        .restaurant, .cafe, .bakery, .brewery, .winery, .distillery, .nightlife
    ]
}

/// Bridges `MKLocalSearchCompleter`'s delegate-based API to async/await.
/// One-shot — fires the continuation on the first delegate callback,
/// then tears down.
@available(iOS 26.0, macOS 26.0, *)
private final class AutocompleteCoordinator: NSObject, MKLocalSearchCompleterDelegate, @unchecked Sendable {
    private let continuation: CheckedContinuation<[MKLocalSearchCompletion], Never>
    private var completer: MKLocalSearchCompleter?
    private var didFire = false

    init(continuation: CheckedContinuation<[MKLocalSearchCompletion], Never>) {
        self.continuation = continuation
        super.init()
    }

    func start(query: String, region: MKCoordinateRegion?) {
        Task { @MainActor in
            let completer = MKLocalSearchCompleter()
            completer.delegate = self
            completer.resultTypes = [.pointOfInterest]
            if let region { completer.region = region }
            completer.queryFragment = query
            self.completer = completer
        }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        fire(with: Array(completer.results.prefix(10)))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        fire(with: [])
    }

    private func fire(with results: [MKLocalSearchCompletion]) {
        guard !didFire else { return }
        didFire = true
        completer?.cancel()
        completer = nil
        // `MKLocalSearchCompletion` isn't Sendable, but we're handing
        // ownership off here (one-shot, never touched again on this
        // side), so suppress the warning explicitly.
        nonisolated(unsafe) let payload = results
        continuation.resume(returning: payload)
    }
}

/// Outcome of `VendorLookupService.enrich`.
@available(iOS 26.0, macOS 26.0, *)
enum EnrichmentOutcome {
    /// Confident match — top result auto-applies.
    case resolved(VendorEnrichment)
    /// Multiple candidates without a clear winner. Caller should let
    /// the user pick from the candidate list.
    case ambiguous([VendorEnrichment])
    /// No candidates at all. Vendor is probably small/local and not in
    /// MapKit's database (e.g., a private seller).
    case notFound
}
#endif
