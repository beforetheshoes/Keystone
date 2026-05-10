import XCTest
import Dependencies
import GRDB
@testable import Keystone

/// `records.database_id` lost its FK in v36 (so records can become
/// CKShare roots), which means deleting a `databases` row no longer
/// auto-cascades to its records via SQL. `DBWrites.deleteDatabaseAndChildren`
/// re-implements the cascade at the application layer.
final class CascadeReplacementTests: XCTestCase {

    func testDeleteDatabaseAndChildrenRemovesEverything() throws {
        try withHermeticDB {
            @Dependency(\.defaultDatabase) var db
            let dbClient = DatabaseClient.liveValue

            // Set up a brand-new throwaway database with one record so
            // we can delete the whole thing without disturbing the
            // user-facing seeded databases.
            let dbID = "test_throwaway"
            try db.write { d in
                try d.execute(sql: """
                    INSERT OR IGNORE INTO databases
                    (id, workspace_id, area_id, name, plural_name, icon, accent, default_view, sort_index, created_at, updated_at)
                    VALUES
                    (?, ?, NULL, ?, ?, ?, 'graphite', 'table', 99, ?, ?)
                """, arguments: [
                    dbID, Seed.workspaceID, "Throwaway", "Throwaways", "T",
                    AppDatabase.isoFormatter.string(from: Date()),
                    AppDatabase.isoFormatter.string(from: Date())
                ])
            }
            let r = try dbClient.createRecord(dbID, "Sentinel")

            // Sanity check: the row exists.
            XCTAssertNotNil(try dbClient.record(r.id))

            try db.write { d in
                _ = try DBWrites.deleteDatabaseAndChildren(d, databaseID: dbID)
            }

            // Database row gone.
            let dbRow: Row? = try db.read { d in
                try Row.fetchOne(d, sql: "SELECT id FROM databases WHERE id = ?", arguments: [dbID])
            }
            XCTAssertNil(dbRow)

            // Records gone.
            let recRow: Row? = try db.read { d in
                try Row.fetchOne(d, sql: "SELECT id FROM records WHERE id = ?", arguments: [r.id])
            }
            XCTAssertNil(recRow)
        }
    }

    /// Plain `DELETE FROM databases` (without the helper) leaves
    /// records orphaned because v36 dropped the FK. This test pins
    /// the behavior so callers never assume the old cascade still
    /// works.
    func testRawDatabaseDeleteOrphansRecords() throws {
        try withHermeticDB {
            @Dependency(\.defaultDatabase) var db
            let dbClient = DatabaseClient.liveValue

            let dbID = "orphan_target"
            try db.write { d in
                try d.execute(sql: """
                    INSERT OR IGNORE INTO databases
                    (id, workspace_id, area_id, name, plural_name, icon, accent, default_view, sort_index, created_at, updated_at)
                    VALUES
                    (?, ?, NULL, ?, ?, ?, 'graphite', 'table', 99, ?, ?)
                """, arguments: [
                    dbID, Seed.workspaceID, "Orphan target", "Orphans", "O",
                    AppDatabase.isoFormatter.string(from: Date()),
                    AppDatabase.isoFormatter.string(from: Date())
                ])
            }
            let r = try dbClient.createRecord(dbID, "Sentinel")

            try db.write { d in
                try d.execute(sql: "DELETE FROM databases WHERE id = ?", arguments: [dbID])
            }

            // Record still exists post-raw-delete — orphaned, but
            // the row hasn't been swept. This is the property the
            // cascade-replacement test pins.
            let recRow: Row? = try db.read { d in
                try Row.fetchOne(d, sql: "SELECT id FROM records WHERE id = ?", arguments: [r.id])
            }
            XCTAssertNotNil(recRow, "record should be orphaned (FK was dropped in v36)")
        }
    }
}
