import Foundation
import GRDB
import OSLog
@preconcurrency import SQLiteData

private let log = Logger(subsystem: "Keystone", category: "Enrichment.CoverImage")

/// Downloads an image URL to a temp file, then hands it to
/// `DBWrites.importCoverImage` so it's content-hashed, copied into Assets/,
/// and promoted to the record's cover. Best-effort: a failed download or
/// import logs and returns silently — the rest of the enrichment apply
/// (property updates) still lands.
enum CoverImageImporter {
    static func attachAsCover(_ url: URL, to recordID: String) async {
        @Dependency(\.defaultDatabase) var database

        // Download into memory, re-encode to a normalized 800-px HEIC
        // before writing to a temp file. The re-encode keeps disk usage
        // bounded (saves ~70% per cover) and ensures every cover decodes
        // through the same fast path. Falls back to the raw bytes when
        // re-encoding isn't possible (unsupported source format or HEIC
        // not available on the device).
        let payload: (data: Data, ext: String)
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                log.error("cover download \(url.absoluteString, privacy: .public): status \(http.statusCode)")
                return
            }
            if let encoded = CoverImageReencoder.reencode(data) {
                payload = (encoded.data, encoded.fileExtension)
            } else {
                let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
                payload = (data, ext)
            }
        } catch {
            log.error("cover download \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kst-cover-\(UUID().uuidString).\(payload.ext)")
        do {
            try payload.data.write(to: tempURL)
        } catch {
            log.error("cover tempwrite \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            try await database.write { db in
                guard let workspaceID = try String.fetchOne(
                    db,
                    sql: "SELECT id FROM workspaces ORDER BY created_at LIMIT 1"
                ) else { return }
                _ = try DBWrites.importCoverImage(
                    db,
                    fileURL: tempURL,
                    recordID: recordID,
                    workspaceID: workspaceID
                )
            }
        } catch {
            log.error("cover import for \(recordID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
