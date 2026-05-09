import Foundation

/// Service Catalog rows for the 2006 GMC Canyon. Hand-authored because
/// I don't have the original GMC owner's manual; intervals are
/// reasonable defaults for a 2000s-era GM truck (5,000 mi / 6 mo for
/// engine oil, 30,000 mi / 24 mo for transmission fluid). The user
/// can edit these in-app if they have manufacturer-specified intervals
/// they'd rather use.
///
/// Stable IDs (`svc-gmc-*`) keep sidecar frontmatter resolvable across
/// re-imports without round-tripping through UUIDs.
enum GMCMaintenanceSchedule {
    struct CatalogRow {
        let id: String
        let title: String
        let intervalMiles: Int?
        let intervalMonths: Int?
        let vehicleTitles: [String]
        let notes: String?
        let sort: Double
    }

    static let gmcTitles = ["2006 GMC Canyon"]

    static let catalogRows: [CatalogRow] = [
        .init(id: "svc-gmc-engine-oil",
              title: "Replace engine oil (GMC)",
              intervalMiles: 5_000, intervalMonths: 6,
              vehicleTitles: gmcTitles,
              notes: "Whichever comes first.",
              sort: 3.0),
        .init(id: "svc-gmc-oil-filter",
              title: "Replace engine oil filter (GMC)",
              intervalMiles: 5_000, intervalMonths: 6,
              vehicleTitles: gmcTitles,
              notes: "Replaced with each oil change.",
              sort: 3.1),
        .init(id: "svc-gmc-tire-rotation",
              title: "Rotate tires (GMC)",
              intervalMiles: 7_500, intervalMonths: nil,
              vehicleTitles: gmcTitles,
              notes: nil,
              sort: 3.2),
        .init(id: "svc-gmc-transmission-service",
              title: "Transmission fluid service (GMC)",
              intervalMiles: 30_000, intervalMonths: 24,
              vehicleTitles: gmcTitles,
              notes: "Drain & refill or flush. Consult shop for type-specific interval.",
              sort: 3.3),
        .init(id: "svc-gmc-air-filter",
              title: "Replace engine air filter (GMC)",
              intervalMiles: 30_000, intervalMonths: nil,
              vehicleTitles: gmcTitles,
              notes: nil,
              sort: 3.4),
    ]
}
