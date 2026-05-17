import Foundation
import OSLog

private let log = Logger(subsystem: "Keystone", category: "Enrichment.Overpass")

/// Subset of OpenStreetMap restaurant tags we read off an Overpass
/// element. Other tags (cuisine, wheelchair, etc.) are intentionally
/// omitted — we only mine OSM for fields the website scrape didn't
/// supply.
struct OSMRestaurantTags: Equatable, Sendable {
    var openingHours: String?
    var website: String?
    var phone: String?
    /// Confidence-of-match label for logging — `"name+amenity"` for an
    /// exact name + amenity hit, `"amenity-only"` for a coordinate
    /// match without a name match. Surfaced for debugging only.
    var matchKind: String
}

/// Network surface for the Overpass query. Production wires
/// `LiveOverpassHTTP`; tests inject a stub that returns canned JSON.
protocol OverpassHTTP: Sendable {
    func post(query: String) async -> Data?
}

/// Reads restaurant tags from a public OpenStreetMap Overpass instance
/// at https://overpass-api.de/api/interpreter, scoped to a tight
/// bounding box around a known coordinate so each query stays under
/// the fair-use envelope (<<10,000/day, <<1GB/day per IP).
///
/// **Licensing**: OSM data is ODbL. We treat the tags we read here as
/// derived data and surface "Hours via OpenStreetMap contributors" in
/// the Help documentation as attribution. We don't redistribute raw
/// OSM rows — just consume specific fields into the user's local
/// records.
struct OverpassClient: Sendable {
    var http: any OverpassHTTP

    static let live = OverpassClient(http: LiveOverpassHTTP())

    /// Search a small box around `coordinate` for a restaurant whose
    /// name fuzzy-matches `name`. The bounding box defaults to ~250m
    /// per side, which comfortably covers GPS jitter while keeping
    /// the candidate pool tractable. Returns nil if the call fails or
    /// nothing matches.
    func lookup(name: String, latitude: Double, longitude: Double,
                halfSideMeters: Double = 125) async -> OSMRestaurantTags? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else { return nil }

        let bbox = boundingBox(latitude: latitude, longitude: longitude,
                               halfSideMeters: halfSideMeters)
        let query = Self.query(name: trimmedName, bbox: bbox)
        guard let data = await http.post(query: query) else { return nil }
        guard let elements = parseElements(data) else { return nil }

        return pickBest(elements: elements, requestedName: trimmedName)
    }

    /// Build the Overpass QL query. We ask for nodes AND ways
    /// (restaurants are sometimes mapped as building footprints) tagged
    /// as eating/drinking amenities or cuisine-aware shops. The
    /// `~"^foo$",i` regex is case-insensitive prefix-ish match; the
    /// final candidate selection in `pickBest` re-scores by name
    /// proximity.
    static func query(name: String, bbox: (south: Double, west: Double, north: Double, east: Double)) -> String {
        let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
        // `[bbox:s,w,n,e]` is the global bounding box; `[out:json]`
        // returns parseable JSON; `[timeout:15]` keeps a slow query
        // from blocking the enrichment pass.
        return """
        [out:json][timeout:15][bbox:\(bbox.south),\(bbox.west),\(bbox.north),\(bbox.east)];
        (
          nwr[amenity~"^(restaurant|cafe|bar|pub|fast_food|food_court|ice_cream|biergarten)$"][name~"\(escaped)",i];
          nwr[shop~"^(bakery|coffee|pastry|deli|confectionery)$"][name~"\(escaped)",i];
        );
        out tags center 5;
        """
    }

    /// Approximate ~halfSideMeters as a lat/lng delta. Good enough at
    /// any non-polar latitude — we're after a few hundred meters, not
    /// surveying continents.
    private func boundingBox(latitude: Double, longitude: Double, halfSideMeters: Double)
        -> (south: Double, west: Double, north: Double, east: Double)
    {
        let metersPerDegLat = 111_320.0
        let dLat = halfSideMeters / metersPerDegLat
        let dLng = halfSideMeters / (metersPerDegLat * max(cos(latitude * .pi / 180), 0.01))
        return (latitude - dLat, longitude - dLng, latitude + dLat, longitude + dLng)
    }

    // MARK: - JSON parsing

    private struct Element: Decodable {
        let id: Int
        let type: String
        let tags: [String: String]?
    }

    private struct Response: Decodable {
        let elements: [Element]
    }

    private func parseElements(_ data: Data) -> [Element]? {
        do {
            return try JSONDecoder().decode(Response.self, from: data).elements
        } catch {
            log.error("Overpass parse failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Pick the closest-named element from the candidate set. Exact
    /// case-insensitive match wins; otherwise the lowest case-folded
    /// Levenshtein-ish prefix score; otherwise nil so we don't write
    /// hours from an obviously-wrong restaurant that happened to be
    /// in the bounding box.
    private func pickBest(elements: [Element], requestedName: String) -> OSMRestaurantTags? {
        let wanted = requestedName.lowercased()
        let candidates: [(score: Int, tags: [String: String])] = elements.compactMap { el in
            guard let tags = el.tags, let name = tags["name"]?.lowercased() else { return nil }
            if name == wanted { return (0, tags) }
            if name.hasPrefix(wanted) || wanted.hasPrefix(name) { return (1, tags) }
            if name.contains(wanted) || wanted.contains(name) { return (2, tags) }
            return nil
        }
        guard let best = candidates.min(by: { $0.score < $1.score }) else { return nil }
        return OSMRestaurantTags(
            openingHours: best.tags["opening_hours"],
            website: best.tags["website"]
                ?? best.tags["contact:website"],
            phone: best.tags["phone"] ?? best.tags["contact:phone"],
            matchKind: best.score == 0 ? "name+amenity" : "name-fuzzy"
        )
    }
}

// MARK: - Live HTTP

/// POSTs the Overpass query to the public endpoint with a short
/// timeout. POST is preferred over GET because the query string can
/// exceed URL length limits when restaurant names are long.
struct LiveOverpassHTTP: OverpassHTTP {
    static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!

    func post(query: String) async -> Data? {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 18)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Identify ourselves so the public Overpass operators can
        // contact the maintainer if our traffic pattern misbehaves.
        request.setValue("Keystone/1.0 (https://github.com/ryanleewilliams)", forHTTPHeaderField: "User-Agent")
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")".data(using: .utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            log.error("Overpass POST failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
