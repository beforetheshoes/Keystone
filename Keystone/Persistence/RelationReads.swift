import Foundation
import GRDB

struct RelationLink: Equatable, Sendable, Identifiable {
    let id: String
    let sourceRecordID: String
    let targetRecordID: String
    let propertyID: String?
    let propertyName: String?       // hydrated for display ("Pets", "Vet", etc.)
    let targetTitle: String
    let targetGlyph: String
    let targetTone: AccentTone
    let targetDatabaseID: String
    let targetDatabaseName: String
}

enum RelationReads {
    /// Outgoing relations FROM `recordID`. Optionally filtered by relation property.
    static func outgoing(_ db: Database, recordID: String, propertyID: String? = nil) throws -> [RelationLink] {
        let sql: String
        let args: StatementArguments
        if let propertyID {
            sql = """
                SELECT r.id AS relID, r.source_record_id, r.target_record_id, r.property_id,
                       p.name AS prop_name,
                       t.title, t.glyph, t.tone, t.database_id,
                       d.name AS db_name
                FROM relations r
                JOIN records t ON t.id = r.target_record_id
                JOIN databases d ON d.id = t.database_id
                LEFT JOIN properties p ON p.id = r.property_id
                WHERE r.source_record_id = ? AND r.property_id = ?
                ORDER BY t.title COLLATE NOCASE
            """
            args = [recordID, propertyID]
        } else {
            sql = """
                SELECT r.id AS relID, r.source_record_id, r.target_record_id, r.property_id,
                       p.name AS prop_name,
                       t.title, t.glyph, t.tone, t.database_id,
                       d.name AS db_name
                FROM relations r
                JOIN records t ON t.id = r.target_record_id
                JOIN databases d ON d.id = t.database_id
                LEFT JOIN properties p ON p.id = r.property_id
                WHERE r.source_record_id = ?
                ORDER BY d.sort_index, t.title COLLATE NOCASE
            """
            args = [recordID]
        }
        let rows = try Row.fetchAll(db, sql: sql, arguments: args)
        return rows.map(rowToLink)
    }

    /// Incoming relations TO `recordID` (records that link here).
    static func incoming(_ db: Database, recordID: String) throws -> [RelationLink] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT r.id AS relID, r.source_record_id, r.target_record_id, r.property_id,
                   p.name AS prop_name,
                   s.title, s.glyph, s.tone, s.database_id,
                   d.name AS db_name
            FROM relations r
            JOIN records s ON s.id = r.source_record_id
            JOIN databases d ON d.id = s.database_id
            LEFT JOIN properties p ON p.id = r.property_id
            WHERE r.target_record_id = ?
            ORDER BY d.sort_index, s.title COLLATE NOCASE
        """, arguments: [recordID])
        // For incoming, target_* fields actually carry source data — flip semantics:
        return rows.map { row in
            RelationLink(
                id: row["relID"],
                sourceRecordID: row["source_record_id"],
                targetRecordID: row["target_record_id"],
                propertyID: row["property_id"],
                propertyName: row["prop_name"],
                targetTitle: row["title"],
                targetGlyph: row["glyph"] ?? "",
                targetTone: AccentTone(rawValue: row["tone"] ?? "graphite") ?? .graphite,
                targetDatabaseID: row["database_id"],
                targetDatabaseName: row["db_name"]
            )
        }
    }

    static func link(_ db: Database, relationID: String) throws -> RelationLink? {
        let row = try Row.fetchOne(db, sql: """
            SELECT r.id AS relID, r.source_record_id, r.target_record_id, r.property_id,
                   p.name AS prop_name,
                   t.title, t.glyph, t.tone, t.database_id,
                   d.name AS db_name
            FROM relations r
            JOIN records t ON t.id = r.target_record_id
            JOIN databases d ON d.id = t.database_id
            LEFT JOIN properties p ON p.id = r.property_id
            WHERE r.id = ?
        """, arguments: [relationID])
        return row.map(rowToLink)
    }

    /// Resolve the target database for a relation property, by reading config_json.
    static func relationTargetDB(_ db: Database, propertyID: String) throws -> String? {
        guard let json = try String.fetchOne(db, sql: "SELECT config_json FROM properties WHERE id = ?", arguments: [propertyID]),
              let data = json.data(using: .utf8),
              let cfg = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return cfg["targetDatabaseID"] as? String
    }

    private static func rowToLink(_ row: Row) -> RelationLink {
        RelationLink(
            id: row["relID"],
            sourceRecordID: row["source_record_id"],
            targetRecordID: row["target_record_id"],
            propertyID: row["property_id"],
            propertyName: row["prop_name"],
            targetTitle: row["title"],
            targetGlyph: row["glyph"] ?? "",
            targetTone: AccentTone(rawValue: row["tone"] ?? "graphite") ?? .graphite,
            targetDatabaseID: row["database_id"],
            targetDatabaseName: row["db_name"]
        )
    }
}
