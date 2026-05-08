import Foundation
import GRDB

enum Seed {
    static let workspaceID = "ws-default"

    static func runIfEmpty(_ db: Database) throws {
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workspaces") ?? 0
        guard count == 0 else { return }

        let now = AppDatabase.isoFormatter.string(from: Date())

        try db.execute(
            sql: "INSERT OR IGNORE INTO workspaces (id, name, created_at, updated_at, schema_version) VALUES (?, ?, ?, ?, ?)",
            arguments: [workspaceID, "My Keystone", now, now, 1]
        )

        // Areas
        let areas: [(id: String, title: String, accent: String, sort: Double)] = [
            ("area-family",   "Family",   "cerulean", 0),
            ("area-home",     "Home",     "sage",     1),
            ("area-mobility", "Mobility", "iris",     2),
            ("area-records",  "Records",  "cerulean", 3),
            ("area-plans",    "Plans",    "amber",    4),
        ]
        for a in areas {
            try db.execute(
                sql: "INSERT OR IGNORE INTO areas (id, workspace_id, title, accent, sort_index) VALUES (?, ?, ?, ?, ?)",
                arguments: [a.id, workspaceID, a.title, a.accent, a.sort]
            )
        }

        // Databases (key, name, plural, icon, accent, area, defaultView)
        struct DBSeed { let key: String; let name: String; let plural: String; let icon: String; let accent: String; let area: String; let defaultView: String; let sort: Double }
        let dbs: [DBSeed] = [
            DBSeed(key: "people",      name: "People",         plural: "People",        icon: "P",  accent: "cerulean", area: "area-family",   defaultView: "table",     sort: 0),
            DBSeed(key: "pets",        name: "Pets",           plural: "Pets",          icon: "Pe", accent: "sage",     area: "area-family",   defaultView: "gallery",   sort: 1),
            DBSeed(key: "homes",       name: "Homes",          plural: "Homes",         icon: "H",  accent: "sage",     area: "area-home",     defaultView: "gallery",   sort: 2),
            DBSeed(key: "maintenance", name: "Maintenance",    plural: "Maintenance",   icon: "M",  accent: "sage",     area: "area-home",     defaultView: "list",      sort: 3),
            DBSeed(key: "vehicles",    name: "Vehicles",       plural: "Vehicles",      icon: "V",  accent: "iris",     area: "area-mobility", defaultView: "table",     sort: 4),
            DBSeed(key: "vehicle_maintenance", name: "Vehicle Maintenance", plural: "Vehicle Maintenance", icon: "VM", accent: "iris", area: "area-mobility", defaultView: "table", sort: 4.5),
            DBSeed(key: "vendors",     name: "Vendors",        plural: "Vendors",       icon: "Vn", accent: "graphite", area: "area-records",  defaultView: "table",     sort: 4.7),
            DBSeed(key: "documents",   name: "Documents",      plural: "Documents",     icon: "D",  accent: "cerulean", area: "area-records",  defaultView: "table",     sort: 5),
            DBSeed(key: "events",      name: "Events & Trips", plural: "Events & Trips",icon: "E",  accent: "amber",    area: "area-plans",    defaultView: "table",     sort: 6),
        ]
        for d in dbs {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO databases (id, workspace_id, area_id, name, plural_name, icon, accent, default_view, created_at, updated_at, sort_index)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [d.key, workspaceID, d.area, d.name, d.plural, d.icon, d.accent, d.defaultView, now, now, d.sort]
            )
        }

        // Properties — keyed (database_id, key)
        struct PropSeed { let db: String; let key: String; let label: String; let type: String; let sort: Double }
        let props: [PropSeed] = [
            // people
            PropSeed(db: "people", key: "name",         label: "Name",       type: "title",  sort: 0),
            PropSeed(db: "people", key: "relationship", label: "Relation",   type: "select", sort: 1),
            PropSeed(db: "people", key: "birthday",     label: "Birthday",   type: "date",   sort: 2),
            PropSeed(db: "people", key: "phone",        label: "Phone",      type: "phone",  sort: 3),
            PropSeed(db: "people", key: "email",        label: "Email",      type: "email",  sort: 4),
            PropSeed(db: "people", key: "lastSeen",     label: "Last seen",  type: "date",   sort: 5),
            // pets
            PropSeed(db: "pets", key: "name",     label: "Name",     type: "title",    sort: 0),
            PropSeed(db: "pets", key: "species",  label: "Species",  type: "select",   sort: 1),
            PropSeed(db: "pets", key: "breed",    label: "Breed",    type: "text",     sort: 2),
            PropSeed(db: "pets", key: "birthday", label: "Born",     type: "date",     sort: 3),
            PropSeed(db: "pets", key: "vet",      label: "Vet",      type: "relation", sort: 4),
            // homes
            PropSeed(db: "homes", key: "name",      label: "Name",      type: "title",  sort: 0),
            PropSeed(db: "homes", key: "address",   label: "Address",   type: "text",   sort: 1),
            PropSeed(db: "homes", key: "sqft",      label: "Sq Ft",     type: "number", sort: 2),
            PropSeed(db: "homes", key: "purchased", label: "Purchased", type: "date",   sort: 3),
            // vehicles
            PropSeed(db: "vehicles", key: "name",    label: "Name",    type: "title",  sort: 0),
            PropSeed(db: "vehicles", key: "make",    label: "Make",    type: "text",   sort: 1),
            PropSeed(db: "vehicles", key: "model",   label: "Model",   type: "text",   sort: 2),
            PropSeed(db: "vehicles", key: "year",    label: "Year",    type: "number", sort: 3),
            PropSeed(db: "vehicles", key: "plate",   label: "Plate",   type: "text",   sort: 4),
            PropSeed(db: "vehicles", key: "vin",     label: "VIN",     type: "text",   sort: 5),
            PropSeed(db: "vehicles", key: "mileage", label: "Mileage", type: "number", sort: 6),
            // vehicle_maintenance
            PropSeed(db: "vehicle_maintenance", key: "name",    label: "Title",   type: "title",    sort: 0),
            PropSeed(db: "vehicle_maintenance", key: "date",    label: "Date",    type: "date",     sort: 1),
            PropSeed(db: "vehicle_maintenance", key: "vehicle", label: "Vehicle", type: "relation", sort: 2),
            PropSeed(db: "vehicle_maintenance", key: "kind",    label: "Kind",    type: "select",   sort: 3),
            PropSeed(db: "vehicle_maintenance", key: "vendor",  label: "Vendor",  type: "relation", sort: 4),
            PropSeed(db: "vehicle_maintenance", key: "mileage", label: "Mileage", type: "number",   sort: 5),
            PropSeed(db: "vehicle_maintenance", key: "cost",    label: "Cost",    type: "number",   sort: 6),
            // vendors
            PropSeed(db: "vendors", key: "name",     label: "Name",            type: "title",  sort: 0),
            PropSeed(db: "vendors", key: "kind",     label: "Kind",            type: "select", sort: 1),
            PropSeed(db: "vendors", key: "phone",    label: "Phone",           type: "phone",  sort: 2),
            PropSeed(db: "vendors", key: "email",    label: "Email",           type: "email",  sort: 3),
            PropSeed(db: "vendors", key: "website",  label: "Website",         type: "url",    sort: 4),
            PropSeed(db: "vendors", key: "address",  label: "Address",         type: "text",   sort: 5),
            PropSeed(db: "vendors", key: "locality", label: "City",            type: "text",   sort: 5.5),
            PropSeed(db: "vendors", key: "notes",    label: "Notes",           type: "text",   sort: 6),
            PropSeed(db: "vendors", key: "place_id", label: "Apple Place ID",  type: "text",   sort: 7),
            // documents
            PropSeed(db: "documents", key: "name",    label: "Title",      type: "title",    sort: 0),
            PropSeed(db: "documents", key: "kind",    label: "Kind",       type: "select",   sort: 1),
            PropSeed(db: "documents", key: "expires", label: "Expires",    type: "date",     sort: 2),
            PropSeed(db: "documents", key: "related", label: "Related to", type: "relation", sort: 3),
            // events
            PropSeed(db: "events", key: "name",  label: "Name",  type: "title",    sort: 0),
            PropSeed(db: "events", key: "when",  label: "When",  type: "date",     sort: 1),
            PropSeed(db: "events", key: "where", label: "Where", type: "text",     sort: 2),
            PropSeed(db: "events", key: "with",  label: "With",  type: "relation", sort: 3),
            // maintenance
            PropSeed(db: "maintenance", key: "name",    label: "Task",    type: "title",    sort: 0),
            PropSeed(db: "maintenance", key: "home",    label: "Home",    type: "relation", sort: 1),
            PropSeed(db: "maintenance", key: "due",     label: "Due",     type: "date",     sort: 2),
            PropSeed(db: "maintenance", key: "cadence", label: "Cadence", type: "select",   sort: 3),
        ]
        for p in props {
            let propID = "\(p.db).\(p.key)"
            let configJSON: String = {
                guard p.type == "relation" else { return "{}" }
                switch (p.db, p.key) {
                case ("pets", "vet"):           return #"{"targetDatabaseID":"people"}"#
                case ("documents", "related"):  return #"{"targetDatabaseID":"people"}"#
                case ("events", "with"):        return #"{"targetDatabaseID":"people"}"#
                case ("maintenance", "home"):   return #"{"targetDatabaseID":"homes"}"#
                case ("vehicle_maintenance", "vehicle"): return #"{"targetDatabaseID":"vehicles"}"#
                case ("vehicle_maintenance", "vendor"):  return #"{"targetDatabaseID":"vendors"}"#
                default:                        return "{}"
                }
            }()
            // OR IGNORE so a partially-applied previous Seed run (or a
            // pre-fix v19/v20 migration that landed a property row before
            // the vendors database existed) doesn't trip on the second
            // attempt. The property's column values are deterministic
            // and identical between runs, so keeping the existing row
            // is equivalent to inserting it.
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO properties (id, database_id, key, name, type, config_json, is_required, is_archived, created_at, updated_at, sort_index)
                    VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?)
                """,
                arguments: [propID, p.db, p.key, p.label, p.type, configJSON, now, now, p.sort]
            )
        }
    }

}
