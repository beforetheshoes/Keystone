import Foundation

/// Tolerant decoder for schema.org JSON-LD blocks that describe a
/// restaurant. Restaurant websites publish a `<script type="application/
/// ld+json">` element with one of the food-service `@type`s; this parser
/// pulls out the fields Keystone cares about (hours, rating, price band,
/// menu URL) and hands back a normalized struct.
///
/// JSON-LD in the wild is messier than the spec: `@graph` wrappers are
/// common, `@type` is sometimes an array, `dayOfWeek` can be a single
/// string or an array, and the `opens` / `closes` values vary between
/// `"11:00"`, `"11:00:00"`, and `"23:00:00-05:00"`. The parser absorbs
/// those variants rather than rejecting them.
enum SchemaOrgLDParser {
    /// Parsed view of the fields we extract. All optional — missing
    /// values stay nil rather than throwing, so a partially-populated
    /// JSON-LD block still yields something useful.
    struct Parsed: Equatable, Sendable {
        var hours: String?
        var rating: Double?
        var priceRange: String?
        var menuURL: URL?
    }

    /// Restaurant-ish `@type` values worth opening up. The JSON-LD spec
    /// has a long lineage tree under `FoodEstablishment`; this list is
    /// the practical subset that real restaurant sites use.
    static let restaurantTypes: Set<String> = [
        "Restaurant",
        "FoodEstablishment",
        "CafeOrCoffeeShop",
        "BarOrPub",
        "FastFoodRestaurant",
        "LocalBusiness",
        "Bakery",
        "Brewery",
        "Winery",
        "IceCreamShop",
    ]

    /// Parse one or more raw JSON-LD documents and merge their findings.
    /// The first non-nil value for each field wins, which mirrors how
    /// browsers and search engines treat multi-block pages.
    static func parse(jsonStrings: [String]) -> Parsed {
        var merged = Parsed()
        for json in jsonStrings {
            guard let data = json.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { continue }
            for node in flatten(raw) {
                guard isRestaurantNode(node) else { continue }
                let partial = parseRestaurantNode(node)
                if merged.hours == nil      { merged.hours      = partial.hours }
                if merged.rating == nil     { merged.rating     = partial.rating }
                if merged.priceRange == nil { merged.priceRange = partial.priceRange }
                if merged.menuURL == nil    { merged.menuURL    = partial.menuURL }
            }
        }
        return merged
    }

    // MARK: - Tree walking

    /// Expand `@graph` wrappers and top-level arrays into a flat list
    /// of candidate object nodes.
    private static func flatten(_ value: Any) -> [[String: Any]] {
        if let array = value as? [Any] {
            return array.flatMap(flatten)
        }
        if let dict = value as? [String: Any] {
            if let graph = dict["@graph"] {
                return flatten(graph)
            }
            return [dict]
        }
        return []
    }

    private static func isRestaurantNode(_ node: [String: Any]) -> Bool {
        let type = node["@type"]
        if let s = type as? String, restaurantTypes.contains(s) { return true }
        if let arr = type as? [String] { return arr.contains(where: restaurantTypes.contains) }
        return false
    }

    // MARK: - Field extraction

    private static func parseRestaurantNode(_ node: [String: Any]) -> Parsed {
        var out = Parsed()
        out.hours = parseHours(node["openingHoursSpecification"]) ?? parseOpeningHoursStrings(node["openingHours"])
        out.rating = parseRating(node["aggregateRating"])
        out.priceRange = parsePriceRange(node["priceRange"])
        out.menuURL = parseURL(node["hasMenu"]) ?? parseURL(node["menu"])
        return out
    }

    private static func parsePriceRange(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let dollarsOnly = trimmed.filter { $0 == "$" }
        guard (1...4).contains(dollarsOnly.count), dollarsOnly == trimmed else { return nil }
        return dollarsOnly
    }

    private static func parseRating(_ value: Any?) -> Double? {
        guard let dict = value as? [String: Any] else { return nil }
        if let n = dict["ratingValue"] as? Double { return n }
        if let n = dict["ratingValue"] as? Int    { return Double(n) }
        if let s = dict["ratingValue"] as? String,
           let n = Double(s.trimmingCharacters(in: .whitespaces)) { return n }
        return nil
    }

    private static func parseURL(_ value: Any?) -> URL? {
        if let s = value as? String,
           let url = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.scheme != nil { return url }
        if let dict = value as? [String: Any] {
            if let id = dict["@id"] as? String, let url = URL(string: id) { return url }
            if let urlStr = dict["url"] as? String, let url = URL(string: urlStr) { return url }
        }
        if let arr = value as? [Any] {
            for item in arr {
                if let url = parseURL(item) { return url }
            }
        }
        return nil
    }

    // MARK: - Hours

    /// Decode `openingHoursSpecification` (the structured form). Each
    /// entry pins one or more days to an `opens`/`closes` pair. We
    /// canonicalize and then compress consecutive same-hours days into
    /// a "Mon–Fri 11:00–22:00" style summary.
    private static func parseHours(_ value: Any?) -> String? {
        let entries: [[String: Any]]
        if let arr = value as? [[String: Any]] { entries = arr }
        else if let single = value as? [String: Any] { entries = [single] }
        else { return nil }

        // Map weekday index (0=Mon … 6=Sun) → "HH:mm–HH:mm" string.
        // 24h venues map to "open 24h"; closed days stay absent.
        var byDay: [Int: String] = [:]
        for entry in entries {
            let days = extractDays(entry["dayOfWeek"])
            guard let opens  = formatTime(entry["opens"]),
                  let closes = formatTime(entry["closes"]) else { continue }
            let label = WeekdayHoursFormatter.timeLabel(opens: opens, closes: closes)
            for d in days where byDay[d] == nil {
                byDay[d] = label
            }
        }
        guard !byDay.isEmpty else { return nil }

        return WeekdayHoursFormatter.compress(byDay)
    }

    /// Fallback: schema.org also allows a plain-string `openingHours`
    /// property like `"Mo-Fr 11:00-22:00"`. We just pass that through —
    /// it's already human-readable, and replicating it perfectly into
    /// the compressed form is fragile.
    ///
    /// The array variant filters out empty strings before joining. Some
    /// sites emit a placeholder `["", "", "", "", "", "", ""]` for the
    /// seven weekdays without ever filling the values; a naive join
    /// would produce a comma-only string ("`, , , , , , `") that
    /// later renders as visible garbage in the detail view.
    private static func parseOpeningHoursStrings(_ value: Any?) -> String? {
        if let s = value as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
            return s
        }
        if let arr = value as? [String] {
            let nonEmpty = arr
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !nonEmpty.isEmpty else { return nil }
            return nonEmpty.joined(separator: ", ")
        }
        return nil
    }

    private static let dayLookup: [String: Int] = [
        // Long names
        "monday": 0, "tuesday": 1, "wednesday": 2, "thursday": 3,
        "friday": 4, "saturday": 5, "sunday": 6,
        // Abbreviations
        "mon": 0, "tue": 1, "wed": 2, "thu": 3,
        "fri": 4, "sat": 5, "sun": 6,
        // schema.org/PublicHolidays — skip
    ]

    private static func extractDays(_ value: Any?) -> [Int] {
        let raw: [String]
        if let s = value as? String { raw = [s] }
        else if let arr = value as? [String] { raw = arr }
        else if let arr = value as? [Any] { raw = arr.compactMap { $0 as? String } }
        else { return [] }

        return raw.compactMap { dayLookup[normalizedDay($0)] }
    }

    private static func normalizedDay(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Accept "https://schema.org/Monday" style URLs.
        if let lastSlash = v.lastIndex(of: "/") {
            v = String(v[v.index(after: lastSlash)...])
        }
        return v
    }

    /// Normalize times like `"11:00"`, `"11:00:00"`, `"23:00:00-05:00"`
    /// down to a clean `"HH:mm"`.
    private static func formatTime(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Strip timezone suffix (+HH:MM or -HH:MM, but not the H:M separator).
        let withoutTZ: String = {
            if let plus = trimmed.firstIndex(of: "+"), plus > trimmed.startIndex {
                return String(trimmed[..<plus])
            }
            // Negative offsets: only treat as TZ if there's a colon-separated
            // hour:minute in front (avoids confusion with negative numerals,
            // which don't appear in time strings anyway).
            if let minus = trimmed.lastIndex(of: "-"),
               minus > trimmed.index(after: trimmed.startIndex) {
                return String(trimmed[..<minus])
            }
            return trimmed
        }()
        let parts = withoutTZ.split(separator: ":")
        guard parts.count >= 2,
              let hh = Int(parts[0]),
              let mm = Int(parts[1]),
              (0...24).contains(hh), (0...59).contains(mm) else {
            return nil
        }
        return String(format: "%02d:%02d", hh, mm)
    }

}
