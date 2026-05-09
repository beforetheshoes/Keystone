import Foundation
import GRDB

/// Reads helpers that translate between the database schema and the
/// pure-data inputs to `MaintenanceStatusEngine`. Lives next to the
/// engine so callers in the CLI and SwiftUI layers can share one
/// fetch path.
enum MaintenanceReads {
    /// Load every Service Catalog row plus its `applies_to_vehicles`
    /// link set. Catalog with no links comes back with an empty
    /// `appliesTo`, which the engine treats as "all vehicles".
    static func catalogItems(_ db: Database) throws -> [MaintenanceCatalogItem] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT r.id, r.title,
                   pv_miles.number_value  AS interval_miles,
                   pv_months.number_value AS interval_months,
                   pv_sev.text_value     AS severity,
                   pv_stage.text_value   AS stage
            FROM records r
            LEFT JOIN property_values pv_miles  ON pv_miles.record_id  = r.id AND pv_miles.property_id  = 'service_catalog.interval_miles'
            LEFT JOIN property_values pv_months ON pv_months.record_id = r.id AND pv_months.property_id = 'service_catalog.interval_months'
            LEFT JOIN property_values pv_sev    ON pv_sev.record_id    = r.id AND pv_sev.property_id    = 'service_catalog.schedule_severity'
            LEFT JOIN property_values pv_stage  ON pv_stage.record_id  = r.id AND pv_stage.property_id  = 'service_catalog.stage'
            WHERE r.database_id = 'service_catalog' AND r.deleted_at IS NULL
            ORDER BY r.sort_index
        """)

        // Pull predecessor relations and applies_to_vehicles in two
        // small joins, keyed by source record id.
        let predRows = try Row.fetchAll(db, sql: """
            SELECT source_record_id, target_record_id
            FROM relations
            WHERE property_id = 'service_catalog.predecessor'
        """)
        var predecessorBySource: [String: String] = [:]
        for r in predRows {
            predecessorBySource[r["source_record_id"] as String] = r["target_record_id"] as String
        }

        let appRows = try Row.fetchAll(db, sql: """
            SELECT source_record_id, target_record_id
            FROM relations
            WHERE property_id = 'service_catalog.applies_to_vehicles'
        """)
        var appliesBySource: [String: Set<String>] = [:]
        for r in appRows {
            appliesBySource[r["source_record_id"] as String, default: []].insert(r["target_record_id"] as String)
        }

        return rows.map { r in
            let id: String = r["id"]
            let intervalMiles  = (r["interval_miles"]  as Double?).map(Int.init)
            let intervalMonths = (r["interval_months"] as Double?).map(Int.init)
            return MaintenanceCatalogItem(
                id: id,
                title: r["title"] as String,
                intervalMiles: intervalMiles,
                intervalMonths: intervalMonths,
                severity: r["severity"] as String?,
                stage: r["stage"] as String?,
                predecessorID: predecessorBySource[id],
                appliesTo: appliesBySource[id] ?? []
            )
        }
    }

    /// Load every vehicle_maintenance event, including its date,
    /// mileage, vehicle relation, and `services` catalog ids.
    static func events(_ db: Database) throws -> [MaintenanceEvent] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT r.id,
                   pv_date.date_value     AS date_iso,
                   pv_mi.number_value    AS mileage,
                   rel_v.target_record_id AS vehicle_id
            FROM records r
            LEFT JOIN property_values pv_date ON pv_date.record_id = r.id AND pv_date.property_id = 'vehicle_maintenance.date'
            LEFT JOIN property_values pv_mi   ON pv_mi.record_id   = r.id AND pv_mi.property_id   = 'vehicle_maintenance.mileage'
            LEFT JOIN relations       rel_v   ON rel_v.source_record_id = r.id AND rel_v.property_id = 'vehicle_maintenance.vehicle'
            WHERE r.database_id = 'vehicle_maintenance' AND r.deleted_at IS NULL
        """)
        let svcRows = try Row.fetchAll(db, sql: """
            SELECT source_record_id, target_record_id
            FROM relations
            WHERE property_id = 'vehicle_maintenance.services'
        """)
        var servicesByEvent: [String: Set<String>] = [:]
        for r in svcRows {
            servicesByEvent[r["source_record_id"] as String, default: []].insert(r["target_record_id"] as String)
        }

        let parser = ISO8601DateFormatter()
        let plain = DateFormatter()
        plain.dateFormat = "yyyy-MM-dd"
        plain.timeZone = TimeZone(identifier: "UTC")

        return rows.compactMap { r in
            let id: String = r["id"]
            guard let vehicleID = r["vehicle_id"] as String? else { return nil }
            let dateString = (r["date_iso"] as String?) ?? ""
            let date = parser.date(from: dateString) ?? plain.date(from: dateString)
            guard let date else { return nil }
            let mileage = (r["mileage"] as Double?).map(Int.init)
            return MaintenanceEvent(
                id: id,
                vehicleID: vehicleID,
                date: date,
                mileage: mileage,
                catalogIDs: servicesByEvent[id] ?? []
            )
        }
    }

    /// Load every vehicle plus its current-mileage snapshot. The
    /// effective mileage is the **max** of:
    ///   - any user-set `vehicles.current_mileage` property value, and
    ///   - the highest `mileage` across that vehicle's
    ///     `vehicle_maintenance` events.
    ///
    /// Computing on read avoids the "stored snapshot drifts away from
    /// actual data" class of bug. The user can still override via the
    /// vehicle property (e.g. punch in today's odometer reading
    /// without creating an event), and any later event with a higher
    /// reading takes over automatically. The `as_of` date follows
    /// whichever source won.
    static func vehicleSnapshots(_ db: Database) throws -> [VehicleSnapshot] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT r.id, r.title,
                   pv_cm.number_value AS stored_mileage,
                   pv_as.date_value   AS stored_as_of
            FROM records r
            LEFT JOIN property_values pv_cm ON pv_cm.record_id = r.id AND pv_cm.property_id = 'vehicles.current_mileage'
            LEFT JOIN property_values pv_as ON pv_as.record_id = r.id AND pv_as.property_id = 'vehicles.current_mileage_as_of'
            WHERE r.database_id = 'vehicles' AND r.deleted_at IS NULL
            ORDER BY r.sort_index
        """)

        // Per-vehicle max event mileage + the date of that event,
        // pulled in one pass and indexed by vehicle id. Plus the
        // earliest event date as `firstSeenAt` — needed by the
        // engine's time-based `never` check.
        let eventRows = try Row.fetchAll(db, sql: """
            SELECT rel.target_record_id AS vehicle_id,
                   pv_m.number_value    AS event_mileage,
                   pv_d.date_value      AS event_date
            FROM relations rel
            JOIN records r ON r.id = rel.source_record_id
            LEFT JOIN property_values pv_m ON pv_m.record_id = r.id AND pv_m.property_id = 'vehicle_maintenance.mileage'
            LEFT JOIN property_values pv_d ON pv_d.record_id = r.id AND pv_d.property_id = 'vehicle_maintenance.date'
            WHERE rel.property_id = 'vehicle_maintenance.vehicle'
              AND r.deleted_at IS NULL
        """)

        let plain = DateFormatter()
        plain.dateFormat = "yyyy-MM-dd"
        plain.timeZone = TimeZone(identifier: "UTC")

        var eventMaxByVehicle: [String: (mileage: Int, date: Date?)] = [:]
        var firstSeenByVehicle: [String: Date] = [:]
        for row in eventRows {
            let vid = row["vehicle_id"] as String
            let d = (row["event_date"] as String?).flatMap { plain.date(from: $0) }
            if let m = (row["event_mileage"] as Double?).map(Int.init) {
                if let prior = eventMaxByVehicle[vid] {
                    if m > prior.mileage { eventMaxByVehicle[vid] = (m, d) }
                } else {
                    eventMaxByVehicle[vid] = (m, d)
                }
            }
            if let d {
                if let prior = firstSeenByVehicle[vid] {
                    if d < prior { firstSeenByVehicle[vid] = d }
                } else {
                    firstSeenByVehicle[vid] = d
                }
            }
        }

        return rows.map { r in
            let id: String = r["id"]
            let storedMileage = (r["stored_mileage"] as Double?).map(Int.init)
            let storedAsOf    = (r["stored_as_of"] as String?).flatMap { plain.date(from: $0) }
            let eventMax = eventMaxByVehicle[id]

            // Pick whichever source has the higher mileage. Ties go to
            // the stored value (user's explicit assertion wins over a
            // tying event). When neither is set, both fields are nil.
            let effective: (mileage: Int?, asOf: Date?) = {
                switch (storedMileage, eventMax) {
                case (nil, nil):
                    return (nil, nil)
                case (let s?, nil):
                    return (s, storedAsOf)
                case (nil, let e?):
                    return (e.mileage, e.date)
                case (let s?, let e?):
                    return e.mileage > s ? (e.mileage, e.date) : (s, storedAsOf)
                }
            }()

            return VehicleSnapshot(
                id: id,
                title: r["title"] as String,
                currentMileage: effective.mileage,
                currentMileageAsOf: effective.asOf,
                firstSeenAt: firstSeenByVehicle[id]
            )
        }
    }
}
