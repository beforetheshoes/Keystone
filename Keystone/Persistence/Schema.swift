import Foundation
import GRDB
import os

enum Schema {
    static func createV1(_ db: Database) throws {
        try db.execute(sql: #"""
            CREATE TABLE IF NOT EXISTS workspaces (
              id TEXT PRIMARY KEY NOT NULL,
              name TEXT NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              schema_version INTEGER NOT NULL
            )
        """#)

        try db.execute(sql: #"""
            CREATE TABLE IF NOT EXISTS areas (
              id TEXT PRIMARY KEY NOT NULL,
              workspace_id TEXT NOT NULL,
              title TEXT NOT NULL,
              accent TEXT NOT NULL,
              sort_index REAL NOT NULL,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            )
        """#)

        try db.execute(sql: #"""
            CREATE TABLE IF NOT EXISTS databases (
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
              sort_index REAL NOT NULL,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
              FOREIGN KEY (area_id) REFERENCES areas(id) ON DELETE SET NULL
            )
        """#)

        try db.execute(sql: #"""
            CREATE TABLE IF NOT EXISTS properties (
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
              sort_index REAL NOT NULL,
              FOREIGN KEY (database_id) REFERENCES databases(id) ON DELETE CASCADE,
              UNIQUE(database_id, key)
            )
        """#)

        try db.execute(sql: #"""
            CREATE TABLE IF NOT EXISTS records (
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
              sort_index REAL NOT NULL,
              FOREIGN KEY (database_id) REFERENCES databases(id) ON DELETE CASCADE
            )
        """#)

        try db.execute(sql: #"""
            CREATE TABLE IF NOT EXISTS property_values (
              id TEXT PRIMARY KEY NOT NULL,
              record_id TEXT NOT NULL,
              property_id TEXT NOT NULL,
              text_value TEXT,
              number_value REAL,
              bool_value INTEGER,
              date_value TEXT,
              json_value TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              UNIQUE(record_id, property_id),
              FOREIGN KEY (record_id) REFERENCES records(id) ON DELETE CASCADE,
              FOREIGN KEY (property_id) REFERENCES properties(id) ON DELETE CASCADE
            )
        """#)

        try db.execute(sql: #"""
            CREATE TABLE IF NOT EXISTS tags (
              id TEXT PRIMARY KEY NOT NULL,
              workspace_id TEXT NOT NULL,
              name TEXT NOT NULL,
              scope_type TEXT NOT NULL,
              scope_id TEXT,
              color TEXT,
              description TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            )
        """#)

        try db.execute(sql: #"""
            CREATE TABLE IF NOT EXISTS record_tags (
              id TEXT PRIMARY KEY NOT NULL,
              record_id TEXT NOT NULL,
              tag_id TEXT NOT NULL,
              created_at TEXT NOT NULL,
              UNIQUE(record_id, tag_id),
              FOREIGN KEY (record_id) REFERENCES records(id) ON DELETE CASCADE,
              FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE
            )
        """#)

        try db.execute(sql: #"""
            CREATE TABLE IF NOT EXISTS relations (
              id TEXT PRIMARY KEY NOT NULL,
              source_record_id TEXT NOT NULL,
              target_record_id TEXT NOT NULL,
              relation_type TEXT,
              property_id TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              FOREIGN KEY (source_record_id) REFERENCES records(id) ON DELETE CASCADE,
              FOREIGN KEY (target_record_id) REFERENCES records(id) ON DELETE CASCADE,
              FOREIGN KEY (property_id) REFERENCES properties(id) ON DELETE SET NULL
            )
        """#)

        try db.execute(sql: #"""
            CREATE TABLE IF NOT EXISTS views (
              id TEXT PRIMARY KEY NOT NULL,
              database_id TEXT,
              workspace_id TEXT NOT NULL,
              name TEXT NOT NULL,
              type TEXT NOT NULL,
              query_json TEXT NOT NULL,
              presentation_json TEXT NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              FOREIGN KEY (database_id) REFERENCES databases(id) ON DELETE CASCADE,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            )
        """#)

        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_records_db ON records(database_id)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_property_values_record ON property_values(record_id)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_relations_source ON relations(source_record_id)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_relations_target ON relations(target_record_id)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_databases_area ON databases(area_id)")
    }

    static func createBlocksV2(_ db: Database) throws {
        try db.execute(sql: #"""
            CREATE TABLE IF NOT EXISTS blocks (
              id TEXT PRIMARY KEY NOT NULL,
              record_id TEXT NOT NULL,
              parent_block_id TEXT,
              type TEXT NOT NULL,
              content_json TEXT NOT NULL DEFAULT '{}',
              sort_index REAL NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              deleted_at TEXT,
              FOREIGN KEY (record_id) REFERENCES records(id) ON DELETE CASCADE,
              FOREIGN KEY (parent_block_id) REFERENCES blocks(id) ON DELETE SET NULL
            )
        """#)
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_blocks_record ON blocks(record_id, sort_index)")
    }

    /// v4: nothing schema-wise for now (config_json on properties already exists);
    /// reserved for future tag/relation schema tweaks.
    static func relationConfigV4(_ db: Database) throws {
        // No-op. The relation `targetDatabaseID` lives in
        // properties.config_json which is already a TEXT column.
    }

    /// v5: backfill seed-data relations from property_values into the relations
    /// table. For each relation-typed property, find any text values and turn
    /// them into actual `relations` rows pointing at records by title.
    static func backfillRelationsV5(_ db: Database) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())
        let propRows = try Row.fetchAll(db, sql: """
            SELECT id, database_id, key FROM properties WHERE type = 'relation'
        """)

        for prop in propRows {
            let propID: String = prop["id"]
            let configJSON: String = (try? String.fetchOne(db, sql: "SELECT config_json FROM properties WHERE id = ?", arguments: [propID])) ?? "{}"
            // Look up target database
            guard let cfgData = configJSON.data(using: .utf8),
                  let cfg = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any],
                  let targetDB = cfg["targetDatabaseID"] as? String else {
                // No target db configured — leave as text for now
                continue
            }

            // For each property_value of this relation property
            let pvRows = try Row.fetchAll(db, sql: """
                SELECT pv.record_id, pv.text_value FROM property_values pv WHERE pv.property_id = ? AND pv.text_value IS NOT NULL AND pv.text_value != '—'
            """, arguments: [propID])
            for pv in pvRows {
                let sourceID: String = pv["record_id"]
                let label: String = pv["text_value"]

                // Find target record by title
                if let targetID = try String.fetchOne(db, sql: """
                    SELECT id FROM records WHERE database_id = ? AND title = ?
                """, arguments: [targetDB, label]) {
                    let relID = "rel-\(sourceID)-\(propID)-\(targetID)"
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO relations
                            (id, source_record_id, target_record_id, relation_type, property_id, created_at, updated_at)
                        VALUES (?, ?, ?, 'linked', ?, ?, ?)
                    """, arguments: [relID, sourceID, targetID, propID, now, now])
                }
            }

            // Drop the now-redundant text values for relation properties
            try db.execute(sql: """
                DELETE FROM property_values WHERE property_id = ?
            """, arguments: [propID])
        }
    }

    static func createAssetsV6(_ db: Database) throws {
        try db.execute(sql: #"""
            CREATE TABLE IF NOT EXISTS assets (
              id TEXT PRIMARY KEY NOT NULL,
              workspace_id TEXT NOT NULL,
              record_id TEXT,
              original_filename TEXT NOT NULL,
              stored_filename TEXT NOT NULL,
              relative_path TEXT NOT NULL,
              mime_type TEXT,
              file_extension TEXT,
              byte_size INTEGER,
              content_hash TEXT,
              extracted_text TEXT,
              metadata_json TEXT NOT NULL DEFAULT '{}',
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
              FOREIGN KEY (record_id) REFERENCES records(id) ON DELETE SET NULL
            )
        """#)
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_assets_record ON assets(record_id)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_assets_hash ON assets(content_hash)")
    }

    /// Historical no-op. Earlier builds seeded demo blocks here; v7 wipes any
    /// such rows. Kept as a registered migration so installs that already
    /// recorded "v3-eleanor-blocks" don't trip GRDB's missing-migration check.
    static func seedEleanorBlocksV3(_ db: Database) throws {
        // Intentionally empty.
    }

    /// Removes the demo records, tags, and relations that earlier builds seeded
    /// into every fresh install. Real records use UUID identifiers, so deleting
    /// rows by these literal seed IDs cannot collide with user data. FK
    /// cascades take care of property_values, blocks, record_tags, and
    /// relations attached to deleted records.
    static func removeDemoDataV7(_ db: Database) throws {
        let recordIDs = [
            "p1","p2","p3","p4","p5","p6","p7","p8",
            "pet1","pet2",
            "h1","h2",
            "v1","v2","v3",
            "d1","d2","d3","d4","d5","d6",
            "e1","e2","e3","e4",
            "m1","m2","m3","m4",
        ]
        let placeholders = Array(repeating: "?", count: recordIDs.count).joined(separator: ",")
        try db.execute(
            sql: "DELETE FROM records WHERE id IN (\(placeholders))",
            arguments: StatementArguments(recordIDs)
        )

        let tagIDs = ["tag-family", "tag-medical", "tag-urgent", "tag-property"]
        let tagPlaceholders = Array(repeating: "?", count: tagIDs.count).joined(separator: ",")
        try db.execute(
            sql: "DELETE FROM tags WHERE id IN (\(tagPlaceholders))",
            arguments: StatementArguments(tagIDs)
        )

        try db.execute(sql: "DELETE FROM relations WHERE id LIKE 'seed-rel-%' OR id LIKE 'rel-p%'")
        try db.execute(sql: "DELETE FROM blocks WHERE id LIKE 'eleanor-block-%'")
    }

    /// v9: SQLiteData's `SyncEngine` rejects schemas with reference cycles,
    /// and `blocks.parent_block_id REFERENCES blocks(id)` is a self-cycle.
    /// We drop the foreign-key constraint while keeping the column (no app
    /// code currently writes nested blocks; the column is retained so a
    /// future nested-block feature doesn't need another schema bump).
    /// SQLite has no `DROP CONSTRAINT`, so we recreate the table.
    static func dropBlocksSelfFKV9(_ db: Database) throws {
        try db.execute(sql: "PRAGMA foreign_keys = OFF")
        try db.execute(sql: #"""
            CREATE TABLE IF NOT EXISTS blocks_new (
              id TEXT PRIMARY KEY NOT NULL,
              record_id TEXT NOT NULL,
              parent_block_id TEXT,
              type TEXT NOT NULL,
              content_json TEXT NOT NULL DEFAULT '{}',
              sort_index REAL NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              deleted_at TEXT,
              FOREIGN KEY (record_id) REFERENCES records(id) ON DELETE CASCADE
            )
        """#)
        try db.execute(sql: """
            INSERT INTO blocks_new (id, record_id, parent_block_id, type, content_json, sort_index, created_at, updated_at, deleted_at)
            SELECT id, record_id, parent_block_id, type, content_json, sort_index, created_at, updated_at, deleted_at FROM blocks
        """)
        try db.execute(sql: "DROP TABLE blocks")
        try db.execute(sql: "ALTER TABLE blocks_new RENAME TO blocks")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_blocks_record ON blocks(record_id, sort_index)")
        try db.execute(sql: "PRAGMA foreign_keys = ON")
    }

    /// v10: SQLiteData's `SyncEngine` rejects schemas with UNIQUE
    /// constraints (other than the primary key). The original schema had
    /// three: `properties UNIQUE(database_id, key)`,
    /// `property_values UNIQUE(record_id, property_id)`, and
    /// `record_tags UNIQUE(record_id, tag_id)`. App-level invariants take
    /// over for these:
    ///
    /// - `properties.id = "<db>.<key>"` (deterministic) so the PK enforces
    ///   uniqueness per (db, key).
    /// - `property_values.id = "<recordID>.<propertyKey>"` likewise.
    /// - `record_tags` gets an explicit existence check in `attachTag`.
    static func dropUniqueConstraintsV10(_ db: Database) throws {
        try db.execute(sql: "PRAGMA foreign_keys = OFF")

        // properties
        try db.execute(sql: #"""
            CREATE TABLE properties_new (
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
              sort_index REAL NOT NULL,
              FOREIGN KEY (database_id) REFERENCES databases(id) ON DELETE CASCADE
            )
        """#)
        try db.execute(sql: """
            INSERT INTO properties_new
            SELECT id, database_id, key, name, type, config_json,
                   is_required, is_archived, created_at, updated_at, sort_index
            FROM properties
        """)
        try db.execute(sql: "DROP TABLE properties")
        try db.execute(sql: "ALTER TABLE properties_new RENAME TO properties")

        // property_values
        try db.execute(sql: #"""
            CREATE TABLE property_values_new (
              id TEXT PRIMARY KEY NOT NULL,
              record_id TEXT NOT NULL,
              property_id TEXT NOT NULL,
              text_value TEXT,
              number_value REAL,
              bool_value INTEGER,
              date_value TEXT,
              json_value TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              FOREIGN KEY (record_id) REFERENCES records(id) ON DELETE CASCADE,
              FOREIGN KEY (property_id) REFERENCES properties(id) ON DELETE CASCADE
            )
        """#)
        try db.execute(sql: """
            INSERT INTO property_values_new
            SELECT id, record_id, property_id, text_value, number_value, bool_value,
                   date_value, json_value, created_at, updated_at
            FROM property_values
        """)
        try db.execute(sql: "DROP TABLE property_values")
        try db.execute(sql: "ALTER TABLE property_values_new RENAME TO property_values")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_property_values_record ON property_values(record_id)")

        // record_tags
        try db.execute(sql: #"""
            CREATE TABLE record_tags_new (
              id TEXT PRIMARY KEY NOT NULL,
              record_id TEXT NOT NULL,
              tag_id TEXT NOT NULL,
              created_at TEXT NOT NULL,
              FOREIGN KEY (record_id) REFERENCES records(id) ON DELETE CASCADE,
              FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE
            )
        """#)
        try db.execute(sql: """
            INSERT INTO record_tags_new
            SELECT id, record_id, tag_id, created_at FROM record_tags
        """)
        try db.execute(sql: "DROP TABLE record_tags")
        try db.execute(sql: "ALTER TABLE record_tags_new RENAME TO record_tags")

        try db.execute(sql: "PRAGMA foreign_keys = ON")
    }

    /// v13: wipe all blocks for records whose body originally came from
    /// an attached `.md` asset, so the per-boot
    /// `backfillBlocksFromMarkdownAssets` regenerates them with the
    /// current `MarkdownBlockConverter`. One-shot — runs once via the
    /// migrator. Only touches records that *both* have a `.md` asset
    /// attached (the marker for "this body was machine-generated from
    /// the markdown source"). Records you've authored notes for by hand
    /// have no `.md` asset attached and are left alone.
    ///
    /// **Important**: also marks the deleted rows as `_isDeleted=true`
    /// in sqlite-data's `SyncMetadata` table when present. Migrations
    /// run *before* `SyncEngine` attaches its triggers, so a raw `DELETE`
    /// here doesn't propagate the deletion to CloudKit — and the deleted
    /// blocks then come back from CloudKit as inserts on next sync,
    /// resurrecting the duplicates this migration was supposed to clean
    /// up. Touching the SyncMetadata directly is the workaround.
    static func regenerateImportedBlocksV13(_ db: Database) throws {
        // Identify the blocks we're about to delete so the SyncMetadata
        // update can target them by ID.
        let blockIDs = try String.fetchAll(db, sql: """
            SELECT b.id FROM blocks b
            WHERE b.record_id IN (
                SELECT DISTINCT a.record_id
                FROM assets a
                WHERE a.record_id IS NOT NULL
                  AND LOWER(a.file_extension) = 'md'
            )
        """)

        // Best-effort: if the SyncMetadata table is reachable (i.e. the
        // sqlitedata_icloud metadata DB is attached, which happens after
        // SyncEngine.init), mark these rows as deleted so the deletion
        // propagates to CloudKit. If not attached (e.g. on first install
        // before SyncEngine has ever run), the table doesn't exist and
        // we skip the update — there's nothing on CloudKit to resurrect
        // anyway.
        if !blockIDs.isEmpty {
            let attached = (try? Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM pragma_database_list WHERE name = 'sqlitedata_icloud'
            """) ?? 0) ?? 0
            if attached > 0 {
                let placeholders = Array(repeating: "?", count: blockIDs.count).joined(separator: ",")
                try? db.execute(
                    sql: """
                        UPDATE sqlitedata_icloud.sqlitedata_icloud_metadata
                        SET _isDeleted = 1
                        WHERE recordType = 'blocks'
                          AND recordPrimaryKey IN (\(placeholders))
                    """,
                    arguments: StatementArguments(blockIDs)
                )
            }
        }

        try db.execute(sql: """
            DELETE FROM blocks
            WHERE record_id IN (
                SELECT DISTINCT a.record_id
                FROM assets a
                WHERE a.record_id IS NOT NULL
                  AND LOWER(a.file_extension) = 'md'
            )
        """)
    }

    /// v14: same idea as v13 — wipe import-generated blocks so the
    /// converter regenerates them on the same boot. Needed because the
    /// markdown→blocks converter changed (numbered-list rendering, table
    /// rendering with row labels) and existing blocks were generated by
    /// the older logic. Migrations run once-only by identifier, so we
    /// add a new version every time the converter changes shape.
    static func regenerateImportedBlocksV14(_ db: Database) throws {
        try regenerateImportedBlocksV13(db)
    }

    /// v15: third regenerate-imported-blocks pass. Triggered by adding a
    /// real `.table` block kind — the converter now emits tables as
    /// structured payloads instead of paragraphs of separator-joined cells.
    static func regenerateImportedBlocksV15(_ db: Database) throws {
        try regenerateImportedBlocksV13(db)
    }

    /// v17: fourth regenerate-imported-blocks pass. Triggered by the
    /// converter gaining duplicate-block dedup — adjacent identical
    /// paragraphs and post-table flattened-paragraph copies now collapse,
    /// so existing imports need a re-render to lose their duplicates.
    static func regenerateImportedBlocksV17(_ db: Database) throws {
        try regenerateImportedBlocksV13(db)
    }

    /// v18: introduce the `vendors` database, flip
    /// `vehicle_maintenance.vendor` from text to a relation pointing
    /// at `vendors`, and materialize a vendor record for each distinct
    /// text value already stored in property_values.
    ///
    /// Idempotent — uses INSERT OR IGNORE for the schema rows and a
    /// case-insensitive title-match dedupe when promoting text values
    /// to records.
    static func seedVendorsAndPromoteRelationsV18(_ db: Database) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())

        // No workspace yet → nothing to migrate. The Seed.runIfEmpty
        // path on first install handles fresh setups separately.
        guard let workspaceID = try String.fetchOne(
            db,
            sql: "SELECT id FROM workspaces ORDER BY created_at LIMIT 1"
        ) else { return }

        // 1. Create the `vendors` database row. Sort it after
        //    vehicle_maintenance in the Records area.
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO databases
                    (id, workspace_id, area_id, name, plural_name, icon, accent, default_view, created_at, updated_at, sort_index)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                "vendors", workspaceID, "area-records",
                "Vendors", "Vendors",
                "Vn", "graphite", "table", now, now, 4.7
            ]
        )

        // 2. Vendor properties. Schema kept narrow — most are optional
        //    free-form fields. Users can fill in as needed.
        struct Prop { let key: String; let label: String; let type: String; let sort: Double }
        let props: [Prop] = [
            .init(key: "name",    label: "Name",    type: "title",  sort: 0),
            .init(key: "kind",    label: "Kind",    type: "select", sort: 1),
            .init(key: "phone",   label: "Phone",   type: "phone",  sort: 2),
            .init(key: "email",   label: "Email",   type: "email",  sort: 3),
            .init(key: "website", label: "Website", type: "url",    sort: 4),
            .init(key: "address", label: "Address", type: "text",   sort: 5),
            .init(key: "notes",   label: "Notes",   type: "text",   sort: 6),
        ]
        for p in props {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO properties
                        (id, database_id, key, name, type, config_json, is_required, is_archived, created_at, updated_at, sort_index)
                    VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?)
                """,
                arguments: [
                    "vendors.\(p.key)", "vendors",
                    p.key, p.label, p.type, "{}", now, now, p.sort
                ]
            )
        }

        // 3. Flip `vehicle_maintenance.vendor` from text to relation
        //    pointing at vendors. Idempotent: if it's already relation,
        //    the UPDATE is a no-op.
        try db.execute(
            sql: """
                UPDATE properties
                SET type = 'relation',
                    config_json = ?,
                    updated_at = ?
                WHERE id = 'vehicle_maintenance.vendor'
            """,
            arguments: [#"{"targetDatabaseID":"vendors"}"#, now]
        )

        // 4. For every distinct text value still sitting in
        //    property_values for vehicle_maintenance.vendor, create or
        //    reuse a vendors record. Reuse is by case-insensitive title
        //    match so capitalization variants collapse onto one record.
        let distinctVendorNames = try String.fetchAll(db, sql: """
            SELECT DISTINCT TRIM(text_value)
            FROM property_values
            WHERE property_id = 'vehicle_maintenance.vendor'
              AND text_value IS NOT NULL
              AND TRIM(text_value) != ''
        """)

        // name → record_id, populated as we go
        var vendorIDByName: [String: String] = [:]
        for name in distinctVendorNames {
            // Look for an existing vendor record by case-insensitive title.
            if let existing = try String.fetchOne(
                db,
                sql: """
                    SELECT id FROM records
                    WHERE database_id = 'vendors' AND LOWER(title) = LOWER(?)
                    LIMIT 1
                """,
                arguments: [name]
            ) {
                vendorIDByName[name.lowercased()] = existing
                continue
            }
            // Create a fresh vendor record.
            let id = UUID().uuidString
            let glyph = makeGlyph(from: name)
            let nextSort = (try Double.fetchOne(
                db,
                sql: "SELECT MAX(sort_index) FROM records WHERE database_id = 'vendors'"
            ) ?? -1) + 1
            try db.execute(
                sql: """
                    INSERT INTO records
                        (id, database_id, title, glyph, tone, created_at, updated_at, sort_index)
                    VALUES (?, 'vendors', ?, ?, 'graphite', ?, ?, ?)
                """,
                arguments: [id, name, glyph, now, now, nextSort]
            )
            vendorIDByName[name.lowercased()] = id
        }

        // 5. For every property_value row referencing the now-relation
        //    vendor property, create a relations row from the source
        //    record to the matching vendor, then delete the
        //    property_value. Mark the property_value's SyncMetadata as
        //    `_isDeleted=true` so the deletion propagates to CloudKit
        //    (raw DELETEs in a migration bypass the SyncEngine
        //    triggers — see regenerateImportedBlocksV13's comment).
        let pvRows = try Row.fetchAll(db, sql: """
            SELECT id AS pv_id, record_id, TRIM(text_value) AS vendor_name
            FROM property_values
            WHERE property_id = 'vehicle_maintenance.vendor'
              AND text_value IS NOT NULL
              AND TRIM(text_value) != ''
        """)

        let metadataAttached = (try? Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM pragma_database_list WHERE name = 'sqlitedata_icloud'
        """) ?? 0) ?? 0

        for row in pvRows {
            let pvID: String = row["pv_id"]
            let sourceRecordID: String = row["record_id"]
            let name: String = row["vendor_name"]
            guard let vendorID = vendorIDByName[name.lowercased()] else { continue }

            let relID = UUID().uuidString
            try db.execute(
                sql: """
                    INSERT INTO relations
                        (id, source_record_id, target_record_id, relation_type, property_id, created_at, updated_at)
                    VALUES (?, ?, ?, 'linked', 'vehicle_maintenance.vendor', ?, ?)
                """,
                arguments: [relID, sourceRecordID, vendorID, now, now]
            )

            if metadataAttached > 0 {
                try? db.execute(
                    sql: """
                        UPDATE sqlitedata_icloud.sqlitedata_icloud_metadata
                        SET _isDeleted = 1
                        WHERE recordType = 'property_values' AND recordPrimaryKey = ?
                    """,
                    arguments: [pvID]
                )
            }
            try db.execute(sql: "DELETE FROM property_values WHERE id = ?", arguments: [pvID])
        }
    }

    /// v19: add a `place_id` property to vendors so we can store the
    /// Apple Place ID returned from MapKit lookups. Place IDs are
    /// opaque, persistent identifiers — keep one on a vendor and we
    /// can re-resolve fresh phone/website/address forever via
    /// `MKMapItemRequest(mapItemIdentifier:)`. Stored as text; users
    /// don't edit this directly.
    ///
    /// Guarded on the existence of the `vendors` database — on a
    /// fresh install the migrations run before `Seed.runIfEmpty`,
    /// so the vendors database doesn't exist yet. In that case we
    /// skip the insert; `Seed.runIfEmpty` will create the property
    /// itself when it seeds the canonical structural rows.
    static func addVendorPlaceIDPropertyV19(_ db: Database) throws {
        let vendorsExists = (try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM databases WHERE id = 'vendors'"
        ) ?? 0) > 0
        guard vendorsExists else { return }

        let now = AppDatabase.isoFormatter.string(from: Date())
        // Sort below the existing notes property — it's machine data
        // rather than human-curated.
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO properties
                    (id, database_id, key, name, type, config_json, is_required, is_archived, created_at, updated_at, sort_index)
                VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?)
            """,
            arguments: [
                "vendors.place_id", "vendors",
                "place_id", "Apple Place ID", "text", "{}",
                now, now, 7
            ]
        )
    }

    /// v21: targeted removal of legacy demo-seed orphans that survived
    /// the v7 demo-data wipe. Earlier builds seeded records with literal
    /// IDs `p1…p8`, `pet1…pet2`, `h1…h2`, `v1…v3`, `d1…d6`, `e1…e4`,
    /// `m1…m4` plus their child property_values keyed `<id>.<propkey>`.
    /// v7 deleted the records, but the FK was added later (v10), so
    /// ON DELETE CASCADE didn't fire and the child property_values
    /// leaked through every subsequent table-rebuild. They surface now
    /// as `PRAGMA foreign_key_check` violations on first sync to a
    /// fresh device, which crashes the app at boot.
    ///
    /// This migration is one-shot, narrow, and only deletes rows whose
    /// `record_id` matches the legacy demo-ID pattern — real records
    /// use UUIDs, so collisions are impossible. Safe to ship.
    static func removeLegacyDemoOrphansV21(_ db: Database) throws {
        let demoIDs = [
            "p1","p2","p3","p4","p5","p6","p7","p8",
            "pet1","pet2",
            "h1","h2",
            "v1","v2","v3",
            "d1","d2","d3","d4","d5","d6",
            "e1","e2","e3","e4",
            "m1","m2","m3","m4",
        ]
        let placeholders = Array(repeating: "?", count: demoIDs.count).joined(separator: ",")
        let args = StatementArguments(demoIDs)

        for table in ["property_values", "blocks", "record_tags"] {
            let n = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(table) WHERE record_id IN (\(placeholders))",
                arguments: args
            ) ?? 0
            if n > 0 {
                try db.execute(
                    sql: "DELETE FROM \(table) WHERE record_id IN (\(placeholders))",
                    arguments: args
                )
            }
        }

        // relations: both endpoints can be the demo IDs.
        let nRel = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM relations
                WHERE source_record_id IN (\(placeholders))
                   OR target_record_id IN (\(placeholders))
            """,
            arguments: args + args
        ) ?? 0
        if nRel > 0 {
            try db.execute(
                sql: """
                    DELETE FROM relations
                    WHERE source_record_id IN (\(placeholders))
                       OR target_record_id IN (\(placeholders))
                """,
                arguments: args + args
            )
        }
    }

    /// v20: add a `locality` property to vendors — a compact "City, ST"
    /// string suitable for table-cell display. Populated by
    /// `VendorLookupService.extract` from `MKAddressRepresentations.
    /// cityWithContext(.short)` so it disambiguates duplicate cities
    /// (Springfield, IL vs Springfield, MA) without dragging in the
    /// full multi-line address.
    ///
    /// Same fresh-install guard as v19.
    static func addVendorLocalityPropertyV20(_ db: Database) throws {
        let vendorsExists = (try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM databases WHERE id = 'vendors'"
        ) ?? 0) > 0
        guard vendorsExists else { return }

        let now = AppDatabase.isoFormatter.string(from: Date())
        // Sort right after the full address (sort_index 5).
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO properties
                    (id, database_id, key, name, type, config_json, is_required, is_archived, created_at, updated_at, sort_index)
                VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?)
            """,
            arguments: [
                "vendors.locality", "vendors",
                "locality", "City", "text", "{}",
                now, now, 5.5
            ]
        )
    }

    /// v22: introduce the Travel area and its four seeded databases —
    /// `trips`, `activities`, `lodging`, `transportation` — plus their
    /// properties. Foundation for the Traveling Snails port (umbrella
    /// issue #1). Idempotent: `INSERT OR IGNORE` is the established
    /// reseed-on-known-keys pattern (see v11, v18, v19, v20). Skips
    /// fresh installs because `Seed.runIfEmpty` writes the same rows
    /// from a single source of truth on first launch.
    static func seedTravelAreaV22(_ db: Database) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())

        guard let workspaceID = try String.fetchOne(
            db,
            sql: "SELECT id FROM workspaces ORDER BY created_at LIMIT 1"
        ) else { return }

        try db.execute(
            sql: """
                INSERT OR IGNORE INTO areas (id, workspace_id, title, accent, sort_index)
                VALUES (?, ?, ?, ?, ?)
            """,
            arguments: ["area-travel", workspaceID, "Travel", "cerulean", 5.0]
        )

        struct DBRow { let id: String; let name: String; let plural: String; let icon: String; let view: String; let sort: Double }
        let dbs: [DBRow] = [
            .init(id: "trips",          name: "Trips",          plural: "Trips",          icon: "T",  view: "list",  sort: 7.0),
            .init(id: "activities",     name: "Activities",     plural: "Activities",     icon: "Ac", view: "table", sort: 7.1),
            .init(id: "lodging",        name: "Lodging",        plural: "Lodging",        icon: "L",  view: "table", sort: 7.2),
            .init(id: "transportation", name: "Transportation", plural: "Transportation", icon: "Tr", view: "table", sort: 7.3),
        ]
        for d in dbs {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO databases
                        (id, workspace_id, area_id, name, plural_name, icon, accent, default_view, created_at, updated_at, sort_index)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [d.id, workspaceID, "area-travel", d.name, d.plural, d.icon, "cerulean", d.view, now, now, d.sort]
            )
        }

        struct P { let db: String; let key: String; let label: String; let type: String; let sort: Double; let cfg: String }
        let tripsRel = #"{"targetDatabaseID":"trips"}"#
        let vendorsRel = #"{"targetDatabaseID":"vendors"}"#
        let props: [P] = [
            // trips
            .init(db: "trips", key: "name",         label: "Name",   type: "title",    sort: 0, cfg: "{}"),
            .init(db: "trips", key: "notes",        label: "Notes",  type: "text",     sort: 1, cfg: "{}"),
            .init(db: "trips", key: "start_date",   label: "Start",  type: "date",     sort: 2, cfg: "{}"),
            .init(db: "trips", key: "end_date",     label: "End",    type: "date",     sort: 3, cfg: "{}"),
            .init(db: "trips", key: "is_protected", label: "Locked", type: "checkbox", sort: 4, cfg: "{}"),
            // activities
            .init(db: "activities", key: "name",         label: "Title",  type: "title",    sort: 0, cfg: "{}"),
            .init(db: "activities", key: "trip",         label: "Trip",   type: "relation", sort: 1, cfg: tripsRel),
            .init(db: "activities", key: "organization", label: "Vendor", type: "relation", sort: 2, cfg: vendorsRel),
            .init(db: "activities", key: "start",        label: "Start",  type: "date_tz",  sort: 3, cfg: "{}"),
            .init(db: "activities", key: "end",          label: "End",    type: "date_tz",  sort: 4, cfg: "{}"),
            .init(db: "activities", key: "cost",         label: "Cost",   type: "currency", sort: 5, cfg: "{}"),
            .init(db: "activities", key: "notes",        label: "Notes",  type: "text",     sort: 6, cfg: "{}"),
            // lodging
            .init(db: "lodging", key: "name",                label: "Name",         type: "title",    sort: 0, cfg: "{}"),
            .init(db: "lodging", key: "trip",                label: "Trip",         type: "relation", sort: 1, cfg: tripsRel),
            .init(db: "lodging", key: "organization",        label: "Vendor",       type: "relation", sort: 2, cfg: vendorsRel),
            .init(db: "lodging", key: "check_in",            label: "Check-in",     type: "date_tz",  sort: 3, cfg: "{}"),
            .init(db: "lodging", key: "check_out",           label: "Check-out",    type: "date_tz",  sort: 4, cfg: "{}"),
            .init(db: "lodging", key: "confirmation_number", label: "Confirmation", type: "text",     sort: 5, cfg: "{}"),
            .init(db: "lodging", key: "cost",                label: "Cost",         type: "currency", sort: 6, cfg: "{}"),
            .init(db: "lodging", key: "notes",               label: "Notes",        type: "text",     sort: 7, cfg: "{}"),
            // transportation
            .init(db: "transportation", key: "name",         label: "Name",   type: "title",    sort: 0, cfg: "{}"),
            .init(db: "transportation", key: "trip",         label: "Trip",   type: "relation", sort: 1, cfg: tripsRel),
            .init(db: "transportation", key: "organization", label: "Vendor", type: "relation", sort: 2, cfg: vendorsRel),
            .init(db: "transportation", key: "kind",         label: "Kind",   type: "select",   sort: 3, cfg: "{}"),
            .init(db: "transportation", key: "legs",         label: "Legs",   type: "json",     sort: 4, cfg: "{}"),
            .init(db: "transportation", key: "cost",         label: "Cost",   type: "currency", sort: 5, cfg: "{}"),
            .init(db: "transportation", key: "notes",        label: "Notes",  type: "text",     sort: 6, cfg: "{}"),
        ]
        for p in props {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO properties
                        (id, database_id, key, name, type, config_json, is_required, is_archived, created_at, updated_at, sort_index)
                    VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?)
                """,
                arguments: [
                    "\(p.db).\(p.key)", p.db,
                    p.key, p.label, p.type, p.cfg, now, now, p.sort
                ]
            )
        }
    }

    /// v24: introduce the Collections area + four media databases —
    /// `books`, `movies`, `tv_shows`, `restaurants`. Books / Movies /
    /// TV are gallery-default (cover-art-forward); Restaurants is
    /// table-default and reuses MapKit enrichment via a relation to
    /// the existing `vendors` database.
    ///
    /// Status / Price properties carry an `options` config_json so the
    /// `.select` editor renders a cycle-on-tap pill (per #6's plan)
    /// rather than a free-form TextField.
    ///
    /// Idempotent — `INSERT OR IGNORE` is the established
    /// reseed-on-known-keys pattern (see v11, v18, v19, v20, v22).
    /// Skips fresh installs because `Seed.runIfEmpty` writes the same
    /// rows from a single source of truth on first launch.
    static func seedCollectionsAreaV24(_ db: Database) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())

        guard let workspaceID = try String.fetchOne(
            db,
            sql: "SELECT id FROM workspaces ORDER BY created_at LIMIT 1"
        ) else { return }

        try db.execute(
            sql: """
                INSERT OR IGNORE INTO areas (id, workspace_id, title, accent, sort_index)
                VALUES (?, ?, ?, ?, ?)
            """,
            arguments: ["area-collections", workspaceID, "Collections", "iris", 6.0]
        )

        struct DBRow { let id: String; let name: String; let plural: String; let icon: String; let view: String; let sort: Double }
        let dbs: [DBRow] = [
            .init(id: "books",       name: "Books",       plural: "Books",       icon: "B",  view: "gallery", sort: 8.0),
            .init(id: "movies",      name: "Movies",      plural: "Movies",      icon: "Mo", view: "gallery", sort: 8.1),
            .init(id: "tv_shows",    name: "TV Shows",    plural: "TV Shows",    icon: "Tv", view: "gallery", sort: 8.2),
            .init(id: "restaurants", name: "Restaurants", plural: "Restaurants", icon: "Re", view: "table",   sort: 8.3),
        ]
        for d in dbs {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO databases
                        (id, workspace_id, area_id, name, plural_name, icon, accent, default_view, created_at, updated_at, sort_index)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [d.id, workspaceID, "area-collections", d.name, d.plural, d.icon, "iris", d.view, now, now, d.sort]
            )
        }

        struct P { let db: String; let key: String; let label: String; let type: String; let sort: Double; let cfg: String }
        let vendorsRel = #"{"targetDatabaseID":"vendors"}"#
        let booksStatus = #"{"options":["to_read","reading","read","abandoned"]}"#
        let moviesStatus = #"{"options":["to_watch","watched","dropped"]}"#
        let tvStatus = #"{"options":["to_watch","watching","watched","dropped"]}"#
        let restStatus = #"{"options":["want_to_try","visited"]}"#
        let priceRange = #"{"options":["$","$$","$$$","$$$$"]}"#
        let props: [P] = [
            // books
            .init(db: "books", key: "name",           label: "Title",     type: "title",  sort: 0,  cfg: "{}"),
            .init(db: "books", key: "author",         label: "Author",    type: "text",   sort: 1,  cfg: "{}"),
            .init(db: "books", key: "isbn",           label: "ISBN",      type: "text",   sort: 2,  cfg: "{}"),
            .init(db: "books", key: "publisher",      label: "Publisher", type: "text",   sort: 3,  cfg: "{}"),
            .init(db: "books", key: "published_date", label: "Published", type: "date",   sort: 4,  cfg: "{}"),
            .init(db: "books", key: "page_count",     label: "Pages",     type: "number", sort: 5,  cfg: "{}"),
            .init(db: "books", key: "status",         label: "Status",    type: "select", sort: 6,  cfg: booksStatus),
            .init(db: "books", key: "rating",         label: "Rating",    type: "number", sort: 7,  cfg: "{}"),
            .init(db: "books", key: "started_date",   label: "Started",   type: "date",   sort: 8,  cfg: "{}"),
            .init(db: "books", key: "finished_date",  label: "Finished",  type: "date",   sort: 9,  cfg: "{}"),
            .init(db: "books", key: "notes",          label: "Notes",     type: "text",   sort: 10, cfg: "{}"),
            // movies
            .init(db: "movies", key: "name",            label: "Title",         type: "title",  sort: 0, cfg: "{}"),
            .init(db: "movies", key: "year",            label: "Year",          type: "number", sort: 1, cfg: "{}"),
            .init(db: "movies", key: "tmdb_id",         label: "TMDB ID",       type: "text",   sort: 2, cfg: "{}"),
            .init(db: "movies", key: "release_date",    label: "Released",      type: "date",   sort: 3, cfg: "{}"),
            .init(db: "movies", key: "runtime_minutes", label: "Runtime (min)", type: "number", sort: 4, cfg: "{}"),
            .init(db: "movies", key: "overview",        label: "Overview",      type: "text",   sort: 5, cfg: "{}"),
            .init(db: "movies", key: "status",          label: "Status",        type: "select", sort: 6, cfg: moviesStatus),
            .init(db: "movies", key: "rating",          label: "Rating",        type: "number", sort: 7, cfg: "{}"),
            .init(db: "movies", key: "watched_date",    label: "Watched",       type: "date",   sort: 8, cfg: "{}"),
            .init(db: "movies", key: "notes",           label: "Notes",         type: "text",   sort: 9, cfg: "{}"),
            // tv_shows
            .init(db: "tv_shows", key: "name",           label: "Title",        type: "title",  sort: 0,  cfg: "{}"),
            .init(db: "tv_shows", key: "year",           label: "Year",         type: "number", sort: 1,  cfg: "{}"),
            .init(db: "tv_shows", key: "tmdb_id",        label: "TMDB ID",      type: "text",   sort: 2,  cfg: "{}"),
            .init(db: "tv_shows", key: "first_air_date", label: "First aired",  type: "date",   sort: 3,  cfg: "{}"),
            .init(db: "tv_shows", key: "season_count",   label: "Seasons",      type: "number", sort: 4,  cfg: "{}"),
            .init(db: "tv_shows", key: "episode_count",  label: "Episodes",     type: "number", sort: 5,  cfg: "{}"),
            .init(db: "tv_shows", key: "overview",       label: "Overview",     type: "text",   sort: 6,  cfg: "{}"),
            .init(db: "tv_shows", key: "status",         label: "Status",       type: "select", sort: 7,  cfg: tvStatus),
            .init(db: "tv_shows", key: "rating",         label: "Rating",       type: "number", sort: 8,  cfg: "{}"),
            .init(db: "tv_shows", key: "last_watched",   label: "Last watched", type: "date",   sort: 9,  cfg: "{}"),
            .init(db: "tv_shows", key: "notes",          label: "Notes",        type: "text",   sort: 10, cfg: "{}"),
            // restaurants
            .init(db: "restaurants", key: "name",         label: "Name",         type: "title",    sort: 0, cfg: "{}"),
            .init(db: "restaurants", key: "vendor",       label: "Vendor",       type: "relation", sort: 1, cfg: vendorsRel),
            .init(db: "restaurants", key: "cuisine",      label: "Cuisine",      type: "select",   sort: 2, cfg: "{}"),
            .init(db: "restaurants", key: "price_range",  label: "Price",        type: "select",   sort: 3, cfg: priceRange),
            .init(db: "restaurants", key: "rating",       label: "Rating",       type: "number",   sort: 4, cfg: "{}"),
            .init(db: "restaurants", key: "status",       label: "Status",       type: "select",   sort: 5, cfg: restStatus),
            .init(db: "restaurants", key: "last_visited", label: "Last visited", type: "date",     sort: 6, cfg: "{}"),
            .init(db: "restaurants", key: "notes",        label: "Notes",        type: "text",     sort: 7, cfg: "{}"),
        ]
        for p in props {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO properties
                        (id, database_id, key, name, type, config_json, is_required, is_archived, created_at, updated_at, sort_index)
                    VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?)
                """,
                arguments: [
                    "\(p.db).\(p.key)", p.db,
                    p.key, p.label, p.type, p.cfg, now, now, p.sort
                ]
            )
        }
    }

    /// v25: flip the two text-typed `address` properties (`vendors.address`
    /// and `homes.address`) to the new `address` PropertyType. At the time
    /// this migration shipped, addresses on activities/lodging/transportation/
    /// restaurants flowed via the `vendor`/`organization` relation. v26
    /// later added direct `address` properties to activities and lodging
    /// to power the Trip detail route map (issue #8); see
    /// `seedTravelAddressesV26`.
    ///
    /// Idempotent — `WHERE … type = 'text'` makes the UPDATE a no-op
    /// once flipped. Existing values in `property_values` are left
    /// untouched: `text_value` keeps the user's typed one-line and
    /// `json_value` stays null until the user re-edits with autocomplete.
    static func flipAddressPropertiesV25(_ db: Database) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())
        let propIDs = ["vendors.address", "homes.address"]
        for id in propIDs {
            try db.execute(
                sql: "UPDATE properties SET type = 'address', updated_at = ? WHERE id = ? AND type = 'text'",
                arguments: [now, id]
            )
        }
    }

    /// v26: add direct `address` properties to `activities` and `lodging`,
    /// powering the Trip detail route map. The original Travel area
    /// (v22) deferred addresses to the linked vendor; the bespoke Trip
    /// detail UI (issue #8) needs per-record pins so each activity/
    /// lodging stop can carry its own structured address regardless of
    /// whether a vendor record exists.
    ///
    /// Idempotent — `INSERT OR IGNORE` follows the same reseed-on-known-
    /// keys idiom as v22 / v24. Skips fresh installs because
    /// `Seed.runIfEmpty` writes the same rows from a single source of
    /// truth on first launch.
    static func seedTravelAddressesV26(_ db: Database) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())
        struct P { let db: String; let key: String; let label: String; let sort: Double }
        let props: [P] = [
            .init(db: "activities", key: "address", label: "Address", sort: 4.5),
            .init(db: "lodging",    key: "address", label: "Address", sort: 4.5),
        ]
        for p in props {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO properties
                        (id, database_id, key, name, type, config_json, is_required, is_archived, created_at, updated_at, sort_index)
                    VALUES (?, ?, ?, ?, 'address', '{}', 0, 0, ?, ?, ?)
                """,
                arguments: ["\(p.db).\(p.key)", p.db, p.key, p.label, now, now, p.sort]
            )
        }
    }

    /// v27: dedupe duplicate relation rows that accumulated under the
    /// pre-uniqueness schema and add partial unique indexes so they
    /// can't return. Symptom that prompted this: a vehicle-maintenance
    /// record's Vehicle column was rendering the same target as a
    /// comma-joined list ("2006 GMC Canyon, 2006 GMC Canyon, …")
    /// because the fetcher emits one row per `relations` entry and
    /// nothing was constraining (source, target, property) to one row.
    ///
    /// Strategy: keep the oldest `relations` row per (source, target,
    /// property) tuple, delete the rest. Then add two partial unique
    /// indexes — one for property-bound relations, one for unbound —
    /// so future inserts can't re-create duplicates. Idempotent: the
    /// `IF NOT EXISTS` on the indexes makes the migration safe to
    /// re-run (GRDB never re-runs registered migrations, but defensive
    /// against a manual replay).
    static func dedupeRelationsV27(_ db: Database) throws {
        // Collapse property-bound duplicates: same source, target, and
        // property — keep the row with the smallest rowid (oldest).
        try db.execute(sql: """
            DELETE FROM relations
            WHERE rowid NOT IN (
                SELECT MIN(rowid)
                FROM relations
                WHERE property_id IS NOT NULL
                GROUP BY source_record_id, target_record_id, property_id
            )
            AND property_id IS NOT NULL
        """)

        // And property-unbound duplicates (free-form `linked` relations
        // created from the detail view's "Related" panel).
        try db.execute(sql: """
            DELETE FROM relations
            WHERE rowid NOT IN (
                SELECT MIN(rowid)
                FROM relations
                WHERE property_id IS NULL
                GROUP BY source_record_id, target_record_id
            )
            AND property_id IS NULL
        """)

        try db.execute(sql: """
            CREATE UNIQUE INDEX IF NOT EXISTS uniq_relations_bound
            ON relations(source_record_id, target_record_id, property_id)
            WHERE property_id IS NOT NULL
        """)
        try db.execute(sql: """
            CREATE UNIQUE INDEX IF NOT EXISTS uniq_relations_unbound
            ON relations(source_record_id, target_record_id)
            WHERE property_id IS NULL
        """)
    }

    /// v23: flip the four time-of-day Travel properties from plain `date`
    /// to time-zone-aware `date_tz`. Activities and lodging now carry
    /// instants in the event's local time zone (with the IANA tz id
    /// stored alongside) instead of whole-day markers. Trip windows
    /// (`trips.start_date` / `trips.end_date`) stay as plain `date`
    /// because they're whole-day markers, not specific instants.
    ///
    /// Idempotent — `WHERE … type = 'date'` makes the UPDATE a no-op
    /// once the type has already been flipped. Existing values in
    /// `property_values` are left untouched; the renderer falls back
    /// to a partial display until the user re-edits.
    static func flipTravelDatePropertiesV23(_ db: Database) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())
        let propIDs = [
            "activities.start",
            "activities.end",
            "lodging.check_in",
            "lodging.check_out",
        ]
        for id in propIDs {
            try db.execute(
                sql: "UPDATE properties SET type = 'date_tz', updated_at = ? WHERE id = ? AND type = 'date'",
                arguments: [now, id]
            )
        }
    }

    /// Glyph helper duplicated from `DBWrites` so the migration doesn't
    /// have to import the writes module. 1–2 letter capitalized
    /// initials of the title's first words; falls back to the first two
    /// characters if there are no word breaks.
    private static func makeGlyph(from title: String) -> String {
        let words = title.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).prefix(2)
        let chars = words.compactMap { $0.first.map(String.init) }.joined().uppercased()
        if chars.isEmpty { return String(title.prefix(2)).uppercased() }
        return String(chars.prefix(2))
    }

    /// v16: move existing assets from the legacy flat
    /// `Assets/<uuid>.<ext>` layout into the per-record layout
    /// `Assets/<Database>/<Title>-<shortID>/<original_filename>`. Files
    /// keep their original (sanitized) filenames; collisions get
    /// `-2`/`-3` suffixes. Updates `assets.relative_path` and
    /// `assets.stored_filename` rows in lockstep so future reads
    /// resolve correctly. Best-effort per asset — a failure on one
    /// file (e.g., file was already moved manually, iCloud download
    /// pending) doesn't abort the migration.
    static func relocateAssetsV16(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT a.id AS asset_id,
                   a.relative_path AS old_path,
                   a.original_filename AS original_filename,
                   r.id AS record_id,
                   r.title AS title,
                   d.name AS db_name
            FROM assets a
            JOIN records r ON r.id = a.record_id
            JOIN databases d ON d.id = r.database_id
            WHERE a.record_id IS NOT NULL
        """)

        let fm = FileManager.default
        let now = AppDatabase.isoFormatter.string(from: Date())
        var moved = 0
        var skipped = 0

        for row in rows {
            let assetID: String = row["asset_id"]
            let oldRelative: String = row["old_path"]
            let originalFilename: String = row["original_filename"]
            let recordID: String = row["record_id"]
            let title: String = row["title"]
            let dbName: String = row["db_name"]

            // Already in the per-record layout? Skip.
            if oldRelative.hasPrefix("Assets/")
                && oldRelative.split(separator: "/").count >= 4 {
                skipped += 1
                continue
            }

            let dbDir = AssetPathing.sanitize(dbName)
            let recDir = AssetPathing.recordFolderName(title: title, recordID: recordID)
            let folderURL = AppDatabase.workspaceFolder
                .appendingPathComponent("Assets", isDirectory: true)
                .appendingPathComponent(dbDir, isDirectory: true)
                .appendingPathComponent(recDir, isDirectory: true)
            do {
                try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
            } catch {
                skipped += 1
                continue
            }

            let resolvedFilename = AssetPathing.disambiguateFilename(originalFilename, in: folderURL)
            let newRelative = "Assets/\(dbDir)/\(recDir)/\(resolvedFilename)"

            let oldURL = AppDatabase.workspaceFolder.appendingPathComponent(oldRelative)
            let newURL = AppDatabase.workspaceFolder.appendingPathComponent(newRelative)

            guard fm.fileExists(atPath: oldURL.path) else {
                // Source missing — update the row anyway so a re-import
                // doesn't trip the dedup logic on a stale path.
                try? db.execute(
                    sql: "UPDATE assets SET relative_path = ?, stored_filename = ?, updated_at = ? WHERE id = ?",
                    arguments: [newRelative, resolvedFilename, now, assetID]
                )
                skipped += 1
                continue
            }

            do {
                try fm.moveItem(at: oldURL, to: newURL)
                try db.execute(
                    sql: "UPDATE assets SET relative_path = ?, stored_filename = ?, updated_at = ? WHERE id = ?",
                    arguments: [newRelative, resolvedFilename, now, assetID]
                )
                moved += 1
            } catch {
                skipped += 1
                continue
            }
        }

        os_log(
            .default,
            log: OSLog(subsystem: "Keystone", category: "Boot"),
            "relocateAssetsV16: moved %d, skipped %d",
            moved, skipped
        )
    }

    /// v11: introduce the `vehicle_maintenance` database for service receipts,
    /// inspections, registrations, recall notices, etc. tied to a Vehicle.
    /// Idempotent — safe to re-run, used on both fresh installs (via the
    /// migrator) and existing installs gaining the type for the first time.
    static func seedVehicleMaintenanceV11(_ db: Database) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())

        // Skip if no workspace yet (fresh installs hit Seed.runIfEmpty
        // afterwards, which writes the same row from a single source of
        // truth).
        guard let workspaceID = try String.fetchOne(
            db,
            sql: "SELECT id FROM workspaces ORDER BY created_at LIMIT 1"
        ) else { return }

        // Place after vehicles in the Mobility area.
        let nextSort = (try Double.fetchOne(
            db,
            sql: "SELECT MAX(sort_index) FROM databases"
        ) ?? -1) + 1

        try db.execute(
            sql: """
                INSERT OR IGNORE INTO databases
                    (id, workspace_id, area_id, name, plural_name, icon, accent, default_view, created_at, updated_at, sort_index)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                "vehicle_maintenance", workspaceID, "area-mobility",
                "Vehicle Maintenance", "Vehicle Maintenance",
                "VM", "iris", "table", now, now, nextSort
            ]
        )

        struct Prop { let key: String; let label: String; let type: String; let sort: Double; let cfg: String }
        let props: [Prop] = [
            .init(key: "name",     label: "Title",   type: "title",    sort: 0, cfg: "{}"),
            .init(key: "date",     label: "Date",    type: "date",     sort: 1, cfg: "{}"),
            .init(key: "vehicle",  label: "Vehicle", type: "relation", sort: 2, cfg: #"{"targetDatabaseID":"vehicles"}"#),
            .init(key: "kind",     label: "Kind",    type: "select",   sort: 3, cfg: "{}"),
            .init(key: "vendor",   label: "Vendor",  type: "text",     sort: 4, cfg: "{}"),
            .init(key: "mileage",  label: "Mileage", type: "number",   sort: 5, cfg: "{}"),
            .init(key: "cost",     label: "Cost",    type: "number",   sort: 6, cfg: "{}"),
        ]
        for p in props {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO properties
                        (id, database_id, key, name, type, config_json, is_required, is_archived, created_at, updated_at, sort_index)
                    VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?)
                """,
                arguments: [
                    "vehicle_maintenance.\(p.key)", "vehicle_maintenance",
                    p.key, p.label, p.type, p.cfg, now, now, p.sort
                ]
            )
        }
    }

    /// v12: real cleanup pass. Deletes asset rows (and their underlying
    /// files on disk) whose `record_id` no longer points to a live record,
    /// plus property_values / blocks / record_tags / relations whose
    /// referenced records are gone. Use this when records vanished outside
    /// the normal `DBWrites.deleteRecord` path (e.g. because iCloud Drive
    /// replaced the SQLite file with a stale version) and you want to
    /// reset the workspace before re-importing. Logs every file deletion
    /// to subsystem `Keystone` category `Boot`.
    static func cleanupOrphansV12(_ db: Database) throws {
        // Files first — collect before we touch the DB rows so the SELECT
        // can still see them.
        let orphanRows = try Row.fetchAll(db, sql: """
            SELECT id, original_filename, relative_path
            FROM assets
            WHERE record_id IS NULL OR record_id NOT IN (SELECT id FROM records)
        """)
        let fm = FileManager.default
        var fileCount = 0
        for row in orphanRows {
            let path: String = row["relative_path"]
            let abs = AppDatabase.absoluteURL(forRelativePath: path)
            if (try? fm.removeItem(at: abs)) != nil { fileCount += 1 }
        }

        let assetCount = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM assets
            WHERE record_id IS NULL OR record_id NOT IN (SELECT id FROM records)
        """) ?? 0
        try db.execute(sql: """
            DELETE FROM assets
            WHERE record_id IS NULL OR record_id NOT IN (SELECT id FROM records)
        """)

        let pvCount = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM property_values
            WHERE record_id NOT IN (SELECT id FROM records)
        """) ?? 0
        try db.execute(sql: """
            DELETE FROM property_values
            WHERE record_id NOT IN (SELECT id FROM records)
        """)

        let blkCount = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM blocks
            WHERE record_id NOT IN (SELECT id FROM records)
        """) ?? 0
        try db.execute(sql: """
            DELETE FROM blocks
            WHERE record_id NOT IN (SELECT id FROM records)
        """)

        let rtCount = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM record_tags
            WHERE record_id NOT IN (SELECT id FROM records)
               OR tag_id NOT IN (SELECT id FROM tags)
        """) ?? 0
        try db.execute(sql: """
            DELETE FROM record_tags
            WHERE record_id NOT IN (SELECT id FROM records)
               OR tag_id NOT IN (SELECT id FROM tags)
        """)

        let relCount = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM relations
            WHERE source_record_id NOT IN (SELECT id FROM records)
               OR target_record_id NOT IN (SELECT id FROM records)
        """) ?? 0
        try db.execute(sql: """
            DELETE FROM relations
            WHERE source_record_id NOT IN (SELECT id FROM records)
               OR target_record_id NOT IN (SELECT id FROM records)
        """)

        // Sweep stray files at the top level of `Assets/` that no
        // `assets.relative_path` row references. These accumulate when a
        // legacy-flat-layout file was an iCloud placeholder during v16:
        // the migration sees `fileExists == false`, repoints the DB row
        // to the new per-record path, then iCloud later downloads the
        // file at the *old* flat location with no DB row pointing at it.
        // We only sweep the top level — per-record subfolders are
        // unambiguously app-owned, top level might contain user-placed
        // files we shouldn't touch unannounced — and only delete files
        // not currently referenced by any asset row.
        let assetsRoot = AppDatabase.workspaceFolder.appendingPathComponent("Assets", isDirectory: true)
        let knownRelativePaths = Set(
            (try? String.fetchAll(db, sql: "SELECT relative_path FROM assets")) ?? []
        )
        var strayFileCount = 0
        if let topItems = try? fm.contentsOfDirectory(
            at: assetsRoot,
            includingPropertiesForKeys: [URLResourceKey.isRegularFileKey],
            options: []
        ) {
            for url in topItems {
                let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                guard isFile else { continue }
                let relative = "Assets/\(url.lastPathComponent)"
                if knownRelativePaths.contains(relative) { continue }
                if (try? fm.removeItem(at: url)) != nil {
                    strayFileCount += 1
                    os_log(
                        .default,
                        log: OSLog(subsystem: "Keystone", category: "Boot"),
                        "cleanupOrphansV12: removed stray file %{public}@",
                        url.lastPathComponent
                    )
                }
            }
        }

        // Prune record/database folders that became empty as a result
        // of removing orphan asset files. Without this, bulk-cleaning
        // (or deleting records) leaves behind empty
        // `Assets/<Database>/<Title>-<id>/` husks the user has to
        // manually clear out.
        AssetPathing.pruneAllEmptyFolders(under: assetsRoot)

        os_log(
            .default,
            log: OSLog(subsystem: "Keystone", category: "Boot"),
            "cleanupOrphansV12: deleted %d asset rows (%d files + %d strays), %d property_values, %d blocks, %d record_tags, %d relations",
            assetCount, fileCount, strayFileCount, pvCount, blkCount, rtCount, relCount
        )
    }

    /// Defensive sweep: any rows still pointing at deleted records (e.g.
    /// recovered from a stale WAL or pulled from CloudKit) get cleaned up so
    /// a fresh boot can never trip a foreign-key violation.
    static func sweepOrphansV8(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM property_values
            WHERE record_id NOT IN (SELECT id FROM records)
        """)
        try db.execute(sql: """
            DELETE FROM blocks
            WHERE record_id NOT IN (SELECT id FROM records)
        """)
        try db.execute(sql: """
            DELETE FROM record_tags
            WHERE record_id NOT IN (SELECT id FROM records)
               OR tag_id NOT IN (SELECT id FROM tags)
        """)
        try db.execute(sql: """
            DELETE FROM relations
            WHERE source_record_id NOT IN (SELECT id FROM records)
               OR target_record_id NOT IN (SELECT id FROM records)
        """)
    }

    /// v28: introduce the Service Catalog database + the `services`
    /// multi-relation that links a maintenance event back to one or
    /// more catalog items, plus current-mileage tracking on
    /// `vehicles`. (Shipped originally as `services_performed`;
    /// renamed to `services` in v31 so the YAML key matches the
    /// property key.) The catalog is the structural backbone
    /// for the next-due / overdue computation: each row is a recurring
    /// service with a mileage-and/or-time interval, optionally scoped
    /// to specific subjects. Adding subject kinds (home, pet) later is
    /// a config change — no further schema work needed.
    ///
    /// Honda Maintenance Schedule rows (Normal + Severe) ship pre-seeded
    /// per the user's directive to apply this PDF as the schedule for
    /// both 2015 Honda Fit and 2018 Honda CR-V. Catalog row IDs are
    /// stable strings (`svc-honda-…`) so sidecar frontmatter can
    /// reference them directly without round-tripping through UUIDs.
    ///
    /// Idempotent — `INSERT OR IGNORE` on every row, plus the
    /// `applies_to_vehicles` link is created via INSERT OR IGNORE
    /// against the v27 partial-unique-index (source, target, property).
    static func seedServiceCatalogV28(_ db: Database) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())

        guard let workspaceID = try String.fetchOne(
            db,
            sql: "SELECT id FROM workspaces ORDER BY created_at LIMIT 1"
        ) else { return }

        // Service Catalog database — sits in the Mobility area for now
        // because vehicles is the only subject kind with rows on day
        // one; can be relocated to a dedicated "Records/Schedules" area
        // later without breaking links.
        let catalogSort = (try Double.fetchOne(
            db,
            sql: "SELECT MAX(sort_index) FROM databases WHERE area_id = 'area-mobility'"
        ) ?? 4.5) + 0.1
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO databases
                    (id, workspace_id, area_id, name, plural_name, icon, accent, default_view, created_at, updated_at, sort_index)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                "service_catalog", workspaceID, "area-mobility",
                "Service Catalog", "Service Catalog",
                "SC", "iris", "list", now, now, catalogSort
            ]
        )

        struct P { let db: String; let key: String; let label: String; let type: String; let sort: Double; let cfg: String }
        let vehiclesRel = #"{"targetDatabaseID":"vehicles"}"#
        let catalogRel  = #"{"targetDatabaseID":"service_catalog","multi":true}"#
        let catalogSelf = #"{"targetDatabaseID":"service_catalog"}"#
        let subjectKindCfg = #"{"options":["vehicle","home","pet"]}"#
        let severityCfg = #"{"options":["normal","severe"]}"#
        let stageCfg = #"{"options":["first","recurring"]}"#

        let props: [P] = [
            // service_catalog
            .init(db: "service_catalog", key: "name",         label: "Service",           type: "title",    sort: 0,  cfg: "{}"),
            .init(db: "service_catalog", key: "subject_kind", label: "Applies to (kind)", type: "select",   sort: 1,  cfg: subjectKindCfg),
            .init(db: "service_catalog", key: "applies_to_vehicles", label: "Vehicles",   type: "relation", sort: 2,  cfg: #"{"targetDatabaseID":"vehicles","multi":true}"#),
            .init(db: "service_catalog", key: "interval_miles",  label: "Every (mi)",     type: "number",   sort: 3,  cfg: "{}"),
            .init(db: "service_catalog", key: "interval_months", label: "Every (months)", type: "number",   sort: 4,  cfg: "{}"),
            .init(db: "service_catalog", key: "schedule_severity", label: "Schedule",     type: "select",   sort: 5,  cfg: severityCfg),
            .init(db: "service_catalog", key: "stage",        label: "Stage",             type: "select",   sort: 6,  cfg: stageCfg),
            .init(db: "service_catalog", key: "predecessor",  label: "After",             type: "relation", sort: 7,  cfg: catalogSelf),
            .init(db: "service_catalog", key: "notes",        label: "Notes",             type: "text",     sort: 8,  cfg: "{}"),
            // vehicle_maintenance.services (multi-relation to catalog)
            .init(db: "vehicle_maintenance", key: "services", label: "Services", type: "relation", sort: 6.5, cfg: catalogRel),
            // vehicles current-mileage snapshot — recomputed by importer
            .init(db: "vehicles", key: "current_mileage",         label: "Current mileage", type: "number", sort: 7.0, cfg: "{}"),
            .init(db: "vehicles", key: "current_mileage_as_of",   label: "As of",           type: "date",   sort: 7.1, cfg: "{}"),
        ]
        // Keep `vehiclesRel` referenced for any future row added during
        // a follow-up; right now the only relation that points at
        // vehicles is `applies_to_vehicles` which is inlined above.
        _ = vehiclesRel
        for p in props {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO properties
                        (id, database_id, key, name, type, config_json, is_required, is_archived, created_at, updated_at, sort_index)
                    VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?)
                """,
                arguments: [
                    "\(p.db).\(p.key)", p.db,
                    p.key, p.label, p.type, p.cfg, now, now, p.sort
                ]
            )
        }

        try seedHondaCatalogRows(db)
    }

    /// Idempotent insertion of the Honda Maintenance Schedule catalog
    /// rows + their `applies_to_vehicles` links. Called from both the
    /// v28 migration (existing workspaces) and `Seed.runIfEmpty` (fresh
    /// installs, where the v28 migration runs *before* the workspace
    /// exists and exits early). Vehicle links resolve by record title
    /// and silently skip when the target vehicle isn't in Keystone yet.
    static func seedHondaCatalogRows(_ db: Database) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())

        // Bail if the catalog database itself isn't present yet — the
        // schema migration's INSERT OR IGNORE on `databases` is what
        // creates it, and on a brand-new install Seed.runIfEmpty runs
        // *before* migrations on the very first writer access. This
        // function is called again from `runIfEmpty` after the database
        // row is guaranteed to exist.
        let dbExists = (try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM databases WHERE id = 'service_catalog'"
        ) ?? 0) > 0
        guard dbExists else { return }

        for item in HondaMaintenanceSchedule.catalogRows {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO records
                        (id, database_id, title, glyph, tone, created_at, updated_at, sort_index)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    item.id, "service_catalog", item.title,
                    makeGlyph(from: item.title), "iris", now, now, item.sort
                ]
            )
            try setCatalogPropertyValue(db, recordID: item.id, key: "subject_kind", text: "vehicle", now: now)
            if let stage = item.stage {
                try setCatalogPropertyValue(db, recordID: item.id, key: "stage", text: stage, now: now)
            }
            if let miles = item.intervalMiles {
                try setCatalogPropertyValue(db, recordID: item.id, key: "interval_miles", number: Double(miles), now: now)
            }
            if let months = item.intervalMonths {
                try setCatalogPropertyValue(db, recordID: item.id, key: "interval_months", number: Double(months), now: now)
            }
            if let notes = item.notes, !notes.isEmpty {
                try setCatalogPropertyValue(db, recordID: item.id, key: "notes", text: notes, now: now)
            }
            if let predecessor = item.predecessorID {
                try linkCatalogPredecessor(db, sourceID: item.id, targetID: predecessor, now: now)
            }
            for vehicleTitle in item.vehicleTitles {
                if let vehicleID = try String.fetchOne(
                    db,
                    sql: "SELECT id FROM records WHERE database_id = 'vehicles' AND LOWER(title) = LOWER(?) LIMIT 1",
                    arguments: [vehicleTitle]
                ) {
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO relations
                                (id, source_record_id, target_record_id, relation_type, property_id, created_at, updated_at)
                            VALUES (?, ?, ?, 'linked', ?, ?, ?)
                        """,
                        arguments: [
                            UUID().uuidString, item.id, vehicleID,
                            "service_catalog.applies_to_vehicles", now, now
                        ]
                    )
                }
            }
        }
    }

    /// Helper used only by `seedServiceCatalogV28` — direct property-value
    /// upsert that bypasses `DBWrites.updatePropertyValue` so the
    /// migration doesn't depend on the writes module's relation
    /// auto-resolution. Catalog rows have no relations beyond the
    /// hand-crafted `applies_to_vehicles` and `predecessor` links above.
    private static func setCatalogPropertyValue(
        _ db: Database, recordID: String, key: String,
        text: String? = nil, number: Double? = nil, now: String
    ) throws {
        let propID = "service_catalog.\(key)"
        let pvID = "\(recordID).\(key)"
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO property_values
                    (id, record_id, property_id, text_value, number_value, date_value, json_value, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, NULL, NULL, ?, ?)
            """,
            arguments: [pvID, recordID, propID, text, number, now, now]
        )
    }

    private static func linkCatalogPredecessor(
        _ db: Database, sourceID: String, targetID: String, now: String
    ) throws {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO relations
                    (id, source_record_id, target_record_id, relation_type, property_id, created_at, updated_at)
                VALUES (?, ?, ?, 'linked', ?, ?, ?)
            """,
            arguments: [
                UUID().uuidString, sourceID, targetID,
                "service_catalog.predecessor", now, now
            ]
        )
    }

    /// v34: re-point existing `vehicle_maintenance` asset rows from the
    /// duplicated copy under `Assets/Vehicle Maintenance/<title>-<id>/`
    /// to the canonical PDF inside the sidecar bundle (`Cars/<vehicle>/
    /// <folder>/<basename>.pdf`). The Assets/ copy is then deleted.
    ///
    /// Why: Cars/ already holds the canonical PDF next to its `.md`
    /// sidecar. The original importer copied that PDF a second time
    /// into Assets/ via `AssetImporter.importFile`, which doubled disk
    /// + iCloud bandwidth (~173 MB on the seed dataset) without
    /// producing any user-visible benefit. After this migration,
    /// `AssetImporter.registerInPlace` is the path used at import time
    /// and the asset row points directly at the bundle file.
    ///
    /// Idempotent. Records whose new (Cars/) location is missing on
    /// disk get logged and left alone; the migration never deletes the
    /// only copy of a file it can't repoint. Assets in other databases
    /// are untouched.
    static func relocateVehicleMaintenanceAssetsInPlaceV34(_ db: Database) throws {
        let fm = FileManager.default
        let workspaceRoot = AppDatabase.workspaceFolder

        let rows = try Row.fetchAll(db, sql: """
            SELECT a.id AS asset_id,
                   a.relative_path AS old_relative,
                   a.original_filename AS filename,
                   r.sidecar_path AS sidecar_path
            FROM assets a
            JOIN records r ON r.id = a.record_id
            WHERE r.database_id = 'vehicle_maintenance'
              AND a.relative_path LIKE 'Assets/Vehicle Maintenance/%'
              AND r.sidecar_path IS NOT NULL
              AND r.sidecar_path != ''
        """)

        var relocated = 0
        var skipped = 0
        let now = AppDatabase.isoFormatter.string(from: Date())

        for row in rows {
            let assetID: String = row["asset_id"]
            let oldRelative: String = row["old_relative"]
            let filename: String = row["filename"]
            let sidecarPath: String = row["sidecar_path"]

            // The sidecar bundle folder is the parent of the .md file.
            // The canonical PDF/PNG/JPG companion lives inside the
            // same folder using the bundle's base filename — i.e.
            // whatever `original_filename` already records.
            let bundleFolder = (sidecarPath as NSString).deletingLastPathComponent
            let newRelative = "\(bundleFolder)/\(filename)"
            let newAbsolute = workspaceRoot.appendingPathComponent(newRelative)
            let oldAbsolute = workspaceRoot.appendingPathComponent(oldRelative)

            guard fm.fileExists(atPath: newAbsolute.path) else {
                os_log(
                    .default,
                    log: OSLog(subsystem: "Keystone", category: "Boot"),
                    "v34 skip asset %{public}@: bundle file missing at %{public}@",
                    assetID, newRelative
                )
                skipped += 1
                continue
            }

            try db.execute(
                sql: """
                    UPDATE assets
                    SET relative_path = ?,
                        stored_filename = ?,
                        updated_at = ?
                    WHERE id = ?
                """,
                arguments: [newRelative, filename, now, assetID]
            )
            // Best-effort: drop the duplicate copy. iCloud may still
            // be uploading; failures here aren't fatal — the file just
            // stays orphaned and falls out via the next per-folder
            // prune below or the cleanup-orphans pass.
            try? fm.removeItem(at: oldAbsolute)
            relocated += 1
        }

        // Prune any now-empty `Assets/Vehicle Maintenance/<…>/` folders
        // (and the parent dir if it's empty after that). Same
        // best-effort posture as `cleanupOrphansV12`.
        let vmAssetsRoot = workspaceRoot
            .appendingPathComponent("Assets", isDirectory: true)
            .appendingPathComponent("Vehicle Maintenance", isDirectory: true)
        AssetPathing.pruneAllEmptyFolders(under: vmAssetsRoot)
        if let entries = try? fm.contentsOfDirectory(atPath: vmAssetsRoot.path),
           entries.allSatisfy({ $0 == ".DS_Store" }) {
            try? fm.removeItem(at: vmAssetsRoot)
        }

        os_log(
            .default,
            log: OSLog(subsystem: "Keystone", category: "Boot"),
            "v34 relocateVehicleMaintenanceAssetsInPlace: relocated=%d skipped=%d",
            relocated, skipped
        )
    }

    /// v33: add `sidecar_path` to the records table so any record
    /// originated from (or paired with) an on-disk markdown file can
    /// be kept in sync with its source. The column stores a path
    /// relative to `AppDatabase.workspaceFolder` (so the value
    /// survives workspace relocation) — `nil` means "no sidecar."
    ///
    /// Used by the Local-First Sync subsystem: any DB write to a
    /// record that has a sidecar_path triggers a re-emit of the
    /// markdown file from the current DB state. Bidirectional sync
    /// — external edits flow back via the InboxWatcher / re-import
    /// path — keeps the Finder-visible files and the in-app data
    /// from drifting.
    static func addSidecarPathV33(_ db: Database) throws {
        // ALTER TABLE ADD COLUMN with a nullable TEXT column is safe
        // and instantaneous — SQLite stores it as a sparse column.
        // Idempotent guard for re-applies (PRAGMA returns the
        // existing schema before / after the migration ran).
        let existing = try Row.fetchAll(db, sql: "PRAGMA table_info(records)")
        let hasColumn = existing.contains { ($0["name"] as String?) == "sidecar_path" }
        guard !hasColumn else { return }
        try db.execute(sql: "ALTER TABLE records ADD COLUMN sidecar_path TEXT")
    }

    /// v32: seed Service Catalog rows for the 2006 GMC Canyon so its
    /// maintenance records can carry `services` links the same way the
    /// Hondas do. Hand-authored intervals (real manual not available);
    /// the rows are user-editable.
    ///
    /// Idempotent: `seedGMCCatalogRows` uses INSERT OR IGNORE on stable
    /// IDs, and the applies_to_vehicles relation is created with INSERT
    /// OR IGNORE against the v30 unique-constraint replacement indexes.
    static func seedGMCCatalogV32(_ db: Database) throws {
        try seedGMCCatalogRows(db)
    }

    /// Idempotent insertion of the GMC Canyon catalog rows. Called from
    /// the v32 migration (existing workspaces) and from
    /// `Seed.runIfEmpty` (fresh installs, where v32 runs before the
    /// workspace exists and exits early). Vehicle links resolve by
    /// record title; missing vehicles are silently skipped.
    static func seedGMCCatalogRows(_ db: Database) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())
        let dbExists = (try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM databases WHERE id = 'service_catalog'"
        ) ?? 0) > 0
        guard dbExists else { return }

        for item in GMCMaintenanceSchedule.catalogRows {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO records
                        (id, database_id, title, glyph, tone, created_at, updated_at, sort_index)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    item.id, "service_catalog", item.title,
                    makeGlyph(from: item.title), "iris", now, now, item.sort
                ]
            )
            try setCatalogPropertyValue(db, recordID: item.id, key: "subject_kind", text: "vehicle", now: now)
            if let miles = item.intervalMiles {
                try setCatalogPropertyValue(db, recordID: item.id, key: "interval_miles", number: Double(miles), now: now)
            }
            if let months = item.intervalMonths {
                try setCatalogPropertyValue(db, recordID: item.id, key: "interval_months", number: Double(months), now: now)
            }
            if let notes = item.notes, !notes.isEmpty {
                try setCatalogPropertyValue(db, recordID: item.id, key: "notes", text: notes, now: now)
            }
            for vehicleTitle in item.vehicleTitles {
                if let vehicleID = try String.fetchOne(
                    db,
                    sql: "SELECT id FROM records WHERE database_id = 'vehicles' AND LOWER(title) = LOWER(?) LIMIT 1",
                    arguments: [vehicleTitle]
                ) {
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO relations
                                (id, source_record_id, target_record_id, relation_type, property_id, created_at, updated_at)
                            VALUES (?, ?, ?, 'linked', ?, ?, ?)
                        """,
                        arguments: [
                            UUID().uuidString, item.id, vehicleID,
                            "service_catalog.applies_to_vehicles", now, now
                        ]
                    )
                }
            }
        }
    }

    /// v31: rename the `vehicle_maintenance.services_performed`
    /// property to `vehicle_maintenance.services` so it matches the
    /// `services:` key used in sidecar YAML frontmatter. Without this
    /// rename the InboxImporter looks up the property by its YAML
    /// key (`services`), finds nothing, and silently drops the value
    /// — every imported maintenance record ends up with an empty
    /// services list.
    ///
    /// Existing relations rows referencing the old `property_id`
    /// (`vehicle_maintenance.services_performed`) get re-pointed to
    /// the new property id. property_values rows get the same
    /// treatment, though we don't expect any to exist for relation
    /// properties.
    static func renameServicesPerformedV31(_ db: Database) throws {
        let oldID = "vehicle_maintenance.services_performed"
        let newID = "vehicle_maintenance.services"

        // No-op if the rename already happened (fresh installs come
        // up with the new key directly via Seed/v28).
        let oldExists = (try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM properties WHERE id = ?",
            arguments: [oldID]
        ) ?? 0) > 0
        guard oldExists else { return }

        let now = AppDatabase.isoFormatter.string(from: Date())

        // Detach FKs first by re-pointing rows away from the old
        // property id.  property_values uses an `id` of "<recordID>.<propertyKey>"
        // so the re-key has to update its primary key too.
        try db.execute(
            sql: """
                UPDATE property_values
                SET property_id = ?,
                    id = REPLACE(id, '.services_performed', '.services'),
                    updated_at = ?
                WHERE property_id = ?
            """,
            arguments: [newID, now, oldID]
        )
        try db.execute(
            sql: "UPDATE relations SET property_id = ?, updated_at = ? WHERE property_id = ?",
            arguments: [newID, now, oldID]
        )
        try db.execute(
            sql: """
                UPDATE properties
                SET id = ?, key = 'services', updated_at = ?
                WHERE id = ?
            """,
            arguments: [newID, now, oldID]
        )
    }

    /// v30: drop the unique indexes that v27 added on `relations`.
    /// SQLiteData's `SyncEngine` rejects synchronized tables that
    /// carry uniqueness constraints (it would have to second-guess
    /// row-level conflict resolution), and that rejection bricks
    /// CloudKit sync entirely — every boot reports `SchemaError(
    /// reason: …uniquenessConstraint)` and the engine refuses to
    /// initialize. Dedupe enforcement moves back to the application
    /// layer:
    ///   1. `DBWrites.addRelation` already does a find-or-insert on
    ///      every call (was originally added in v27), so user-driven
    ///      writes won't create duplicates.
    ///   2. `DBWrites.dedupeRelations` runs every boot from
    ///      AppDatabase as a self-heal in case CloudKit replicates
    ///      conflicting inserts from another device.
    /// Non-unique indexes stay in place so the dedupe SELECT and the
    /// `addRelation` lookup are still O(log n).
    static func dropRelationUniqueIndexesV30(_ db: Database) throws {
        try db.execute(sql: "DROP INDEX IF EXISTS uniq_relations_bound")
        try db.execute(sql: "DROP INDEX IF EXISTS uniq_relations_unbound")

        // Run the same dedupe SQL v27 used. Defensive — v27 already
        // ran this once, but if CloudKit replicated duplicate rows
        // back to this device any time after v27 (and before the
        // unique index started rejecting them), they're still here.
        try db.execute(sql: """
            DELETE FROM relations
            WHERE rowid NOT IN (
                SELECT MIN(rowid)
                FROM relations
                WHERE property_id IS NOT NULL
                GROUP BY source_record_id, target_record_id, property_id
            )
            AND property_id IS NOT NULL
        """)
        try db.execute(sql: """
            DELETE FROM relations
            WHERE rowid NOT IN (
                SELECT MIN(rowid)
                FROM relations
                WHERE property_id IS NULL
                GROUP BY source_record_id, target_record_id
            )
            AND property_id IS NULL
        """)

        // Replace the dropped unique indexes with regular ones so the
        // application-level lookups in `addRelation` and the boot-time
        // dedupe pass stay fast.
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_relations_bound
            ON relations(source_record_id, target_record_id, property_id)
            WHERE property_id IS NOT NULL
        """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_relations_unbound
            ON relations(source_record_id, target_record_id)
            WHERE property_id IS NULL
        """)
    }

    /// v29: drop the Severe Conditions catalog rows and re-title the
    /// remaining rows so neither "(Normal)" nor "(Severe)" appears.
    /// We're not differentiating driving severity — every Honda in
    /// this workspace follows the Normal Conditions schedule. The
    /// `-normal` suffix on stable IDs stays for backward compatibility
    /// with already-tagged sidecars.
    ///
    /// Idempotent — re-running deletes nothing further (no rows match
    /// the severe pattern any more) and the title-rewrite UPDATEs are
    /// no-ops once applied.
    static func dropSevereCatalogRowsV29(_ db: Database) throws {
        // Schema-FK-cascade handles property_values + relations when
        // their owner record is removed.
        try db.execute(sql: """
            DELETE FROM records
            WHERE database_id = 'service_catalog'
              AND id LIKE '%-severe%'
        """)

        // Rewrite the existing v28 titles to drop the "(Normal)" /
        // " (Normal)" suffix the seed used to emit. We rename in place
        // rather than blowing the rows away, so any links the user
        // already made to a normal-row stick.
        let renames: [(id: String, title: String)] = HondaMaintenanceSchedule.catalogRows
            .map { ($0.id, $0.title) }
        let now = AppDatabase.isoFormatter.string(from: Date())
        for r in renames {
            try db.execute(
                sql: """
                    UPDATE records
                    SET title = ?, updated_at = ?
                    WHERE id = ? AND database_id = 'service_catalog'
                """,
                arguments: [r.title, now, r.id]
            )
        }

        // The schedule_severity property remains on the catalog
        // schema (a future feature might use it again) but every
        // value gets cleared since we no longer mean anything by
        // "normal" vs "severe."
        try db.execute(sql: """
            DELETE FROM property_values
            WHERE property_id = 'service_catalog.schedule_severity'
        """)
    }

    /// v35 — encryption-at-rest scaffolding for the privacy lock.
    ///
    /// Adds three new nullable columns:
    ///   - `property_values.enc_value` (BLOB): AES-GCM ciphertext of
    ///     the value when the owning record is protected (or
    ///     cascade-protected). Plaintext columns (`text_value`,
    ///     `number_value`, `date_value`, `json_value`) are nulled when
    ///     `enc_value` is set, so the union of "what's set" tells you
    ///     whether the row is encrypted.
    ///   - `blocks.enc_content` (BLOB): same idea for block bodies.
    ///     The plaintext `content_json` is nulled (or set to '{}' as a
    ///     placeholder) when `enc_content` is populated.
    ///   - `assets.is_encrypted` (INTEGER, default 0): flag indicating
    ///     the on-disk file at `relative_path` is AES-GCM ciphertext
    ///     instead of the original bytes. The asset reader checks this
    ///     before vending data; if true, it decrypts via
    ///     `ProtectionKeyClient` before handing back.
    ///
    /// All three additions are nullable (or default-zero) ALTER TABLE
    /// ADD COLUMNs — instantaneous and crash-safe. Idempotent: each
    /// ALTER is guarded with a PRAGMA table_info check, so re-running
    /// against a half-applied migration succeeds.
    ///
    /// **No automatic encryption pass.** Existing protected records
    /// stay in plaintext until the user opens them next while
    /// authenticated; the encryption-on-write path catches up at that
    /// point. This avoids needing a key during migration time
    /// (migrations run before biometric auth).
    static func addEncryptedColumnsV35(_ db: Database) throws {
        try addColumnIfMissing(db, table: "property_values", column: "enc_value", definition: "BLOB")
        try addColumnIfMissing(db, table: "blocks", column: "enc_content", definition: "BLOB")
        try addColumnIfMissing(db, table: "assets", column: "is_encrypted", definition: "INTEGER NOT NULL DEFAULT 0")
    }

    /// v36 — drop `records.database_id` foreign-key constraint so
    /// individual records become valid CKShare roots. CloudKit zones
    /// can't reference each other, so sqlite-data's `SyncEngine.share()`
    /// rejects records whose table has any outgoing FK
    /// (`recordNotRoot([ForeignKey])`). Removing the FK unblocks
    /// per-record sharing for #14.
    ///
    /// **Cascade replacement.** The old `ON DELETE CASCADE` on this FK
    /// is now gone — deleting a row from `databases` no longer auto-
    /// deletes its records. App writes that delete a database must
    /// explicitly delete the records first; see
    /// `DBWrites.deleteDatabaseAndChildren` for the helper that
    /// replaces this behavior.
    ///
    /// All record columns and rows are preserved verbatim; only the FK
    /// is dropped. The `idx_records_db` index is recreated by name so
    /// queries that filter by `database_id` keep their plan.
    static func dropRecordsDatabaseIDFKV36(_ db: Database) throws {
        // Idempotency: if the FK is already absent, no-op. Detected via
        // PRAGMA foreign_key_list — empty list means we already
        // rebuilt the table.
        let fkRows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(records)")
        if fkRows.isEmpty { return }

        try db.execute(sql: "PRAGMA foreign_keys = OFF")
        try db.execute(sql: #"""
            CREATE TABLE records_new (
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
              sort_index REAL NOT NULL,
              sidecar_path TEXT
            )
        """#)
        try db.execute(sql: """
            INSERT INTO records_new
            SELECT id, database_id, title, subtitle, glyph, tone, icon,
                   cover_asset_id, template_id, created_at, updated_at,
                   archived_at, deleted_at, sort_index, sidecar_path
            FROM records
        """)
        try db.execute(sql: "DROP TABLE records")
        try db.execute(sql: "ALTER TABLE records_new RENAME TO records")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_records_db ON records(database_id)")
    }

    /// v37 — drop the secondary FK from `property_values.property_id →
    /// properties(id)` so the row is single-FK. sqlite-data's CloudKit
    /// trigger routes single-FK rows into the same zone as their parent
    /// (cascade-via-parent-FK); rows with multiple FKs default to the
    /// default zone and don't follow a shared parent. Keeping the
    /// `record_id` FK lets `property_values` follow `records` into a
    /// share zone for #14.
    ///
    /// PropertyDef rows are workspace-level metadata (in
    /// `privateTables:` for the SyncEngine) — not shareable, never move
    /// out of the default zone. Recipients of a shared record already
    /// have the same `properties.id` because property IDs are
    /// deterministic (`"<dbID>.<key>"`) and seeded by migrations on every
    /// device. The orphan risk (a property_value referencing a
    /// since-deleted property) is handled by the existing seed-only
    /// migrations and the read paths' JOINs which silently skip
    /// orphaned values.
    static func dropPropertyValuesPropertyFKV37(_ db: Database) throws {
        let fkRows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(property_values)")
        // Idempotent: stop after the table is already single-FK.
        if fkRows.count <= 1 { return }

        try db.execute(sql: "PRAGMA foreign_keys = OFF")
        try db.execute(sql: #"""
            CREATE TABLE property_values_new (
              id TEXT PRIMARY KEY NOT NULL,
              record_id TEXT NOT NULL,
              property_id TEXT NOT NULL,
              text_value TEXT,
              number_value REAL,
              bool_value INTEGER,
              date_value TEXT,
              json_value TEXT,
              enc_value BLOB,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              FOREIGN KEY (record_id) REFERENCES records(id) ON DELETE CASCADE
            )
        """#)
        try db.execute(sql: """
            INSERT INTO property_values_new
            SELECT id, record_id, property_id, text_value, number_value, bool_value,
                   date_value, json_value, enc_value, created_at, updated_at
            FROM property_values
        """)
        try db.execute(sql: "DROP TABLE property_values")
        try db.execute(sql: "ALTER TABLE property_values_new RENAME TO property_values")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_property_values_record ON property_values(record_id)")
    }

    /// v38 — drop the secondary FK from `assets.workspace_id →
    /// workspaces(id)` so the row is single-FK. Same rationale as v37:
    /// for an attached asset to follow its record into a share zone,
    /// `assets` must be single-FK so sqlite-data's trigger routes it
    /// alongside its parent record. The `workspace_id` column stays
    /// (the value is still useful for non-record-bound assets) — we
    /// just drop the SQL-level constraint.
    static func dropAssetsWorkspaceFKV38(_ db: Database) throws {
        let fkRows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(assets)")
        if fkRows.count <= 1 { return }

        try db.execute(sql: "PRAGMA foreign_keys = OFF")
        try db.execute(sql: #"""
            CREATE TABLE assets_new (
              id TEXT PRIMARY KEY NOT NULL,
              workspace_id TEXT NOT NULL,
              record_id TEXT,
              original_filename TEXT NOT NULL,
              stored_filename TEXT NOT NULL,
              relative_path TEXT NOT NULL,
              mime_type TEXT,
              file_extension TEXT,
              byte_size INTEGER,
              content_hash TEXT,
              extracted_text TEXT,
              metadata_json TEXT NOT NULL DEFAULT '{}',
              is_encrypted INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              FOREIGN KEY (record_id) REFERENCES records(id) ON DELETE SET NULL
            )
        """#)
        try db.execute(sql: """
            INSERT INTO assets_new (
                id, workspace_id, record_id, original_filename, stored_filename,
                relative_path, mime_type, file_extension, byte_size, content_hash,
                extracted_text, metadata_json, is_encrypted, created_at, updated_at
            )
            SELECT
                id, workspace_id, record_id, original_filename, stored_filename,
                relative_path, mime_type, file_extension, byte_size, content_hash,
                extracted_text, metadata_json, is_encrypted, created_at, updated_at
            FROM assets
        """)
        try db.execute(sql: "DROP TABLE assets")
        try db.execute(sql: "ALTER TABLE assets_new RENAME TO assets")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_assets_record ON assets(record_id)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_assets_hash ON assets(content_hash)")
    }

    /// Helper: add a column if it doesn't exist, no-op otherwise.
    /// Wraps the PRAGMA + ALTER pattern used by `addSidecarPathV33`
    /// so future encrypted-column extensions stay one-liners.
    private static func addColumnIfMissing(
        _ db: Database,
        table: String,
        column: String,
        definition: String
    ) throws {
        let existing = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        let hasColumn = existing.contains { ($0["name"] as String?) == column }
        guard !hasColumn else { return }
        try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }

    /// v39 — rename the seeded `events` database from "Events & Trips"
    /// to just "Events". The combined label dates from before #2 split
    /// Trips into a dedicated database under the Travel area; with
    /// that in place, "& Trips" is misleading sidebar copy that points
    /// the user at the wrong database.
    ///
    /// Guarded by an exact match on the prior name + plural so a user
    /// who already renamed the row (e.g. to "Calendar" or back to
    /// "Events" themselves) keeps their override. Idempotent.
    static func renameEventsDatabaseV39(_ db: Database) throws {
        try db.execute(
            sql: """
                UPDATE databases
                SET name = 'Events', plural_name = 'Events'
                WHERE id = 'events'
                  AND name = 'Events & Trips'
                  AND plural_name = 'Events & Trips'
            """
        )
    }

    /// Local-only diagnostic log of CloudKit sync activity. Owned by the
    /// sync layer, deliberately NOT registered with `SyncEngine.tables` /
    /// `privateTables` — events are per-device observability, not user
    /// data, and pushing them through CloudKit would amplify writes
    /// without any benefit (each device sees its own engine activity).
    static func createSyncEventsV40(_ db: Database) throws {
        try db.execute(sql: #"""
            CREATE TABLE IF NOT EXISTS sync_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              timestamp TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
              event_type TEXT NOT NULL,
              record_type TEXT NOT NULL DEFAULT '',
              record_id TEXT NOT NULL DEFAULT '',
              error_code TEXT NOT NULL DEFAULT '',
              details TEXT NOT NULL DEFAULT ''
            )
        """#)
        try db.execute(sql: #"""
            CREATE INDEX IF NOT EXISTS sync_events_timestamp_idx
              ON sync_events(timestamp DESC)
        """#)
        try db.execute(sql: #"""
            CREATE INDEX IF NOT EXISTS sync_events_event_type_idx
              ON sync_events(event_type)
        """#)
    }

    /// v41 — unify Restaurants into Vendors as a saved view.
    ///
    /// Goal: adding a restaurant is one step (search Apple Maps, pick a
    /// result) instead of two (create Restaurant, then attach a Vendor).
    /// To get there cleanly, Restaurants becomes a *view* of the
    /// `vendors` database with `kind = "restaurant"` pinned. Existing
    /// restaurants records are merged into their linked vendor — or a
    /// fresh vendor is materialized when no link exists — and the
    /// `restaurants` database row is retired.
    ///
    /// Restaurant-specific properties (cuisine, price_range, rating,
    /// status, last_visited, hours) move onto `vendors` with
    /// `applicable_kinds: ["restaurant"]` so non-restaurant Vendor
    /// records don't surface them in their detail view.
    ///
    /// Idempotent. Re-running is safe: every INSERT uses OR IGNORE, the
    /// records-merge loop only fires while a `restaurants` database row
    /// still exists, and the schema extensions to `views` are guarded by
    /// `addColumnIfMissing`. Skips fresh installs where the workspace
    /// hasn't been seeded yet — `Seed.runIfEmpty` writes the same final
    /// shape from a single source of truth on first launch.
    static func seedRestaurantsAsVendorsViewV41(_ db: Database) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())

        // 1. Extend the `views` table with sidebar-display columns. The
        //    table was carved at v1 (id/database_id/workspace_id/name/
        //    type/query_json/presentation_json) but never populated; we
        //    now use it for the Restaurants view, which needs an area
        //    binding, an order, and a glyph/accent so the sidebar can
        //    render it next to real databases. The ALTER runs ahead of
        //    the workspace guard below so fresh installs (where
        //    `Seed.runIfEmpty` writes the view row a beat later) see
        //    the extended schema too.
        try addColumnIfMissing(db, table: "views", column: "area_id",     definition: "TEXT")
        try addColumnIfMissing(db, table: "views", column: "sort_index",  definition: "REAL NOT NULL DEFAULT 0")
        try addColumnIfMissing(db, table: "views", column: "icon",        definition: "TEXT")
        try addColumnIfMissing(db, table: "views", column: "accent",      definition: "TEXT NOT NULL DEFAULT 'graphite'")
        try addColumnIfMissing(db, table: "views", column: "plural_name", definition: "TEXT")

        guard let workspaceID = try String.fetchOne(
            db,
            sql: "SELECT id FROM workspaces ORDER BY created_at LIMIT 1"
        ) else { return }

        // 2. Add restaurant-only properties to `vendors`. Each carries
        //    `applicable_kinds: ["restaurant"]` so the detail view hides
        //    them on non-restaurant vendor records, and generic table /
        //    list views (the plain Vendors database) hide them as
        //    columns. The Restaurants view promotes them.
        struct VProp { let key: String; let label: String; let type: String; let sort: Double; let cfg: String }
        let restKinds = #""applicable_kinds":["restaurant"]"#
        let vprops: [VProp] = [
            .init(key: "cuisine",      label: "Cuisine",      type: "select", sort: 1.1,  cfg: "{\(restKinds)}"),
            .init(key: "price_range",  label: "Price",        type: "select", sort: 1.2,  cfg: "{\"options\":[\"$\",\"$$\",\"$$$\",\"$$$$\"],\(restKinds)}"),
            .init(key: "rating",       label: "Rating",       type: "number", sort: 1.3,  cfg: "{\(restKinds)}"),
            .init(key: "status",       label: "Status",       type: "select", sort: 1.4,  cfg: "{\"options\":[\"want_to_try\",\"visited\"],\(restKinds)}"),
            .init(key: "last_visited", label: "Last visited", type: "date",   sort: 1.5,  cfg: "{\(restKinds)}"),
            .init(key: "hours",        label: "Hours",        type: "text",   sort: 1.6,  cfg: "{\(restKinds)}"),
        ]
        for p in vprops {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO properties
                        (id, database_id, key, name, type, config_json, is_required, is_archived, created_at, updated_at, sort_index)
                    VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?)
                """,
                arguments: [
                    "vendors.\(p.key)", "vendors",
                    p.key, p.label, p.type, p.cfg, now, now, p.sort
                ]
            )
        }

        // 3. Migrate every record in the `restaurants` database into
        //    Vendors. Two flavors:
        //    a. Records with a `restaurants.vendor` relation → fold the
        //       restaurant's properties onto the linked vendor.
        //    b. Records without a linked vendor → materialize a fresh
        //       vendor carrying the restaurant's title + properties.
        //    In both cases we set `kind = "restaurant"`, then delete the
        //    restaurant record. Property values cascade off (v37 dropped
        //    the property FK on property_values, but we DELETE by
        //    record_id, not property_id, which still cascades via the
        //    records FK).
        try migrateRestaurantsIntoVendorsV41(db, now: now)

        // 4. Insert the Restaurants view row. Points at `vendors`,
        //    pins `kind = "restaurant"` in its query, and names
        //    `"restaurant"` as the lookup provider — the registry
        //    resolves that to a MapKit variant constrained to food /
        //    drink POI categories.
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

        // 5. Retire the `restaurants` database. Properties first (so
        //    they don't dangle), then the database row itself.
        try db.execute(sql: "DELETE FROM properties WHERE database_id = 'restaurants'")
        try db.execute(sql: "DELETE FROM databases WHERE id = 'restaurants'")
    }

    /// Worker for `seedRestaurantsAsVendorsViewV41`. Pulled out so the
    /// migration body stays readable and the row-by-row merge logic is
    /// testable in isolation. Idempotent: re-running after the
    /// `restaurants` database is already gone is a no-op.
    private static func migrateRestaurantsIntoVendorsV41(_ db: Database, now: String) throws {
        // Heads up: if the restaurants database has already been
        // dropped on this device, there's nothing to migrate.
        let restaurantsExists = (try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM databases WHERE id = 'restaurants'"
        ) ?? 0) > 0
        guard restaurantsExists else { return }

        // Resolve the `restaurants.vendor` property id once. Older
        // workspaces may have created the property under a different
        // id; fall back to a (database_id, key) lookup.
        let vendorRelPropID: String? = (try? String.fetchOne(
            db,
            sql: """
                SELECT id FROM properties
                WHERE database_id = 'restaurants' AND key = 'vendor'
                LIMIT 1
            """
        ))

        // Per-record copy list. Each entry maps a restaurants property
        // key to a vendors property key — usually identical, but spelled
        // out so renames (none right now) are obvious.
        let copyKeys: [(restKey: String, vendKey: String)] = [
            ("cuisine",      "cuisine"),
            ("price_range",  "price_range"),
            ("rating",       "rating"),
            ("status",       "status"),
            ("last_visited", "last_visited"),
        ]
        // Resolve property ids on both sides. Skip entries whose Vendor
        // counterpart is missing (shouldn't happen post step 2 above,
        // but defensive).
        struct PropPair { let restID: String; let vendID: String; let vendKey: String }
        var copyPairs: [PropPair] = []
        for (restKey, vendKey) in copyKeys {
            guard let rid = try String.fetchOne(
                db,
                sql: "SELECT id FROM properties WHERE database_id = 'restaurants' AND key = ? LIMIT 1",
                arguments: [restKey]
            ) else { continue }
            guard let vid = try String.fetchOne(
                db,
                sql: "SELECT id FROM properties WHERE database_id = 'vendors' AND key = ? LIMIT 1",
                arguments: [vendKey]
            ) else { continue }
            copyPairs.append(PropPair(restID: rid, vendID: vid, vendKey: vendKey))
        }
        // Notes is handled specially (append rather than overwrite).
        let restNotesPropID = try String.fetchOne(
            db,
            sql: "SELECT id FROM properties WHERE database_id = 'restaurants' AND key = 'notes' LIMIT 1"
        )
        let vendNotesPropID = try String.fetchOne(
            db,
            sql: "SELECT id FROM properties WHERE database_id = 'vendors' AND key = 'notes' LIMIT 1"
        )
        let vendKindPropID = try String.fetchOne(
            db,
            sql: "SELECT id FROM properties WHERE database_id = 'vendors' AND key = 'kind' LIMIT 1"
        )

        // Walk every surviving restaurants record.
        let restaurantRows = try Row.fetchAll(db, sql: """
            SELECT id, title, glyph, tone, sort_index, cover_asset_id
            FROM records
            WHERE database_id = 'restaurants' AND deleted_at IS NULL
        """)
        for rec in restaurantRows {
            let restID: String = rec["id"]
            let restTitle: String = rec["title"]

            // Find the linked vendor record id, if any. Multi-target
            // relations are rare here; first wins.
            var vendorID: String? = nil
            if let propID = vendorRelPropID {
                vendorID = try String.fetchOne(
                    db,
                    sql: """
                        SELECT target_record_id FROM relations
                        WHERE source_record_id = ? AND property_id = ?
                        LIMIT 1
                    """,
                    arguments: [restID, propID]
                )
            }

            // No linked vendor → materialize one carrying the restaurant's
            // identity. New vendor row keeps the restaurant's cover_asset_id
            // (cover images often point at a hero shot the user picked) and
            // its sort_index relative to the bottom of the vendors list.
            if vendorID == nil {
                let newID = UUID().uuidString
                let glyph: String = rec["glyph"] ?? makeGlyph(from: restTitle)
                let tone: String = rec["tone"] ?? "graphite"
                let coverAssetID: String? = rec["cover_asset_id"]
                let nextSort = (try Double.fetchOne(
                    db,
                    sql: "SELECT MAX(sort_index) FROM records WHERE database_id = 'vendors'"
                ) ?? -1) + 1
                try db.execute(
                    sql: """
                        INSERT INTO records
                            (id, database_id, title, glyph, tone, cover_asset_id,
                             created_at, updated_at, sort_index)
                        VALUES (?, 'vendors', ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [newID, restTitle, glyph, tone, coverAssetID, now, now, nextSort]
                )
                vendorID = newID
            }
            guard let targetVendorID = vendorID else { continue }

            // Copy each restaurant property value to the matching vendor
            // property. We only write when the source value exists and
            // the vendor doesn't already have a non-empty value (don't
            // clobber a manually-curated vendor field).
            for pair in copyPairs {
                guard let srcRow = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT text_value, number_value, date_value, json_value
                        FROM property_values
                        WHERE record_id = ? AND property_id = ?
                        LIMIT 1
                    """,
                    arguments: [restID, pair.restID]
                ) else { continue }
                let text: String? = srcRow["text_value"]
                let number: Double? = srcRow["number_value"]
                let date: String? = srcRow["date_value"]
                let json: String? = srcRow["json_value"]
                let hasSourceValue = (text != nil && !(text ?? "").isEmpty)
                    || number != nil
                    || (date != nil && !(date ?? "").isEmpty)
                    || (json != nil && !(json ?? "").isEmpty)
                guard hasSourceValue else { continue }

                // Vendor already has a value? Don't overwrite.
                let existing: String? = try String.fetchOne(
                    db,
                    sql: """
                        SELECT COALESCE(text_value, CAST(number_value AS TEXT), date_value, json_value)
                        FROM property_values
                        WHERE record_id = ? AND property_id = ?
                        LIMIT 1
                    """,
                    arguments: [targetVendorID, pair.vendID]
                )
                if let existing, !existing.isEmpty { continue }

                let pvID = "\(targetVendorID).\(pair.vendKey)"
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO property_values
                            (id, record_id, property_id, text_value, number_value, date_value, json_value, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [pvID, targetVendorID, pair.vendID, text, number, date, json, now, now]
                )
            }

            // Notes: append rather than overwrite so a manual vendor note
            // doesn't get lost.
            if let restNotesID = restNotesPropID, let vendNotesID = vendNotesPropID {
                let restNotes: String = (try String.fetchOne(
                    db,
                    sql: "SELECT text_value FROM property_values WHERE record_id = ? AND property_id = ? LIMIT 1",
                    arguments: [restID, restNotesID]
                )) ?? ""
                if !restNotes.isEmpty {
                    let existing: String = (try String.fetchOne(
                        db,
                        sql: "SELECT text_value FROM property_values WHERE record_id = ? AND property_id = ? LIMIT 1",
                        arguments: [targetVendorID, vendNotesID]
                    )) ?? ""
                    let combined = existing.isEmpty
                        ? restNotes
                        : (existing + "\n\n" + restNotes)
                    let pvID = "\(targetVendorID).notes"
                    try db.execute(
                        sql: """
                            INSERT OR REPLACE INTO property_values
                                (id, record_id, property_id, text_value, created_at, updated_at)
                            VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [pvID, targetVendorID, vendNotesID, combined, now, now]
                    )
                }
            }

            // Stamp `kind = "restaurant"` on the vendor.
            if let kindID = vendKindPropID {
                let pvID = "\(targetVendorID).kind"
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO property_values
                            (id, record_id, property_id, text_value, created_at, updated_at)
                        VALUES (?, ?, ?, 'restaurant', ?, ?)
                    """,
                    arguments: [pvID, targetVendorID, kindID, now, now]
                )
            }

            // Re-point any incoming relations that named the old
            // restaurant record to the merged vendor instead. Keeps,
            // e.g., a calendar event that linked the restaurant as its
            // venue working post-migration. Idempotent: a re-run
            // re-points already-pointed relations to themselves and the
            // (source, target, property) uniqueness shape from v27
            // collapses any duplicates.
            try db.execute(
                sql: """
                    UPDATE relations
                    SET target_record_id = ?, updated_at = ?
                    WHERE target_record_id = ?
                """,
                arguments: [targetVendorID, now, restID]
            )

            // Soft-delete won't do — we want the row gone so the
            // post-migration sidebar count for restaurants reads zero.
            // FK cascade on records → property_values clears the
            // restaurant's own property_values; the restaurant's
            // outgoing `restaurants.vendor` relation goes away with
            // the source record.
            try db.execute(sql: "DELETE FROM records WHERE id = ?", arguments: [restID])
        }
    }

    /// v42 — per-database view ergonomics (sort, group, filters, gallery
    /// cover size). Local-only table: deliberately NOT registered with
    /// `SyncEngine.tables` / `privateTables`. UI preferences are
    /// per-device; pushing them through CloudKit would cause one
    /// device's "sort by published_date" to overwrite another's "sort
    /// by rating" every time the user switched between them.
    static func createDatabaseViewPrefsV42(_ db: Database) throws {
        try db.execute(sql: #"""
            CREATE TABLE IF NOT EXISTS database_view_prefs (
              database_id        TEXT PRIMARY KEY,
              sort_key           TEXT,
              sort_ascending     INTEGER NOT NULL DEFAULT 1,
              group_key          TEXT,
              gallery_cover_size TEXT NOT NULL DEFAULT 'medium',
              filters_json       TEXT NOT NULL DEFAULT '[]',
              updated_at         TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
            )
        """#)
    }

    /// v43 — descriptions on books (movies/tv already have `overview`)
    /// plus a `tags` multiSelect property on all three collections so
    /// the enrichment providers can write genres / categories. Property
    /// rows are inserted with `OR IGNORE` so re-running is safe and a
    /// user who already created their own `tags` column wins.
    static func addCollectionsDescriptionAndTagsV43(_ db: Database) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())
        struct PropAdd { let dbID: String; let key: String; let label: String; let type: String; let sort: Double; let cfg: String }
        let adds: [PropAdd] = [
            .init(dbID: "books",    key: "description", label: "Description", type: "text",        sort: 9.5, cfg: "{}"),
            .init(dbID: "books",    key: "tags",        label: "Tags",        type: "multiSelect", sort: 9.6, cfg: "{}"),
            .init(dbID: "movies",   key: "tags",        label: "Tags",        type: "multiSelect", sort: 8.5, cfg: "{}"),
            .init(dbID: "tv_shows", key: "tags",        label: "Tags",        type: "multiSelect", sort: 9.5, cfg: "{}"),
        ]
        for p in adds {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO properties
                        (id, database_id, key, name, type, config_json, is_required, is_archived, created_at, updated_at, sort_index)
                    VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?)
                """,
                arguments: [
                    "\(p.dbID).\(p.key)", p.dbID,
                    p.key, p.label, p.type, p.cfg, now, now, p.sort
                ]
            )
        }
    }

    /// v48 — rename the restaurant `cuisine` property to "Tags" and
    /// promote it from `.select` (single value) to `.multiSelect`
    /// (chips). Existing single-string values transparently decode
    /// as 1-element tag lists, so no per-record data migration is
    /// needed — only the property's own row changes shape.
    ///
    /// The property's `key` stays `cuisine` to avoid touching
    /// `property_values.property_id` references (`vendors.cuisine` →
    /// would otherwise need a property-id rename + relink pass).
    /// Users see "Tags"; the on-disk identifier is unchanged.
    static func renameCuisineToTagsV48(_ db: Database) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())
        try db.execute(
            sql: """
                UPDATE properties
                SET name = 'Tags',
                    type = 'multiSelect',
                    updated_at = ?
                WHERE id = 'vendors.cuisine'
            """,
            arguments: [now]
        )
    }

    /// v47 — per-database hidden-columns preference. Backs the
    /// "Columns…" toolbar menu so a user can hide noisy columns from
    /// the table without losing the underlying property values. Stored
    /// as a JSON array of property keys in
    /// `database_view_prefs.hidden_columns_json`. Local-only, same
    /// rationale as the rest of the table — sync-aware preferences
    /// would let one device overwrite another's choices on every
    /// switch.
    static func addHiddenColumnsPrefV47(_ db: Database) throws {
        // `ADD COLUMN … DEFAULT '[]' NOT NULL` would be cleaner but
        // SQLite forbids non-constant defaults on ALTER; the plain
        // DEFAULT keeps existing rows valid, and the reader treats
        // NULL the same as `[]`.
        try db.execute(sql: """
            ALTER TABLE database_view_prefs
                ADD COLUMN hidden_columns_json TEXT NOT NULL DEFAULT '[]'
        """)
    }

    /// v46 — flip `vendors.place_id` to `hidden: true`. The property
    /// is a durable Apple Maps identifier the user never types in
    /// and never needs to see; previous schema versions surfaced it
    /// as a "Apple Place ID" text field at sort 7, which is just
    /// noise on the restaurant detail page.
    ///
    /// Idempotent: writes a fresh config_json with `hidden: true` +
    /// any existing keys preserved, and bumps `sort_index` to 100
    /// so anything that does fall through filters (e.g. CSV exports)
    /// renders it last instead of mid-row.
    static func hidePlaceIdV46(_ db: Database) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())
        let row = try Row.fetchOne(
            db,
            sql: "SELECT config_json FROM properties WHERE id = ?",
            arguments: ["vendors.place_id"]
        )
        let existing: String = row?["config_json"] ?? "{}"
        var obj: [String: Any] = (try? JSONSerialization.jsonObject(with: Data(existing.utf8))
                                  as? [String: Any]) ?? [:]
        obj["hidden"] = true
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let cfg = String(data: data, encoding: .utf8) else { return }
        try db.execute(
            sql: """
                UPDATE properties SET config_json = ?, sort_index = 100, updated_at = ?
                WHERE id = ?
            """,
            arguments: [cfg, now, "vendors.place_id"]
        )
    }

    /// v45 — restaurant website-scrape enrichment. Adds a `menu_url`
    /// property that the new `RestaurantWebsiteEnrichmentProvider` fills
    /// from schema.org JSON-LD (or a `/menu` probe), plus a
    /// `web_enriched_at` marker timestamp so the provider's pending
    /// query short-circuits records it has already processed. Both are
    /// scoped to restaurants via `applicable_kinds`.
    static func addRestaurantWebsiteEnrichmentV45(_ db: Database) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())
        struct PropAdd { let dbID: String; let key: String; let label: String; let type: String; let sort: Double; let cfg: String }
        let adds: [PropAdd] = [
            .init(
                dbID: "vendors", key: "menu_url", label: "Menu",
                type: "url", sort: 1.7,
                cfg: #"{"applicable_kinds":["restaurant"]}"#
            ),
            .init(
                dbID: "vendors", key: "web_enriched_at", label: "Web enriched",
                type: "date", sort: 100,
                cfg: #"{"applicable_kinds":["restaurant"],"hidden":true}"#
            ),
        ]
        for p in adds {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO properties
                        (id, database_id, key, name, type, config_json, is_required, is_archived, created_at, updated_at, sort_index)
                    VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?)
                """,
                arguments: [
                    "\(p.dbID).\(p.key)", p.dbID,
                    p.key, p.label, p.type, p.cfg, now, now, p.sort
                ]
            )
        }
    }

    /// v44 — reading progress on books (dual-mode: pages or percent)
    /// and watch-progress on TV (current season / episode). Movies stay
    /// binary — "watched" or not — because there's no meaningful
    /// in-progress state for a single feature.
    static func addCollectionsProgressV44(_ db: Database) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())
        struct PropAdd { let dbID: String; let key: String; let label: String; let type: String; let sort: Double; let cfg: String }
        let adds: [PropAdd] = [
            // books — dual-mode progress
            .init(dbID: "books", key: "readable_pages",   label: "Readable pages", type: "number", sort: 5.5, cfg: "{}"),
            .init(dbID: "books", key: "progress_mode",    label: "Progress mode",  type: "select", sort: 6.1, cfg: #"{"options":["pages","percent"]}"#),
            .init(dbID: "books", key: "current_page",     label: "Current page",   type: "number", sort: 6.2, cfg: "{}"),
            .init(dbID: "books", key: "progress_percent", label: "Progress %",     type: "number", sort: 6.3, cfg: "{}"),
            // tv_shows — current position
            .init(dbID: "tv_shows", key: "current_season",  label: "Current season",  type: "number", sort: 7.1, cfg: "{}"),
            .init(dbID: "tv_shows", key: "current_episode", label: "Current episode", type: "number", sort: 7.2, cfg: "{}"),
        ]
        for p in adds {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO properties
                        (id, database_id, key, name, type, config_json, is_required, is_archived, created_at, updated_at, sort_index)
                    VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?)
                """,
                arguments: [
                    "\(p.dbID).\(p.key)", p.dbID,
                    p.key, p.label, p.type, p.cfg, now, now, p.sort
                ]
            )
        }
    }
}
