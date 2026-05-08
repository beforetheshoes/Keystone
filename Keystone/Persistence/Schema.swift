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
}
