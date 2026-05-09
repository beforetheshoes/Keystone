import Foundation

/// Pure-data inputs to the next-due engine. The engine has no DB
/// dependency — fetch rows in a Reads helper, hand them to
/// `computeStatuses`, and feed the result to the UI / CLI / reminders.
public struct MaintenanceCatalogItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let intervalMiles: Int?
    public let intervalMonths: Int?
    public let severity: String?  // "normal" / "severe" / nil
    public let stage: String?     // "first" / "recurring" / nil
    public let predecessorID: String?
    /// IDs of the vehicles this catalog item applies to. Empty means
    /// "applies to every vehicle of the matching subject_kind".
    public let appliesTo: Set<String>

    public init(id: String, title: String, intervalMiles: Int?, intervalMonths: Int?,
                severity: String? = nil, stage: String? = nil,
                predecessorID: String? = nil, appliesTo: Set<String>) {
        self.id = id
        self.title = title
        self.intervalMiles = intervalMiles
        self.intervalMonths = intervalMonths
        self.severity = severity
        self.stage = stage
        self.predecessorID = predecessorID
        self.appliesTo = appliesTo
    }
}

public struct MaintenanceEvent: Equatable, Sendable, Identifiable {
    public let id: String
    public let vehicleID: String
    public let date: Date
    public let mileage: Int?
    public let catalogIDs: Set<String>

    public init(id: String, vehicleID: String, date: Date, mileage: Int?, catalogIDs: Set<String>) {
        self.id = id
        self.vehicleID = vehicleID
        self.date = date
        self.mileage = mileage
        self.catalogIDs = catalogIDs
    }
}

public struct VehicleSnapshot: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let currentMileage: Int?
    public let currentMileageAsOf: Date?
    /// Earliest known event date for this vehicle — proxy for "how
    /// long has the user had this vehicle in their records." Used by
    /// the engine's time-based `never` check: if enough time has
    /// elapsed since `firstSeenAt` to clear at least one full
    /// interval, a service that's never been recorded is `never`,
    /// not `ok`. Without this, a recent oil change would push every
    /// time-only interval (brake fluid, etc.) into a fake "OK"
    /// because `currentMileageAsOf` only tracks the latest reading.
    public let firstSeenAt: Date?

    public init(id: String, title: String, currentMileage: Int?, currentMileageAsOf: Date?, firstSeenAt: Date? = nil) {
        self.id = id
        self.title = title
        self.currentMileage = currentMileage
        self.currentMileageAsOf = currentMileageAsOf
        self.firstSeenAt = firstSeenAt
    }
}

/// Status emitted by the engine. Strictly grounded in logged data —
/// the engine never extrapolates "today's current mileage" off a
/// stale last-service reading. The user's actual odometer is
/// unknown to us between visits, so a status that depends on it
/// would be an unverified guess; only date-based and "later logged
/// service crossed the threshold" signals are factual.
public enum MaintenanceStatusKind: String, Equatable, Sendable {
    /// No service for this item has ever been logged AND the vehicle
    /// has been in our records for at least one full interval. (See
    /// `firstSeenAt` on `VehicleSnapshot`.) New-to-us vehicles whose
    /// first logged event is recent stay `scheduled`.
    case never
    /// `nextDueDate` is in the past. Only fires when we have a date.
    case overdue
    /// `nextDueDate` is within ~60 days. Only fires when we have a date.
    case dueSoon = "due-soon"
    /// We have evidence the mileage threshold for this item was
    /// crossed without recording it: a *later* logged service exists
    /// at mileage ≥ `nextDueMileage` and that later service did not
    /// include this catalog item. Distinct from `overdue` (which is
    /// time-based) — the reason matters.
    case missedWindow = "missed-window"
    /// Last service known, next-due is in the future, no later
    /// logged service indicates a missed mileage window. The honest
    /// "we have a plan and nothing in the data tells us anything
    /// is wrong" answer. Named `future` rather than `scheduled`
    /// because nothing's actually been scheduled — it's just not yet
    /// due.
    case future
}

public struct MaintenanceStatus: Equatable, Sendable {
    public let vehicleID: String
    public let catalogID: String
    public let title: String
    public let kind: MaintenanceStatusKind
    public let lastEventDate: Date?
    public let lastEventMileage: Int?
    public let nextDueDate: Date?
    public let nextDueMileage: Int?
    /// Days until `nextDueDate`. Negative when overdue. Nil when no
    /// time interval applies. The engine deliberately does NOT emit
    /// `milesUntilDue` because that requires assuming a current
    /// odometer reading we can't verify.
    public let daysUntilDue: Int?
    /// When `kind == .missedWindow`, the (date, mileage) of the
    /// later-logged service that crosses this item's mileage
    /// threshold without including it. Nil for every other kind.
    public let missedWindowEvidence: MissedWindowEvidence?

    public init(vehicleID: String, catalogID: String, title: String, kind: MaintenanceStatusKind,
                lastEventDate: Date?, lastEventMileage: Int?,
                nextDueDate: Date?, nextDueMileage: Int?,
                daysUntilDue: Int?, missedWindowEvidence: MissedWindowEvidence? = nil) {
        self.vehicleID = vehicleID
        self.catalogID = catalogID
        self.title = title
        self.kind = kind
        self.lastEventDate = lastEventDate
        self.lastEventMileage = lastEventMileage
        self.nextDueDate = nextDueDate
        self.nextDueMileage = nextDueMileage
        self.daysUntilDue = daysUntilDue
        self.missedWindowEvidence = missedWindowEvidence
    }

    public struct MissedWindowEvidence: Equatable, Sendable {
        public let eventDate: Date
        public let eventMileage: Int
        public init(eventDate: Date, eventMileage: Int) {
            self.eventDate = eventDate
            self.eventMileage = eventMileage
        }
    }
}

public struct MaintenanceStatusEngine {
    /// Soft "due-soon" thresholds. Anything within these of a deadline
    /// flips OK → due-soon. Picked to be generous enough to give the
    /// user meaningful lead time without crying wolf.
    public static let dueSoonMiles: Int = 1_500
    public static let dueSoonDays: Int = 60

    public init() {}

    /// Compute statuses for a single (vehicle, catalog) join. Returns
    /// one status per applicable catalog item, ordered by status
    /// severity (overdue → due-soon → never → ok).
    public func computeStatuses(
        vehicle: VehicleSnapshot,
        catalog: [MaintenanceCatalogItem],
        events: [MaintenanceEvent],
        now: Date = Date()
    ) -> [MaintenanceStatus] {
        // Restrict events to this vehicle and pre-sort newest first.
        let myEvents = events
            .filter { $0.vehicleID == vehicle.id }
            .sorted { $0.date > $1.date }

        // Catalog rows that apply to this vehicle: empty appliesTo means
        // "all"; otherwise must contain this vehicle id.
        let myCatalog = catalog.filter { $0.appliesTo.isEmpty || $0.appliesTo.contains(vehicle.id) }

        var out: [MaintenanceStatus] = []
        for item in myCatalog {
            // Stepped intervals: a "recurring" stage is dormant until
            // its predecessor first-stage row has at least one event.
            if item.stage == "recurring",
               let predID = item.predecessorID,
               !myEvents.contains(where: { $0.catalogIDs.contains(predID) }) {
                continue
            }
            // Conversely, "first"-stage rows shouldn't show up after
            // they've already been performed once — once the recurring
            // stage takes over, the first-stage row is a one-shot
            // historical marker.
            if item.stage == "first" {
                let everDone = myEvents.contains(where: { $0.catalogIDs.contains(item.id) })
                let recurringExists = catalog.contains(where: { $0.predecessorID == item.id })
                if everDone, recurringExists { continue }
            }

            // Newest event matching this catalog row directly. For
            // `recurring`-stage rows that have never been performed
            // since the predecessor's first-stage event, fall back to
            // the predecessor's anchor — that's the date/mileage from
            // which the recurring interval starts ticking.
            var last = myEvents.first { $0.catalogIDs.contains(item.id) }
            if last == nil, item.stage == "recurring", let predID = item.predecessorID {
                last = myEvents.first { $0.catalogIDs.contains(predID) }
            }
            out.append(makeStatus(vehicle: vehicle, item: item, last: last, myEvents: myEvents, now: now))
        }

        return out.sorted(by: statusOrdering)
    }

    private func makeStatus(
        vehicle: VehicleSnapshot,
        item: MaintenanceCatalogItem,
        last: MaintenanceEvent?,
        myEvents: [MaintenanceEvent],
        now: Date
    ) -> MaintenanceStatus {
        let (nextDate, nextMiles) = projectNextDue(item: item, last: last)
        let daysUntil: Int? = nextDate.map { Int(($0.timeIntervalSince(now)) / 86_400) }

        // Search for "later service crossed the mileage threshold
        // without including this catalog item" — the only mileage
        // signal we can assert from logged data alone. Today's
        // odometer is unknown to us; we don't extrapolate it.
        let missedEvidence: MaintenanceStatus.MissedWindowEvidence? = {
            guard let last, let nextMiles else { return nil }
            // Look at events newer than `last` (or in time-only mode,
            // any event at all that isn't `last` itself), pick the
            // earliest one whose mileage clears the threshold and
            // does not include this item. Earliest = most-conservative
            // evidence of when the window was crossed.
            let candidates = myEvents
                .filter { $0.id != last.id && $0.date >= last.date }
                .filter { !$0.catalogIDs.contains(item.id) }
                .filter { ($0.mileage ?? -1) >= nextMiles }
                .sorted { $0.date < $1.date }
            guard let first = candidates.first, let m = first.mileage else { return nil }
            return .init(eventDate: first.date, eventMileage: m)
        }()

        let kind: MaintenanceStatusKind = {
            if last == nil {
                // Never logged. The "never vs. scheduled" question is
                // about whether the user has had the vehicle long
                // enough that they should have done this by now.
                if let firstSeen = vehicle.firstSeenAt,
                   let m = item.intervalMonths, m > 0 {
                    let elapsed = Calendar.current.dateComponents([.month], from: firstSeen, to: now).month ?? 0
                    if elapsed >= m { return .never }
                }
                // Mileage-only: if the latest known reading has
                // crossed the interval since the earliest known
                // reading, treat as never. We use known readings
                // only — no extrapolation.
                if let cur = vehicle.currentMileage,
                   let mi = item.intervalMiles, cur >= mi {
                    return .never
                }
                return .future
            }
            // Time-based signals first (factual: clock is real).
            if let d = daysUntil, d < 0 { return .overdue }
            // Then the data-grounded mileage signal.
            if missedEvidence != nil { return .missedWindow }
            // Soft date threshold.
            if let d = daysUntil, d <= Self.dueSoonDays { return .dueSoon }
            return .future
        }()

        return MaintenanceStatus(
            vehicleID: vehicle.id,
            catalogID: item.id,
            title: item.title,
            kind: kind,
            lastEventDate: last?.date,
            lastEventMileage: last?.mileage,
            nextDueDate: nextDate,
            nextDueMileage: nextMiles,
            daysUntilDue: daysUntil,
            missedWindowEvidence: missedEvidence
        )
    }

    private func projectNextDue(
        item: MaintenanceCatalogItem,
        last: MaintenanceEvent?
    ) -> (date: Date?, miles: Int?) {
        guard let last else { return (nil, nil) }
        var dueDate: Date?
        var dueMiles: Int?
        if let m = item.intervalMonths, m > 0 {
            dueDate = Calendar.current.date(byAdding: .month, value: m, to: last.date)
        }
        if let mi = item.intervalMiles, let lastMi = last.mileage {
            dueMiles = lastMi + mi
        }
        return (dueDate, dueMiles)
    }

    private func statusOrdering(_ a: MaintenanceStatus, _ b: MaintenanceStatus) -> Bool {
        let order: [MaintenanceStatusKind: Int] = [
            .overdue: 0, .missedWindow: 1, .dueSoon: 2, .never: 3, .future: 4,
        ]
        let ao = order[a.kind] ?? 99
        let bo = order[b.kind] ?? 99
        if ao != bo { return ao < bo }
        // Within a status bucket, soonest deadline first; nil = far future.
        let aDate = a.nextDueDate ?? .distantFuture
        let bDate = b.nextDueDate ?? .distantFuture
        if aDate != bDate { return aDate < bDate }
        return a.title.localizedCompare(b.title) == .orderedAscending
    }
}
