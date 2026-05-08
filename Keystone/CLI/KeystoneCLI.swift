import Foundation
import GRDB
import Dependencies
@preconcurrency import SQLiteData

/// Command-line interface for Keystone, invoked as
/// `/Applications/Keystone.app/Contents/MacOS/Keystone --cli <command> [args]`.
///
/// The CLI shares the same entitlements (iCloud Drive ubiquity container,
/// CloudKit) and code paths (`WorkspaceLocationManager`, `AppDatabase`,
/// `DBReads`, `DBWrites`) as the GUI app, so it sees the same data the
/// app sees regardless of whether the app is running.
///
/// Output convention:
/// - Success: JSON to stdout, exit 0.
/// - Error: human-readable message to stderr, exit non-zero.
enum KeystoneCLI {
    /// Dispatch entry. Called from `KeystoneApp.main()` *before* SwiftUI
    /// takes over. Returns normally; caller is responsible for `exit()`.
    static func run(arguments: [String]) {
        // CloudKit sync is intentionally skipped in CLI mode. SyncEngine
        // attaches temporary triggers on the writer connection that
        // create per-row metadata for sync. In a short-lived CLI process
        // we don't need that machinery — and skipping it avoids racing
        // an already-running app over CloudKit pushes. The app's
        // `seedSyncMetadataForExistingRows` boot pass picks up any rows
        // we wrote when the app launches next.
        do {
            try prepareDependencies {
                try $0.bootstrapKeystoneDatabaseForCLI()
            }
        } catch {
            stderr("bootstrap failed: \(error.localizedDescription)")
            exit(1)
        }

        guard let command = arguments.first else {
            printUsage()
            exit(1)
        }

        let rest = Array(arguments.dropFirst())

        do {
            switch command {
            case "list-databases":      try listDatabases()
            case "list-records":        try listRecords(args: rest)
            case "get-record":          try getRecord(args: rest)
            case "list-blocks":         try listBlocks(args: rest)
            case "set-property":        try setProperty(args: rest)
            case "update-record-title": try updateRecordTitle(args: rest)
            case "update-block":        try updateBlock(args: rest)
            case "create-block":        try createBlock(args: rest)
            case "delete-block":        try deleteBlock(args: rest)
            case "sql":                 try runSQL(args: rest)
            case "enrich-vendor":       try enrichVendor(args: rest)
            case "enrich-all-vendors":  try enrichAllVendors(args: rest)
            case "promote-relations":   try promoteRelations()
            case "help", "-h", "--help":
                printUsage()
            default:
                stderr("Unknown command: \(command)")
                printUsage()
                exit(1)
            }
        } catch {
            stderr("error: \(error.localizedDescription)")
            exit(1)
        }
    }

    // MARK: - Read commands

    private static func listDatabases() throws {
        @Dependency(\.defaultDatabase) var database
        let rows: [[String: Any]] = try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT d.id, d.name, d.plural_name, d.area_id, d.icon, d.accent, d.sort_index,
                       (SELECT COUNT(*) FROM records r WHERE r.database_id = d.id AND r.deleted_at IS NULL) AS record_count
                FROM databases d
                ORDER BY d.sort_index
            """).map { r in
                [
                    "id": r["id"] as String,
                    "name": r["name"] as String,
                    "plural_name": (r["plural_name"] as String?) as Any,
                    "area_id": (r["area_id"] as String?) as Any,
                    "icon": (r["icon"] as String?) as Any,
                    "accent": r["accent"] as String,
                    "sort_index": r["sort_index"] as Double,
                    "record_count": r["record_count"] as Int,
                ]
            }
        }
        emit(rows)
    }

    private static func listRecords(args: [String]) throws {
        let databaseID = flag("--database", in: args)
        @Dependency(\.defaultDatabase) var database
        let rows: [[String: Any]] = try database.read { db in
            let sql: String
            let arguments: StatementArguments
            if let databaseID {
                sql = """
                    SELECT id, database_id, title, glyph, tone, sort_index, created_at, updated_at
                    FROM records
                    WHERE database_id = ? AND deleted_at IS NULL
                    ORDER BY sort_index
                """
                arguments = [databaseID]
            } else {
                sql = """
                    SELECT id, database_id, title, glyph, tone, sort_index, created_at, updated_at
                    FROM records
                    WHERE deleted_at IS NULL
                    ORDER BY database_id, sort_index
                """
                arguments = []
            }
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map { r in
                [
                    "id": r["id"] as String,
                    "database_id": r["database_id"] as String,
                    "title": r["title"] as String,
                    "glyph": (r["glyph"] as String?) as Any,
                    "tone": (r["tone"] as String?) as Any,
                    "sort_index": r["sort_index"] as Double,
                    "created_at": r["created_at"] as String,
                    "updated_at": r["updated_at"] as String,
                ]
            }
        }
        emit(rows)
    }

    private static func getRecord(args: [String]) throws {
        guard let recordID = args.first else {
            stderr("usage: get-record <recordID>")
            exit(1)
        }
        @Dependency(\.defaultDatabase) var database
        let payload: [String: Any] = try database.read { db in
            guard let recRow = try Row.fetchOne(db, sql: """
                SELECT id, database_id, title, glyph, tone, sort_index, cover_asset_id,
                       created_at, updated_at
                FROM records WHERE id = ?
            """, arguments: [recordID]) else {
                throw CLIError.notFound("record \(recordID)")
            }

            // Properties + values
            let propRows = try Row.fetchAll(db, sql: """
                SELECT p.key, p.name, p.type, pv.text_value, pv.number_value, pv.date_value, pv.bool_value
                FROM properties p
                LEFT JOIN property_values pv ON pv.property_id = p.id AND pv.record_id = ?
                WHERE p.database_id = ?
                ORDER BY p.sort_index
            """, arguments: [recordID, recRow["database_id"] as String])
            let properties: [[String: Any]] = propRows.map { r in
                [
                    "key": r["key"] as String,
                    "name": r["name"] as String,
                    "type": r["type"] as String,
                    "text_value": (r["text_value"] as String?) as Any,
                    "number_value": (r["number_value"] as Double?) as Any,
                    "date_value": (r["date_value"] as String?) as Any,
                    "bool_value": (r["bool_value"] as Int?) as Any,
                ]
            }

            // Blocks
            let blockRows = try Row.fetchAll(db, sql: """
                SELECT id, type, content_json, sort_index
                FROM blocks
                WHERE record_id = ? AND deleted_at IS NULL
                ORDER BY sort_index
            """, arguments: [recordID])
            let blocks: [[String: Any]] = blockRows.map { r in
                [
                    "id": r["id"] as String,
                    "kind": r["type"] as String,
                    "content_json": r["content_json"] as String,
                    "sort_index": r["sort_index"] as Double,
                ]
            }

            // Assets
            let assetRows = try Row.fetchAll(db, sql: """
                SELECT id, original_filename, relative_path, mime_type, byte_size, content_hash
                FROM assets
                WHERE record_id = ?
            """, arguments: [recordID])
            let assets: [[String: Any]] = assetRows.map { r in
                [
                    "id": r["id"] as String,
                    "original_filename": r["original_filename"] as String,
                    "relative_path": r["relative_path"] as String,
                    "mime_type": (r["mime_type"] as String?) as Any,
                    "byte_size": (r["byte_size"] as Int64?) as Any,
                    "content_hash": (r["content_hash"] as String?) as Any,
                ]
            }

            // Outgoing relations bound to a property
            let outgoingRows = try Row.fetchAll(db, sql: """
                SELECT rel.id, rel.target_record_id, rel.property_id, p.key AS property_key,
                       tr.title AS target_title, tr.database_id AS target_database_id
                FROM relations rel
                LEFT JOIN properties p ON p.id = rel.property_id
                JOIN records tr ON tr.id = rel.target_record_id
                WHERE rel.source_record_id = ?
            """, arguments: [recordID])
            let outgoing: [[String: Any]] = outgoingRows.map { r in
                [
                    "id": r["id"] as String,
                    "target_record_id": r["target_record_id"] as String,
                    "property_id": (r["property_id"] as String?) as Any,
                    "property_key": (r["property_key"] as String?) as Any,
                    "target_title": r["target_title"] as String,
                    "target_database_id": r["target_database_id"] as String,
                ]
            }

            return [
                "id": recRow["id"] as String,
                "database_id": recRow["database_id"] as String,
                "title": recRow["title"] as String,
                "glyph": (recRow["glyph"] as String?) as Any,
                "tone": (recRow["tone"] as String?) as Any,
                "sort_index": recRow["sort_index"] as Double,
                "cover_asset_id": (recRow["cover_asset_id"] as String?) as Any,
                "created_at": recRow["created_at"] as String,
                "updated_at": recRow["updated_at"] as String,
                "properties": properties,
                "blocks": blocks,
                "assets": assets,
                "outgoing_relations": outgoing,
            ]
        }
        emit(payload)
    }

    private static func listBlocks(args: [String]) throws {
        guard let recordID = args.first else {
            stderr("usage: list-blocks <recordID>")
            exit(1)
        }
        @Dependency(\.defaultDatabase) var database
        let blocks: [[String: Any]] = try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, type, content_json, sort_index, created_at, updated_at
                FROM blocks
                WHERE record_id = ? AND deleted_at IS NULL
                ORDER BY sort_index
            """, arguments: [recordID]).map { r in
                [
                    "id": r["id"] as String,
                    "kind": r["type"] as String,
                    "content_json": r["content_json"] as String,
                    "sort_index": r["sort_index"] as Double,
                    "created_at": r["created_at"] as String,
                    "updated_at": r["updated_at"] as String,
                ]
            }
        }
        emit(blocks)
    }

    // MARK: - Write commands

    private static func setProperty(args: [String]) throws {
        guard args.count >= 3 else {
            stderr("usage: set-property <recordID> <key> <value>")
            exit(1)
        }
        let (recordID, key, value) = (args[0], args[1], args[2])
        @Dependency(\.defaultDatabase) var database
        try database.write { db in
            try DBWrites.updatePropertyValue(db, recordID: recordID, propertyKey: key, value: value)
        }
        emit(["ok": true, "record_id": recordID, "key": key])
    }

    private static func updateRecordTitle(args: [String]) throws {
        guard args.count >= 2 else {
            stderr("usage: update-record-title <recordID> <title>")
            exit(1)
        }
        let (recordID, title) = (args[0], args[1])
        @Dependency(\.defaultDatabase) var database
        try database.write { db in
            try DBWrites.updateRecordTitle(db, recordID: recordID, title: title)
        }
        emit(["ok": true, "record_id": recordID, "title": title])
    }

    private static func updateBlock(args: [String]) throws {
        guard let blockID = args.first else {
            stderr("usage: update-block <blockID> --text <plain-text>")
            exit(1)
        }
        guard let text = flag("--text", in: args) else {
            stderr("update-block requires --text")
            exit(1)
        }
        @Dependency(\.defaultDatabase) var database
        try database.write { db in
            try DBWrites.updateBlockText(db, blockID: blockID, text: AttributedString(text))
        }
        emit(["ok": true, "block_id": blockID])
    }

    private static func createBlock(args: [String]) throws {
        guard let recordID = args.first else {
            stderr("usage: create-block <recordID> --kind <kind> --text <text> [--after <blockID>] [--checked <true|false>]")
            exit(1)
        }
        guard let kindRaw = flag("--kind", in: args), let kind = BlockKind(rawValue: kindRaw) else {
            stderr("create-block requires --kind (paragraph|heading1|heading2|heading3|bulleted|numbered|checklist|quote|divider|table)")
            exit(1)
        }
        let text = flag("--text", in: args) ?? ""
        let after = flag("--after", in: args)
        let checked: Bool? = flag("--checked", in: args).flatMap { Bool($0) }

        @Dependency(\.defaultDatabase) var database
        let blockID: String = try database.write { db in
            let block = try DBWrites.createBlock(
                db,
                recordID: recordID,
                after: after,
                kind: kind,
                text: AttributedString(text),
                checked: checked
            )
            return block.id
        }
        emit(["ok": true, "block_id": blockID])
    }

    private static func deleteBlock(args: [String]) throws {
        guard let blockID = args.first else {
            stderr("usage: delete-block <blockID>")
            exit(1)
        }
        @Dependency(\.defaultDatabase) var database
        try database.write { db in
            try DBWrites.deleteBlock(db, blockID: blockID)
        }
        emit(["ok": true, "block_id": blockID])
    }

    // MARK: - Vendor enrichment

    /// Promote every text-fallback relation value into a real
    /// `relations` row, auto-creating stub target records when needed.
    /// Useful for cleaning up batches of imports that landed before the
    /// `updatePropertyValue` auto-create code was in place.
    private static func promoteRelations() throws {
        @Dependency(\.defaultDatabase) var database
        let result: (Int, Int) = try database.write { db in
            try DBWrites.backfillRelationsByTitleWithAutoCreate(db)
        }
        emit([
            "links_created": result.0,
            "stubs_created": result.1,
        ])
    }

    /// Enrich a single vendor: look up phone/website/address/place_id
    /// from Apple Maps and write any fields that are blank on the
    /// vendor record. `--overwrite` overrides existing values.
    private static func enrichVendor(args: [String]) throws {
        guard let vendorID = args.first else {
            stderr("usage: enrich-vendor <vendorID> [--overwrite]")
            exit(1)
        }
        let overwrite = args.contains("--overwrite")
        let result = runEnrichment(vendorIDs: [vendorID], overwrite: overwrite)
        emit(result)
    }

    /// Walk every vendor record, attempt enrichment, apply blanks-only
    /// (or all fields with `--overwrite`). Reports per-vendor outcomes
    /// so it's clear which vendors got data and which need manual help.
    private static func enrichAllVendors(args: [String]) throws {
        let overwrite = args.contains("--overwrite")
        let onlyMissing = args.contains("--only-missing-place-id")
        @Dependency(\.defaultDatabase) var database
        let vendorIDs: [String] = try database.read { db in
            var sql = """
                SELECT r.id FROM records r
                WHERE r.database_id = 'vendors' AND r.deleted_at IS NULL
            """
            if onlyMissing {
                sql += """
                  AND r.id NOT IN (
                    SELECT pv.record_id FROM property_values pv
                    WHERE pv.property_id = 'vendors.place_id'
                      AND pv.text_value IS NOT NULL AND pv.text_value != ''
                  )
                """
            }
            sql += " ORDER BY r.title"
            return try String.fetchAll(db, sql: sql)
        }
        let result = runEnrichment(vendorIDs: vendorIDs, overwrite: overwrite)
        emit(result)
    }

    private static func runEnrichment(vendorIDs: [String], overwrite: Bool) -> [String: Any] {
        guard #available(macOS 26.0, *) else {
            stderr("enrichment requires macOS 26 or later")
            exit(1)
        }
        @Dependency(\.defaultDatabase) var database

        var resolved = 0
        var ambiguous = 0
        var notFound = 0
        var failed = 0
        var perVendor: [[String: Any]] = []

        for vendorID in vendorIDs {
            // Fetch vendor's current name + address from the DB.
            let snapshot: (name: String, address: String?, placeID: String?)? = try? database.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT title FROM records WHERE id = ? AND database_id = 'vendors'",
                    arguments: [vendorID]
                ) else { return nil }
                let title: String = row["title"]
                let addr = try String.fetchOne(
                    db,
                    sql: """
                        SELECT pv.text_value FROM property_values pv
                        WHERE pv.record_id = ? AND pv.property_id = 'vendors.address'
                          AND pv.text_value IS NOT NULL AND pv.text_value != ''
                        LIMIT 1
                    """,
                    arguments: [vendorID]
                )
                let pid = try String.fetchOne(
                    db,
                    sql: """
                        SELECT pv.text_value FROM property_values pv
                        WHERE pv.record_id = ? AND pv.property_id = 'vendors.place_id'
                          AND pv.text_value IS NOT NULL AND pv.text_value != ''
                        LIMIT 1
                    """,
                    arguments: [vendorID]
                )
                return (title, addr, pid)
            }
            guard let (name, addressHint, existingPlaceID) = snapshot else {
                stderr("enrich-vendor \(vendorID): no such vendor")
                failed += 1
                continue
            }

            // Run the network call synchronously per-vendor. Sequential
            // is intentional — Apple's MKLocalSearch starts to throttle
            // on concurrent bursts and we'd rather take a few minutes
            // for 30 vendors than burn rate-limit budget.
            // NOTE: do NOT mark this closure `@MainActor`. The CLI runs
            // on the main thread and blocks on `runAsyncBlocking`'s
            // semaphore. If the body needs MainActor, the Task can't
            // make progress → deadlock. MapKit's MKMapItemRequest /
            // MKLocalSearch don't require MainActor; the autocomplete
            // path already hops to MainActor internally.
            let outcome = runAsyncBlocking {
                if let pid = existingPlaceID,
                   let item = await VendorLookupService.refresh(placeID: pid) {
                    return EnrichmentOutcome.resolved(VendorLookupService.extract(from: item))
                }
                return await VendorLookupService.enrich(name: name, address: addressHint)
            }

            switch outcome {
            case .resolved(let enrichment):
                let applied = applyEnrichment(enrichment, to: vendorID, overwrite: overwrite)
                resolved += 1
                perVendor.append([
                    "vendor_id": vendorID,
                    "title": name,
                    "outcome": "resolved",
                    "applied_fields": applied,
                ])
                stderr("  ✓ \(name) — \(applied.joined(separator: ", "))")
            case .ambiguous(let candidates):
                ambiguous += 1
                let names: [String] = candidates.compactMap { $0.placeID == nil ? nil : ($0.placeID ?? "") }
                perVendor.append([
                    "vendor_id": vendorID,
                    "title": name,
                    "outcome": "ambiguous",
                    "candidate_count": candidates.count,
                    "candidate_place_ids": names,
                ])
                stderr("  ? \(name) — \(candidates.count) candidates, skipped")
            case .notFound:
                notFound += 1
                perVendor.append([
                    "vendor_id": vendorID,
                    "title": name,
                    "outcome": "not_found",
                ])
                stderr("  · \(name) — no MapKit match")
            }
        }

        return [
            "total": vendorIDs.count,
            "resolved": resolved,
            "ambiguous": ambiguous,
            "not_found": notFound,
            "failed": failed,
            "vendors": perVendor,
        ]
    }

    /// Apply non-empty enrichment fields to the vendor record. By
    /// default skips fields that already have a value; with
    /// `overwrite=true` clobbers existing values too. Returns the list
    /// of property keys that were actually written.
    private static func applyEnrichment(_ enrichment: VendorEnrichment, to vendorID: String, overwrite: Bool) -> [String] {
        @Dependency(\.defaultDatabase) var database
        var applied: [String] = []
        let fields: [(String, String?)] = [
            ("phone",    enrichment.phone),
            ("website",  enrichment.website),
            ("address",  enrichment.address),
            ("locality", enrichment.locality),
            ("kind",     enrichment.kind),
            ("place_id", enrichment.placeID),
        ]
        for (key, valueOpt) in fields {
            guard let value = valueOpt, !value.isEmpty else { continue }
            // Look up current value to honor overwrite=false.
            let currentValue: String? = try? database.read { db in
                try String.fetchOne(
                    db,
                    sql: """
                        SELECT pv.text_value FROM property_values pv
                        WHERE pv.record_id = ? AND pv.property_id = ?
                          AND pv.text_value IS NOT NULL AND pv.text_value != ''
                        LIMIT 1
                    """,
                    arguments: [vendorID, "vendors.\(key)"]
                )
            }
            if !overwrite, currentValue != nil { continue }
            // Use DBWrites.updatePropertyValue so type coercion (and
            // future relation-property semantics) match the rest of
            // the app.
            try? database.write { db in
                try DBWrites.updatePropertyValue(db, recordID: vendorID, propertyKey: key, value: value)
            }
            applied.append(key)
        }
        return applied
    }

    /// Drive an `async` task to completion from a synchronous CLI
    /// command. We can't just block on a semaphore — MapKit's
    /// network callbacks need the main thread's run loop to spin —
    /// so we keep CFRunLoop running until the Task completes and
    /// then stop it. CLI commands are short-lived, single-flight.
    private static func runAsyncBlocking<T: Sendable>(_ body: @Sendable @escaping () async -> T) -> T {
        nonisolated(unsafe) var result: T? = nil
        nonisolated(unsafe) let runLoop = CFRunLoopGetCurrent()
        Task { @Sendable in
            let value = await body()
            result = value
            CFRunLoopStop(runLoop)
        }
        CFRunLoopRun()
        return result!
    }

    private static func runSQL(args: [String]) throws {
        guard let query = args.first else {
            stderr("usage: sql \"<query>\"")
            exit(1)
        }
        @Dependency(\.defaultDatabase) var database
        // Dispatch read vs write based on the leading keyword. Keeps a SELECT
        // out of an exclusive write transaction (faster) and matches GRDB's
        // expectations.
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let isReadOnly = trimmed.uppercased().hasPrefix("SELECT")
            || trimmed.uppercased().hasPrefix("WITH ")
            || trimmed.uppercased().hasPrefix("PRAGMA ")
        if isReadOnly {
            let rows: [[String: Any]] = try database.read { db in
                let cursor = try Row.fetchCursor(db, sql: query)
                var out: [[String: Any]] = []
                while let row = try cursor.next() {
                    var dict: [String: Any] = [:]
                    for col in row.columnNames {
                        let dbValue: DatabaseValue = row[col]
                        switch dbValue.storage {
                        case .null: dict[col] = NSNull()
                        case .int64(let i): dict[col] = i
                        case .double(let d): dict[col] = d
                        case .string(let s): dict[col] = s
                        case .blob(let b): dict[col] = "blob:\(b.count) bytes"
                        }
                    }
                    out.append(dict)
                }
                return out
            }
            emit(rows)
        } else {
            try database.write { db in
                try db.execute(sql: query)
            }
            emit(["ok": true])
        }
    }

    // MARK: - Helpers

    private static func flag(_ name: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    private static func emit(_ value: Any) {
        let normalized = sanitizeForJSON(value)
        do {
            let data = try JSONSerialization.data(
                withJSONObject: normalized,
                options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A])) // newline
        } catch {
            stderr("encoding failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    /// `JSONSerialization` rejects values it doesn't recognize as JSON-safe.
    /// `Any?` boxed to `Any` becomes `Optional<Wrapped>.some(...)` which serializes
    /// as a string like `"Optional("foo")"`. Coerce optionals into either their
    /// wrapped value or `NSNull` so the output is real JSON.
    private static func sanitizeForJSON(_ value: Any) -> Any {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            if let child = mirror.children.first {
                return sanitizeForJSON(child.value)
            }
            return NSNull()
        }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = sanitizeForJSON(v) }
            return out
        }
        if let array = value as? [Any] {
            return array.map(sanitizeForJSON)
        }
        return value
    }

    private static func stderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func printUsage() {
        let usage = """
        keystone --cli <command> [args]

        Read commands:
          list-databases                                 JSON array of databases
          list-records [--database <id>]                 JSON array of records
          get-record <recordID>                          full record JSON (props/blocks/assets/relations)
          list-blocks <recordID>                         JSON array of blocks for a record

        Write commands:
          update-record-title <recordID> <title>         update title (also re-derives glyph)
          set-property <recordID> <key> <value>          set property value (relations resolve by title)
          create-block <recordID> --kind <kind> --text <text> [--after <blockID>] [--checked <bool>]
          update-block <blockID> --text <text>           replace block text (plain string)
          delete-block <blockID>                         delete block

        Escape hatch:
          sql "<query>"                                  raw SQL; reads return JSON, writes return {ok:true}

        Output: JSON to stdout. Errors to stderr, exit 1.
        """
        FileHandle.standardOutput.write(Data((usage + "\n").utf8))
    }
}

private enum CLIError: LocalizedError {
    case notFound(String)
    var errorDescription: String? {
        switch self {
        case .notFound(let s): return "not found: \(s)"
        }
    }
}
