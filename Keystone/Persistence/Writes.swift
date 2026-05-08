import Foundation
import GRDB
import os

enum DBWrites {
    static func createRecord(_ db: Database, databaseID: String, title: String) throws -> RecordRow {
        guard let dbRow = try DBReads.database(db, id: databaseID) else {
            throw NSError(domain: "Keystone", code: 1, userInfo: [NSLocalizedDescriptionKey: "Database not found: \(databaseID)"])
        }

        let id = UUID().uuidString
        let now = AppDatabase.isoFormatter.string(from: Date())
        let glyph = makeGlyph(from: title)
        let tone = dbRow.accent.rawValue
        let nextSort = (try Double.fetchOne(db, sql: "SELECT MAX(sort_index) FROM records WHERE database_id = ?", arguments: [databaseID]) ?? -1) + 1

        try db.execute(
            sql: """
                INSERT INTO records (id, database_id, title, glyph, tone, created_at, updated_at, sort_index)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [id, databaseID, title, glyph, tone, now, now, nextSort]
        )

        return RecordRow(
            id: id,
            databaseID: databaseID,
            title: title,
            glyph: glyph,
            tone: dbRow.accent,
            sortIndex: nextSort,
            values: [:]
        )
    }

    static func updateRecordTitle(_ db: Database, recordID: String, title: String) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())
        let glyph = makeGlyph(from: title)

        // Capture the old title (and database name) BEFORE the update
        // so we can rename the asset folder on disk to match the new
        // title. The folder layout is
        // `Assets/<Database>/<Title>-<shortID>/...`; if the sanitized
        // title changes, we move the folder and patch every asset's
        // `relative_path` to point at the new location.
        let priorRow = try Row.fetchOne(db, sql: """
            SELECT r.title AS title, d.name AS db_name
            FROM records r
            JOIN databases d ON d.id = r.database_id
            WHERE r.id = ?
        """, arguments: [recordID])

        try db.execute(
            sql: "UPDATE records SET title = ?, glyph = ?, updated_at = ? WHERE id = ?",
            arguments: [title, glyph, now, recordID]
        )

        guard let priorRow else { return }
        let oldTitle: String = priorRow["title"]
        let dbName: String = priorRow["db_name"]
        let dbDir = AssetPathing.sanitize(dbName)
        let oldRecDir = AssetPathing.recordFolderName(title: oldTitle, recordID: recordID)
        let newRecDir = AssetPathing.recordFolderName(title: title, recordID: recordID)
        guard oldRecDir != newRecDir else { return }

        let assetsRoot = AppDatabase.workspaceFolder
            .appendingPathComponent("Assets", isDirectory: true)
            .appendingPathComponent(dbDir, isDirectory: true)
        let oldFolder = assetsRoot.appendingPathComponent(oldRecDir, isDirectory: true)
        let newFolder = assetsRoot.appendingPathComponent(newRecDir, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: oldFolder.path) {
            try? fm.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
            do {
                try fm.moveItem(at: oldFolder, to: newFolder)
                try db.execute(
                    sql: """
                        UPDATE assets
                        SET relative_path = REPLACE(
                                relative_path,
                                ?,
                                ?
                            ),
                            updated_at = ?
                        WHERE record_id = ?
                          AND relative_path LIKE ?
                    """,
                    arguments: [
                        "Assets/\(dbDir)/\(oldRecDir)/",
                        "Assets/\(dbDir)/\(newRecDir)/",
                        now,
                        recordID,
                        "Assets/\(dbDir)/\(oldRecDir)/%"
                    ]
                )
            } catch {
                // Best-effort. If the move fails (locked file, iCloud
                // not-yet-uploaded, etc.) leave the old folder in place;
                // its assets still resolve via their stored
                // `relative_path` which we haven't touched.
            }
        }
    }

    static func updatePropertyValue(_ db: Database, recordID: String, propertyKey: String, value: String) throws {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT p.id AS prop_id, p.type AS prop_type, p.config_json AS prop_config, r.database_id AS db_id
            FROM records r
            JOIN properties p ON p.database_id = r.database_id AND p.key = ?
            WHERE r.id = ?
        """, arguments: [propertyKey, recordID]) else { return }

        let propID: String = row["prop_id"]
        let propType: String = row["prop_type"]
        let propConfig: String = row["prop_config"] ?? "{}"
        let now = AppDatabase.isoFormatter.string(from: Date())
        let pvID = "\(recordID).\(propertyKey)"

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        // Relation properties are stored as `relations` rows, not text in
        // `property_values`. Try to resolve the incoming string to a record
        // by title in the configured target database; if found, replace any
        // existing single-property relation. If not found, fall through to
        // text storage so a later backfill can promote it once the target
        // exists.
        if propType == "relation" {
            // Always clear prior link state for this (source, property)
            // first — both real relations and any text fallback. This keeps
            // the property single-valued from the user's perspective.
            try db.execute(
                sql: "DELETE FROM relations WHERE source_record_id = ? AND property_id = ?",
                arguments: [recordID, propID]
            )
            try db.execute(
                sql: "DELETE FROM property_values WHERE id = ?",
                arguments: [pvID]
            )

            if trimmed.isEmpty {
                try db.execute(
                    sql: "UPDATE records SET updated_at = ? WHERE id = ?",
                    arguments: [now, recordID]
                )
                return
            }

            // Pull targetDatabaseID out of the property's config JSON.
            let targetDB: String? = {
                guard let data = propConfig.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return obj["targetDatabaseID"] as? String
            }()

            if let targetDB {
                // Resolve the target by case-insensitive title; if it
                // doesn't exist, create a stub record in the target
                // database. This auto-creation is the right behavior
                // for structured ingestion (Inbox imports of Vehicle
                // Maintenance with `vehicle: Civic`, frontmatter from
                // bulk imports, CLI `set-property` calls). Interactive
                // editing in the UI uses `RecordPickerPopover` which
                // never hits this code path, so we don't risk creating
                // garbage records on every keystroke.
                let targetID: String
                if let existing = try String.fetchOne(
                    db,
                    sql: "SELECT id FROM records WHERE database_id = ? AND LOWER(title) = LOWER(?) LIMIT 1",
                    arguments: [targetDB, trimmed]
                ) {
                    targetID = existing
                } else if let stub = try createRelationTargetStub(
                    db, databaseID: targetDB, title: trimmed
                ) {
                    targetID = stub
                } else {
                    // Target database itself doesn't exist — fall through
                    // to text fallback so a future schema change might
                    // resolve it.
                    try storeAsRelationTextFallback(
                        db, pvID: pvID, recordID: recordID,
                        propID: propID, value: trimmed, now: now
                    )
                    return
                }

                let relID = UUID().uuidString
                try db.execute(
                    sql: """
                        INSERT INTO relations (id, source_record_id, target_record_id, relation_type, property_id, created_at, updated_at)
                        VALUES (?, ?, ?, 'linked', ?, ?, ?)
                    """,
                    arguments: [relID, recordID, targetID, propID, now, now]
                )
                try db.execute(
                    sql: "UPDATE records SET updated_at = ? WHERE id = ?",
                    arguments: [now, recordID]
                )
                return
            }

            // No target database configured — store as text so
            // backfillRelationsByTitle can promote it later if the
            // property's config gets fixed.
            try storeAsRelationTextFallback(
                db, pvID: pvID, recordID: recordID,
                propID: propID, value: trimmed, now: now
            )
            return
        }

        var textValue: String? = nil
        var numberValue: Double? = nil
        var dateValue: String? = nil
        var jsonValue: String? = nil

        switch propType {
        case "number":
            if let n = Double(trimmed) { numberValue = n }
            else if !trimmed.isEmpty { textValue = trimmed }
        case "date":
            dateValue = trimmed.isEmpty ? nil : trimmed
            textValue = dateValue
        case "json":
            // Round-trip valid JSON through json_value; on parse failure
            // keep the raw string in text_value so partially-typed input
            // isn't dropped (the editor can re-validate on next commit).
            if trimmed.isEmpty {
                jsonValue = nil
            } else if let data = trimmed.data(using: .utf8),
                      (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
                jsonValue = trimmed
            } else {
                textValue = trimmed
            }
        default:
            textValue = trimmed.isEmpty ? nil : trimmed
        }

        // The pvID is "<recordID>.<propertyKey>" — deterministic — so a
        // PK conflict is the same as a (record_id, property_id) conflict.
        try db.execute(
            sql: """
                INSERT INTO property_values (id, record_id, property_id, text_value, number_value, date_value, json_value, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    text_value = excluded.text_value,
                    number_value = excluded.number_value,
                    date_value = excluded.date_value,
                    json_value = excluded.json_value,
                    updated_at = excluded.updated_at
            """,
            arguments: [pvID, recordID, propID, textValue, numberValue, dateValue, jsonValue, now, now]
        )

        try db.execute(
            sql: "UPDATE records SET updated_at = ? WHERE id = ?",
            arguments: [now, recordID]
        )
    }

    /// Create a minimal stub record in `databaseID` titled `title`, used
    /// when `updatePropertyValue` resolves a relation field to a name
    /// that has no matching target yet (e.g. importing Vehicle Maintenance
    /// with `vehicle: Civic` before any Civic record exists). Returns the
    /// new record's ID, or `nil` if the target database itself doesn't
    /// exist (caller should fall back to text storage).
    ///
    /// The stub has no property values or blocks — just title + glyph +
    /// tone — so the user can flesh it out later. Sort index goes at the
    /// end of the target database.
    private static func createRelationTargetStub(
        _ db: Database,
        databaseID: String,
        title: String
    ) throws -> String? {
        // Pull the target database's accent so the new record's tone
        // matches the rest of the database visually.
        guard let accent = try String.fetchOne(
            db,
            sql: "SELECT accent FROM databases WHERE id = ?",
            arguments: [databaseID]
        ) else { return nil }

        let id = UUID().uuidString
        let now = AppDatabase.isoFormatter.string(from: Date())
        let glyph = makeGlyph(from: title)
        let nextSort = (try Double.fetchOne(
            db,
            sql: "SELECT MAX(sort_index) FROM records WHERE database_id = ?",
            arguments: [databaseID]
        ) ?? -1) + 1

        try db.execute(
            sql: """
                INSERT INTO records (id, database_id, title, glyph, tone, created_at, updated_at, sort_index)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [id, databaseID, title, glyph, accent, now, now, nextSort]
        )
        return id
    }

    /// Last-resort: store a relation-field value as plain text in
    /// `property_values` so a later `backfillRelationsByTitle` pass can
    /// promote it. Used when the relation property has no
    /// `targetDatabaseID` configured (recoverable schema misconfiguration).
    private static func storeAsRelationTextFallback(
        _ db: Database,
        pvID: String,
        recordID: String,
        propID: String,
        value: String,
        now: String
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO property_values (id, record_id, property_id, text_value, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [pvID, recordID, propID, value, now, now]
        )
        try db.execute(
            sql: "UPDATE records SET updated_at = ? WHERE id = ?",
            arguments: [now, recordID]
        )
    }

    /// Persist a column-alignment override on a property's `config_json`.
    /// Reads the existing config, mutates the alignment, writes back.
    /// Pass `alignment: nil` to clear the override and fall back to the
    /// type-aware default in `PropertyRow.resolvedAlignment`.
    static func setPropertyAlignment(
        _ db: Database,
        propertyID: String,
        alignment: PropertyAlignment?
    ) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())
        let existing = (try String.fetchOne(
            db,
            sql: "SELECT config_json FROM properties WHERE id = ?",
            arguments: [propertyID]
        )) ?? "{}"
        var config = PropertyConfig.parse(existing)
        config.alignment = alignment
        try db.execute(
            sql: "UPDATE properties SET config_json = ?, updated_at = ? WHERE id = ?",
            arguments: [config.encoded(), now, propertyID]
        )
    }

    static func deleteRecord(_ db: Database, recordID: String) throws {
        // Log every record deletion so the boot trace log can prove whether
        // record loss came from explicit user action vs. some other path
        // (sync, FK cascade, migration).
        let title = (try? String.fetchOne(db, sql: "SELECT title FROM records WHERE id = ?", arguments: [recordID])) ?? "?"
        let dbID = (try? String.fetchOne(db, sql: "SELECT database_id FROM records WHERE id = ?", arguments: [recordID])) ?? "?"
        os_log(.default, log: OSLog(subsystem: "Keystone", category: "Boot"), "deleteRecord %{public}@ (db=%{public}@ title=%{public}@)", recordID, dbID, title)
        try db.execute(sql: "DELETE FROM records WHERE id = ?", arguments: [recordID])
    }

    /// Sweep records that have a `.md` asset attached but no editor
    /// blocks, parse the asset's body, and populate the record's NOTES
    /// section with the resulting blocks. Idempotent — records that
    /// already have any block (deleted or not) are skipped, so this is
    /// safe to call on every boot. Returns the number of records that
    /// got blocks populated.
    @discardableResult
    static func backfillBlocksFromMarkdownAssets(_ db: Database) throws -> Int {
        // Records that have at least one .md asset and zero blocks.
        let rows = try Row.fetchAll(db, sql: """
            SELECT r.id AS record_id, a.relative_path AS md_path
            FROM records r
            JOIN assets a ON a.record_id = r.id AND LOWER(a.file_extension) = 'md'
            WHERE r.deleted_at IS NULL
              AND NOT EXISTS (SELECT 1 FROM blocks b WHERE b.record_id = r.id)
            ORDER BY r.id
        """)
        var done = 0
        for row in rows {
            let recordID: String = row["record_id"]
            let path: String = row["md_path"]
            let url = AppDatabase.absoluteURL(forRelativePath: path)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let (_, body) = FrontmatterParser.parse(source)
            let parsed = MarkdownBlockConverter.parse(body)
            var lastID: String? = nil
            for block in parsed {
                let inserted: BlockRow
                if block.kind == .table, let table = block.tableData {
                    inserted = try createTableBlock(
                        db,
                        recordID: recordID,
                        after: lastID,
                        table: table
                    )
                } else {
                    inserted = try createBlock(
                        db,
                        recordID: recordID,
                        after: lastID,
                        kind: block.kind,
                        text: block.text,
                        checked: block.checked
                    )
                }
                lastID = inserted.id
            }
            if !parsed.isEmpty { done += 1 }
        }
        return done
    }

    /// Sweep `property_values` rows for `relation` properties and promote
    /// each matching text value into a real `relations` row whenever the
    /// target record now exists (matched by title within the relation's
    /// configured `targetDatabaseID`). Idempotent — safe to call repeatedly.
    /// Returns the number of links created.
    @discardableResult
    static func backfillRelationsByTitle(_ db: Database) throws -> Int {
        let now = AppDatabase.isoFormatter.string(from: Date())
        let rows = try Row.fetchAll(db, sql: """
            SELECT pv.id AS pv_id, pv.record_id AS source_id, pv.property_id AS prop_id,
                   pv.text_value AS title_value, p.config_json AS config
            FROM property_values pv
            JOIN properties p ON p.id = pv.property_id
            WHERE p.type = 'relation' AND pv.text_value IS NOT NULL AND pv.text_value != ''
        """)

        var created = 0
        for row in rows {
            let pvID: String = row["pv_id"]
            let sourceID: String = row["source_id"]
            let propID: String = row["prop_id"]
            let title: String = row["title_value"]
            let configJSON: String = row["config"] ?? "{}"

            guard let data = configJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let targetDB = obj["targetDatabaseID"] as? String else { continue }

            guard let targetID = try String.fetchOne(
                db,
                sql: "SELECT id FROM records WHERE database_id = ? AND LOWER(title) = LOWER(?) LIMIT 1",
                arguments: [targetDB, title]
            ) else { continue }

            let relID = UUID().uuidString
            try db.execute(
                sql: """
                    INSERT INTO relations (id, source_record_id, target_record_id, relation_type, property_id, created_at, updated_at)
                    VALUES (?, ?, ?, 'linked', ?, ?, ?)
                """,
                arguments: [relID, sourceID, targetID, propID, now, now]
            )
            try db.execute(sql: "DELETE FROM property_values WHERE id = ?", arguments: [pvID])
            created += 1
        }
        return created
    }

    /// Like `backfillRelationsByTitle`, but auto-creates a stub target
    /// record when one doesn't exist yet. Use this to clean up a batch
    /// of imports that landed before the auto-create code in
    /// `updatePropertyValue` was in place — text-fallback values for
    /// relation properties get promoted, and any missing target records
    /// get created on the fly.
    ///
    /// Returns `(linksCreated, stubsCreated)`.
    @discardableResult
    static func backfillRelationsByTitleWithAutoCreate(_ db: Database) throws -> (Int, Int) {
        let now = AppDatabase.isoFormatter.string(from: Date())
        let rows = try Row.fetchAll(db, sql: """
            SELECT pv.id AS pv_id, pv.record_id AS source_id, pv.property_id AS prop_id,
                   pv.text_value AS title_value, p.config_json AS config
            FROM property_values pv
            JOIN properties p ON p.id = pv.property_id
            WHERE p.type = 'relation' AND pv.text_value IS NOT NULL AND pv.text_value != ''
        """)

        var linksCreated = 0
        var stubsCreated = 0
        for row in rows {
            let pvID: String = row["pv_id"]
            let sourceID: String = row["source_id"]
            let propID: String = row["prop_id"]
            let title: String = row["title_value"]
            let configJSON: String = row["config"] ?? "{}"

            guard let data = configJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let targetDB = obj["targetDatabaseID"] as? String else { continue }

            let targetID: String
            if let existing = try String.fetchOne(
                db,
                sql: "SELECT id FROM records WHERE database_id = ? AND LOWER(title) = LOWER(?) LIMIT 1",
                arguments: [targetDB, title]
            ) {
                targetID = existing
            } else if let stub = try createRelationTargetStub(
                db, databaseID: targetDB, title: title
            ) {
                targetID = stub
                stubsCreated += 1
            } else {
                // Target database itself doesn't exist; leave the text
                // fallback in place for some future caller to handle.
                continue
            }

            let relID = UUID().uuidString
            try db.execute(
                sql: """
                    INSERT INTO relations (id, source_record_id, target_record_id, relation_type, property_id, created_at, updated_at)
                    VALUES (?, ?, ?, 'linked', ?, ?, ?)
                """,
                arguments: [relID, sourceID, targetID, propID, now, now]
            )
            try db.execute(sql: "DELETE FROM property_values WHERE id = ?", arguments: [pvID])
            linksCreated += 1
        }
        return (linksCreated, stubsCreated)
    }

    /// Move a record from one database to another. Property values whose
    /// (key, type) pair exists in both schemas survive and have their
    /// `property_id` rewritten to the new database's matching property;
    /// all other values — and any relations bound to a property of the
    /// old database — are dropped. The `tone` is updated to the new
    /// database's accent so the glyph color tracks the type. Tags,
    /// blocks, assets, and the cover all carry over unchanged because
    /// they aren't database-scoped.
    static func changeRecordDatabase(_ db: Database, recordID: String, newDatabaseID: String) throws {
        guard let oldDatabaseID = try String.fetchOne(
            db,
            sql: "SELECT database_id FROM records WHERE id = ?",
            arguments: [recordID]
        ) else {
            throw NSError(domain: "Keystone", code: 1, userInfo: [NSLocalizedDescriptionKey: "Record not found: \(recordID)"])
        }
        if oldDatabaseID == newDatabaseID { return }

        guard let newDB = try DBReads.database(db, id: newDatabaseID) else {
            throw NSError(domain: "Keystone", code: 1, userInfo: [NSLocalizedDescriptionKey: "Database not found: \(newDatabaseID)"])
        }

        // Drop property values that don't have a same-(key,type) match in
        // the new schema. The LEFT JOIN finds rows whose new-schema match
        // is missing.
        try db.execute(
            sql: """
                DELETE FROM property_values
                WHERE id IN (
                    SELECT pv.id FROM property_values pv
                    JOIN properties op ON op.id = pv.property_id
                    LEFT JOIN properties np
                      ON np.database_id = ? AND np.key = op.key AND np.type = op.type
                    WHERE pv.record_id = ? AND np.id IS NULL
                )
            """,
            arguments: [newDatabaseID, recordID]
        )

        // Rewrite the surviving values' property_id to the new database's
        // matching property. The pvID (`<recordID>.<key>`) doesn't change.
        try db.execute(
            sql: """
                UPDATE property_values
                SET property_id = (
                    SELECT np.id FROM properties np
                    JOIN properties op ON op.id = property_values.property_id
                    WHERE np.database_id = ?
                      AND np.key = op.key
                      AND np.type = op.type
                    LIMIT 1
                ),
                updated_at = ?
                WHERE record_id = ?
            """,
            arguments: [newDatabaseID, AppDatabase.isoFormatter.string(from: Date()), recordID]
        )

        // Relations bound to a property of the old database don't make
        // sense after the move; drop them. Property-less relations are
        // free-form and stay.
        try db.execute(
            sql: """
                DELETE FROM relations
                WHERE (source_record_id = ? OR target_record_id = ?)
                  AND property_id IN (SELECT id FROM properties WHERE database_id = ?)
            """,
            arguments: [recordID, recordID, oldDatabaseID]
        )

        let now = AppDatabase.isoFormatter.string(from: Date())
        let nextSort = (try Double.fetchOne(
            db,
            sql: "SELECT MAX(sort_index) FROM records WHERE database_id = ?",
            arguments: [newDatabaseID]
        ) ?? -1) + 1

        try db.execute(
            sql: """
                UPDATE records
                SET database_id = ?, tone = ?, sort_index = ?, updated_at = ?
                WHERE id = ?
            """,
            arguments: [newDatabaseID, newDB.accent.rawValue, nextSort, now, recordID]
        )
    }

    /// Sets (or clears) the cover asset for a record. Passing nil clears it.
    /// The asset itself isn't deleted from the assets table — a record can keep
    /// the file as a regular attachment after losing its cover designation.
    static func setRecordCover(_ db: Database, recordID: String, assetID: String?) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())
        try db.execute(
            sql: "UPDATE records SET cover_asset_id = ?, updated_at = ? WHERE id = ?",
            arguments: [assetID, now, recordID]
        )
    }

    /// Imports an image file as the record's cover. Reuses the asset importer
    /// so the file is content-hashed and copied into Assets/, then promotes
    /// the new asset to cover. Returns the resulting asset record.
    static func importCoverImage(_ db: Database, fileURL: URL, recordID: String, workspaceID: String) throws -> AssetRecord {
        let asset = try AssetImporter.importFile(db, fileURL: fileURL, recordID: recordID, workspaceID: workspaceID)
        try setRecordCover(db, recordID: recordID, assetID: asset.id)
        return asset
    }

    /// Create a `.table` block carrying tabular data. Tables don't have
    /// editable text — `text` is empty and the payload lives in
    /// `tableData`. Returns the inserted row.
    @discardableResult
    static func createTableBlock(
        _ db: Database,
        recordID: String,
        after anchorID: String?,
        table: BlockTableData
    ) throws -> BlockRow {
        let id = UUID().uuidString
        let now = AppDatabase.isoFormatter.string(from: Date())
        let sortIndex = try nextBlockSortIndex(db, recordID: recordID, after: anchorID)
        let json = BlockContentCodec.encodeTable(table)
        try db.execute(
            sql: """
                INSERT INTO blocks (id, record_id, type, content_json, sort_index, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [id, recordID, BlockKind.table.rawValue, json, sortIndex, now, now]
        )
        return BlockRow(
            id: id,
            recordID: recordID,
            kind: .table,
            text: AttributedString(),
            checked: nil,
            tableData: table,
            sortIndex: sortIndex
        )
    }

    /// Compute the next `sort_index` for an inserted block — duplicated
    /// from the inline closure inside `createBlock` so `createTableBlock`
    /// can reuse the same fractional-key insertion logic without
    /// duplicating the SQL.
    private static func nextBlockSortIndex(_ db: Database, recordID: String, after anchorID: String?) throws -> Double {
        if let anchor = anchorID {
            let anchorSort = try Double.fetchOne(db, sql: "SELECT sort_index FROM blocks WHERE id = ?", arguments: [anchor]) ?? 0
            let nextSort = try Double.fetchOne(db, sql: """
                SELECT MIN(sort_index) FROM blocks
                WHERE record_id = ? AND deleted_at IS NULL AND sort_index > ?
            """, arguments: [recordID, anchorSort])
            if let nextSort, nextSort.isFinite {
                return (anchorSort + nextSort) / 2
            }
            return anchorSort + 1
        } else {
            let max = try Double.fetchOne(db, sql: """
                SELECT MAX(sort_index) FROM blocks WHERE record_id = ? AND deleted_at IS NULL
            """, arguments: [recordID]) ?? -1
            return max + 1
        }
    }

    static func createBlock(_ db: Database, recordID: String, after anchorID: String?, kind: BlockKind, text: AttributedString, checked: Bool? = nil) throws -> BlockRow {
        let id = UUID().uuidString
        let now = AppDatabase.isoFormatter.string(from: Date())

        let sortIndex: Double = try {
            if let anchor = anchorID {
                let anchorSort = try Double.fetchOne(db, sql: "SELECT sort_index FROM blocks WHERE id = ?", arguments: [anchor]) ?? 0
                let nextSort = try Double.fetchOne(db, sql: """
                    SELECT MIN(sort_index) FROM blocks
                    WHERE record_id = ? AND deleted_at IS NULL AND sort_index > ?
                """, arguments: [recordID, anchorSort])
                if let nextSort, nextSort.isFinite {
                    return (anchorSort + nextSort) / 2
                }
                return anchorSort + 1
            } else {
                let max = try Double.fetchOne(db, sql: """
                    SELECT MAX(sort_index) FROM blocks WHERE record_id = ? AND deleted_at IS NULL
                """, arguments: [recordID]) ?? -1
                return max + 1
            }
        }()

        let json = BlockContentCodec.encode(text: text, checked: checked)
        try db.execute(
            sql: """
                INSERT INTO blocks (id, record_id, type, content_json, sort_index, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [id, recordID, kind.rawValue, json, sortIndex, now, now]
        )

        return BlockRow(id: id, recordID: recordID, kind: kind, text: text, checked: checked, sortIndex: sortIndex)
    }

    static func updateBlockText(_ db: Database, blockID: String, text: AttributedString) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())
        // Preserve checked
        let existing: String = try String.fetchOne(db, sql: "SELECT content_json FROM blocks WHERE id = ?", arguments: [blockID]) ?? "{}"
        let (_, checked) = BlockContentCodec.decode(existing)
        let json = BlockContentCodec.encode(text: text, checked: checked)
        try db.execute(
            sql: "UPDATE blocks SET content_json = ?, updated_at = ? WHERE id = ?",
            arguments: [json, now, blockID]
        )
    }

    static func updateBlockKind(_ db: Database, blockID: String, kind: BlockKind, text: AttributedString? = nil) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())
        if let text {
            let existing: String = try String.fetchOne(db, sql: "SELECT content_json FROM blocks WHERE id = ?", arguments: [blockID]) ?? "{}"
            let (_, checked) = BlockContentCodec.decode(existing)
            let resolvedChecked = kind == .checklist ? (checked ?? false) : nil
            let json = BlockContentCodec.encode(text: text, checked: resolvedChecked)
            try db.execute(
                sql: "UPDATE blocks SET type = ?, content_json = ?, updated_at = ? WHERE id = ?",
                arguments: [kind.rawValue, json, now, blockID]
            )
        } else {
            try db.execute(
                sql: "UPDATE blocks SET type = ?, updated_at = ? WHERE id = ?",
                arguments: [kind.rawValue, now, blockID]
            )
        }
    }

    /// Replace a `.table` block's tabular payload. The block's `text`
    /// and `checked` fields aren't used by tables, so we don't bother
    /// preserving them — `encodeTable` always writes a fresh content
    /// blob with only `tableData`.
    static func updateBlockTable(_ db: Database, blockID: String, table: BlockTableData) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())
        let json = BlockContentCodec.encodeTable(table)
        try db.execute(
            sql: "UPDATE blocks SET content_json = ?, updated_at = ? WHERE id = ?",
            arguments: [json, now, blockID]
        )
    }

    static func updateBlockChecked(_ db: Database, blockID: String, checked: Bool) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())
        let existing: String = try String.fetchOne(db, sql: "SELECT content_json FROM blocks WHERE id = ?", arguments: [blockID]) ?? "{}"
        let (text, _) = BlockContentCodec.decode(existing)
        let json = BlockContentCodec.encode(text: text, checked: checked)
        try db.execute(
            sql: "UPDATE blocks SET content_json = ?, updated_at = ? WHERE id = ?",
            arguments: [json, now, blockID]
        )
    }

    static func deleteBlock(_ db: Database, blockID: String) throws {
        try db.execute(sql: "DELETE FROM blocks WHERE id = ?", arguments: [blockID])
    }

    // MARK: - Tags

    static func createTag(_ db: Database, workspaceID: String, name: String, scope: TagScope, scopeID: String?, color: AccentTone) throws -> TagModel {
        let id = UUID().uuidString
        let now = AppDatabase.isoFormatter.string(from: Date())
        try db.execute(
            sql: """
                INSERT INTO tags (id, workspace_id, name, scope_type, scope_id, color, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [id, workspaceID, name, scope.rawValue, scopeID, color.rawValue, now, now]
        )
        return TagModel(id: id, name: name, scopeType: scope, scopeID: scopeID, color: color, recordCount: 0)
    }

    static func updateTag(_ db: Database, tagID: String, name: String?, color: AccentTone?) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())
        if let name {
            try db.execute(sql: "UPDATE tags SET name = ?, updated_at = ? WHERE id = ?", arguments: [name, now, tagID])
        }
        if let color {
            try db.execute(sql: "UPDATE tags SET color = ?, updated_at = ? WHERE id = ?", arguments: [color.rawValue, now, tagID])
        }
    }

    static func deleteTag(_ db: Database, tagID: String) throws {
        try db.execute(sql: "DELETE FROM tags WHERE id = ?", arguments: [tagID])
    }

    static func attachTag(_ db: Database, recordID: String, tagID: String) throws {
        // App-level uniqueness check, since the schema no longer carries a
        // UNIQUE(record_id, tag_id) constraint (SyncEngine rejects those).
        let exists = (try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM record_tags WHERE record_id = ? AND tag_id = ?",
            arguments: [recordID, tagID]
        ) ?? 0) > 0
        guard !exists else { return }

        let id = UUID().uuidString
        let now = AppDatabase.isoFormatter.string(from: Date())
        try db.execute(
            sql: """
                INSERT INTO record_tags (id, record_id, tag_id, created_at)
                VALUES (?, ?, ?, ?)
            """,
            arguments: [id, recordID, tagID, now]
        )
    }

    static func detachTag(_ db: Database, recordID: String, tagID: String) throws {
        try db.execute(
            sql: "DELETE FROM record_tags WHERE record_id = ? AND tag_id = ?",
            arguments: [recordID, tagID]
        )
    }

    // MARK: - Relations

    static func setRelationTargetDB(_ db: Database, propertyID: String, targetDatabaseID: String) throws {
        let now = AppDatabase.isoFormatter.string(from: Date())
        let json = #"{"targetDatabaseID":"\#(targetDatabaseID)"}"#
        try db.execute(
            sql: "UPDATE properties SET config_json = ?, updated_at = ? WHERE id = ?",
            arguments: [json, now, propertyID]
        )
    }

    static func addRelation(_ db: Database, sourceRecordID: String, targetRecordID: String, propertyID: String?) throws -> RelationLink? {
        let id = UUID().uuidString
        let now = AppDatabase.isoFormatter.string(from: Date())
        try db.execute(
            sql: """
                INSERT INTO relations (id, source_record_id, target_record_id, relation_type, property_id, created_at, updated_at)
                VALUES (?, ?, ?, 'linked', ?, ?, ?)
            """,
            arguments: [id, sourceRecordID, targetRecordID, propertyID, now, now]
        )
        return try RelationReads.link(db, relationID: id)
    }

    static func removeRelation(_ db: Database, relationID: String) throws {
        try db.execute(sql: "DELETE FROM relations WHERE id = ?", arguments: [relationID])
    }

    static func removeRelationByEndpoints(_ db: Database, sourceRecordID: String, targetRecordID: String, propertyID: String?) throws {
        if let propertyID {
            try db.execute(
                sql: "DELETE FROM relations WHERE source_record_id = ? AND target_record_id = ? AND property_id = ?",
                arguments: [sourceRecordID, targetRecordID, propertyID]
            )
        } else {
            try db.execute(
                sql: "DELETE FROM relations WHERE source_record_id = ? AND target_record_id = ?",
                arguments: [sourceRecordID, targetRecordID]
            )
        }
    }

    // MARK: - Assets

    static func deleteAsset(_ db: Database, assetID: String) throws {
        // Look up the relative path so we can also delete the file on disk.
        if let path = try String.fetchOne(db, sql: "SELECT relative_path FROM assets WHERE id = ?", arguments: [assetID]) {
            let fileURL = AppDatabase.absoluteURL(forRelativePath: path)
            try? FileManager.default.removeItem(at: fileURL)
            // Prune the now-possibly-empty record folder (and database
            // folder if it too became empty) so deleting the last asset
            // for a record doesn't leave an empty `<Title>-<id>/` husk
            // in the user's `Assets/` tree.
            AssetPathing.pruneEmptyAncestors(
                fileURL.deletingLastPathComponent(),
                stopAt: AppDatabase.workspaceFolder.appendingPathComponent("Assets", isDirectory: true)
            )
        }
        try db.execute(sql: "DELETE FROM assets WHERE id = ?", arguments: [assetID])
    }

    private static func makeGlyph(from title: String) -> String {
        let words = title.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .prefix(2)
        let chars = words.compactMap { $0.first.map(String.init) }.joined().uppercased()
        if chars.isEmpty {
            return String(title.prefix(2)).uppercased()
        }
        return String(chars.prefix(2))
    }
}
