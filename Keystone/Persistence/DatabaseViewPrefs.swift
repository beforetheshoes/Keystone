import Foundation
import GRDB

/// Per-database view ergonomics — sort, group, filters, gallery cover
/// size. Stored locally in `database_view_prefs` and *not* synced
/// through CloudKit (see migration v42 comment for why).
struct DatabaseViewPrefs: Equatable, Sendable {
    var sortKey: String?
    var sortAscending: Bool
    var groupKey: String?
    var galleryCoverSize: GalleryCoverSize
    var filters: [Filter]
    /// Property keys the user has hidden from the table view's
    /// columns. The detail view still shows every property; this is a
    /// purely visual filter for at-a-glance scanning in the table.
    var hiddenColumns: Set<String>

    static let `default` = DatabaseViewPrefs(
        sortKey: nil,
        sortAscending: true,
        groupKey: nil,
        galleryCoverSize: .medium,
        filters: [],
        hiddenColumns: []
    )
}

/// Cover-size preset for the gallery view. The raw value lands in
/// `database_view_prefs.gallery_cover_size` so it persists; the pixel
/// width per column is resolved on read.
enum GalleryCoverSize: String, Codable, Sendable, CaseIterable {
    case small, medium, large

    /// Minimum width used by `GridItem(.adaptive(minimum:))`. Higher
    /// values mean fewer, larger cards per row.
    var minimumColumnWidth: CGFloat {
        switch self {
        case .small:  return 140
        case .medium: return 220
        case .large:  return 320
        }
    }
}

enum DatabaseViewPrefsReads {
    static func load(_ db: Database, databaseID: String) throws -> DatabaseViewPrefs {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT sort_key, sort_ascending, group_key, gallery_cover_size,
                       filters_json, hidden_columns_json
                FROM database_view_prefs
                WHERE database_id = ?
            """,
            arguments: [databaseID]
        ) else {
            return .default
        }
        let sortKey: String? = row["sort_key"]
        let sortAscending: Bool = (row["sort_ascending"] as Int? ?? 1) != 0
        let groupKey: String? = row["group_key"]
        let sizeRaw: String = row["gallery_cover_size"] ?? "medium"
        let size = GalleryCoverSize(rawValue: sizeRaw) ?? .medium
        let filtersJSON: String = row["filters_json"] ?? "[]"
        let filters = decodeFilters(filtersJSON)
        let hiddenJSON: String = row["hidden_columns_json"] ?? "[]"
        let hidden = decodeHiddenColumns(hiddenJSON)
        return DatabaseViewPrefs(
            sortKey: sortKey,
            sortAscending: sortAscending,
            groupKey: groupKey,
            galleryCoverSize: size,
            filters: filters,
            hiddenColumns: hidden
        )
    }

    private static func decodeFilters(_ json: String) -> [Filter] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Filter].self, from: data)) ?? []
    }

    private static func decodeHiddenColumns(_ json: String) -> Set<String> {
        guard let data = json.data(using: .utf8) else { return [] }
        let list = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        return Set(list)
    }
}

enum DatabaseViewPrefsWrites {
    static func save(_ db: Database, databaseID: String, prefs: DatabaseViewPrefs) throws {
        let filtersJSON = encodeFilters(prefs.filters)
        let hiddenJSON = encodeHiddenColumns(prefs.hiddenColumns)
        try db.execute(
            sql: """
                INSERT INTO database_view_prefs
                    (database_id, sort_key, sort_ascending, group_key,
                     gallery_cover_size, filters_json, hidden_columns_json, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ','now'))
                ON CONFLICT(database_id) DO UPDATE SET
                    sort_key = excluded.sort_key,
                    sort_ascending = excluded.sort_ascending,
                    group_key = excluded.group_key,
                    gallery_cover_size = excluded.gallery_cover_size,
                    filters_json = excluded.filters_json,
                    hidden_columns_json = excluded.hidden_columns_json,
                    updated_at = excluded.updated_at
            """,
            arguments: [
                databaseID,
                prefs.sortKey,
                prefs.sortAscending ? 1 : 0,
                prefs.groupKey,
                prefs.galleryCoverSize.rawValue,
                filtersJSON,
                hiddenJSON,
            ]
        )
    }

    private static func encodeFilters(_ filters: [Filter]) -> String {
        guard let data = try? JSONEncoder().encode(filters),
              let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
    }

    private static func encodeHiddenColumns(_ hidden: Set<String>) -> String {
        guard let data = try? JSONEncoder().encode(Array(hidden).sorted()),
              let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
    }
}
