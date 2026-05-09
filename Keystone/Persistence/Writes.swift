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

        // For sidecar-backed databases, mint a workspace-relative path
        // at creation time so the record participates in bidirectional
        // sync from the moment it exists. The folder is named after
        // the recordID (path-safe, stable across rename) and lives
        // under `Cars/Unknown/` until/unless the user assigns a
        // vehicle relation. Folder migration on vehicle assignment is
        // a separate concern and not handled here.
        let sidecarPath: String? = (databaseID == "vehicle_maintenance")
            ? "Cars/Unknown/\(id)/\(id).pdf-processed-markdown.md"
            : nil

        try db.execute(
            sql: """
                INSERT INTO records (id, database_id, title, glyph, tone, created_at, updated_at, sort_index, sidecar_path)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [id, databaseID, title, glyph, tone, now, now, nextSort, sidecarPath]
        )

        // Materialize the sidecar file immediately so the user sees
        // it in Finder right after create. Errors inside SidecarWriter
        // are logged but never thrown — disk failure can't block a
        // DB write.
        if sidecarPath != nil {
            SidecarWriter.writeIfNeeded(db, recordID: id)
        }

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

    /// Trigger a sidecar regenerate-and-write for the record affected
    /// by a block-level mutation. No-op if the block doesn't exist
    /// or its parent record has no sidecar_path. Errors are logged
    /// inside `SidecarWriter` and never propagate — DB writes must
    /// not depend on disk I/O succeeding.
    private static func sidecarWritebackForBlock(_ db: Database, blockID: String) {
        guard let recordID = try? String.fetchOne(
            db, sql: "SELECT record_id FROM blocks WHERE id = ?", arguments: [blockID]
        ) else { return }
        SidecarWriter.writeIfNeeded(db, recordID: recordID)
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

        SidecarWriter.writeIfNeeded(db, recordID: recordID)
    }

    static func updatePropertyValue(_ db: Database, recordID: String, propertyKey: String, value: String) throws {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT p.id AS prop_id, p.type AS prop_type, p.config_json AS prop_config, r.database_id AS db_id
            FROM records r
            JOIN properties p ON p.database_id = r.database_id AND p.key = ?
            WHERE r.id = ?
        """, arguments: [propertyKey, recordID]) else { return }
        // Sidecar regenerate runs on every successful return path,
        // including the relation early-returns deeper in this function.
        // Captured here so the defer fires after all branches finish.
        defer { SidecarWriter.writeIfNeeded(db, recordID: recordID) }

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
            // first — both real relations and any text fallback. The
            // call sets the *complete* set of links for this property,
            // single or multi, so we replace rather than merge.
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

            // Parse config — `targetDatabaseID` and the optional
            // `multi: true` flag.
            let configObj: [String: Any]? = {
                guard let data = propConfig.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return obj
            }()
            let targetDB: String? = configObj?["targetDatabaseID"] as? String
            let isMulti = (configObj?["multi"] as? Bool) ?? false

            // Determine the candidate list. For a multi-relation
            // property whose value is a YAML flow list (`[a, b, c]`),
            // split into individual items; otherwise treat the whole
            // value as a single candidate.
            let candidates: [String] = {
                if isMulti, trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                    let inner = String(trimmed.dropFirst().dropLast())
                    return parseRelationFlowList(inner)
                } else {
                    return [trimmed]
                }
            }()

            if let targetDB {
                var anyLinked = false
                for raw in candidates {
                    let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !candidate.isEmpty else { continue }

                    // Resolve target: try exact ID match first
                    // (stable seeded IDs like "svc-honda-engine-oil-
                    // normal" land here), then case-insensitive title,
                    // then auto-create a stub.
                    let targetID: String
                    if let byID = try String.fetchOne(
                        db,
                        sql: "SELECT id FROM records WHERE database_id = ? AND id = ? LIMIT 1",
                        arguments: [targetDB, candidate]
                    ) {
                        targetID = byID
                    } else if let byTitle = try String.fetchOne(
                        db,
                        sql: "SELECT id FROM records WHERE database_id = ? AND LOWER(title) = LOWER(?) LIMIT 1",
                        arguments: [targetDB, candidate]
                    ) {
                        targetID = byTitle
                    } else if let stub = try createRelationTargetStub(
                        db, databaseID: targetDB, title: candidate
                    ) {
                        targetID = stub
                    } else {
                        continue
                    }

                    try db.execute(
                        sql: """
                            INSERT INTO relations (id, source_record_id, target_record_id, relation_type, property_id, created_at, updated_at)
                            VALUES (?, ?, ?, 'linked', ?, ?, ?)
                        """,
                        arguments: [UUID().uuidString, recordID, targetID, propID, now, now]
                    )
                    anyLinked = true
                }

                if anyLinked {
                    try db.execute(
                        sql: "UPDATE records SET updated_at = ? WHERE id = ?",
                        arguments: [now, recordID]
                    )
                    return
                }

                // Fall through to text fallback only for single-
                // relation values — for multi-relation imports, an
                // empty resolution set is just a no-op (nothing to
                // promote later).
                if !isMulti {
                    try storeAsRelationTextFallback(
                        db, pvID: pvID, recordID: recordID,
                        propID: propID, value: trimmed, now: now
                    )
                }
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
        case "date_tz":
            if let split = DateValueCodec.parseTZRaw(trimmed) {
                textValue = split.tz
                dateValue = split.dateString
            } else if !trimmed.isEmpty {
                // Legacy / partial fallback: stash the raw input in
                // text_value so a later edit can recover it.
                textValue = trimmed
            }
        case "address":
            // Two storage modes:
            //   • Structured (autocomplete pick) → JSON in `value` parses
            //     via AddressValueCodec; we store the one-line display
            //     in text_value AND the JSON in json_value.
            //   • Free-form text → keep just the one-line in text_value.
            // Reads.swift always emits text_value into the values map,
            // so cell renderers see the same one-line in either mode.
            if let parsed = AddressValueCodec.parse(trimmed) {
                textValue = parsed.display.isEmpty ? trimmed : parsed.display
                jsonValue = trimmed
            } else if !trimmed.isEmpty {
                textValue = trimmed
            }
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

    /// Split a YAML flow-list body (the part *between* the brackets)
    /// into its individual items, preserving quotes and respecting
    /// commas inside them. Returns trimmed, unquoted strings —
    /// suitable for use as either record IDs or titles.
    private static func parseRelationFlowList(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        for ch in s {
            switch ch {
            case "'" where !inDouble: inSingle.toggle()
            case "\"" where !inSingle: inDouble.toggle()
            case "," where !inSingle && !inDouble:
                out.append(current); current = ""
            default:
                current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(current)
        }
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
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
        // Capture the sidecar_path BEFORE the row is gone so we can
        // remove the corresponding `.md` from disk. Without this, the
        // file watcher would re-import the orphan file on its next
        // scan and resurrect the record we just deleted.
        let sidecarPath = (try? String.fetchOne(
            db, sql: "SELECT sidecar_path FROM records WHERE id = ?", arguments: [recordID]
        )) ?? nil
        os_log(.default, log: OSLog(subsystem: "Keystone", category: "Boot"), "deleteRecord %{public}@ (db=%{public}@ title=%{public}@)", recordID, dbID, title)
        try db.execute(sql: "DELETE FROM records WHERE id = ?", arguments: [recordID])

        if let sidecarPath, !sidecarPath.isEmpty {
            let absolute = AppDatabase.workspaceFolder.appendingPathComponent(sidecarPath)
            // Forget the hash first so a stray FSEvent on the deletion
            // can't be misinterpreted as "external edit, hash mismatch
            // → re-import."
            SidecarHashCache.shared.forget(absolutePath: absolute.path)
            try? FileManager.default.removeItem(at: absolute)
            // Best-effort: prune the empty event folder so the
            // user's Cars/ tree doesn't accumulate empty husks. The
            // PDF asset companion was already removed by deleteAsset
            // upstream of this in the wipe path.
            let parent = absolute.deletingLastPathComponent()
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: parent.path),
               entries.allSatisfy({ $0 == ".DS_Store" }) {
                try? FileManager.default.removeItem(at: parent)
            }
        }
    }

    /// Hard-delete every record in `databaseID` along with its
    /// associated asset files on disk. For `vehicle_maintenance`,
    /// also clears each vehicle's `current_mileage` /
    /// `current_mileage_as_of` snapshot since those are derived from
    /// the now-deleted events. Returns counts the caller can surface
    /// in confirmation UI.
    ///
    /// Two-pass disk cleanup: first per-asset (gets the
    /// AssetPathing-tracked files), then nuke the whole
    /// `Assets/<sanitized-db-name>/` directory (catches orphans whose
    /// asset rows drifted from the on-disk path or were never tracked
    /// via the assets table at all). The whole-folder pass is safe
    /// because every record in this database is gone — anything left
    /// under that asset folder is by definition orphaned.
    @discardableResult
    static func deleteAllRecordsInDatabase(_ db: Database, databaseID: String) throws -> (deletedRecords: Int, deletedAssets: Int) {
        // Capture the database NAME before any rows go away — the
        // sanitized form is the on-disk folder name we'll need to
        // remove. Looked up once and held over the deletion span.
        let dbName = try String.fetchOne(
            db,
            sql: "SELECT name FROM databases WHERE id = ?",
            arguments: [databaseID]
        )

        let assetIDs = try String.fetchAll(
            db,
            sql: """
                SELECT a.id FROM assets a
                JOIN records r ON r.id = a.record_id
                WHERE r.database_id = ?
            """,
            arguments: [databaseID]
        )
        for assetID in assetIDs {
            try deleteAsset(db, assetID: assetID)
        }

        let recordIDs = try String.fetchAll(
            db,
            sql: "SELECT id FROM records WHERE database_id = ?",
            arguments: [databaseID]
        )
        for recordID in recordIDs {
            try deleteRecord(db, recordID: recordID)
        }

        // Catch any orphan files left under this database's asset
        // folder. After deleting every record, that folder *should*
        // be empty (or gone) — anything still there is leftover from
        // an asset row whose path drifted, an aborted import, or a
        // file dropped in by hand. Best-effort: failures (iCloud
        // upload-in-progress, permissions) don't block the rest of
        // the deletion.
        if let dbName, !dbName.isEmpty {
            let dbDir = AssetPathing.sanitize(dbName)
            let folder = AppDatabase.workspaceFolder
                .appendingPathComponent("Assets", isDirectory: true)
                .appendingPathComponent(dbDir, isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path) {
                try? FileManager.default.removeItem(at: folder)
            }
        }

        if databaseID == "vehicle_maintenance" {
            try db.execute(sql: """
                DELETE FROM property_values
                WHERE property_id IN (
                    'vehicles.current_mileage',
                    'vehicles.current_mileage_as_of'
                )
            """)
        }

        return (recordIDs.count, assetIDs.count)
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
        SidecarWriter.writeIfNeeded(db, recordID: recordID)
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
        SidecarWriter.writeIfNeeded(db, recordID: recordID)
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
        sidecarWritebackForBlock(db, blockID: blockID)
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
        sidecarWritebackForBlock(db, blockID: blockID)
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
        sidecarWritebackForBlock(db, blockID: blockID)
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
        sidecarWritebackForBlock(db, blockID: blockID)
    }

    static func deleteBlock(_ db: Database, blockID: String) throws {
        // Capture the parent record_id BEFORE the delete so we can
        // still find it for the sidecar regenerate.
        let recordID = try String.fetchOne(
            db, sql: "SELECT record_id FROM blocks WHERE id = ?", arguments: [blockID]
        )
        try db.execute(sql: "DELETE FROM blocks WHERE id = ?", arguments: [blockID])
        if let recordID { SidecarWriter.writeIfNeeded(db, recordID: recordID) }
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
        defer { SidecarWriter.writeIfNeeded(db, recordID: sourceRecordID) }
        // Find-or-insert: the relations table now carries partial
        // unique indexes (v27) on (source, target, property) and
        // (source, target) for the unbound case. Surface that as a
        // first-class behavior here — return the existing link rather
        // than letting INSERT fail with a constraint violation. This
        // also makes the code path idempotent for sync replays.
        let existingID: String?
        if let propertyID {
            existingID = try String.fetchOne(
                db,
                sql: """
                    SELECT id FROM relations
                    WHERE source_record_id = ? AND target_record_id = ? AND property_id = ?
                    LIMIT 1
                """,
                arguments: [sourceRecordID, targetRecordID, propertyID]
            )
        } else {
            existingID = try String.fetchOne(
                db,
                sql: """
                    SELECT id FROM relations
                    WHERE source_record_id = ? AND target_record_id = ? AND property_id IS NULL
                    LIMIT 1
                """,
                arguments: [sourceRecordID, targetRecordID]
            )
        }
        if let existingID {
            return try RelationReads.link(db, relationID: existingID)
        }

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
        let sourceID = try String.fetchOne(
            db,
            sql: "SELECT source_record_id FROM relations WHERE id = ?",
            arguments: [relationID]
        )
        try db.execute(sql: "DELETE FROM relations WHERE id = ?", arguments: [relationID])
        if let sourceID { SidecarWriter.writeIfNeeded(db, recordID: sourceID) }
    }

    /// Collapse duplicate `relations` rows. Two flavors of dup:
    ///   1. Property-bound: same (source, target, property) triple.
    ///   2. Property-unbound: same (source, target) pair with NULL
    ///      property (free-form "Related" links from the detail view).
    /// Keeps the row with the smallest rowid (oldest insert) in each
    /// duplicate group. Returns the number of rows deleted.
    ///
    /// We can't enforce uniqueness with a SQLite index because
    /// SQLiteData's `SyncEngine` refuses to initialize against
    /// synchronized tables that carry uniqueness constraints. Instead,
    /// `addRelation` does a find-or-insert on every call and the boot
    /// path runs this dedupe to clean up anything CloudKit replicated
    /// in from another device.
    @discardableResult
    static func dedupeRelations(_ db: Database) throws -> Int {
        let beforeCount = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM relations") ?? 0)
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
        let afterCount = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM relations") ?? 0)
        return beforeCount - afterCount
    }

    static func removeRelationByEndpoints(_ db: Database, sourceRecordID: String, targetRecordID: String, propertyID: String?) throws {
        defer { SidecarWriter.writeIfNeeded(db, recordID: sourceRecordID) }
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
