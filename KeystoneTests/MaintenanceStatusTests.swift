import XCTest
@testable import Keystone

/// Unit tests for the pure-data next-due engine. Covers the statuses
/// the engine emits, the "whichever comes first" semantics across
/// mileage / time intervals, and the stepped first→recurring catalog
/// transition.
final class MaintenanceStatusTests: XCTestCase {
    let engine = MaintenanceStatusEngine()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    /// The bug that surfaced this fix: a vehicle with several recent
    /// events (oil changes, tires) had `currentMileageAsOf` bumped by
    /// every one — so a time-only service the user has *never*
    /// recorded (brake fluid, every 36 months) showed OK because the
    /// "as of" date was always recent. The right baseline for "never"
    /// is how long the user has owned the vehicle in their records,
    /// i.e. the earliest event date.
    func testNeverFiresForTimeOnlyServiceWhenVehicleOldEnoughEvenWithRecentEvents() {
        let now = date(2026, 5, 9)
        let vehicle = VehicleSnapshot(
            id: "v1", title: "CR-V",
            currentMileage: 82_000,
            currentMileageAsOf: date(2026, 1, 15),     // recent oil change
            firstSeenAt: date(2019, 8, 2)              // owned 6.7 yrs
        )
        let brakeFluid = MaintenanceCatalogItem(
            id: "svc-brake-fluid", title: "Replace brake fluid",
            intervalMiles: nil, intervalMonths: 36,
            appliesTo: ["v1"]
        )
        // Recent oil-change event for an UNRELATED catalog item — the
        // engine should not let this hide the never-done brake fluid.
        let recentOilChange = MaintenanceEvent(
            id: "e-oil", vehicleID: "v1",
            date: date(2026, 1, 15), mileage: 82_000,
            catalogIDs: ["svc-oil"]
        )
        let statuses = engine.computeStatuses(
            vehicle: vehicle,
            catalog: [brakeFluid],
            events: [recentOilChange],
            now: now
        )
        XCTAssertEqual(statuses.first?.kind, .never,
                       "brake fluid never recorded + 6.7 yrs of ownership must surface as never, not OK")
    }

    /// Symmetric guard: a *new* vehicle (first event last month)
    /// shouldn't surface time-only services as never. The user
    /// hasn't had enough time to do them yet.
    func testOkForTimeOnlyServiceWhenVehicleTooNewToNeed() {
        let now = date(2026, 5, 9)
        let vehicle = VehicleSnapshot(
            id: "v-new", title: "New CR-V",
            currentMileage: 1_500,
            currentMileageAsOf: date(2026, 4, 1),
            firstSeenAt: date(2026, 4, 1)              // owned 5 weeks
        )
        let brakeFluid = MaintenanceCatalogItem(
            id: "svc-brake-fluid", title: "Replace brake fluid",
            intervalMiles: nil, intervalMonths: 36,
            appliesTo: ["v-new"]
        )
        let statuses = engine.computeStatuses(vehicle: vehicle, catalog: [brakeFluid], events: [], now: now)
        XCTAssertEqual(statuses.first?.kind, .future,
                       "five-week-old vehicle has no business being flagged for never-done brake fluid")
    }

    func testScheduledWhenInsideDateThreshold() {
        let now = date(2026, 1, 1)
        let vehicle = VehicleSnapshot(id: "v1", title: "CR-V", currentMileage: 50_000, currentMileageAsOf: now)
        let item = MaintenanceCatalogItem(
            id: "svc-oil", title: "Replace engine oil",
            intervalMiles: 10_000, intervalMonths: 12,
            appliesTo: ["v1"]
        )
        let event = MaintenanceEvent(
            id: "e1", vehicleID: "v1", date: date(2025, 11, 1), mileage: 49_000,
            catalogIDs: ["svc-oil"]
        )
        let statuses = engine.computeStatuses(vehicle: vehicle, catalog: [item], events: [event], now: now)
        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(statuses[0].kind, .future)
        XCTAssertEqual(statuses[0].nextDueMileage, 59_000)
    }

    /// Replaces the prior `testOverdueByMileage`. The engine no
    /// longer extrapolates "today's mileage" off `currentMileage`,
    /// because we don't actually know what the odometer reads
    /// between visits. The mileage signal we *can* assert is data:
    /// a *later* logged service exists at mileage past the threshold
    /// without including this catalog item — we know the user
    /// crossed the window without recording the service.
    func testMissedWindowWhenLaterServiceCrossesThreshold() {
        let now = date(2026, 1, 1)
        let vehicle = VehicleSnapshot(id: "v1", title: "CR-V", currentMileage: nil, currentMileageAsOf: nil)
        let oil = MaintenanceCatalogItem(
            id: "svc-oil", title: "Replace engine oil",
            intervalMiles: 10_000, intervalMonths: 12,
            appliesTo: ["v1"]
        )
        // Last oil change at 50k on a recent date so the time-based
        // overdue path doesn't fire — we want a clean test of the
        // mileage signal alone. Next due: 60k mi / 2026-11-01 (date).
        let oilEvent = MaintenanceEvent(
            id: "e-oil", vehicleID: "v1", date: date(2025, 11, 1), mileage: 50_000,
            catalogIDs: ["svc-oil"]
        )
        // Tire rotation a week later at 65k that didn't include oil —
        // proves the mileage threshold was crossed without recording oil.
        let tireEvent = MaintenanceEvent(
            id: "e-tires", vehicleID: "v1", date: date(2025, 11, 8), mileage: 65_000,
            catalogIDs: ["svc-tires"]
        )
        let statuses = engine.computeStatuses(
            vehicle: vehicle, catalog: [oil],
            events: [oilEvent, tireEvent], now: now
        )
        XCTAssertEqual(statuses[0].kind, .missedWindow)
        XCTAssertEqual(statuses[0].missedWindowEvidence?.eventMileage, 65_000)
        XCTAssertEqual(statuses[0].missedWindowEvidence?.eventDate, date(2025, 11, 8))
    }

    /// Counter-case: a later service that DOES include this catalog
    /// item rolls the next-due forward; no missed window.
    func testNoMissedWindowWhenLaterServiceIncludesItem() {
        let now = date(2026, 1, 1)
        let vehicle = VehicleSnapshot(id: "v1", title: "CR-V", currentMileage: nil, currentMileageAsOf: nil)
        let oil = MaintenanceCatalogItem(
            id: "svc-oil", title: "Replace engine oil",
            intervalMiles: 10_000, intervalMonths: 12,
            appliesTo: ["v1"]
        )
        let earlyOil = MaintenanceEvent(
            id: "e-oil-1", vehicleID: "v1", date: date(2024, 9, 1), mileage: 50_000,
            catalogIDs: ["svc-oil"]
        )
        let recentOil = MaintenanceEvent(
            id: "e-oil-2", vehicleID: "v1", date: date(2025, 12, 15), mileage: 65_000,
            catalogIDs: ["svc-oil", "svc-tires"]
        )
        let statuses = engine.computeStatuses(
            vehicle: vehicle, catalog: [oil],
            events: [earlyOil, recentOil], now: now
        )
        XCTAssertNotEqual(statuses[0].kind, .missedWindow)
        XCTAssertNil(statuses[0].missedWindowEvidence)
    }

    func testOverdueByTimeEvenIfMileageOK() {
        // Time intervals fire even on a low-mileage car.
        let now = date(2026, 6, 1)
        let vehicle = VehicleSnapshot(id: "v1", title: "Fit", currentMileage: 30_000, currentMileageAsOf: now)
        let item = MaintenanceCatalogItem(
            id: "svc-brake-fluid", title: "Replace brake fluid",
            intervalMiles: nil, intervalMonths: 36,
            appliesTo: []
        )
        let event = MaintenanceEvent(
            id: "e1", vehicleID: "v1", date: date(2022, 1, 1), mileage: 25_000,
            catalogIDs: ["svc-brake-fluid"]
        )
        let statuses = engine.computeStatuses(vehicle: vehicle, catalog: [item], events: [event], now: now)
        XCTAssertEqual(statuses[0].kind, .overdue)
        XCTAssertNil(statuses[0].nextDueMileage)
    }

    /// `dueSoon` now fires only on date proximity (mileage-window
    /// `dueSoon` was deleted along with the rest of the
    /// extrapolated-current-mileage logic).
    func testDueSoonByDate() {
        let now = date(2026, 1, 1)
        let vehicle = VehicleSnapshot(id: "v1", title: "CR-V", currentMileage: nil, currentMileageAsOf: nil)
        let item = MaintenanceCatalogItem(
            id: "svc-oil", title: "Replace engine oil",
            intervalMiles: 10_000, intervalMonths: 12,
            appliesTo: []
        )
        // Last oil change 11 months ago → next due in ~30 days.
        let event = MaintenanceEvent(
            id: "e1", vehicleID: "v1", date: date(2025, 2, 1), mileage: 50_000,
            catalogIDs: ["svc-oil"]
        )
        let statuses = engine.computeStatuses(vehicle: vehicle, catalog: [item], events: [event], now: now)
        XCTAssertEqual(statuses[0].kind, .dueSoon)
    }

    func testNeverWhenVehiclePastFirstInterval() {
        // Vehicle has 25k miles and never logged an oil change.
        let now = date(2026, 1, 1)
        let vehicle = VehicleSnapshot(id: "v1", title: "Fit", currentMileage: 25_000, currentMileageAsOf: now)
        let item = MaintenanceCatalogItem(
            id: "svc-oil", title: "Replace engine oil",
            intervalMiles: 10_000, intervalMonths: 12,
            appliesTo: []
        )
        let statuses = engine.computeStatuses(vehicle: vehicle, catalog: [item], events: [], now: now)
        XCTAssertEqual(statuses[0].kind, .never)
        XCTAssertNil(statuses[0].lastEventDate)
    }

    func testNewVehicleBelowFirstIntervalShowsScheduled() {
        // New vehicle with 2k miles never had an oil change yet — that's fine.
        let now = date(2026, 1, 1)
        let vehicle = VehicleSnapshot(id: "v1", title: "Fit", currentMileage: 2_000, currentMileageAsOf: now)
        let item = MaintenanceCatalogItem(
            id: "svc-oil", title: "Replace engine oil",
            intervalMiles: 10_000, intervalMonths: 12,
            appliesTo: []
        )
        let statuses = engine.computeStatuses(vehicle: vehicle, catalog: [item], events: [], now: now)
        XCTAssertEqual(statuses[0].kind, .future)
    }

    func testSteppedFirstThenRecurring() {
        // Honda A/T fluid: first at 120k/6yr, then every 90k/5yr.
        let now = date(2026, 1, 1)
        let vehicle = VehicleSnapshot(id: "v1", title: "CR-V", currentMileage: 130_000, currentMileageAsOf: now)
        let first = MaintenanceCatalogItem(
            id: "svc-at-first", title: "AT fluid first",
            intervalMiles: 120_000, intervalMonths: 72,
            stage: "first", appliesTo: []
        )
        let recurring = MaintenanceCatalogItem(
            id: "svc-at-recur", title: "AT fluid recurring",
            intervalMiles: 90_000, intervalMonths: 60,
            stage: "recurring", predecessorID: "svc-at-first",
            appliesTo: []
        )
        // No events yet — recurring should be hidden, first should appear (overdue).
        let statuses1 = engine.computeStatuses(vehicle: vehicle, catalog: [first, recurring], events: [], now: now)
        XCTAssertEqual(statuses1.count, 1)
        XCTAssertEqual(statuses1[0].catalogID, "svc-at-first")

        // Once the first-stage was performed, the first row hides and
        // the recurring row activates from that event's anchor.
        let firstEvent = MaintenanceEvent(
            id: "e1", vehicleID: "v1", date: date(2025, 1, 1), mileage: 125_000,
            catalogIDs: ["svc-at-first"]
        )
        let statuses2 = engine.computeStatuses(vehicle: vehicle, catalog: [first, recurring], events: [firstEvent], now: now)
        XCTAssertEqual(statuses2.count, 1)
        XCTAssertEqual(statuses2[0].catalogID, "svc-at-recur")
        XCTAssertEqual(statuses2[0].nextDueMileage, 215_000)
    }

    func testCatalogScopedByVehicle() {
        // CR-V-only items don't appear on the Fit.
        let now = date(2026, 1, 1)
        let crv = VehicleSnapshot(id: "v-crv", title: "CR-V", currentMileage: 80_000, currentMileageAsOf: now)
        let fit = VehicleSnapshot(id: "v-fit", title: "Fit", currentMileage: 80_000, currentMileageAsOf: now)
        let crvOnly = MaintenanceCatalogItem(
            id: "svc-diff", title: "Rear diff fluid (4WD)",
            intervalMiles: 90_000, intervalMonths: 60,
            appliesTo: ["v-crv"]
        )
        let universal = MaintenanceCatalogItem(
            id: "svc-brakefluid", title: "Brake fluid",
            intervalMiles: nil, intervalMonths: 36,
            appliesTo: []
        )
        let crvStatuses = engine.computeStatuses(vehicle: crv, catalog: [crvOnly, universal], events: [], now: now)
        let fitStatuses = engine.computeStatuses(vehicle: fit, catalog: [crvOnly, universal], events: [], now: now)
        XCTAssertEqual(Set(crvStatuses.map(\.catalogID)), ["svc-diff", "svc-brakefluid"])
        XCTAssertEqual(Set(fitStatuses.map(\.catalogID)), ["svc-brakefluid"])
    }
}
