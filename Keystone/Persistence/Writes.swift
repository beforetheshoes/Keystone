import Foundation
import GRDB

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
        try db.execute(
            sql: "UPDATE records SET title = ?, glyph = ?, updated_at = ? WHERE id = ?",
            arguments: [title, glyph, now, recordID]
        )
    }

    static func updatePropertyValue(_ db: Database, recordID: String, propertyKey: String, value: String) throws {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT p.id AS prop_id, p.type AS prop_type, r.database_id AS db_id
            FROM records r
            JOIN properties p ON p.database_id = r.database_id AND p.key = ?
            WHERE r.id = ?
        """, arguments: [propertyKey, recordID]) else { return }

        let propID: String = row["prop_id"]
        let propType: String = row["prop_type"]
        let now = AppDatabase.isoFormatter.string(from: Date())
        let pvID = "\(recordID).\(propertyKey)"

        var textValue: String? = nil
        var numberValue: Double? = nil
        var dateValue: String? = nil

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch propType {
        case "number":
            if let n = Double(trimmed) { numberValue = n }
            else if !trimmed.isEmpty { textValue = trimmed }
        case "date":
            dateValue = trimmed.isEmpty ? nil : trimmed
            textValue = dateValue
        default:
            textValue = trimmed.isEmpty ? nil : trimmed
        }

        // The pvID is "<recordID>.<propertyKey>" — deterministic — so a
        // PK conflict is the same as a (record_id, property_id) conflict.
        try db.execute(
            sql: """
                INSERT INTO property_values (id, record_id, property_id, text_value, number_value, date_value, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    text_value = excluded.text_value,
                    number_value = excluded.number_value,
                    date_value = excluded.date_value,
                    updated_at = excluded.updated_at
            """,
            arguments: [pvID, recordID, propID, textValue, numberValue, dateValue, now, now]
        )

        try db.execute(
            sql: "UPDATE records SET updated_at = ? WHERE id = ?",
            arguments: [now, recordID]
        )
    }

    static func deleteRecord(_ db: Database, recordID: String) throws {
        try db.execute(sql: "DELETE FROM records WHERE id = ?", arguments: [recordID])
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
