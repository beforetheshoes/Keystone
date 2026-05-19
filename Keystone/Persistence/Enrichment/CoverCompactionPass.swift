import Foundation
import GRDB
import OSLog
@preconcurrency import SQLiteData

private let log = Logger(subsystem: "Keystone", category: "CoverCompaction")

/// One-shot at-boot pass that re-encodes existing plaintext cover
/// images to HEIC at 800-px max. Same shape as the post-import flow —
/// the import path normalizes new covers, this pass cleans up the
/// pre-existing ones on first launch after the upgrade.
///
/// Guarded by `UserDefaults` flag `kCoverCompactionV1Done` so it runs
/// exactly once per device, regardless of how many cover assets are
/// already in normalized form. Idempotent independent of the flag —
/// it skips assets whose file_extension is already `heic`, encrypted
/// assets (we'd need decrypt/re-encrypt round-trip), and rows whose
/// file is missing on disk.
///
/// Runs **off the main actor** and updates `assets` rows one at a
/// time so progress accrues even if the pass is interrupted by a
/// crash or app quit.
enum CoverCompactionPass {
    private static let userDefaultsKey = "kCoverCompactionV1Done"

    /// True iff the boot-time pass has already finished on this device.
    static var hasRun: Bool {
        UserDefaults.standard.bool(forKey: userDefaultsKey)
    }

    static func markComplete() {
        UserDefaults.standard.set(true, forKey: userDefaultsKey)
    }

    /// Schedule the pass to run shortly after launch. Same delay /
    /// background-actor pattern as `EnrichmentService.start()` so the
    /// app's startup work stays uncontested. Callable from any actor;
    /// the work itself runs detached.
    static func start() {
        guard !hasRun else { return }
        Task.detached(priority: .utility) {
            // 10s after launch — let enrichment / sync settle first.
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await runOnce()
        }
    }

    /// Walk every cover asset, re-encode the eligible ones, update
    /// each row + delete the old file as soon as its replacement is
    /// safely written. Returns the count of assets compacted (for
    /// the test-side hooks; nothing in production reads it).
    @discardableResult
    static func runOnce() async -> Int {
        @Dependency(\.defaultDatabase) var database

        let candidates: [Candidate]
        do {
            candidates = try await database.read { db in
                try Candidate.fetch(db)
            }
        } catch {
            log.error("cover compaction: fetch candidates failed — \(error.localizedDescription, privacy: .public)")
            return 0
        }

        guard !candidates.isEmpty else {
            log.info("cover compaction: nothing to do")
            markComplete()
            return 0
        }
        log.info("cover compaction: \(candidates.count) candidate(s)")

        var compactedTotalBefore: Int64 = 0
        var compactedTotalAfter: Int64 = 0
        var compacted = 0
        for cand in candidates {
            let result = await compactOne(cand)
            switch result {
            case .skipped:
                continue
            case .failed(let why):
                log.error("cover compaction \(cand.assetID, privacy: .public): \(why, privacy: .public)")
            case let .ok(beforeBytes, afterBytes):
                compactedTotalBefore += Int64(beforeBytes)
                compactedTotalAfter += Int64(afterBytes)
                compacted += 1
            }
        }
        let savedKB = (compactedTotalBefore - compactedTotalAfter) / 1024
        log.info("cover compaction: compacted=\(compacted) saved=\(savedKB)KB")
        markComplete()
        return compacted
    }

    private enum Outcome {
        case ok(beforeBytes: Int, afterBytes: Int)
        case skipped
        case failed(String)
    }

    private static func compactOne(_ cand: Candidate) async -> Outcome {
        // Skip when nothing useful to do.
        if (cand.fileExtension ?? "").lowercased() == "heic" { return .skipped }
        if cand.isEncrypted { return .skipped }

        let absoluteURL = AppDatabase.absoluteURL(forRelativePath: cand.relativePath)
        guard FileManager.default.fileExists(atPath: absoluteURL.path) else {
            return .failed("file missing on disk: \(cand.relativePath)")
        }

        // Re-encode to a sibling file.
        guard let newURL = CoverImageReencoder.reencodeFile(at: absoluteURL) else {
            return .failed("re-encode failed")
        }
        guard let newSize = (try? newURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) else {
            try? FileManager.default.removeItem(at: newURL)
            return .failed("stat new file failed")
        }
        let beforeSize = (try? Int(absoluteURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)) ?? 0

        // Update the DB row, then delete the old file. Order matters:
        // if the DB write succeeds but the unlink doesn't, we've leaked
        // a stale file but the new file is canonical. If the DB write
        // fails, the new file is orphaned but the old one still works.
        @Dependency(\.defaultDatabase) var database
        let newRelative = relativePathSwappingExtension(cand.relativePath, to: "heic")
        do {
            try await database.write { db in
                try db.execute(
                    sql: """
                        UPDATE assets
                        SET relative_path = ?,
                            stored_filename = ?,
                            file_extension = 'heic',
                            mime_type = 'image/heic',
                            byte_size = ?,
                            updated_at = ?
                        WHERE id = ?
                    """,
                    arguments: [
                        newRelative,
                        newURL.lastPathComponent,
                        newSize,
                        AppDatabase.isoFormatter.string(from: Date()),
                        cand.assetID,
                    ]
                )
            }
        } catch {
            // Roll back the new file.
            try? FileManager.default.removeItem(at: newURL)
            return .failed("db update: \(error.localizedDescription)")
        }

        // Remove the now-orphaned source file. We don't fail the
        // compaction if cleanup fails — the DB is authoritative and
        // the asset table now points at the new file.
        if newURL.path != absoluteURL.path {
            try? FileManager.default.removeItem(at: absoluteURL)
        }

        // Bust the in-memory thumbnail cache so the gallery picks up
        // the smaller file on its next decode rather than serving the
        // cached large-source thumbnail. `invalidateAll` drops the
        // whole cache (NSCache has no enumeration API); cover
        // compaction is one-shot at boot, so warm-up cost is negligible.
        await ThumbnailDecoder.invalidateAll()

        return .ok(beforeBytes: beforeSize, afterBytes: newSize)
    }

    /// `Assets/Books/Foo-abc123/cover.jpg` → `Assets/Books/Foo-abc123/cover.heic`.
    /// Drops the original extension; reencodeFile already wrote the new
    /// `.heic` sibling under the same stem.
    private static func relativePathSwappingExtension(_ path: String, to ext: String) -> String {
        guard let dot = path.lastIndex(of: ".") else { return "\(path).\(ext)" }
        // Reject if the dot is part of a directory name (`.foo/bar`)
        // rather than the filename.
        if let slash = path.lastIndex(of: "/"), slash > dot { return "\(path).\(ext)" }
        return "\(path.prefix(upTo: dot)).\(ext)"
    }
}

private struct Candidate {
    let assetID: String
    let relativePath: String
    let fileExtension: String?
    let isEncrypted: Bool

    static func fetch(_ db: Database) throws -> [Candidate] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT a.id, a.relative_path, a.file_extension, a.is_encrypted
            FROM assets a
            WHERE a.id IN (
                SELECT cover_asset_id FROM records WHERE cover_asset_id IS NOT NULL
            )
            AND (a.mime_type LIKE 'image/%' OR a.file_extension IN ('jpg','jpeg','png','webp','heif'))
            AND (a.file_extension IS NULL OR LOWER(a.file_extension) != 'heic')
        """)
        return rows.map { row in
            Candidate(
                assetID: row["id"],
                relativePath: row["relative_path"],
                fileExtension: row["file_extension"],
                isEncrypted: (row["is_encrypted"] as Int? ?? 0) != 0
            )
        }
    }
}
