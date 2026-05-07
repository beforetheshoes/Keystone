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
}

struct RecordRow: Equatable, Sendable, Identifiable {
    let id: String
    let databaseID: String
    var title: String
    var glyph: String
    let tone: AccentTone
    let sortIndex: Double
    var values: [String: String] = [:]
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
            SELECT id, key, name, type, sort_index FROM properties WHERE database_id = ? AND is_archived = 0 ORDER BY sort_index
        """, arguments: [databaseID]).map { row in
            PropertyRow(
                id: row["id"],
                key: row["key"],
                name: row["name"],
                type: PropertyType(rawValue: row["type"]) ?? .text,
                sortIndex: row["sort_index"]
            )
        }
    }

    static func records(_ db: Database, databaseID: String) throws -> [RecordRow] {
        let recRows = try Row.fetchAll(db, sql: """
            SELECT r.id, r.database_id, r.title, r.glyph, r.tone, r.sort_index,
                   r.cover_asset_id, a.relative_path AS cover_relative_path
            FROM records r
            LEFT JOIN assets a ON a.id = r.cover_asset_id
            WHERE r.database_id = ? AND r.deleted_at IS NULL
            ORDER BY r.sort_index
        """, arguments: [databaseID])

        let recIDs = recRows.map { $0["id"] as String }
        guard !recIDs.isEmpty else { return [] }

        let placeholders = Array(repeating: "?", count: recIDs.count).joined(separator: ",")
        let valueRows = try Row.fetchAll(db, sql: """
            SELECT pv.record_id, p.key, pv.text_value, pv.number_value, pv.date_value
            FROM property_values pv
            JOIN properties p ON p.id = pv.property_id
            WHERE pv.record_id IN (\(placeholders))
        """, arguments: StatementArguments(recIDs))

        var byRecord: [String: [String: String]] = [:]
        for row in valueRows {
            let rid: String = row["record_id"]
            let key: String = row["key"]
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
            }
        }

        // Fold relation links into `values` so list/table cells render the
        // target record's title. Best-effort — if any relation row trips
        // (e.g. orphaned property_id, broken FK from a sync conflict), we
        // skip the relation labels rather than failing the whole records
        // fetch and leaving the table view empty.
        let relRows: [Row] = (try? Row.fetchAll(db, sql: """
            SELECT rel.source_record_id, p.key, tr.title AS target_title
            FROM relations rel
            JOIN properties p ON p.id = rel.property_id
            JOIN records tr ON tr.id = rel.target_record_id
            WHERE rel.source_record_id IN (\(placeholders))
        """, arguments: StatementArguments(recIDs))) ?? []
        for row in relRows {
            guard let rid: String = row["source_record_id"],
                  let key: String = row["key"],
                  let title: String = row["target_title"] else { continue }
            if let existing = byRecord[rid]?[key], !existing.isEmpty {
                byRecord[rid, default: [:]][key] = existing + ", " + title
            } else {
                byRecord[rid, default: [:]][key] = title
            }
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
                coverAssetID: row["cover_asset_id"],
                coverRelativePath: row["cover_relative_path"]
            )
        }
    }

    static func record(_ db: Database, id: String) throws -> RecordRow? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT r.id, r.database_id, r.title, r.glyph, r.tone, r.sort_index,
                   r.cover_asset_id, a.relative_path AS cover_relative_path
            FROM records r
            LEFT JOIN assets a ON a.id = r.cover_asset_id
            WHERE r.id = ?
        """, arguments: [id]) else { return nil }

        let valueRows = try Row.fetchAll(db, sql: """
            SELECT p.key, pv.text_value, pv.number_value, pv.date_value
            FROM property_values pv
            JOIN properties p ON p.id = pv.property_id
            WHERE pv.record_id = ?
        """, arguments: [id])

        var values: [String: String] = [:]
        for vrow in valueRows {
            let key: String = vrow["key"]
            if let t: String = vrow["text_value"] {
                values[key] = t
            } else if let n: Double = vrow["number_value"] {
                values[key] = n.rounded() == n ? String(Int(n)) : String(n)
            } else if let d: String = vrow["date_value"] {
                values[key] = d
            }
        }

        // Fold relation link target titles into `values` so the property
        // grid's display path sees the same shape as text/number/date.
        // Best-effort — see the matching block in `records()` for why.
        let relRows: [Row] = (try? Row.fetchAll(db, sql: """
            SELECT p.key, tr.title AS target_title
            FROM relations rel
            JOIN properties p ON p.id = rel.property_id
            JOIN records tr ON tr.id = rel.target_record_id
            WHERE rel.source_record_id = ?
        """, arguments: [id])) ?? []
        for vrow in relRows {
            guard let key: String = vrow["key"],
                  let title: String = vrow["target_title"] else { continue }
            if let existing = values[key], !existing.isEmpty {
                values[key] = existing + ", " + title
            } else {
                values[key] = title
            }
        }

        return RecordRow(
            id: row["id"],
            databaseID: row["database_id"],
            title: row["title"],
            glyph: row["glyph"] ?? "",
            tone: AccentTone(rawValue: row["tone"]) ?? .graphite,
            sortIndex: row["sort_index"],
            values: values,
            coverAssetID: row["cover_asset_id"],
            coverRelativePath: row["cover_relative_path"]
        )
    }

    static func relatedRecords(_ db: Database, sourceID: String) throws -> [RecordRow] {
        let targetIDs = try String.fetchAll(db, sql: """
            SELECT target_record_id FROM relations WHERE source_record_id = ?
        """, arguments: [sourceID])
        return try targetIDs.compactMap { try record(db, id: $0) }
    }

    static func paletteItems(_ db: Database) throws -> [PaletteItem] {
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
