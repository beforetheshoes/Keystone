import XCTest
import Dependencies
import GRDB
@testable import Keystone

/// Coverage for the Settings → Attachments read layer:
///
///   1. `AssetReads.stats` buckets every asset into exactly one of
///      image / pdf / document / other (and counts encrypted ones)
///      based on the `mime_type` CASE expression.
///   2. `AssetReads.search` matches filenames for every row and
///      `extracted_text` only for rows where `is_encrypted = 0` —
///      so a phrase that lives only inside a protected attachment's
///      OCR column never leaks via the global Settings search.
final class AssetSearchAndStatsTests: XCTestCase {

    private func withDB<T>(_ body: () throws -> T) rethrows -> T {
        try withHermeticDB(body)
    }

    /// Insert a synthetic asset row with full control over mime, ext,
    /// size, encryption flag, and extracted_text. Doesn't touch the
    /// filesystem — these tests exercise SQL only.
    @discardableResult
    private func insertAsset(
        _ db: Database,
        id: String? = nil,
        filename: String,
        mime: String?,
        ext: String?,
        size: Int64,
        encrypted: Bool = false,
        extractedText: String? = nil
    ) throws -> String {
        let assetID = id ?? UUID().uuidString
        let now = AppDatabase.isoFormatter.string(from: Date())
        try db.execute(
            sql: """
                INSERT INTO assets (
                    id, workspace_id, record_id,
                    original_filename, stored_filename, relative_path,
                    mime_type, file_extension, byte_size, content_hash,
                    extracted_text, metadata_json, is_encrypted,
                    created_at, updated_at
                ) VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, NULL, ?, '{}', ?, ?, ?)
            """,
            arguments: [
                assetID, Seed.workspaceID,
                filename, filename, "Assets/test/\(filename)",
                mime, ext, size,
                extractedText,
                encrypted ? 1 : 0,
                now, now,
            ]
        )
        return assetID
    }

    // MARK: - stats

    func testAssetStatsBucketsByMimeAndCountsEncrypted() throws {
        try withDB {
            @Dependency(\.defaultDatabase) var database
            try database.write { db in
                try insertAsset(db, filename: "photo.jpg",  mime: "image/jpeg", ext: "jpg",  size: 100)
                try insertAsset(db, filename: "shot.heic",  mime: "image/heic", ext: "heic", size: 200)
                try insertAsset(db, filename: "manual.pdf", mime: "application/pdf", ext: "pdf", size: 1_000)
                try insertAsset(db, filename: "notes.md",   mime: "text/markdown", ext: "md",  size: 50)
                try insertAsset(db, filename: "report.docx",
                                mime: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                                ext: "docx", size: 5_000)
                // No mime → "other" bucket.
                try insertAsset(db, filename: "blob.bin", mime: nil, ext: "bin", size: 10)
                // One of the images is encrypted to exercise the count.
                try insertAsset(db, filename: "secret.jpg", mime: "image/jpeg", ext: "jpg", size: 300, encrypted: true)
            }

            try database.read { db in
                let stats = try AssetReads.stats(db, workspaceID: Seed.workspaceID)
                XCTAssertEqual(stats.totalCount, 7)
                XCTAssertEqual(stats.totalBytes, 100 + 200 + 1_000 + 50 + 5_000 + 10 + 300)
                XCTAssertEqual(stats.imageCount, 3, "image/jpeg + image/heic + the encrypted jpeg")
                XCTAssertEqual(stats.pdfCount, 1)
                XCTAssertEqual(stats.documentCount, 2, "text/markdown + officedocument.wordprocessingml")
                XCTAssertEqual(stats.otherCount, 1, "NULL-mime row falls through to 'other'")
                XCTAssertEqual(stats.encryptedCount, 1)
            }
        }
    }

    func testAssetStatsEmptyWorkspaceReportsZeros() throws {
        try withDB {
            @Dependency(\.defaultDatabase) var database
            try database.read { db in
                let stats = try AssetReads.stats(db, workspaceID: Seed.workspaceID)
                XCTAssertEqual(stats.totalCount, 0)
                XCTAssertEqual(stats.totalBytes, 0)
                XCTAssertEqual(stats.imageCount, 0)
                XCTAssertEqual(stats.pdfCount, 0)
                XCTAssertEqual(stats.documentCount, 0)
                XCTAssertEqual(stats.otherCount, 0)
                XCTAssertEqual(stats.encryptedCount, 0)
            }
        }
    }

    // MARK: - search

    func testSearchMatchesFilenameSubstring() throws {
        try withDB {
            @Dependency(\.defaultDatabase) var database
            try database.write { db in
                try insertAsset(db, filename: "Costco-receipt-2024.pdf", mime: "application/pdf", ext: "pdf", size: 1)
                try insertAsset(db, filename: "trader-joes.pdf",         mime: "application/pdf", ext: "pdf", size: 1)
            }
            try database.read { db in
                let hits = try AssetReads.search(db, workspaceID: Seed.workspaceID, query: "costco", typeFilter: .all)
                XCTAssertEqual(hits.count, 1)
                XCTAssertEqual(hits.first?.originalFilename, "Costco-receipt-2024.pdf")
            }
        }
    }

    func testSearchMatchesExtractedTextOnlyForUnencryptedRows() throws {
        // Both assets share an OCR'd phrase. Only the unencrypted one
        // should surface when the user searches by phrase. The encrypted
        // one must still be findable by filename.
        try withDB {
            @Dependency(\.defaultDatabase) var database
            try database.write { db in
                try insertAsset(
                    db,
                    filename: "open-receipt.pdf",
                    mime: "application/pdf", ext: "pdf",
                    size: 100, encrypted: false,
                    extractedText: "Total billed at Wally's Diner on Tuesday"
                )
                try insertAsset(
                    db,
                    filename: "private-receipt.pdf",
                    mime: "application/pdf", ext: "pdf",
                    size: 100, encrypted: true,
                    extractedText: "Total billed at Wally's Diner on Tuesday"
                )
            }
            try database.read { db in
                let phraseHits = try AssetReads.search(
                    db, workspaceID: Seed.workspaceID,
                    query: "Wally's Diner", typeFilter: .all
                )
                XCTAssertEqual(phraseHits.count, 1, "phrase-only search must skip encrypted rows")
                XCTAssertEqual(phraseHits.first?.originalFilename, "open-receipt.pdf")
                XCTAssertNotNil(phraseHits.first?.snippet)

                let nameHits = try AssetReads.search(
                    db, workspaceID: Seed.workspaceID,
                    query: "private-receipt", typeFilter: .all
                )
                XCTAssertEqual(nameHits.count, 1)
                XCTAssertEqual(nameHits.first?.originalFilename, "private-receipt.pdf")
                XCTAssertTrue(nameHits.first?.isEncrypted == true)
                XCTAssertNil(nameHits.first?.snippet, "encrypted hit should never carry an OCR snippet")
            }
        }
    }

    func testSearchHonorsTypeFilter() throws {
        try withDB {
            @Dependency(\.defaultDatabase) var database
            try database.write { db in
                try insertAsset(db, filename: "trip-photo.jpg",  mime: "image/jpeg",       ext: "jpg",  size: 1)
                try insertAsset(db, filename: "trip-manual.pdf", mime: "application/pdf",  ext: "pdf",  size: 1)
                try insertAsset(db, filename: "trip-notes.md",   mime: "text/markdown",    ext: "md",   size: 1)
            }
            try database.read { db in
                let imagesOnly = try AssetReads.search(
                    db, workspaceID: Seed.workspaceID,
                    query: "trip", typeFilter: .images
                )
                XCTAssertEqual(imagesOnly.map(\.originalFilename), ["trip-photo.jpg"])

                let pdfsOnly = try AssetReads.search(
                    db, workspaceID: Seed.workspaceID,
                    query: "trip", typeFilter: .pdfs
                )
                XCTAssertEqual(pdfsOnly.map(\.originalFilename), ["trip-manual.pdf"])

                let docsOnly = try AssetReads.search(
                    db, workspaceID: Seed.workspaceID,
                    query: "trip", typeFilter: .documents
                )
                XCTAssertEqual(docsOnly.map(\.originalFilename), ["trip-notes.md"])
            }
        }
    }

    func testSearchEmptyQueryReturnsNothing() throws {
        try withDB {
            @Dependency(\.defaultDatabase) var database
            try database.write { db -> Void in
                try insertAsset(db, filename: "anything.pdf", mime: "application/pdf", ext: "pdf", size: 1)
            }
            try database.read { db in
                let hits = try AssetReads.search(
                    db, workspaceID: Seed.workspaceID,
                    query: "   ", typeFilter: .all
                )
                XCTAssertTrue(hits.isEmpty, "whitespace-only query must short-circuit, not match every row")
            }
        }
    }

    func testSearchEscapesLikeWildcards() throws {
        // A literal underscore in a query must not behave as a single-
        // char SQL LIKE wildcard. Without ESCAPE handling, "a_b" would
        // also match "axb"; with it, only the literal "a_b" matches.
        try withDB {
            @Dependency(\.defaultDatabase) var database
            try database.write { db in
                try insertAsset(db, filename: "alpha_beta.pdf", mime: "application/pdf", ext: "pdf", size: 1)
                try insertAsset(db, filename: "alphaXbeta.pdf", mime: "application/pdf", ext: "pdf", size: 1)
            }
            try database.read { db in
                let hits = try AssetReads.search(
                    db, workspaceID: Seed.workspaceID,
                    query: "alpha_beta", typeFilter: .all
                )
                XCTAssertEqual(hits.map(\.originalFilename), ["alpha_beta.pdf"])
            }
        }
    }
}

#if canImport(AppKit)
/// Coverage for the Quick Look defensive preflight. We don't open
/// `QLPreviewPanel` in tests — only assert the pure-state machine in
/// `QuickLookManager.preflight` so the test runs headless.
final class QuickLookPreflightTests: XCTestCase {

    func testPreflightOnExistingNonEmptyFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ks-preflight-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(QuickLookManager.preflight(url), .ok)
    }

    func testPreflightOnMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ks-preflight-missing-\(UUID().uuidString).txt")
        XCTAssertEqual(QuickLookManager.preflight(url), .missing(.notOnDisk))
    }

    func testPreflightOnEmptyFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ks-preflight-empty-\(UUID().uuidString).txt")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(QuickLookManager.preflight(url), .missing(.empty))
    }
}
#endif
