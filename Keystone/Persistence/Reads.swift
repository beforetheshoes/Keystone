import Foundation
import GRDB

struct AreaRow: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let accent: AccentTone
    let sortIndex: Double
}

struct DBRow: Equatable, Sendable, Identifiable {
    let id: String
    let areaID: String?
    let name: String
    let pluralName: String?
    let icon: String
    let accent: AccentTone
    let defaultView: ViewKind
    let sortIndex: Double
    var recordCount: Int = 0
}

struct PropertyRow: Equatable, Sendable, Identifiable {
    let id: String
    let key: String
    let name: String
    let type: PropertyType
    let sortIndex: Double
    /// Raw `config_json` blob from the `properties` row. Parsed on demand
    /// via `config` so callers that don't need it pay nothing.
    let configJSON: String

    var config: PropertyConfig {
        PropertyConfig.parse(configJSON)
    }

    /// The column alignment to use in tables. Honors an explicit
    /// `alignment` from the property's config; otherwise falls back to a
    /// type-aware default — numbers and currency right, select/checkbox
    /// center, everything else left.
    var resolvedAlignment: PropertyAlignment {
        if let explicit = config.alignment { return explicit }
        switch type {
        case .number, .currency:        return .right
        case .select, .checkbox:        return .center
        default:                        return .leading
        }
    }
}

/// Decoded form of `properties.config_json`. Only the fields we
/// understand are decoded; unknown JSON keys are preserved by re-encoding
/// from the raw dictionary in `merging(_:)` so a write doesn't strip
/// targetDatabaseID or other configs we don't model here.
struct PropertyConfig: Equatable, Sendable {
    /// Optional explicit alignment override. `nil` means "use the
    /// type-aware default" (`PropertyRow.resolvedAlignment`).
    var alignment: PropertyAlignment?
    /// Optional formatting for number/currency columns. `nil` means
    /// "use the type-aware default" (currency type → USD, number → none).
    var format: PropertyFormat?
    /// Currency code for `.currency` formatting. Defaults to "USD"
    /// when format is `.currency` but no code is set.
    var currencyCode: String?
    /// For `.select` properties: the allowed values, in display order.
    /// When non-nil, the editor renders a pill that cycles through the
    /// list on tap; when nil, the property accepts free-form text.
    var options: [String]?
    /// Verbatim JSON-encoded blob of other keys we don't model directly
    /// here (e.g. `targetDatabaseID` for relations). Stored as a string
    /// so the struct stays `Sendable` — writes round-trip via `encoded()`
    /// without stripping these keys.
    var rawExtrasJSON: String

    static let empty = PropertyConfig(alignment: nil, format: nil, currencyCode: nil, options: nil, rawExtrasJSON: "{}")

    static func parse(_ json: String) -> PropertyConfig {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }
        var extras = obj
        let alignment = (obj["alignment"] as? String).flatMap(PropertyAlignment.init(rawValue:))
        let format = (obj["format"] as? String).flatMap(PropertyFormat.init(rawValue:))
        let code = obj["currencyCode"] as? String
        // Reject non-string elements so a corrupted config can't crash
        // the cycle helper; treat as no-options instead.
        let options: [String]? = {
            guard let raw = obj["options"] as? [Any] else { return nil }
            let strings = raw.compactMap { $0 as? String }
            return strings.count == raw.count ? strings : nil
        }()
        extras.removeValue(forKey: "alignment")
        extras.removeValue(forKey: "format")
        extras.removeValue(forKey: "currencyCode")
        extras.removeValue(forKey: "options")
        let extrasJSON: String = {
            guard let data = try? JSONSerialization.data(withJSONObject: extras),
                  let str = String(data: data, encoding: .utf8) else { return "{}" }
            return str
        }()
        return PropertyConfig(alignment: alignment, format: format, currencyCode: code, options: options, rawExtrasJSON: extrasJSON)
    }

    /// Re-encode the config back to a JSON string, preserving any
    /// unknown keys captured in `rawExtrasJSON`. Stable key ordering is
    /// not guaranteed; SQLite doesn't care.
    func encoded() -> String {
        var obj: [String: Any] = {
            guard let data = rawExtrasJSON.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return parsed
        }()
        if let alignment { obj["alignment"] = alignment.rawValue }
        if let format { obj["format"] = format.rawValue }
        if let currencyCode { obj["currencyCode"] = currencyCode }
        if let options { obj["options"] = options }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}

enum PropertyAlignment: String, Sendable, Equatable, CaseIterable {
    case leading
    case center
    case right
}

enum PropertyFormat: String, Sendable, Equatable {
    case currency
    case decimal
    case integer
    case percent
}

struct RelationTarget: Equatable, Sendable {
    let recordID: String
    let databaseID: String
    let title: String
}

struct RecordRow: Equatable, Sendable, Identifiable {
    let id: String
    let databaseID: String
    var title: String
    var glyph: String
    let tone: AccentTone
    let sortIndex: Double
    var values: [String: String] = [:]
    /// Outgoing relations keyed by the property key. Populated alongside
    /// `values` so a cell renderer that wants to navigate to a related
    /// record (e.g., the table view's Vendor or Vehicle column) can
    /// look up the target's id + database without a second query.
    var relationTargets: [String: [RelationTarget]] = [:]
    var coverAssetID: String? = nil
    var coverRelativePath: String? = nil

    var coverImageURL: URL? {
        coverRelativePath.map(AppDatabase.absoluteURL(forRelativePath:))
    }
}

struct PaletteItem: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable, Equatable { case database, record, action }
    let id: String
    let kind: Kind
    let label: String
    let sub: String
    let glyph: String
    let tone: AccentTone
    let dbID: String?
}

enum DBReads {
    static func areas(_ db: Database) throws -> [AreaRow] {
        try Row.fetchAll(db, sql: "SELECT id, title, accent, sort_index FROM areas ORDER BY sort_index").map { row in
            AreaRow(
                id: row["id"],
                title: row["title"],
                accent: AccentTone(rawValue: row["accent"]) ?? .graphite,
                sortIndex: row["sort_index"]
            )
        }
    }

    static func databases(_ db: Database) throws -> [DBRow] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT d.id, d.area_id, d.name, d.plural_name, d.icon, d.accent, d.default_view, d.sort_index,
                   (SELECT COUNT(*) FROM records r WHERE r.database_id = d.id AND r.deleted_at IS NULL) AS rcount
            FROM databases d
            ORDER BY d.sort_index
        """)
        return rows.map { row in
            DBRow(
                id: row["id"],
                areaID: row["area_id"],
                name: row["name"],
                pluralName: row["plural_name"],
                icon: row["icon"] ?? "",
                accent: AccentTone(rawValue: row["accent"]) ?? .graphite,
                defaultView: ViewKind(rawValue: row["default_view"]) ?? .table,
                sortIndex: row["sort_index"],
                recordCount: row["rcount"]
            )
        }
    }

    static func database(_ db: Database, id: String) throws -> DBRow? {
        try databases(db).first(where: { $0.id == id })
    }

    static func properties(_ db: Database, databaseID: String) throws -> [PropertyRow] {
        try Row.fetchAll(db, sql: """
            SELECT id, key, name, type, sort_index, config_json FROM properties WHERE database_id = ? AND is_archived = 0 ORDER BY sort_index
        """, arguments: [databaseID]).map { row in
            PropertyRow(
                id: row["id"],
                key: row["key"],
                name: row["name"],
                type: PropertyType(rawValue: row["type"]) ?? .text,
                sortIndex: row["sort_index"],
                configJSON: row["config_json"] ?? "{}"
            )
        }
    }

    /// Fetch every visible record in `databaseID`, soft-deletes excluded.
    /// `excluding` is the privacy-lock hidden set from
    /// `AppFeature.State.hiddenRecordIDs` — protected records (and any
    /// dependents in the cascade) are filtered out at the SQL level so
    /// downstream UI surfaces never see them.
    ///
    /// `encryptor` is optional: when present (live env via DatabaseClient),
    /// `enc_value` blobs are decrypted into the values dict; when nil
    /// (CLI / tests), encrypted rows surface as the literal `[encrypted]`
    /// placeholder so callers can tell at a glance.
    static func records(
        _ db: Database,
        databaseID: String,
        excluding: Set<String> = [],
        encryptor: ValueEncryptor? = nil
    ) throws -> [RecordRow] {
        let recRowsRaw = try Row.fetchAll(db, sql: """
            SELECT r.id, r.database_id, r.title, r.glyph, r.tone, r.sort_index,
                   r.cover_asset_id, a.relative_path AS cover_relative_path
            FROM records r
            LEFT JOIN assets a ON a.id = r.cover_asset_id
            WHERE r.database_id = ? AND r.deleted_at IS NULL
            ORDER BY r.sort_index
        """, arguments: [databaseID])

        let recRows: [Row]
        if excluding.isEmpty {
            recRows = recRowsRaw
        } else {
            recRows = recRowsRaw.filter { !excluding.contains($0["id"] as String) }
        }

        let recIDs = recRows.map { $0["id"] as String }
        guard !recIDs.isEmpty else { return [] }

        let placeholders = Array(repeating: "?", count: recIDs.count).joined(separator: ",")
        let valueRows = try Row.fetchAll(db, sql: """
            SELECT pv.record_id, p.key, p.type, pv.text_value, pv.number_value, pv.date_value, pv.json_value, pv.enc_value
            FROM property_values pv
            JOIN properties p ON p.id = pv.property_id
            WHERE pv.record_id IN (\(placeholders))
        """, arguments: StatementArguments(recIDs))

        var byRecord: [String: [String: String]] = [:]
        for row in valueRows {
            let rid: String = row["record_id"]
            let key: String = row["key"]
            let propType: String = row["type"] ?? ""
            // Encrypted column wins — when populated, plaintext columns
            // were nulled by the encryption pass. Decrypt if a key is
            // available; otherwise surface a placeholder so the caller
            // (CLI, tests) can tell the value is intentionally opaque.
            if let enc: Data = row["enc_value"], !enc.isEmpty {
                if let encryptor, let plain = try? encryptor.decrypt(enc) {
                    byRecord[rid, default: [:]][key] = plain
                } else {
                    byRecord[rid, default: [:]][key] = "[encrypted]"
                }
                continue
            }
            if propType == "date_tz" {
                let date = row["date_value"] as String? ?? ""
                let tz = row["text_value"] as String? ?? ""
                if !date.isEmpty && !tz.isEmpty {
                    byRecord[rid, default: [:]][key] = "\(date)|\(tz)"
                } else if !date.isEmpty {
                    byRecord[rid, default: [:]][key] = date
                } else if !tz.isEmpty {
                    byRecord[rid, default: [:]][key] = tz
                }
                continue
            }
            if propType == "address" {
                // Cell renderers / search / filters only need the
                // denormalized one-line; the editor pulls json_value
                // separately via DatabaseClient.propertyJSON.
                if let t: String = row["text_value"], !t.isEmpty {
                    byRecord[rid, default: [:]][key] = t
                }
                continue
            }
            if let t: String = row["text_value"] {
                byRecord[rid, default: [:]][key] = t
            } else if let n: Double = row["number_value"] {
                if n.rounded() == n {
                    byRecord[rid, default: [:]][key] = String(Int(n))
                } else {
                    byRecord[rid, default: [:]][key] = String(n)
                }
            } else if let d: String = row["date_value"] {
                byRecord[rid, default: [:]][key] = d
            } else if let j: String = row["json_value"] {
                byRecord[rid, default: [:]][key] = j
            }
        }

        // Fold relation links into `values` so list/table cells render the
        // target record's title. Also collect the target's record_id +
        // database_id under `relationTargets` so callers (e.g. the table
        // view) can navigate straight to the related record without a
        // second query. Best-effort — if any relation row trips (e.g.
        // orphaned property_id, broken FK from a sync conflict), we
        // skip the relation labels rather than failing the whole records
        // fetch and leaving the table view empty.
        let relRows: [Row] = (try? Row.fetchAll(db, sql: """
            SELECT rel.source_record_id, p.key,
                   tr.id AS target_id, tr.database_id AS target_db, tr.title AS target_title
            FROM relations rel
            JOIN properties p ON p.id = rel.property_id
            JOIN records tr ON tr.id = rel.target_record_id
            WHERE rel.source_record_id IN (\(placeholders))
        """, arguments: StatementArguments(recIDs))) ?? []
        var relationsByRecord: [String: [String: [RelationTarget]]] = [:]
        // Tracks which (record, property) pairs we've already started
        // populating from `relations`. The first hit for a pair clears
        // any residual `property_values` text (e.g. legacy text written
        // into a column that was later switched to a relation) so
        // relation-derived titles don't get prepended to a stale string.
        var clearedKeys: Set<String> = []
        // Per (record, property), tracks target ids we've already
        // appended so duplicate `relations` rows (from sync conflicts /
        // older unconstrained inserts) render as ONE title, not "Foo,
        // Foo, Foo".
        var seenTargets: [String: Set<String>] = [:]
        for row in relRows {
            guard let rid: String = row["source_record_id"],
                  let key: String = row["key"],
                  let targetID: String = row["target_id"],
                  let targetDB: String = row["target_db"],
                  let title: String = row["target_title"] else { continue }
            let pairKey = "\(rid)|\(key)"
            if !clearedKeys.contains(pairKey) {
                byRecord[rid, default: [:]][key] = ""
                clearedKeys.insert(pairKey)
            }
            if seenTargets[pairKey, default: []].contains(targetID) { continue }
            seenTargets[pairKey, default: []].insert(targetID)

            if let existing = byRecord[rid]?[key], !existing.isEmpty {
                byRecord[rid, default: [:]][key] = existing + ", " + title
            } else {
                byRecord[rid, default: [:]][key] = title
            }
            relationsByRecord[rid, default: [:]][key, default: []]
                .append(RelationTarget(recordID: targetID, databaseID: targetDB, title: title))
        }

        return recRows.map { row in
            let rid: String = row["id"]
            return RecordRow(
                id: rid,
                databaseID: row["database_id"],
                title: row["title"],
                glyph: row["glyph"] ?? "",
                tone: AccentTone(rawValue: row["tone"]) ?? .graphite,
                sortIndex: row["sort_index"],
                values: byRecord[rid] ?? [:],
                relationTargets: relationsByRecord[rid] ?? [:],
                coverAssetID: row["cover_asset_id"],
                coverRelativePath: row["cover_relative_path"]
            )
        }
    }

    /// Fetch the raw `json_value` for a (record, property-key) pair.
    /// Returns nil when no row exists, the property doesn't exist on the
    /// record's database, or json_value is empty. Used by the address
    /// editor to hydrate structured state on demand.
    static func propertyJSON(_ db: Database, recordID: String, propertyKey: String) throws -> String? {
        let raw: String? = try String.fetchOne(
            db,
            sql: """
                SELECT pv.json_value
                FROM property_values pv
                JOIN properties p ON p.id = pv.property_id
                JOIN records r ON r.id = pv.record_id
                WHERE pv.record_id = ?
                  AND p.key = ?
                  AND p.database_id = r.database_id
                LIMIT 1
            """,
            arguments: [recordID, propertyKey]
        )
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    static func record(
        _ db: Database,
        id: String,
        encryptor: ValueEncryptor? = nil
    ) throws -> RecordRow? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT r.id, r.database_id, r.title, r.glyph, r.tone, r.sort_index,
                   r.cover_asset_id, a.relative_path AS cover_relative_path
            FROM records r
            LEFT JOIN assets a ON a.id = r.cover_asset_id
            WHERE r.id = ?
        """, arguments: [id]) else { return nil }

        let valueRows = try Row.fetchAll(db, sql: """
            SELECT p.key, p.type, pv.text_value, pv.number_value, pv.date_value, pv.json_value, pv.enc_value
            FROM property_values pv
            JOIN properties p ON p.id = pv.property_id
            WHERE pv.record_id = ?
        """, arguments: [id])

        var values: [String: String] = [:]
        for vrow in valueRows {
            let key: String = vrow["key"]
            let propType: String = vrow["type"] ?? ""
            if let enc: Data = vrow["enc_value"], !enc.isEmpty {
                if let encryptor, let plain = try? encryptor.decrypt(enc) {
                    values[key] = plain
                } else {
                    values[key] = "[encrypted]"
                }
                continue
            }
            if propType == "date_tz" {
                let date = vrow["date_value"] as String? ?? ""
                let tz = vrow["text_value"] as String? ?? ""
                if !date.isEmpty && !tz.isEmpty {
                    values[key] = "\(date)|\(tz)"
                } else if !date.isEmpty {
                    values[key] = date
                } else if !tz.isEmpty {
                    values[key] = tz
                }
                continue
            }
            if propType == "address" {
                if let t: String = vrow["text_value"], !t.isEmpty {
                    values[key] = t
                }
                continue
            }
            if let t: String = vrow["text_value"] {
                values[key] = t
            } else if let n: Double = vrow["number_value"] {
                values[key] = n.rounded() == n ? String(Int(n)) : String(n)
            } else if let d: String = vrow["date_value"] {
                values[key] = d
            } else if let j: String = vrow["json_value"] {
                values[key] = j
            }
        }

        // Fold relation link target titles into `values` so the property
        // grid's display path sees the same shape as text/number/date.
        // Also gather target IDs in `relationTargets` so callers can
        // navigate to the linked record. Best-effort — see the matching
        // block in `records()` for why.
        let relRows: [Row] = (try? Row.fetchAll(db, sql: """
            SELECT p.key,
                   tr.id AS target_id, tr.database_id AS target_db, tr.title AS target_title
            FROM relations rel
            JOIN properties p ON p.id = rel.property_id
            JOIN records tr ON tr.id = rel.target_record_id
            WHERE rel.source_record_id = ?
        """, arguments: [id])) ?? []
        var relationTargets: [String: [RelationTarget]] = [:]
        // Same dedup logic as `records()`: clear any residual
        // property_values text on first relation hit per key, and skip
        // duplicate target ids so the comma-joined display doesn't
        // show "Foo, Foo, Foo" for orphan duplicate relation rows.
        var clearedKeys: Set<String> = []
        var seenTargets: [String: Set<String>] = [:]
        for vrow in relRows {
            guard let key: String = vrow["key"],
                  let targetID: String = vrow["target_id"],
                  let targetDB: String = vrow["target_db"],
                  let title: String = vrow["target_title"] else { continue }
            if !clearedKeys.contains(key) {
                values[key] = ""
                clearedKeys.insert(key)
            }
            if seenTargets[key, default: []].contains(targetID) { continue }
            seenTargets[key, default: []].insert(targetID)

            if let existing = values[key], !existing.isEmpty {
                values[key] = existing + ", " + title
            } else {
                values[key] = title
            }
            relationTargets[key, default: []]
                .append(RelationTarget(recordID: targetID, databaseID: targetDB, title: title))
        }

        return RecordRow(
            id: row["id"],
            databaseID: row["database_id"],
            title: row["title"],
            glyph: row["glyph"] ?? "",
            tone: AccentTone(rawValue: row["tone"]) ?? .graphite,
            sortIndex: row["sort_index"],
            values: values,
            relationTargets: relationTargets,
            coverAssetID: row["cover_asset_id"],
            coverRelativePath: row["cover_relative_path"]
        )
    }

    static func relatedRecords(
        _ db: Database,
        sourceID: String,
        excluding: Set<String> = [],
        encryptor: ValueEncryptor? = nil
    ) throws -> [RecordRow] {
        let targetIDs = try String.fetchAll(db, sql: """
            SELECT target_record_id FROM relations WHERE source_record_id = ?
        """, arguments: [sourceID])
        return try targetIDs
            .filter { !excluding.contains($0) }
            .compactMap { try record(db, id: $0, encryptor: encryptor) }
    }

    static func paletteItems(
        _ db: Database,
        excluding: Set<String> = []
    ) throws -> [PaletteItem] {
        var items: [PaletteItem] = []
        let dbs = try databases(db)
        for d in dbs {
            items.append(PaletteItem(
                id: "db-\(d.id)",
                kind: .database,
                label: d.name,
                sub: "Database",
                glyph: d.icon,
                tone: d.accent,
                dbID: d.id
            ))
        }
        let recRows = try Row.fetchAll(db, sql: """
            SELECT r.id, r.database_id, r.title, r.glyph, r.tone, d.name AS dbname
            FROM records r JOIN databases d ON d.id = r.database_id
            WHERE r.deleted_at IS NULL
            ORDER BY r.title
        """)
        for row in recRows {
            let id: String = row["id"]
            if excluding.contains(id) { continue }
            let dbID: String = row["database_id"]
            let dbname: String = row["dbname"]
            items.append(PaletteItem(
                id: "rec-\(id)",
                kind: .record,
                label: row["title"],
                sub: String(dbname.dropLast(dbname.hasSuffix("s") ? 1 : 0)),
                glyph: row["glyph"] ?? "",
                tone: AccentTone(rawValue: row["tone"]) ?? .graphite,
                dbID: dbID
            ))
        }
        items.append(PaletteItem(id: "act-new-person", kind: .action, label: "New person", sub: "Quick capture", glyph: "+", tone: .cerulean, dbID: nil))
        items.append(PaletteItem(id: "act-new-event",  kind: .action, label: "New event",  sub: "Quick capture", glyph: "+", tone: .amber,    dbID: nil))
        return items
    }
}
