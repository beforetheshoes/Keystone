import Foundation

/// Maps line-item / service-description text in maintenance sidecar
/// bodies to one or more Service Catalog row IDs. Used by the
/// frontmatter backfill to auto-populate `services:` in YAML, and by
/// the importer to wire `services` relations.
///
/// The catalog row IDs match `HondaMaintenanceSchedule.catalogRows`. A
/// match here doesn't decide normal vs severe — that's scoped per
/// vehicle by the catalog row's `applies_to_vehicles` link, not by
/// individual events. We resolve to the *family* of items (e.g. "engine
/// oil") and let the next-due engine pick the right row(s) using each
/// vehicle's catalog scope.
///
/// Synonym matches are case-insensitive and run as substring searches
/// after collapsing whitespace. Adding new patterns is the recommended
/// way to improve coverage — keep `tokens` lowercase and as
/// shop-agnostic as possible.
enum MaintenanceVocab {
    struct Rule {
        /// Stable catalog row ID this rule satisfies. The `-normal`
        /// suffix on existing IDs is a vestige of the abandoned
        /// Normal/Severe distinction; we no longer differentiate
        /// driving severity, but the suffix stays for compatibility
        /// with sidecars already tagged before the simplification.
        let catalogID: String
        /// Lowercased substrings; ANY match in the body fires the rule.
        let tokens: [String]
    }

    static let rules: [Rule] = [
        // Oil change family — body covers both "engine oil" and the
        // filter when present together. We tag filter only on a
        // distinct cue ("oil filter", "filter, oil") to avoid
        // double-counting.
        Rule(catalogID: "svc-honda-engine-oil-normal",
             tokens: ["oil change", "engine oil", "perform engine oil", "oil and filter change", "lof "]),
        Rule(catalogID: "svc-honda-oil-filter-normal",
             tokens: ["oil filter", "filter, oil", "filter oil"]),

        // Tire rotation
        Rule(catalogID: "svc-honda-tire-rotation-normal",
             tokens: ["tire rotation", "rotate tires", "rotated tires", "tires rotated", "perform tire rotation"]),

        // Brake inspection
        Rule(catalogID: "svc-honda-brakes-inspect-normal",
             tokens: ["brake inspection", "inspect brakes", "inspect front and rear brakes", "brake check"]),

        // Multi-point / visual inspection
        Rule(catalogID: "svc-honda-multi-inspect-normal",
             tokens: ["multi point inspection", "multi-point inspection", "multipoint inspection", "visual inspection"]),

        // Drive belt
        Rule(catalogID: "svc-honda-drive-belt-normal",
             tokens: ["drive belt", "serpentine belt", "accessory belt"]),

        // Air cleaner / engine air filter. "air filter" alone fires
        // this rule; the cabin-filter rule below catches the
        // narrower "cabin filter" / "pollen filter" cases.
        Rule(catalogID: "svc-honda-air-cleaner-normal",
             tokens: ["air cleaner", "engine air filter", "air filter element", "air filter"]),

        // Cabin / dust+pollen filter
        Rule(catalogID: "svc-honda-dust-pollen-filter-normal",
             tokens: ["cabin filter", "dust and pollen filter", "pollen filter", "micron cabin filter"]),

        // Differential fluid (4WD CR-V)
        Rule(catalogID: "svc-honda-rear-diff-fluid-normal",
             tokens: ["differential fluid", "rear differential", "diff fluid"]),

        // Transmission fluid — A/T (covers Honda CVT). The next-due
        // engine handles first→recurring stage transitions; we tag the
        // first-stage row and the engine takes over from there.
        Rule(catalogID: "svc-honda-trans-fluid-at-normal-first",
             tokens: ["transmission fluid", "atf service", "trans fluid", "cvt fluid", "atf replacement"]),

        // Engine coolant
        Rule(catalogID: "svc-honda-coolant-normal-first",
             tokens: ["engine coolant", "coolant flush", "coolant exchange", "antifreeze"]),

        // Spark plugs
        Rule(catalogID: "svc-honda-spark-plugs-normal",
             tokens: ["spark plug", "spark plugs"]),

        // Valve clearance
        Rule(catalogID: "svc-honda-valve-clearance-normal",
             tokens: ["valve clearance", "valve adjust"]),

        // Idle speed
        Rule(catalogID: "svc-honda-idle-speed-normal",
             tokens: ["idle speed"]),

        // Brake fluid
        Rule(catalogID: "svc-honda-brake-fluid",
             tokens: ["brake fluid", "brake flush", "bleed brakes"]),
    ]

    /// Match catalog IDs to a body. Returns a sorted-unique array so
    /// the YAML output is deterministic across runs.
    static func match(in body: String) -> [String] {
        let needle = body.lowercased().replacingOccurrences(of: "\n", with: " ")
        var hits = Set<String>()
        for rule in rules {
            for token in rule.tokens {
                if needle.contains(token) {
                    hits.insert(rule.catalogID)
                    break
                }
            }
        }
        return hits.sorted()
    }
}
