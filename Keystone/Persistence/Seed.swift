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
            ("area-travel",   "Travel",   "cerulean", 5),
            ("area-collections", "Collections", "iris",  6),
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
            DBSeed(key: "service_catalog", name: "Service Catalog", plural: "Service Catalog", icon: "SC", accent: "iris", area: "area-mobility", defaultView: "list", sort: 4.6),
            DBSeed(key: "vendors",     name: "Vendors",        plural: "Vendors",       icon: "Vn", accent: "graphite", area: "area-records",  defaultView: "table",     sort: 4.7),
            DBSeed(key: "documents",   name: "Documents",      plural: "Documents",     icon: "D",  accent: "cerulean", area: "area-records",  defaultView: "table",     sort: 5),
            DBSeed(key: "events",      name: "Events",         plural: "Events",        icon: "E",  accent: "amber",    area: "area-plans",    defaultView: "table",     sort: 6),
            DBSeed(key: "trips",          name: "Trips",          plural: "Trips",          icon: "T",  accent: "cerulean", area: "area-travel", defaultView: "list",  sort: 7.0),
            DBSeed(key: "activities",     name: "Activities",     plural: "Activities",     icon: "Ac", accent: "cerulean", area: "area-travel", defaultView: "table", sort: 7.1),
            DBSeed(key: "lodging",        name: "Lodging",        plural: "Lodging",        icon: "L",  accent: "cerulean", area: "area-travel", defaultView: "table", sort: 7.2),
            DBSeed(key: "transportation", name: "Transportation", plural: "Transportation", icon: "Tr", accent: "cerulean", area: "area-travel", defaultView: "table", sort: 7.3),
            DBSeed(key: "books",       name: "Books",       plural: "Books",       icon: "B",  accent: "iris", area: "area-collections", defaultView: "gallery", sort: 8.0),
            DBSeed(key: "movies",      name: "Movies",      plural: "Movies",      icon: "Mo", accent: "iris", area: "area-collections", defaultView: "gallery", sort: 8.1),
            DBSeed(key: "tv_shows",    name: "TV Shows",    plural: "TV Shows",    icon: "Tv", accent: "iris", area: "area-collections", defaultView: "gallery", sort: 8.2),
            // NB: Restaurants is no longer a database — see v41. It's
            // seeded below as a saved view over `vendors` with
            // `kind = "restaurant"` pinned.
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
            PropSeed(db: "homes", key: "address",   label: "Address",   type: "address", sort: 1),
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
            PropSeed(db: "vehicles", key: "current_mileage",       label: "Current mileage", type: "number", sort: 7.0),
            PropSeed(db: "vehicles", key: "current_mileage_as_of", label: "As of",           type: "date",   sort: 7.1),
            // service_catalog
            PropSeed(db: "service_catalog", key: "name",         label: "Service",           type: "title",    sort: 0),
            PropSeed(db: "service_catalog", key: "subject_kind", label: "Applies to (kind)", type: "select",   sort: 1),
            PropSeed(db: "service_catalog", key: "applies_to_vehicles", label: "Vehicles",   type: "relation", sort: 2),
            PropSeed(db: "service_catalog", key: "interval_miles",  label: "Every (mi)",     type: "number",   sort: 3),
            PropSeed(db: "service_catalog", key: "interval_months", label: "Every (months)", type: "number",   sort: 4),
            PropSeed(db: "service_catalog", key: "schedule_severity", label: "Schedule",     type: "select",   sort: 5),
            PropSeed(db: "service_catalog", key: "stage",        label: "Stage",             type: "select",   sort: 6),
            PropSeed(db: "service_catalog", key: "predecessor",  label: "After",             type: "relation", sort: 7),
            PropSeed(db: "service_catalog", key: "notes",        label: "Notes",             type: "text",     sort: 8),
            // vehicle_maintenance
            PropSeed(db: "vehicle_maintenance", key: "name",    label: "Title",   type: "title",    sort: 0),
            PropSeed(db: "vehicle_maintenance", key: "date",    label: "Date",    type: "date",     sort: 1),
            PropSeed(db: "vehicle_maintenance", key: "vehicle", label: "Vehicle", type: "relation", sort: 2),
            PropSeed(db: "vehicle_maintenance", key: "kind",    label: "Kind",    type: "select",   sort: 3),
            PropSeed(db: "vehicle_maintenance", key: "vendor",  label: "Vendor",  type: "relation", sort: 4),
            PropSeed(db: "vehicle_maintenance", key: "mileage", label: "Mileage", type: "number",   sort: 5),
            PropSeed(db: "vehicle_maintenance", key: "cost",    label: "Cost",    type: "number",   sort: 6),
            PropSeed(db: "vehicle_maintenance", key: "services", label: "Services", type: "relation", sort: 6.5),
            // vendors
            PropSeed(db: "vendors", key: "name",         label: "Name",            type: "title",  sort: 0),
            PropSeed(db: "vendors", key: "kind",         label: "Kind",            type: "select", sort: 1),
            // Restaurant-only vendor properties (v41). The applicable_kinds
            // config keeps them hidden from non-restaurant vendor detail
            // views and from generic Vendor table columns.
            PropSeed(db: "vendors", key: "cuisine",      label: "Tags",            type: "multiSelect", sort: 1.1),
            PropSeed(db: "vendors", key: "price_range",  label: "Price",           type: "select", sort: 1.2),
            PropSeed(db: "vendors", key: "rating",       label: "Rating",          type: "number", sort: 1.3),
            PropSeed(db: "vendors", key: "status",       label: "Status",          type: "select", sort: 1.4),
            PropSeed(db: "vendors", key: "last_visited", label: "Last visited",    type: "date",   sort: 1.5),
            PropSeed(db: "vendors", key: "hours",        label: "Hours",           type: "text",   sort: 1.6),
            PropSeed(db: "vendors", key: "menu_url",     label: "Menu",            type: "url",    sort: 1.7),
            PropSeed(db: "vendors", key: "phone",        label: "Phone",           type: "phone",  sort: 2),
            PropSeed(db: "vendors", key: "email",        label: "Email",           type: "email",  sort: 3),
            PropSeed(db: "vendors", key: "website",      label: "Website",         type: "url",    sort: 4),
            PropSeed(db: "vendors", key: "address",      label: "Address",         type: "address",sort: 5),
            PropSeed(db: "vendors", key: "locality",     label: "City",            type: "text",   sort: 5.5),
            PropSeed(db: "vendors", key: "notes",        label: "Notes",           type: "text",   sort: 6),
            PropSeed(db: "vendors", key: "place_id",     label: "Apple Place ID",  type: "text",   sort: 100),
            PropSeed(db: "vendors", key: "web_enriched_at", label: "Web enriched",  type: "date",   sort: 100),
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
            // trips
            PropSeed(db: "trips", key: "name",         label: "Name",   type: "title",    sort: 0),
            PropSeed(db: "trips", key: "notes",        label: "Notes",  type: "text",     sort: 1),
            PropSeed(db: "trips", key: "start_date",   label: "Start",  type: "date",     sort: 2),
            PropSeed(db: "trips", key: "end_date",     label: "End",    type: "date",     sort: 3),
            PropSeed(db: "trips", key: "is_protected", label: "Locked", type: "checkbox", sort: 4),
            // activities
            PropSeed(db: "activities", key: "name",         label: "Title",  type: "title",    sort: 0),
            PropSeed(db: "activities", key: "trip",         label: "Trip",   type: "relation", sort: 1),
            PropSeed(db: "activities", key: "organization", label: "Vendor", type: "relation", sort: 2),
            PropSeed(db: "activities", key: "start",        label: "Start",  type: "date_tz",  sort: 3),
            PropSeed(db: "activities", key: "end",          label: "End",    type: "date_tz",  sort: 4),
            PropSeed(db: "activities", key: "address",      label: "Address",type: "address",  sort: 4.5),
            PropSeed(db: "activities", key: "cost",         label: "Cost",   type: "currency", sort: 5),
            PropSeed(db: "activities", key: "notes",        label: "Notes",  type: "text",     sort: 6),
            // lodging
            PropSeed(db: "lodging", key: "name",                label: "Name",         type: "title",    sort: 0),
            PropSeed(db: "lodging", key: "trip",                label: "Trip",         type: "relation", sort: 1),
            PropSeed(db: "lodging", key: "organization",        label: "Vendor",       type: "relation", sort: 2),
            PropSeed(db: "lodging", key: "check_in",            label: "Check-in",     type: "date_tz",  sort: 3),
            PropSeed(db: "lodging", key: "check_out",           label: "Check-out",    type: "date_tz",  sort: 4),
            PropSeed(db: "lodging", key: "address",             label: "Address",      type: "address",  sort: 4.5),
            PropSeed(db: "lodging", key: "confirmation_number", label: "Confirmation", type: "text",     sort: 5),
            PropSeed(db: "lodging", key: "cost",                label: "Cost",         type: "currency", sort: 6),
            PropSeed(db: "lodging", key: "notes",               label: "Notes",        type: "text",     sort: 7),
            // transportation
            PropSeed(db: "transportation", key: "name",         label: "Name",   type: "title",    sort: 0),
            PropSeed(db: "transportation", key: "trip",         label: "Trip",   type: "relation", sort: 1),
            PropSeed(db: "transportation", key: "organization", label: "Vendor", type: "relation", sort: 2),
            PropSeed(db: "transportation", key: "kind",         label: "Kind",   type: "select",   sort: 3),
            PropSeed(db: "transportation", key: "legs",         label: "Legs",   type: "json",     sort: 4),
            PropSeed(db: "transportation", key: "cost",         label: "Cost",   type: "currency", sort: 5),
            PropSeed(db: "transportation", key: "notes",        label: "Notes",  type: "text",     sort: 6),
            // books
            PropSeed(db: "books", key: "name",             label: "Title",          type: "title",       sort: 0),
            PropSeed(db: "books", key: "author",           label: "Author",         type: "text",        sort: 1),
            PropSeed(db: "books", key: "isbn",             label: "ISBN",           type: "text",        sort: 2),
            PropSeed(db: "books", key: "publisher",        label: "Publisher",      type: "text",        sort: 3),
            PropSeed(db: "books", key: "published_date",   label: "Published",      type: "date",        sort: 4),
            PropSeed(db: "books", key: "page_count",       label: "Pages",          type: "number",      sort: 5),
            PropSeed(db: "books", key: "readable_pages",   label: "Readable pages", type: "number",      sort: 5.5),
            PropSeed(db: "books", key: "status",           label: "Status",         type: "select",      sort: 6),
            PropSeed(db: "books", key: "progress_mode",    label: "Progress mode",  type: "select",      sort: 6.1),
            PropSeed(db: "books", key: "current_page",     label: "Current page",   type: "number",      sort: 6.2),
            PropSeed(db: "books", key: "progress_percent", label: "Progress %",     type: "number",      sort: 6.3),
            PropSeed(db: "books", key: "rating",           label: "Rating",         type: "number",      sort: 7),
            PropSeed(db: "books", key: "started_date",     label: "Started",        type: "date",        sort: 8),
            PropSeed(db: "books", key: "finished_date",    label: "Finished",       type: "date",        sort: 9),
            PropSeed(db: "books", key: "description",      label: "Description",    type: "text",        sort: 9.5),
            PropSeed(db: "books", key: "tags",             label: "Tags",           type: "multiSelect", sort: 9.6),
            PropSeed(db: "books", key: "notes",            label: "Notes",          type: "text",        sort: 10),
            // movies
            PropSeed(db: "movies", key: "name",            label: "Title",         type: "title",       sort: 0),
            PropSeed(db: "movies", key: "year",            label: "Year",          type: "number",      sort: 1),
            PropSeed(db: "movies", key: "tmdb_id",         label: "TMDB ID",       type: "text",        sort: 2),
            PropSeed(db: "movies", key: "release_date",    label: "Released",      type: "date",        sort: 3),
            PropSeed(db: "movies", key: "runtime_minutes", label: "Runtime (min)", type: "number",      sort: 4),
            PropSeed(db: "movies", key: "overview",        label: "Overview",      type: "text",        sort: 5),
            PropSeed(db: "movies", key: "status",          label: "Status",        type: "select",      sort: 6),
            PropSeed(db: "movies", key: "rating",          label: "Rating",        type: "number",      sort: 7),
            PropSeed(db: "movies", key: "watched_date",    label: "Watched",       type: "date",        sort: 8),
            PropSeed(db: "movies", key: "tags",            label: "Tags",          type: "multiSelect", sort: 8.5),
            PropSeed(db: "movies", key: "notes",           label: "Notes",         type: "text",        sort: 9),
            // tv_shows
            PropSeed(db: "tv_shows", key: "name",            label: "Title",          type: "title",       sort: 0),
            PropSeed(db: "tv_shows", key: "year",            label: "Year",           type: "number",      sort: 1),
            PropSeed(db: "tv_shows", key: "tmdb_id",         label: "TMDB ID",        type: "text",        sort: 2),
            PropSeed(db: "tv_shows", key: "first_air_date",  label: "First aired",    type: "date",        sort: 3),
            PropSeed(db: "tv_shows", key: "season_count",    label: "Seasons",        type: "number",      sort: 4),
            PropSeed(db: "tv_shows", key: "episode_count",   label: "Episodes",       type: "number",      sort: 5),
            PropSeed(db: "tv_shows", key: "overview",        label: "Overview",       type: "text",        sort: 6),
            PropSeed(db: "tv_shows", key: "status",          label: "Status",         type: "select",      sort: 7),
            PropSeed(db: "tv_shows", key: "current_season",  label: "Current season", type: "number",      sort: 7.1),
            PropSeed(db: "tv_shows", key: "current_episode", label: "Current episode",type: "number",      sort: 7.2),
            PropSeed(db: "tv_shows", key: "rating",          label: "Rating",         type: "number",      sort: 8),
            PropSeed(db: "tv_shows", key: "last_watched",    label: "Last watched",   type: "date",        sort: 9),
            PropSeed(db: "tv_shows", key: "tags",            label: "Tags",           type: "multiSelect", sort: 9.5),
            PropSeed(db: "tv_shows", key: "notes",           label: "Notes",          type: "text",        sort: 10),
            // (Restaurants props live on `vendors` post-v41 — see above.)
        ]
        for p in props {
            let propID = "\(p.db).\(p.key)"
            let configJSON: String = {
                switch (p.db, p.key) {
                // Relation properties — point at the target database.
                case ("pets", "vet"):           return #"{"targetDatabaseID":"people"}"#
                case ("documents", "related"):  return #"{"targetDatabaseID":"people"}"#
                case ("events", "with"):        return #"{"targetDatabaseID":"people"}"#
                case ("maintenance", "home"):   return #"{"targetDatabaseID":"homes"}"#
                case ("vehicle_maintenance", "vehicle"): return #"{"targetDatabaseID":"vehicles"}"#
                case ("vehicle_maintenance", "vendor"):  return #"{"targetDatabaseID":"vendors"}"#
                case ("vehicle_maintenance", "services"): return #"{"targetDatabaseID":"service_catalog","multi":true}"#
                case ("service_catalog",     "applies_to_vehicles"): return #"{"targetDatabaseID":"vehicles","multi":true}"#
                case ("service_catalog",     "predecessor"):         return #"{"targetDatabaseID":"service_catalog"}"#
                case ("service_catalog",     "subject_kind"):        return #"{"options":["vehicle","home","pet"]}"#
                case ("service_catalog",     "schedule_severity"):   return #"{"options":["normal","severe"]}"#
                case ("service_catalog",     "stage"):               return #"{"options":["first","recurring"]}"#
                case ("activities",     "trip"):         return #"{"targetDatabaseID":"trips"}"#
                case ("activities",     "organization"): return #"{"targetDatabaseID":"vendors"}"#
                case ("lodging",        "trip"):         return #"{"targetDatabaseID":"trips"}"#
                case ("lodging",        "organization"): return #"{"targetDatabaseID":"vendors"}"#
                case ("transportation", "trip"):         return #"{"targetDatabaseID":"trips"}"#
                case ("transportation", "organization"): return #"{"targetDatabaseID":"vendors"}"#
                // Select properties with a fixed option list. Cycle-on-tap
                // depends on this; without options the editor falls back
                // to free-form text.
                case ("books",       "status"):        return #"{"options":["to_read","reading","read","abandoned"]}"#
                case ("books",       "progress_mode"): return #"{"options":["pages","percent"]}"#
                case ("movies",      "status"):        return #"{"options":["to_watch","watched","dropped"]}"#
                case ("tv_shows",    "status"):        return #"{"options":["to_watch","watching","watched","dropped"]}"#
                // Restaurant-only vendor properties (v41). Each carries
                // `applicable_kinds:["restaurant"]` so the detail view
                // hides the field for non-restaurant vendors.
                case ("vendors", "cuisine"):      return #"{"applicable_kinds":["restaurant"]}"#
                case ("vendors", "price_range"):  return #"{"options":["$","$$","$$$","$$$$"],"applicable_kinds":["restaurant"]}"#
                case ("vendors", "rating"):       return #"{"applicable_kinds":["restaurant"]}"#
                case ("vendors", "status"):       return #"{"options":["want_to_try","visited"],"applicable_kinds":["restaurant"]}"#
                case ("vendors", "last_visited"): return #"{"applicable_kinds":["restaurant"]}"#
                case ("vendors", "hours"):        return #"{"applicable_kinds":["restaurant"]}"#
                case ("vendors", "menu_url"):     return #"{"applicable_kinds":["restaurant"]}"#
                case ("vendors", "web_enriched_at"): return #"{"applicable_kinds":["restaurant"],"hidden":true}"#
                case ("vendors", "place_id"):     return #"{"hidden":true}"#
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

        // Service Catalog rows for the Honda Maintenance Schedule.
        // The v28 migration also seeds these, but on fresh installs
        // it runs before this workspace exists and exits early — call
        // again here to cover the cold-start case. Idempotent.
        try Schema.seedHondaCatalogRows(db)
        // Same logic for the GMC catalog (v32). Idempotent.
        try Schema.seedGMCCatalogRows(db)

        // Restaurants is a saved view over `vendors` with kind pinned to
        // "restaurant" (v41). Same shape the v41 migration writes for
        // existing workspaces. Idempotent via the row's stable id.
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO views (
                    id, database_id, workspace_id, name, plural_name,
                    type, query_json, presentation_json,
                    icon, accent, area_id, sort_index,
                    created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                "view-restaurants", "vendors", workspaceID,
                "Restaurants", "Restaurants",
                "table",
                #"{"kind":["restaurant"]}"#,
                #"{"lookupProvider":"restaurant"}"#,
                "Re", "iris", "area-collections", 8.3,
                now, now
            ]
        )
    }

}
