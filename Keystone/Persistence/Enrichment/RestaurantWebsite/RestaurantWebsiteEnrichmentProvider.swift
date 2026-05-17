import Foundation
import OSLog

private let log = Logger(subsystem: "Keystone", category: "Enrichment.RestaurantWebsite")

/// Second-pass enrichment that runs after `MapKitVendorProvider` has
/// populated `website` on a restaurant record. Fetches the restaurant's
/// own site, harvests a logo (apple-touch-icon → favicon → og:image),
/// and parses schema.org JSON-LD for hours, rating, price band, and a
/// menu URL.
///
/// **OpenStreetMap fallback**: when the website didn't yield hours
/// (the indie long tail where JSON-LD isn't published), we re-resolve
/// the record's coordinate via MapKit's stored `place_id`, then query
/// the public Overpass endpoint for a restaurant node within ~125m
/// whose name matches. OSM tags use their own `opening_hours` grammar
/// which we translate into the same compact text shape the JSON-LD
/// path produces. OSM data is ODbL — the Help doc credits OpenStreetMap
/// contributors.
///
/// The trigger property `web_enriched_at` is set on every run (success
/// or not) so non-restaurant vendors and dead-end restaurants don't get
/// re-scanned on every pass. The user can force a fresh scrape via the
/// existing "Re-enrich…" detail-view affordance (overwrite mode).
struct RestaurantWebsiteEnrichmentProvider: EnrichmentProvider {
    let databaseKey = "vendors"
    let triggerPropertyKey = "web_enriched_at"

    private static let priceRangeOptions: Set<String> = ["$", "$$", "$$$", "$$$$"]

    var scraper: RestaurantWebsiteScraper
    var overpass: OverpassClient
    /// Map a stored Apple Maps `place_id` back to a `(lat, lng)`
    /// coordinate. Injected so tests don't need MapKit on the wire.
    var resolveCoordinate: @Sendable (_ placeID: String) async -> (Double, Double)?

    init(
        scraper: RestaurantWebsiteScraper = .live,
        overpass: OverpassClient = .live,
        resolveCoordinate: @escaping @Sendable (String) async -> (Double, Double)? = Self.liveCoordinateResolver
    ) {
        self.scraper = scraper
        self.overpass = overpass
        self.resolveCoordinate = resolveCoordinate
    }

    func isAvailable() async -> Bool { true }

    func enrich(record: EnrichmentRecord) async -> EnrichmentResult {
        let kind = record.propertyValues["kind"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let websiteString = record.propertyValues["website"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let websiteURL = websiteString.flatMap { URL(string: $0) }

        // Mark non-restaurants / restaurants-without-a-website as done
        // so we don't re-check them every launch. Cheap idempotent op.
        guard kind == "restaurant", let websiteURL else {
            return .resolved(EnrichmentApply(propertyUpdates: [
                "web_enriched_at": nowISO()
            ]))
        }

        let result = await scraper.scrape(websiteURL: websiteURL)

        var updates: [String: String] = [
            "web_enriched_at": nowISO()
        ]
        if let hours = sanitizedHours(result.parsed.hours) {
            updates["hours"] = hours
        }
        if let rating = result.parsed.rating {
            updates["rating"] = formatRating(rating)
        }
        if let price = result.parsed.priceRange,
           Self.priceRangeOptions.contains(price) {
            updates["price_range"] = price
        }
        if let menu = result.parsed.menuURL?.absoluteString
            ?? result.probedMenuURL?.absoluteString,
           !menu.isEmpty {
            updates["menu_url"] = menu
        }

        // OSM fallback for hours when the website didn't carry them.
        // Only one of the two paths gets to write `hours`; the JSON-LD
        // result above always wins when present, since the restaurant's
        // own site is the freshest source.
        if updates["hours"] == nil,
           let placeID = record.propertyValues["place_id"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !placeID.isEmpty,
           let coord = await resolveCoordinate(placeID),
           let osm = await overpass.lookup(name: record.title,
                                           latitude: coord.0,
                                           longitude: coord.1),
           let rawHours = osm.openingHours,
           let formatted = sanitizedHours(OSMOpeningHoursParser.parse(rawHours))
        {
            log.info("\(record.title, privacy: .public): hours from OSM (\(osm.matchKind, privacy: .public))")
            updates["hours"] = formatted
        }

        let coverURL = persistLogoToTempFile(result.logo, record: record)
        if coverURL == nil, result.logo != nil {
            log.error("\(record.title, privacy: .public): logo present but temp-write failed")
        }

        return .resolved(EnrichmentApply(
            propertyUpdates: updates,
            coverImageURL: coverURL,
            previewLabel: nil
        ))
    }

    // MARK: - Helpers

    private func nowISO() -> String {
        AppDatabase.isoFormatter.string(from: Date())
    }

    /// Reject candidate hours strings that contain no letters or digits
    /// — pure punctuation like `", , , , , , "` is a known footgun from
    /// upstream sources that emit empty-string placeholder arrays, and
    /// it renders as visible garbage in the detail view. Returns nil
    /// for unusable input so callers fall back to the blanks-only path.
    private func sanitizedHours(_ candidate: String?) -> String? {
        guard let candidate else { return nil }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let hasContent = trimmed.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }
        return hasContent ? trimmed : nil
    }

    /// Format the rating as either an integer (4) or one decimal (4.3),
    /// matching the conventions used by other providers writing numeric
    /// properties through the text-value path.
    private func formatRating(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }

    /// Default coordinate resolver. Refreshes the MapKit place by its
    /// stored `place_id` and reads the `MKMapItem.location`. Returns
    /// nil when the place no longer exists, MapKit refuses to refresh,
    /// or we're below the iOS/macOS 26 deployment floor that the
    /// rest of the MapKit pipeline already requires.
    @Sendable
    static func liveCoordinateResolver(_ placeID: String) async -> (Double, Double)? {
        #if canImport(MapKit)
        if #available(iOS 26.0, macOS 26.0, *) {
            guard let item = await VendorLookupService.refresh(placeID: placeID) else { return nil }
            let coord = item.location.coordinate
            return (coord.latitude, coord.longitude)
        }
        #endif
        return nil
    }

    /// Write the validated logo bytes to a unique temp file and return
    /// the file:// URL `EnrichmentService` will pass to
    /// `CoverImageImporter.attachAsCover`. Returns nil on any I/O
    /// failure so the property updates still go through.
    private func persistLogoToTempFile(_ logo: RestaurantScrapeResult.LogoFile?, record: EnrichmentRecord) -> URL? {
        guard let logo else { return nil }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kst-restaurant-logo-\(UUID().uuidString).\(logo.fileExtension)")
        do {
            try logo.data.write(to: tempURL)
            return tempURL
        } catch {
            log.error("logo temp write failed for \(record.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
