import Foundation

#if canImport(MapKit)
import MapKit

/// `EnrichmentProvider` adapter around `VendorLookupService`. Behavior is
/// unchanged from the pre-refactor `VendorEnrichmentService`: confident
/// MapKit matches auto-apply, ambiguous results are skipped (the
/// in-detail lookup sheet handles those interactively), and only blank
/// fields get written.
@available(iOS 26.0, macOS 26.0, *)
struct MapKitVendorProvider: EnrichmentProvider {
    let databaseKey = "vendors"
    let triggerPropertyKey = "place_id"

    func isAvailable() async -> Bool { true }

    func enrich(record: EnrichmentRecord) async -> EnrichmentResult {
        let address = record.propertyValues["address"]
        let outcome = await VendorLookupService.enrich(
            name: record.title,
            address: address
        )
        switch outcome {
        case .resolved(let enrichment):
            return .resolved(Self.apply(from: enrichment))
        case .ambiguous(let candidates):
            return .ambiguous(candidates.map(Self.apply(from:)))
        case .notFound:
            return .notFound
        }
    }

    /// Project the MapKit-shaped `VendorEnrichment` into the generic
    /// `EnrichmentApply`. Only non-empty fields are forwarded so the
    /// service's blanks-only write logic doesn't have to second-guess.
    private static func apply(from enrichment: VendorEnrichment) -> EnrichmentApply {
        var updates: [String: String] = [:]
        let pairs: [(String, String?)] = [
            ("phone",    enrichment.phone),
            ("website",  enrichment.website),
            ("address",  enrichment.address),
            ("locality", enrichment.locality),
            ("kind",     enrichment.kind),
            ("place_id", enrichment.placeID),
        ]
        for (key, value) in pairs {
            guard let value, !value.isEmpty else { continue }
            updates[key] = value
        }
        return EnrichmentApply(
            propertyUpdates: updates,
            coverImageURL: nil,
            previewLabel: enrichment.address
        )
    }
}

#endif
