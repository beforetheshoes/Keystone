import XCTest
import Dependencies
import GRDB
@preconcurrency import SQLiteData
@testable import Keystone

/// Coverage for the v41 unification: Restaurants is a saved view over
/// Vendors with `kind = "restaurant"` pinned, restaurant-specific
/// properties live on the Vendors table tagged with `applicable_kinds`,
/// and the v41 migration folds any pre-existing `restaurants` records
/// into their linked Vendor (or materializes a new one).
final class RestaurantsAsVendorsViewTests: XCTestCase {
    private func withDB<T>(_ body: () throws -> T) rethrows -> T {
        try withHermeticDB(body)
    }

    // MARK: - Post-seed shape

    func testRestaurantsDatabaseRetired() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue
            let dbs = try dbClient.databases()
            XCTAssertFalse(dbs.contains { $0.id == "restaurants" },
                           "restaurants database should be gone after v41")
        }
    }

    func testRestaurantsViewSeeded() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue
            let views = try dbClient.views()
            let restaurants = try XCTUnwrap(
                views.first { $0.id == "view-restaurants" },
                "Restaurants view should be present in `views`"
            )
            XCTAssertEqual(restaurants.databaseID, "vendors")
            XCTAssertEqual(restaurants.areaID, "area-collections")
            XCTAssertEqual(restaurants.name, "Restaurants")
            XCTAssertEqual(restaurants.queryFilters["kind"], ["restaurant"])
            XCTAssertEqual(restaurants.lookupProviderKey, "restaurant")
            XCTAssertEqual(restaurants.pinnedKind, "restaurant")
        }
    }

    // MARK: - Vendor property additions

    func testVendorGainsRestaurantProperties() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue
            let props = try dbClient.properties("vendors")
            for key in ["cuisine", "price_range", "rating", "status", "last_visited", "hours"] {
                let prop = try XCTUnwrap(
                    props.first { $0.key == key },
                    "vendors.\(key) missing post-v41"
                )
                XCTAssertEqual(prop.config.applicableKinds, ["restaurant"],
                               "vendors.\(key) should scope to kind=restaurant")
            }
        }
    }

    func testUniversalVendorPropertiesUnscoped() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue
            let props = try dbClient.properties("vendors")
            for key in ["name", "kind", "phone", "address", "locality"] {
                let prop = try XCTUnwrap(props.first { $0.key == key })
                XCTAssertNil(prop.config.applicableKinds,
                             "\(key) is a universal column and shouldn't be kind-scoped")
            }
        }
    }

    func testPriceRangeOptionsPreserved() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue
            let props = try dbClient.properties("vendors")
            let priceRange = try XCTUnwrap(props.first { $0.key == "price_range" })
            XCTAssertEqual(priceRange.config.options, ["$", "$$", "$$$", "$$$$"])
        }
    }

    // MARK: - PropertyRow.isVisible(forKind:)

    func testPropertyVisibilityForKind() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue
            let props = try dbClient.properties("vendors")
            let cuisine = try XCTUnwrap(props.first { $0.key == "cuisine" })
            let phone = try XCTUnwrap(props.first { $0.key == "phone" })

            // Restaurant-only field
            XCTAssertTrue(cuisine.isVisible(forKind: "restaurant"))
            XCTAssertFalse(cuisine.isVisible(forKind: "shop"))
            XCTAssertFalse(cuisine.isVisible(forKind: nil))

            // Universal field
            XCTAssertTrue(phone.isVisible(forKind: "restaurant"))
            XCTAssertTrue(phone.isVisible(forKind: "shop"))
            XCTAssertTrue(phone.isVisible(forKind: nil))
        }
    }

    // MARK: - Migration: fold restaurants into vendors

    /// Drive the v41 migration body directly against an in-memory DB
    /// pre-loaded with a pre-v41 shape: a workspace, a `restaurants`
    /// database with the original column set, sample records (one
    /// linked to an existing vendor, one not), and the `vendors`
    /// database. Asserts the post-migration shape: every restaurants
    /// row is gone, the linked vendor picked up the restaurant's
    /// cuisine / price / status / notes, the unlinked record produced
    /// a fresh vendor with the same data, and both vendors carry
    /// `kind = "restaurant"`.
    func testMigrationFoldsRestaurantsIntoVendors() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try seedPreV41(db)
            try Schema.seedRestaurantsAsVendorsViewV41(db)
        }

        try queue.read { db in
            // 1. Restaurants database is gone.
            let restCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM databases WHERE id = 'restaurants'") ?? -1
            XCTAssertEqual(restCount, 0, "restaurants database row should be deleted")

            // 2. Restaurant records are gone.
            let rowCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM records WHERE database_id = 'restaurants'") ?? -1
            XCTAssertEqual(rowCount, 0, "every restaurants record should be merged + deleted")

            // 3. Pre-existing vendor (Joe's Pizza) picked up the
            //    restaurant fields and kind=restaurant.
            let joesKind = try String.fetchOne(db, sql: """
                SELECT pv.text_value FROM property_values pv
                WHERE pv.record_id = 'joes-vendor' AND pv.property_id = 'vendors.kind'
            """)
            XCTAssertEqual(joesKind, "restaurant")

            let joesCuisine = try String.fetchOne(db, sql: """
                SELECT pv.text_value FROM property_values pv
                WHERE pv.record_id = 'joes-vendor' AND pv.property_id = 'vendors.cuisine'
            """)
            XCTAssertEqual(joesCuisine, "italian")

            let joesPrice = try String.fetchOne(db, sql: """
                SELECT pv.text_value FROM property_values pv
                WHERE pv.record_id = 'joes-vendor' AND pv.property_id = 'vendors.price_range'
            """)
            XCTAssertEqual(joesPrice, "$$")

            // Notes append (vendor had a pre-existing note).
            let joesNotes = try XCTUnwrap(try String.fetchOne(db, sql: """
                SELECT pv.text_value FROM property_values pv
                WHERE pv.record_id = 'joes-vendor' AND pv.property_id = 'vendors.notes'
            """))
            XCTAssertTrue(joesNotes.contains("Catering available"),
                          "pre-existing vendor note must be preserved")
            XCTAssertTrue(joesNotes.contains("Best slice on the block"),
                          "restaurant note must be appended to vendor notes")

            // 4. Unlinked restaurant materialized a fresh vendor.
            let newVendorTitle = try String.fetchOne(db, sql: """
                SELECT title FROM records
                WHERE database_id = 'vendors' AND title = 'Standalone Diner'
            """)
            XCTAssertEqual(newVendorTitle, "Standalone Diner")

            let newVendorID = try XCTUnwrap(try String.fetchOne(db, sql: """
                SELECT id FROM records
                WHERE database_id = 'vendors' AND title = 'Standalone Diner'
                LIMIT 1
            """))
            let newKind = try String.fetchOne(db, sql: """
                SELECT pv.text_value FROM property_values pv
                WHERE pv.record_id = ? AND pv.property_id = 'vendors.kind'
            """, arguments: [newVendorID])
            XCTAssertEqual(newKind, "restaurant")

            let newCuisine = try String.fetchOne(db, sql: """
                SELECT pv.text_value FROM property_values pv
                WHERE pv.record_id = ? AND pv.property_id = 'vendors.cuisine'
            """, arguments: [newVendorID])
            XCTAssertEqual(newCuisine, "american")

            // 5. Restaurants view row exists.
            let viewID = try String.fetchOne(db, sql: "SELECT id FROM views WHERE id = 'view-restaurants'")
            XCTAssertEqual(viewID, "view-restaurants")
        }
    }

    /// Set up the minimum schema needed to drive `seedRestaurantsAsVendorsViewV41`
    /// in isolation. Mirrors v1's table shapes and the restaurants/vendors
    /// database rows the v22-v24 era of migrations would have left.
    private func seedPreV41(_ db: Database) throws {
        // Tables.
        try db.execute(sql: """
            CREATE TABLE workspaces (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                schema_version INTEGER NOT NULL
            )
        """)
        try db.execute(sql: """
            CREATE TABLE databases (
                id TEXT PRIMARY KEY NOT NULL,
                workspace_id TEXT NOT NULL,
                area_id TEXT,
                name TEXT NOT NULL,
                plural_name TEXT,
                icon TEXT,
                color TEXT,
                accent TEXT NOT NULL DEFAULT 'graphite',
                description TEXT,
                default_view TEXT NOT NULL DEFAULT 'table',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                sort_index REAL NOT NULL
            )
        """)
        try db.execute(sql: """
            CREATE TABLE properties (
                id TEXT PRIMARY KEY NOT NULL,
                database_id TEXT NOT NULL,
                key TEXT NOT NULL,
                name TEXT NOT NULL,
                type TEXT NOT NULL,
                config_json TEXT NOT NULL DEFAULT '{}',
                is_required INTEGER NOT NULL DEFAULT 0,
                is_archived INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                sort_index REAL NOT NULL
            )
        """)
        try db.execute(sql: """
            CREATE TABLE records (
                id TEXT PRIMARY KEY NOT NULL,
                database_id TEXT NOT NULL,
                title TEXT NOT NULL,
                subtitle TEXT,
                glyph TEXT NOT NULL DEFAULT '',
                tone TEXT NOT NULL DEFAULT 'graphite',
                icon TEXT,
                cover_asset_id TEXT,
                template_id TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                archived_at TEXT,
                deleted_at TEXT,
                sort_index REAL NOT NULL
            )
        """)
        try db.execute(sql: """
            CREATE TABLE property_values (
                id TEXT PRIMARY KEY NOT NULL,
                record_id TEXT NOT NULL,
                property_id TEXT NOT NULL,
                text_value TEXT,
                number_value REAL,
                bool_value INTEGER,
                date_value TEXT,
                json_value TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
        """)
        try db.execute(sql: """
            CREATE TABLE relations (
                id TEXT PRIMARY KEY NOT NULL,
                source_record_id TEXT NOT NULL,
                target_record_id TEXT NOT NULL,
                relation_type TEXT,
                property_id TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
        """)
        try db.execute(sql: """
            CREATE TABLE views (
                id TEXT PRIMARY KEY NOT NULL,
                database_id TEXT,
                workspace_id TEXT NOT NULL,
                name TEXT NOT NULL,
                type TEXT NOT NULL,
                query_json TEXT NOT NULL,
                presentation_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
        """)

        let now = "2026-05-11T00:00:00Z"
        try db.execute(sql: """
            INSERT INTO workspaces (id, name, created_at, updated_at, schema_version)
            VALUES ('ws-default', 'Test', ?, ?, 41)
        """, arguments: [now, now])

        // Vendors database + properties (the v18-v20 shape).
        try db.execute(sql: """
            INSERT INTO databases (id, workspace_id, area_id, name, plural_name, icon, accent, default_view, created_at, updated_at, sort_index)
            VALUES ('vendors', 'ws-default', 'area-records', 'Vendors', 'Vendors', 'Vn', 'graphite', 'table', ?, ?, 4.7)
        """, arguments: [now, now])
        struct VProp { let key: String; let label: String; let type: String; let sort: Double }
        for p in [
            VProp(key: "name",  label: "Name",  type: "title",   sort: 0),
            VProp(key: "kind",  label: "Kind",  type: "select",  sort: 1),
            VProp(key: "phone", label: "Phone", type: "phone",   sort: 2),
            VProp(key: "email", label: "Email", type: "email",   sort: 3),
            VProp(key: "website", label: "Website", type: "url", sort: 4),
            VProp(key: "address", label: "Address", type: "address", sort: 5),
            VProp(key: "locality", label: "City", type: "text",  sort: 5.5),
            VProp(key: "notes", label: "Notes", type: "text",    sort: 6),
        ] {
            try db.execute(sql: """
                INSERT INTO properties (id, database_id, key, name, type, config_json, is_required, is_archived, created_at, updated_at, sort_index)
                VALUES (?, 'vendors', ?, ?, ?, '{}', 0, 0, ?, ?, ?)
            """, arguments: ["vendors.\(p.key)", p.key, p.label, p.type, now, now, p.sort])
        }

        // Restaurants database + properties (the v24 shape).
        try db.execute(sql: """
            INSERT INTO databases (id, workspace_id, area_id, name, plural_name, icon, accent, default_view, created_at, updated_at, sort_index)
            VALUES ('restaurants', 'ws-default', 'area-collections', 'Restaurants', 'Restaurants', 'Re', 'iris', 'table', ?, ?, 8.3)
        """, arguments: [now, now])
        struct RProp { let key: String; let label: String; let type: String; let sort: Double; let cfg: String }
        for p in [
            RProp(key: "name",         label: "Name",         type: "title",    sort: 0, cfg: "{}"),
            RProp(key: "vendor",       label: "Vendor",       type: "relation", sort: 1, cfg: #"{"targetDatabaseID":"vendors"}"#),
            RProp(key: "cuisine",      label: "Cuisine",      type: "select",   sort: 2, cfg: "{}"),
            RProp(key: "price_range",  label: "Price",        type: "select",   sort: 3, cfg: #"{"options":["$","$$","$$$","$$$$"]}"#),
            RProp(key: "rating",       label: "Rating",       type: "number",   sort: 4, cfg: "{}"),
            RProp(key: "status",       label: "Status",       type: "select",   sort: 5, cfg: #"{"options":["want_to_try","visited"]}"#),
            RProp(key: "last_visited", label: "Last visited", type: "date",     sort: 6, cfg: "{}"),
            RProp(key: "notes",        label: "Notes",        type: "text",     sort: 7, cfg: "{}"),
        ] {
            try db.execute(sql: """
                INSERT INTO properties (id, database_id, key, name, type, config_json, is_required, is_archived, created_at, updated_at, sort_index)
                VALUES (?, 'restaurants', ?, ?, ?, ?, 0, 0, ?, ?, ?)
            """, arguments: ["restaurants.\(p.key)", p.key, p.label, p.type, p.cfg, now, now, p.sort])
        }

        // Pre-existing Joe's Pizza vendor with a hand-written note.
        try db.execute(sql: """
            INSERT INTO records (id, database_id, title, glyph, tone, created_at, updated_at, sort_index)
            VALUES ('joes-vendor', 'vendors', 'Joe''s Pizza', 'JP', 'graphite', ?, ?, 0)
        """, arguments: [now, now])
        try db.execute(sql: """
            INSERT INTO property_values (id, record_id, property_id, text_value, created_at, updated_at)
            VALUES ('joes-vendor.notes', 'joes-vendor', 'vendors.notes', 'Catering available', ?, ?)
        """, arguments: [now, now])

        // Restaurant 1 — linked to Joe's vendor, has cuisine/price/notes.
        try db.execute(sql: """
            INSERT INTO records (id, database_id, title, glyph, tone, created_at, updated_at, sort_index)
            VALUES ('rest-joes', 'restaurants', 'Joe''s Pizza', 'JP', 'iris', ?, ?, 0)
        """, arguments: [now, now])
        try db.execute(sql: """
            INSERT INTO relations (id, source_record_id, target_record_id, relation_type, property_id, created_at, updated_at)
            VALUES ('rel-joes', 'rest-joes', 'joes-vendor', 'linked', 'restaurants.vendor', ?, ?)
        """, arguments: [now, now])
        for (key, value) in [
            ("cuisine", "italian"),
            ("price_range", "$$"),
            ("notes", "Best slice on the block"),
        ] {
            try db.execute(sql: """
                INSERT INTO property_values (id, record_id, property_id, text_value, created_at, updated_at)
                VALUES (?, 'rest-joes', ?, ?, ?, ?)
            """, arguments: ["rest-joes.\(key)", "restaurants.\(key)", value, now, now])
        }

        // Restaurant 2 — no vendor link, should materialize a new vendor.
        try db.execute(sql: """
            INSERT INTO records (id, database_id, title, glyph, tone, created_at, updated_at, sort_index)
            VALUES ('rest-diner', 'restaurants', 'Standalone Diner', 'SD', 'iris', ?, ?, 1)
        """, arguments: [now, now])
        try db.execute(sql: """
            INSERT INTO property_values (id, record_id, property_id, text_value, created_at, updated_at)
            VALUES ('rest-diner.cuisine', 'rest-diner', 'restaurants.cuisine', 'american', ?, ?)
        """, arguments: [now, now])
    }

    // MARK: - RestaurantHours parser + Open Now predicate

    func testRestaurantHoursParsesValidJSON() throws {
        let json = """
        {
            "mon": [{"open": "08:00", "close": "22:00"}],
            "fri": [{"open": "11:00", "close": "23:30"}]
        }
        """
        let hours = try XCTUnwrap(RestaurantHours.parse(json))
        XCTAssertEqual(hours.byWeekday[.mon]?.count, 1)
        XCTAssertEqual(hours.byWeekday[.fri]?.first?.openMinute, 11 * 60)
        XCTAssertEqual(hours.byWeekday[.fri]?.first?.closeMinute, 23 * 60 + 30)
    }

    func testRestaurantHoursReturnsNilForBlankInput() {
        XCTAssertNil(RestaurantHours.parse(""))
        XCTAssertNil(RestaurantHours.parse("   "))
        XCTAssertNil(RestaurantHours.parse("not json"))
    }

    func testIsOpenAtKnownInstant() throws {
        let json = """
        { "mon": [{"open": "10:00", "close": "22:00"}] }
        """
        let hours = try XCTUnwrap(RestaurantHours.parse(json))
        // 2026-03-09 was a Monday. Calendar(.gregorian) returns
        // weekday=2 for Monday in the default UTC region; the parser
        // maps that to .mon.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = 9
        comps.hour = 15; comps.minute = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let mondayAfternoon = try XCTUnwrap(cal.date(from: comps))
        XCTAssertTrue(hours.isOpen(at: mondayAfternoon, calendar: cal))

        comps.hour = 23
        let mondayNight = try XCTUnwrap(cal.date(from: comps))
        XCTAssertFalse(hours.isOpen(at: mondayNight, calendar: cal))

        comps.day = 10  // Tuesday — no slot configured.
        comps.hour = 12
        let tuesday = try XCTUnwrap(cal.date(from: comps))
        XCTAssertFalse(hours.isOpen(at: tuesday, calendar: cal))
    }

    func testIsOpenHandlesPostMidnightWrap() throws {
        // Bar that closes at 02:00 the next day. Encoded as close="26:00"
        // (minutes past midnight, > 1440).
        let json = """
        { "fri": [{"open": "20:00", "close": "26:00"}] }
        """
        let hours = try XCTUnwrap(RestaurantHours.parse(json))
        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = 14  // Saturday
        comps.hour = 1; comps.minute = 30
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let earlySaturday = try XCTUnwrap(cal.date(from: comps))
        XCTAssertTrue(hours.isOpen(at: earlySaturday, calendar: cal),
                      "Friday's overnight slot should keep the bar open at Sat 01:30")
    }
}
