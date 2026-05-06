import Foundation
import GRDB
import CryptoKit
import OSLog
@preconcurrency import SQLiteData

private let log = Logger(subsystem: "Keystone", category: "Inbox")

/// Watches `<workspaceFolder>/Inbox/` and auto-imports any file dropped in
/// there as a new record in the **Documents** database with the original
/// file attached as its cover. Lets users add records by saving / drag-and
/// dropping into a regular Finder folder (or the iCloud Drive folder on
/// any device) without ever opening the app.
///
/// Lifecycle:
/// - `start(onImport:)` opens an `O_EVTONLY` file descriptor on the Inbox
///   directory and watches `.write` events. Initial scan runs immediately
///   so anything already there at launch gets imported.
/// - Events are debounced 500 ms so a multi-file drop coalesces into one
///   scan instead of one-per-file thrash.
/// - `onImport` fires on the main actor whenever at least one file was
///   imported, so the UI can refresh the sidebar / current records list.
final class InboxWatcher: @unchecked Sendable {
    static let shared = InboxWatcher()

    private let lock = NSLock()
    private var fileDescriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?
    private var debounceTask: Task<Void, Never>?
    private var onImport: (@MainActor () -> Void)?
    private let scanQueue = DispatchQueue(label: "com.ryanleewilliams.keystone.inbox-scan", qos: .utility)

    private init() {}

    func start(onImport: @escaping @MainActor () -> Void) {
        lock.lock()
        self.onImport = onImport
        if let existing = source {
            existing.cancel()
            source = nil
        }
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        lock.unlock()

        let inbox = Self.ensureInboxFolder()
        log.info("InboxWatcher.start watching \(inbox.path, privacy: .public)")
        Task.detached { [weak self] in
            await self?.scan(inbox: inbox)
        }
        attachWatcher(inbox: inbox)
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        source?.cancel()
        source = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        debounceTask?.cancel()
        debounceTask = nil
    }

    // MARK: - Folder bootstrap

    @discardableResult
    static func ensureInboxFolder() -> URL {
        let inbox = AppDatabase.workspaceFolder.appendingPathComponent("Inbox", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: inbox.path) {
            try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        }
        let readme = inbox.appendingPathComponent("README.md")
        if !fm.fileExists(atPath: readme.path) {
            let body = """
            # Inbox

            Drop any file into this folder — Keystone will pick it up the next time it's running and create a new entry in your **Documents** database with this file attached as the cover. The original then disappears from this Inbox once it's been imported.

            Works the same way on every device: save a PDF or photo into this folder from your iPhone's Files app, and it'll show up as a new Document on every Mac signed into the same Apple ID.

            **Don't move `workspace.sqlite` or anything in `Assets/` here** — those are managed by the app.
            """
            try? body.data(using: .utf8)?.write(to: readme)
        }
        return inbox
    }

    // MARK: - FSEvents wiring

    private func attachWatcher(inbox: URL) {
        let fd = open(inbox.path, O_EVTONLY)
        guard fd >= 0 else { return }

        lock.lock()
        fileDescriptor = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename],
            queue: scanQueue
        )
        src.setEventHandler { [weak self] in
            self?.scheduleDebouncedScan(inbox: inbox)
        }
        src.setCancelHandler { [weak self] in
            self?.lock.lock()
            if let cur = self?.fileDescriptor, cur >= 0 {
                close(cur)
                self?.fileDescriptor = -1
            }
            self?.lock.unlock()
        }
        source = src
        lock.unlock()
        src.resume()
    }

    private func scheduleDebouncedScan(inbox: URL) {
        lock.lock()
        debounceTask?.cancel()
        debounceTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self?.scan(inbox: inbox)
        }
        lock.unlock()
    }

    // MARK: - Scan + import

    private func scan(inbox: URL) async {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .nameKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            log.info("scan: folder not readable")
            return
        }

        log.info("scan: \(items.count, privacy: .public) item(s) in inbox")
        var importedAny = false
        var skippedFresh = false
        for url in items {
            // Skip non-files, our own README, and anything that looks like
            // an iCloud placeholder (extension `.icloud` for files not yet
            // downloaded — the FS event will fire again once the bytes
            // arrive locally).
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isFile else {
                log.info("skip non-file \(url.lastPathComponent, privacy: .public)")
                continue
            }
            if url.lastPathComponent == "README.md" { continue }
            if url.pathExtension == "icloud" {
                log.info("skip iCloud placeholder \(url.lastPathComponent, privacy: .public)")
                continue
            }

            if let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])).flatMap(\.contentModificationDate) {
                if Date().timeIntervalSince(mtime) < 2.0 {
                    log.info("skip too-fresh \(url.lastPathComponent, privacy: .public)")
                    skippedFresh = true
                    continue
                }
            }

            do {
                log.info("importing \(url.lastPathComponent, privacy: .public)")
                if try await importOne(url: url) {
                    importedAny = true
                    log.info("imported \(url.lastPathComponent, privacy: .public)")
                } else {
                    log.info("dedup-skipped \(url.lastPathComponent, privacy: .public)")
                }
            } catch {
                log.error("import failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
        }

        if importedAny, let cb = onImport {
            await MainActor.run { cb() }
        }

        // Files that were too-fresh on this pass need another look once
        // the 2s settle window has elapsed. Without this, a file dropped
        // via `cp` (which doesn't write atomically) sits in the inbox
        // forever because no further FS event re-triggers the scan.
        if skippedFresh {
            Task.detached(priority: .utility) { [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                await self?.scan(inbox: inbox)
            }
        }
    }

    /// Import a single file. Returns `true` if a new record was created,
    /// `false` if the file was a duplicate of something already in the
    /// workspace (still removes it from the inbox so the user knows it
    /// was processed).
    private func importOne(url: URL) async throws -> Bool {
        @Dependency(\.defaultDatabase) var database

        let data = try Data(contentsOf: url)
        let hashHex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let originalFilename = url.lastPathComponent
        let titleBase = url.deletingPathExtension().lastPathComponent

        // Dedupe: if we already have an asset with this content hash,
        // treat the inbox drop as a no-op and clean it up so the user's
        // folder stays empty.
        let existingHash = try await database.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT id FROM assets WHERE content_hash = ? LIMIT 1",
                arguments: [hashHex]
            )
        }
        if existingHash != nil {
            try? FileManager.default.removeItem(at: url)
            return false
        }

        // Make sure a "documents" database exists; structural seed
        // creates it on first launch but we guard defensively.
        let docsExists = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM databases WHERE id = 'documents'") ?? 0
        }
        guard docsExists > 0 else { return false }

        try await database.write { db in
            // Create the host record and import the file as an attached
            // asset in one transaction so partial failure can't leave a
            // titleless record without its file.
            let record = try DBWrites.createRecord(db, databaseID: "documents", title: titleBase)
            let asset = try AssetImporter.importFile(
                db,
                fileURL: url,
                recordID: record.id,
                workspaceID: Seed.workspaceID
            )

            // If the asset is an image, promote it to the record's cover
            // so the new Documents row has a real thumbnail right away.
            if let mime = asset.mimeType, mime.hasPrefix("image/") {
                try DBWrites.setRecordCover(db, recordID: record.id, assetID: asset.id)
            } else {
                // Non-image: still set the original filename as a hint
                // value on the `kind` property so the table view shows
                // something useful.
                try DBWrites.updatePropertyValue(
                    db,
                    recordID: record.id,
                    propertyKey: "kind",
                    value: originalFilename
                )
            }
        }

        // Remove the source file from the inbox once the DB transaction
        // committed — leaving the inbox empty is the user-visible signal
        // that import succeeded.
        try? FileManager.default.removeItem(at: url)
        return true
    }
}
