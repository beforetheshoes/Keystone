import Foundation
import GRDB

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
