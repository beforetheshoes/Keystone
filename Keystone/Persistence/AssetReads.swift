import Foundation
import GRDB

struct AssetRecord: Equatable, Sendable, Identifiable {
    let id: String
    let recordID: String?
    let originalFilename: String
    let storedFilename: String
    let relativePath: String
    let mimeType: String?
    let fileExtension: String?
    let byteSize: Int64?
    let contentHash: String?
    let createdAt: String
    /// True when the file at `relativePath` contains AES-GCM ciphertext
    /// rather than the original bytes. Open/Quick Look paths must
    /// decrypt to a temp file before handing the URL to NSWorkspace.
    let isEncrypted: Bool

    var absoluteURL: URL {
        AppDatabase.absoluteURL(forRelativePath: relativePath)
    }
}

/// Coarse type buckets for the Settings → Attachments panel. These
/// map onto MIME prefixes (not file extensions) so `image/jpeg` and
/// `image/heic` stay together, and `application/vnd.openxmlformats-…`
/// rolls into "documents" without enumerating every Office subtype.
enum AssetTypeFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case images
    case pdfs
    case documents
    case other
}

/// Aggregate counts + total bytes for the workspace, broken down by
/// the same MIME buckets as `AssetTypeFilter`. Single SQL roundtrip.
struct AssetStats: Equatable, Sendable {
    var totalCount: Int
    var totalBytes: Int64
    var imageCount: Int
    var pdfCount: Int
    var documentCount: Int
    var otherCount: Int
    var encryptedCount: Int

    static let empty = AssetStats(
        totalCount: 0, totalBytes: 0,
        imageCount: 0, pdfCount: 0, documentCount: 0, otherCount: 0,
        encryptedCount: 0
    )
}

/// Single hit returned by `AssetReads.search`. `snippet` is populated
/// in Swift after fetch by locating the query inside `extractedText`
/// — never set for encrypted rows even if their extracted_text column
/// happens to contain the phrase.
struct AssetSearchHit: Equatable, Sendable, Identifiable {
    let id: String
    let recordID: String?
    let originalFilename: String
    let mimeType: String?
    let fileExtension: String?
    let byteSize: Int64?
    let createdAt: String
    let isEncrypted: Bool
    let snippet: String?
}

enum AssetReads {
    static func assets(_ db: Database, recordID: String) throws -> [AssetRecord] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, record_id, original_filename, stored_filename, relative_path,
                   mime_type, file_extension, byte_size, content_hash, created_at, is_encrypted
            FROM assets
            WHERE record_id = ?
            ORDER BY created_at DESC
        """, arguments: [recordID])
        return rows.map(rowToAsset)
    }

    static func asset(_ db: Database, id: String) throws -> AssetRecord? {
        try Row.fetchOne(db, sql: """
            SELECT id, record_id, original_filename, stored_filename, relative_path,
                   mime_type, file_extension, byte_size, content_hash, created_at, is_encrypted
            FROM assets WHERE id = ?
        """, arguments: [id]).map(rowToAsset)
    }

    // MARK: - Settings → Attachments panel

    /// MIME-bucket CASE expression reused by `stats` and the search
    /// type-filter clause. Returns one of `image | pdf | document | other`.
    /// `application/vnd.openxmlformats-officedocument.*` covers .docx /
    /// .xlsx / .pptx; legacy `application/msword` covers .doc; `text/*`
    /// covers .txt / .md / .csv / etc.
    private static let mimeBucketCase = """
        CASE
            WHEN mime_type LIKE 'image/%' THEN 'image'
            WHEN mime_type = 'application/pdf' THEN 'pdf'
            WHEN mime_type LIKE 'text/%'
              OR mime_type = 'application/msword'
              OR mime_type LIKE 'application/vnd.openxmlformats-officedocument.%'
              OR mime_type = 'application/rtf'
              THEN 'document'
            ELSE 'other'
        END
    """

    static func stats(_ db: Database, workspaceID: String) throws -> AssetStats {
        let row = try Row.fetchOne(db, sql: """
            SELECT
                COUNT(*)                                    AS total_count,
                COALESCE(SUM(byte_size), 0)                 AS total_bytes,
                SUM(CASE WHEN \(mimeBucketCase) = 'image'    THEN 1 ELSE 0 END) AS image_count,
                SUM(CASE WHEN \(mimeBucketCase) = 'pdf'      THEN 1 ELSE 0 END) AS pdf_count,
                SUM(CASE WHEN \(mimeBucketCase) = 'document' THEN 1 ELSE 0 END) AS document_count,
                SUM(CASE WHEN \(mimeBucketCase) = 'other'    THEN 1 ELSE 0 END) AS other_count,
                SUM(CASE WHEN is_encrypted = 1               THEN 1 ELSE 0 END) AS encrypted_count
            FROM assets
            WHERE workspace_id = ?
        """, arguments: [workspaceID])
        guard let row else { return .empty }
        return AssetStats(
            totalCount: row["total_count"] ?? 0,
            totalBytes: row["total_bytes"] ?? 0,
            imageCount: row["image_count"] ?? 0,
            pdfCount: row["pdf_count"] ?? 0,
            documentCount: row["document_count"] ?? 0,
            otherCount: row["other_count"] ?? 0,
            encryptedCount: row["encrypted_count"] ?? 0
        )
    }

    /// Match `original_filename` (LIKE %query%) for every row, plus
    /// `extracted_text` (LIKE %query%) only for rows where
    /// `is_encrypted = 0`. Protected records have plaintext OCR on
    /// disk today, but surfacing that in the global Settings search
    /// would defeat the lock UX — so we gate the OCR-side match.
    /// Filename match still wins for encrypted rows.
    static func search(
        _ db: Database,
        workspaceID: String,
        query: String,
        typeFilter: AssetTypeFilter,
        limit: Int = 200
    ) throws -> [AssetSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let likePattern = "%\(escapedLike(trimmed))%"

        var sql = """
            SELECT id, record_id, original_filename, mime_type, file_extension,
                   byte_size, extracted_text, created_at, is_encrypted
            FROM assets
            WHERE workspace_id = ?
              AND (
                  original_filename LIKE ? ESCAPE '\\'
                  OR (is_encrypted = 0 AND extracted_text LIKE ? ESCAPE '\\')
              )
            """
        var args: [DatabaseValueConvertible] = [workspaceID, likePattern, likePattern]

        switch typeFilter {
        case .all:
            break
        case .images:
            sql += "  AND \(mimeBucketCase) = 'image'\n"
        case .pdfs:
            sql += "  AND \(mimeBucketCase) = 'pdf'\n"
        case .documents:
            sql += "  AND \(mimeBucketCase) = 'document'\n"
        case .other:
            sql += "  AND \(mimeBucketCase) = 'other'\n"
        }

        sql += "ORDER BY created_at DESC\nLIMIT ?\n"
        args.append(Int64(limit))

        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        return rows.map { row in
            let isEnc = (row["is_encrypted"] as Int?) == 1
            let extracted: String? = row["extracted_text"]
            // Only surface a snippet when the OCR text was eligible
            // for the search in the first place — i.e. the row is
            // unencrypted. Encrypted rows are matched by filename
            // only, so they never carry a snippet.
            let snippet = isEnc ? nil : snippet(in: extracted, around: trimmed)
            return AssetSearchHit(
                id: row["id"],
                recordID: row["record_id"],
                originalFilename: row["original_filename"],
                mimeType: row["mime_type"],
                fileExtension: row["file_extension"],
                byteSize: row["byte_size"],
                createdAt: row["created_at"],
                isEncrypted: isEnc,
                snippet: snippet
            )
        }
    }

    /// Escape `%`, `_`, and `\` in a user-provided LIKE term so a
    /// literal underscore in a filename doesn't behave as a single-
    /// char wildcard. Pairs with `ESCAPE '\\'` in the SQL above.
    private static func escapedLike(_ term: String) -> String {
        var out = ""
        out.reserveCapacity(term.count)
        for ch in term {
            if ch == "\\" || ch == "%" || ch == "_" { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// ~120-char window centred on the first case-insensitive match
    /// of `term` in `text`. Whitespace runs collapsed; truncation
    /// markers ("…") added when we trimmed either side.
    private static func snippet(in text: String?, around term: String) -> String? {
        guard let text, !text.isEmpty else { return nil }
        guard let range = text.range(of: term, options: .caseInsensitive) else { return nil }
        let radius = 60
        let totalCount = text.count
        let beforeMatch = text.distance(from: text.startIndex, to: range.lowerBound)
        let matchLen    = text.distance(from: range.lowerBound, to: range.upperBound)
        let afterMatch  = totalCount - beforeMatch - matchLen

        let lowerOffset = max(0, beforeMatch - radius)
        let upperOffset = min(totalCount, beforeMatch + matchLen + radius)
        let lower = text.index(text.startIndex, offsetBy: lowerOffset)
        let upper = text.index(text.startIndex, offsetBy: upperOffset)

        var slice = String(text[lower..<upper])
        slice = slice.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if lowerOffset > 0 { slice = "…" + slice }
        if afterMatch > radius { slice = slice + "…" }
        return slice
    }

    private static func rowToAsset(_ row: Row) -> AssetRecord {
        AssetRecord(
            id: row["id"],
            recordID: row["record_id"],
            originalFilename: row["original_filename"],
            storedFilename: row["stored_filename"],
            relativePath: row["relative_path"],
            mimeType: row["mime_type"],
            fileExtension: row["file_extension"],
            byteSize: row["byte_size"],
            contentHash: row["content_hash"],
            createdAt: row["created_at"],
            isEncrypted: (row["is_encrypted"] as Int?) == 1
        )
    }
}
