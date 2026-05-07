import Foundation
import GRDB
import CryptoKit
import OSLog

private let log = Logger(subsystem: "Keystone", category: "Inbox")

/// Stateless import logic invoked by `InboxWatcher` for each top-level
/// inbox entry. Split out so the watcher only deals with FS events.
enum InboxImporter {
    /// Result of an attempted import. `imported` means a new record was
    /// created (or in the bundle case, the markdown produced a record);
    /// `false` means everything was a content-hash duplicate and the
    /// source files were cleaned up without state change.
    struct Outcome {
        var imported: Bool
    }

    /// Import a Markdown / plain-text file. Frontmatter (if present and
    /// `type:` resolves to a known database id) routes the new record to
    /// that database and seeds matching property values. Otherwise the
    /// file falls back to the `documents` database. The markdown source
    /// file is always attached as an asset.
    static func importMarkdown(
        _ db: Database,
        url: URL,
        companion: URL? = nil
    ) throws -> Outcome {
        let data = try Data(contentsOf: url)
        let hashHex = sha256(data)

        // Dedup ONLY when the existing asset is still wired to a live
        // record. Plain "any asset row with this hash" is too aggressive —
        // CloudKit sync replicates `assets` rows independently of `records`,
        // so a row may exist locally pointing at a record_id that's NULL or
        // gone (an orphan), and treating those as duplicates means we
        // silently delete the user's re-import without ever creating a
        // record.
        if try assetHasLiveRecord(db, hashHex: hashHex) {
            try? FileManager.default.removeItem(at: url)
            if let companion { try? FileManager.default.removeItem(at: companion) }
            return Outcome(imported: false)
        }

        let source = String(data: data, encoding: .utf8) ?? ""
        let (frontmatter, body) = FrontmatterParser.parse(source)

        let databaseID = try resolveDatabaseID(db, requested: frontmatter?.type) ?? "documents"
        let title = frontmatter?.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? url.deletingPathExtension().lastPathComponent

        let record = try DBWrites.createRecord(db, databaseID: databaseID, title: title)
        log.notice("import md: \(url.lastPathComponent, privacy: .public) → \(databaseID, privacy: .public)/\(record.id, privacy: .public) title=\(title, privacy: .public)")

        // Apply each frontmatter field as a property value. Unknown keys
        // are no-ops because `updatePropertyValue` joins on (database_id,
        // key) — a missing match silently drops the value.
        for (key, value) in frontmatter?.fields ?? [:] {
            try DBWrites.updatePropertyValue(db, recordID: record.id, propertyKey: key, value: value)
        }

        // Convert the markdown body into a stream of editor blocks so the
        // record's NOTES section shows the transcribed content (not just
        // the attached source file). Empty body → no blocks.
        let parsedBlocks = MarkdownBlockConverter.parse(body)
        var lastBlockID: String? = nil
        for block in parsedBlocks {
            let inserted: BlockRow
            if block.kind == .table, let table = block.tableData {
                inserted = try DBWrites.createTableBlock(
                    db,
                    recordID: record.id,
                    after: lastBlockID,
                    table: table
                )
            } else {
                inserted = try DBWrites.createBlock(
                    db,
                    recordID: record.id,
                    after: lastBlockID,
                    kind: block.kind,
                    text: block.text,
                    checked: block.checked
                )
            }
            lastBlockID = inserted.id
        }

        // Always attach the markdown source itself.
        _ = try AssetImporter.importFile(db, fileURL: url, recordID: record.id, workspaceID: Seed.workspaceID)

        // Bundle companion: attach if its bytes aren't already in the
        // workspace. Companion never becomes the cover unless the markdown
        // provided no other context — keep it simple and always non-cover.
        if let companion {
            let companionData = try Data(contentsOf: companion)
            let companionHash = sha256(companionData)
            if try assetHasLiveRecord(db, hashHex: companionHash) {
                log.info("companion already in workspace, skipping attach: \(companion.lastPathComponent, privacy: .public)")
            } else {
                _ = try AssetImporter.importFile(db, fileURL: companion, recordID: record.id, workspaceID: Seed.workspaceID)
            }
        }

        try? FileManager.default.removeItem(at: url)
        if let companion { try? FileManager.default.removeItem(at: companion) }
        return Outcome(imported: true)
    }

    /// Import a non-markdown file as a Documents record with the file as
    /// cover (if image) or attached asset (otherwise). Same behavior the
    /// inbox has shipped with — extracted here so the watcher's scan loop
    /// can route both cases through one code path.
    static func importOpaque(_ db: Database, url: URL) throws -> Outcome {
        let data = try Data(contentsOf: url)
        let hashHex = sha256(data)
        if try assetHasLiveRecord(db, hashHex: hashHex) {
            try? FileManager.default.removeItem(at: url)
            return Outcome(imported: false)
        }

        let docsExists = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM databases WHERE id = 'documents'") ?? 0) > 0
        guard docsExists else { return Outcome(imported: false) }

        let originalFilename = url.lastPathComponent
        let titleBase = url.deletingPathExtension().lastPathComponent

        let record = try DBWrites.createRecord(db, databaseID: "documents", title: titleBase)
        let asset = try AssetImporter.importFile(db, fileURL: url, recordID: record.id, workspaceID: Seed.workspaceID)

        if let mime = asset.mimeType, mime.hasPrefix("image/") {
            try DBWrites.setRecordCover(db, recordID: record.id, assetID: asset.id)
        } else {
            try DBWrites.updatePropertyValue(db, recordID: record.id, propertyKey: "kind", value: originalFilename)
        }

        try? FileManager.default.removeItem(at: url)
        return Outcome(imported: true)
    }

    // MARK: - Helpers

    /// Resolves a frontmatter `type:` value to a database id. Per the
    /// product spec we only accept exact (case-insensitive) matches
    /// against the `databases.id` column — no name/plural fallback —
    /// so users always know which value to write.
    private static func resolveDatabaseID(_ db: Database, requested: String?) throws -> String? {
        guard let requested, !requested.isEmpty else { return nil }
        let lowered = requested.lowercased()
        return try String.fetchOne(
            db,
            sql: "SELECT id FROM databases WHERE LOWER(id) = ? LIMIT 1",
            arguments: [lowered]
        )
    }

    /// True only when an existing asset with this content hash is currently
    /// attached to a non-deleted record. Orphaned asset rows (record_id NULL
    /// or pointing at a record that no longer exists) are *not* treated as
    /// duplicates — those are typically debris from CloudKit row-sync that
    /// arrived ahead of (or after the deletion of) their parent record, and
    /// blocking re-imports because of them locks the user out of their own
    /// content.
    private static func assetHasLiveRecord(_ db: Database, hashHex: String) throws -> Bool {
        let id = try String.fetchOne(
            db,
            sql: """
                SELECT a.id FROM assets a
                JOIN records r ON r.id = a.record_id
                WHERE a.content_hash = ? AND r.deleted_at IS NULL
                LIMIT 1
            """,
            arguments: [hashHex]
        )
        return id != nil
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
