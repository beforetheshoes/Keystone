import Foundation
import GRDB

enum TagScope: String, Codable, Sendable, Equatable, CaseIterable {
    case global, database
}

struct TagModel: Equatable, Sendable, Identifiable {
    let id: String
    var name: String
    var scopeType: TagScope
    var scopeID: String?           // databaseID when scopeType == .database
    var color: AccentTone
    var recordCount: Int
}

enum TagReads {
    static func tags(_ db: Database, workspaceID: String) throws -> [TagModel] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.id, t.name, t.scope_type, t.scope_id, t.color,
                   (SELECT COUNT(*) FROM record_tags rt WHERE rt.tag_id = t.id) AS rcount
            FROM tags t WHERE t.workspace_id = ?
            ORDER BY t.name COLLATE NOCASE
        """, arguments: [workspaceID])
        return rows.map { row in
            TagModel(
                id: row["id"],
                name: row["name"],
                scopeType: TagScope(rawValue: row["scope_type"] ?? "global") ?? .global,
                scopeID: row["scope_id"],
                color: AccentTone(rawValue: row["color"] ?? "graphite") ?? .graphite,
                recordCount: row["rcount"]
            )
        }
    }

    /// Tags available for a record in a given database: global tags + tags scoped to that database.
    static func tagsAvailable(_ db: Database, workspaceID: String, databaseID: String) throws -> [TagModel] {
        try tags(db, workspaceID: workspaceID).filter { tag in
            tag.scopeType == .global || tag.scopeID == databaseID
        }
    }

    static func tagsForRecord(_ db: Database, recordID: String) throws -> [TagModel] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.id, t.name, t.scope_type, t.scope_id, t.color,
                   (SELECT COUNT(*) FROM record_tags rt2 WHERE rt2.tag_id = t.id) AS rcount
            FROM tags t
            JOIN record_tags rt ON rt.tag_id = t.id
            WHERE rt.record_id = ?
            ORDER BY t.name COLLATE NOCASE
        """, arguments: [recordID])
        return rows.map { row in
            TagModel(
                id: row["id"],
                name: row["name"],
                scopeType: TagScope(rawValue: row["scope_type"] ?? "global") ?? .global,
                scopeID: row["scope_id"],
                color: AccentTone(rawValue: row["color"] ?? "graphite") ?? .graphite,
                recordCount: row["rcount"]
            )
        }
    }

    static func recordIDsForTag(_ db: Database, tagID: String) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT record_id FROM record_tags WHERE tag_id = ?", arguments: [tagID])
    }

    /// Records (with database name) that have a given tag, across the workspace.
    static func recordsForTag(_ db: Database, tagID: String) throws -> [(record: RecordRow, dbName: String)] {
        let recIDs = try recordIDsForTag(db, tagID: tagID)
        guard !recIDs.isEmpty else { return [] }
        var out: [(RecordRow, String)] = []
        for id in recIDs {
            if let rec = try DBReads.record(db, id: id),
               let row = try Row.fetchOne(db, sql: "SELECT name FROM databases WHERE id = ?", arguments: [rec.databaseID]) {
                out.append((rec, row["name"]))
            }
        }
        return out
    }
}
