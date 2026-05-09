import Foundation

/// Seed data for the Service Catalog rows that mirror the Honda
/// Maintenance Schedule PDF at the repo root. IDs are stable strings so
/// sidecar frontmatter (`services: [svc-honda-engine-oil-normal, …]`)
/// resolves directly without a UUID lookup.
///
/// Only the **U.S. Normal Conditions** schedule is seeded. The Severe
/// Conditions variant was removed once it became clear we weren't going
/// to differentiate driving conditions; the `-normal` suffix on IDs is
/// kept for backward compatibility with already-tagged sidecars.
///
/// `applies_to_vehicles` link targets are written as record TITLES; the
/// migration resolves them against `records.title` at apply time. If a
/// vehicle hasn't been added to Keystone yet, that specific link is
/// skipped. Re-running the migration is safe but won't re-link
/// retroactively — users can wire missing links in-app.
enum HondaMaintenanceSchedule {
    struct CatalogRow {
        let id: String
        let title: String
        let stage: String?          // "first" / "recurring" / nil
        let intervalMiles: Int?
        let intervalMonths: Int?
        let predecessorID: String?
        let vehicleTitles: [String] // empty → applies to all vehicles
        let notes: String?
        let sort: Double
    }

    static let hondaTitles = ["2015 Honda Fit", "2018 Honda CR-V"]
    static let crvOnly     = ["2018 Honda CR-V"]   // 4WD-specific items

    static let catalogRows: [CatalogRow] = [
        .init(id: "svc-honda-engine-oil-normal",
              title: "Replace engine oil",
              stage: nil,
              intervalMiles: 10_000, intervalMonths: 12,
              predecessorID: nil, vehicleTitles: hondaTitles,
              notes: "Whichever comes first.",
              sort: 1.0),
        .init(id: "svc-honda-oil-filter-normal",
              title: "Replace engine oil filter",
              stage: nil,
              intervalMiles: 20_000, intervalMonths: 24,
              predecessorID: nil, vehicleTitles: hondaTitles,
              notes: "Performed at every other oil change.",
              sort: 1.1),
        .init(id: "svc-honda-tire-rotation-normal",
              title: "Rotate tires",
              stage: nil,
              intervalMiles: 10_000, intervalMonths: nil,
              predecessorID: nil, vehicleTitles: hondaTitles,
              notes: "Check tire inflation and condition at least once per month.",
              sort: 1.2),
        .init(id: "svc-honda-brakes-inspect-normal",
              title: "Inspect front and rear brakes",
              stage: nil,
              intervalMiles: 20_000, intervalMonths: 24,
              predecessorID: nil, vehicleTitles: hondaTitles,
              notes: nil,
              sort: 1.3),
        .init(id: "svc-honda-multi-inspect-normal",
              title: "Visual inspection: tie rods, suspension, driveshaft boots, brake hoses, fluids, exhaust, fuel lines",
              stage: nil,
              intervalMiles: 20_000, intervalMonths: 24,
              predecessorID: nil, vehicleTitles: hondaTitles,
              notes: nil,
              sort: 1.4),
        .init(id: "svc-honda-drive-belt-normal",
              title: "Inspect and adjust drive belt",
              stage: nil,
              intervalMiles: 30_000, intervalMonths: nil,
              predecessorID: nil, vehicleTitles: hondaTitles,
              notes: nil,
              sort: 1.5),
        .init(id: "svc-honda-air-cleaner-normal",
              title: "Replace air cleaner element",
              stage: nil,
              intervalMiles: 30_000, intervalMonths: nil,
              predecessorID: nil, vehicleTitles: hondaTitles,
              notes: nil,
              sort: 1.6),
        .init(id: "svc-honda-dust-pollen-filter-normal",
              title: "Replace dust and pollen filter",
              stage: nil,
              intervalMiles: 30_000, intervalMonths: nil,
              predecessorID: nil, vehicleTitles: hondaTitles,
              notes: nil,
              sort: 1.7),
        .init(id: "svc-honda-rear-diff-fluid-normal",
              title: "Replace rear differential fluid (4WD)",
              stage: nil,
              intervalMiles: 90_000, intervalMonths: 60,
              predecessorID: nil, vehicleTitles: crvOnly,
              notes: "4WD only. CR-V; not applicable to FWD Fit.",
              sort: 1.8),
        .init(id: "svc-honda-trans-fluid-at-normal-first",
              title: "Replace transmission fluid (A/T) — first",
              stage: "first",
              intervalMiles: 120_000, intervalMonths: 72,
              predecessorID: nil, vehicleTitles: hondaTitles,
              notes: "First A/T fluid replacement at 120k mi or 6 yr.",
              sort: 1.9),
        .init(id: "svc-honda-trans-fluid-at-normal-recurring",
              title: "Replace transmission fluid (A/T) — recurring",
              stage: "recurring",
              intervalMiles: 90_000, intervalMonths: 60,
              predecessorID: "svc-honda-trans-fluid-at-normal-first",
              vehicleTitles: hondaTitles,
              notes: "After first A/T replacement, every 90k mi or 5 yr.",
              sort: 1.91),
        .init(id: "svc-honda-trans-fluid-mt-normal",
              title: "Replace transmission fluid (M/T)",
              stage: nil,
              intervalMiles: 120_000, intervalMonths: 72,
              predecessorID: nil, vehicleTitles: hondaTitles,
              notes: "Manual transmission only.",
              sort: 1.92),
        .init(id: "svc-honda-coolant-normal-first",
              title: "Replace engine coolant — first",
              stage: "first",
              intervalMiles: 120_000, intervalMonths: 120,
              predecessorID: nil, vehicleTitles: hondaTitles,
              notes: "First at 120k mi or 10 yr.",
              sort: 1.93),
        .init(id: "svc-honda-coolant-normal-recurring",
              title: "Replace engine coolant — recurring",
              stage: "recurring",
              intervalMiles: 60_000, intervalMonths: 60,
              predecessorID: "svc-honda-coolant-normal-first",
              vehicleTitles: hondaTitles,
              notes: "After first coolant change, every 60k mi or 5 yr.",
              sort: 1.94),
        .init(id: "svc-honda-spark-plugs-normal",
              title: "Replace spark plugs",
              stage: nil,
              intervalMiles: 110_000, intervalMonths: nil,
              predecessorID: nil, vehicleTitles: hondaTitles,
              notes: nil,
              sort: 1.95),
        .init(id: "svc-honda-valve-clearance-normal",
              title: "Inspect valve clearance",
              stage: nil,
              intervalMiles: 110_000, intervalMonths: nil,
              predecessorID: nil, vehicleTitles: hondaTitles,
              notes: "Cold engine; otherwise adjust only if noisy.",
              sort: 1.96),
        .init(id: "svc-honda-idle-speed-normal",
              title: "Inspect idle speed",
              stage: nil,
              intervalMiles: 160_000, intervalMonths: 96,
              predecessorID: nil, vehicleTitles: hondaTitles,
              notes: nil,
              sort: 1.97),
        .init(id: "svc-honda-brake-fluid",
              title: "Replace brake fluid",
              stage: nil,
              intervalMiles: nil, intervalMonths: 36,
              predecessorID: nil, vehicleTitles: hondaTitles,
              notes: "Every 3 years independent of mileage.",
              sort: 1.98),
    ]
}
