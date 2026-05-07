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
        // Enumerate including hidden files so we can detect iCloud
        // `.<name>.icloud` placeholders and trigger downloads instead of
        // letting them slip past as "nothing here."
        guard let items = try? fm.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .nameKey],
            options: []
        ) else {
            log.info("scan: folder not readable")
            return
        }

        log.info("scan: \(items.count, privacy: .public) item(s) in inbox")
        var importedAny = false
        var skippedFresh = false
        for url in items {
            // iCloud placeholder for a not-yet-downloaded file. Request the
            // download and bail; the FS event will refire when bytes arrive.
            if url.lastPathComponent.hasPrefix(".") && url.pathExtension == "icloud" {
                log.info("triggering download for \(url.lastPathComponent, privacy: .public)")
                try? fm.startDownloadingUbiquitousItem(at: url)
                skippedFresh = true
                continue
            }
            // Other dot-files: skip silently (.DS_Store, app-internal markers).
            if url.lastPathComponent.hasPrefix(".") { continue }

            let resVals = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey])
            let isFile = resVals?.isRegularFile ?? false
            let isDir = resVals?.isDirectory ?? false

            if isDir {
                do {
                    let result = try await processDirectory(folder: url, depth: 1)
                    if result.imported { importedAny = true }
                    if result.skippedFresh { skippedFresh = true }
                } catch {
                    log.error("subfolder import failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                continue
            }

            guard isFile else {
                log.info("skip non-file \(url.lastPathComponent, privacy: .public)")
                continue
            }
            if url.lastPathComponent == "README.md" { continue }
            if url.pathExtension == "icloud" {
                log.info("triggering download for \(url.lastPathComponent, privacy: .public)")
                try? fm.startDownloadingUbiquitousItem(at: url)
                skippedFresh = true
                continue
            }

            if let mtime = resVals?.contentModificationDate, Date().timeIntervalSince(mtime) < 2.0 {
                log.info("skip too-fresh \(url.lastPathComponent, privacy: .public)")
                skippedFresh = true
                continue
            }

            do {
                log.info("importing \(url.lastPathComponent, privacy: .public)")
                if try await importTopLevelFile(url: url) {
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

    /// Top-level inbox file: route to InboxImporter based on extension.
    private func importTopLevelFile(url: URL) async throws -> Bool {
        @Dependency(\.defaultDatabase) var database

        let ext = url.pathExtension.lowercased()
        let isMarkdown = (ext == "md" || ext == "markdown")

        let outcome = try await database.write { db -> InboxImporter.Outcome in
            if isMarkdown {
                return try InboxImporter.importMarkdown(db, url: url, companion: nil)
            } else {
                return try InboxImporter.importOpaque(db, url: url)
            }
        }
        return outcome.imported
    }

    private struct SubfolderResult {
        var imported: Bool = false
        var skippedFresh: Bool = false
    }

    /// Maximum depth processDirectory will recurse to. The Cars/ archive
    /// the importer was designed for sits at depth 4 (`Inbox/Cars/<vehicle>/<doc>/<file>`);
    /// 8 leaves headroom for messier real-world drops without risking a
    /// runaway walk on a misconfigured drop target.
    private static let maxRecursionDepth = 8

    /// Walk a directory tree dropped into the inbox. At each level:
    ///
    /// 1. If the folder looks like a leaf bundle (exactly one `.md`/`.markdown`
    ///    plus one companion file, where the markdown body mentions the
    ///    companion's filename), import as a single typed record with the
    ///    companion attached.
    /// 2. Otherwise, import each settled regular file at this level using
    ///    the same routing as top-level files, then recurse into any
    ///    subdirectories.
    ///
    /// Folders are removed once their contents have been processed, so
    /// "empty Inbox" continues to mean "everything caught up". Recursion
    /// stops at `maxRecursionDepth` to bound the walk.
    private func processDirectory(folder: URL, depth: Int) async throws -> SubfolderResult {
        @Dependency(\.defaultDatabase) var database
        let fm = FileManager.default
        var result = SubfolderResult(imported: false, skippedFresh: false)

        guard depth <= Self.maxRecursionDepth else {
            log.info("recursion depth cap hit at \(folder.path, privacy: .public)")
            return result
        }

        // Enumerate WITHOUT skipping hidden files so we can see iCloud
        // `.<name>.icloud` placeholders. Treat each placeholder as
        // "in-flight" — request the download from iCloud and mark the
        // scan as having seen fresh items so a follow-up scan retries
        // once the file has materialized.
        let items = try fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey],
            options: []
        )

        var settled: [URL] = []
        var subdirs: [URL] = []
        for url in items {
            // iCloud not-yet-downloaded placeholder. Hidden because of
            // the leading dot. Ask iCloud to materialize the real file;
            // the FS event will fire again and we'll see the live file
            // on the next scan.
            if url.lastPathComponent.hasPrefix(".") && url.pathExtension == "icloud" {
                try? fm.startDownloadingUbiquitousItem(at: url)
                result.skippedFresh = true
                continue
            }
            // Skip the macOS-noise hidden file unconditionally.
            if url.lastPathComponent == ".DS_Store" { continue }

            let res = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey])
            if res?.isDirectory == true {
                subdirs.append(url)
                continue
            }
            guard res?.isRegularFile == true else { continue }
            if url.pathExtension == "icloud" {
                // Defensive: visible-suffix variants do exist in some setups.
                try? fm.startDownloadingUbiquitousItem(at: url)
                result.skippedFresh = true
                continue
            }
            if let mtime = res?.contentModificationDate, Date().timeIntervalSince(mtime) < 2.0 {
                result.skippedFresh = true
                continue
            }
            settled.append(url)
        }

        // Leaf bundle detection: one .md + one companion file mentioned by
        // name in the markdown body. Subdirectories must be absent — a
        // bundle is by definition a leaf.
        if subdirs.isEmpty,
           settled.count == 2,
           let mdIndex = settled.firstIndex(where: { $0.pathExtension.lowercased() == "md" || $0.pathExtension.lowercased() == "markdown" }) {
            let mdURL = settled[mdIndex]
            let other = settled[mdIndex == 0 ? 1 : 0]
            let otherExt = other.pathExtension.lowercased()
            if otherExt != "md" && otherExt != "markdown",
               let mdSource = try? String(contentsOf: mdURL, encoding: .utf8),
               mdSource.contains(other.lastPathComponent) {
                let outcome = try await database.write { db -> InboxImporter.Outcome in
                    try InboxImporter.importMarkdown(db, url: mdURL, companion: other)
                }
                if outcome.imported { result.imported = true }
                removeIfEmpty(folder)
                return result
            }
        }

        // Otherwise import each settled file at this level using the
        // same per-file routing as top-level inbox files.
        for url in settled {
            let ext = url.pathExtension.lowercased()
            let isMarkdown = (ext == "md" || ext == "markdown")
            do {
                let outcome = try await database.write { db -> InboxImporter.Outcome in
                    if isMarkdown {
                        return try InboxImporter.importMarkdown(db, url: url, companion: nil)
                    } else {
                        return try InboxImporter.importOpaque(db, url: url)
                    }
                }
                if outcome.imported { result.imported = true }
            } catch {
                log.error("import failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // Recurse into subdirectories.
        for sub in subdirs {
            do {
                let nested = try await processDirectory(folder: sub, depth: depth + 1)
                if nested.imported { result.imported = true }
                if nested.skippedFresh { result.skippedFresh = true }
            } catch {
                log.error("nested folder failed at \(sub.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // Best-effort cleanup; if files remain (e.g. an unsupported
        // dot-file or an unimported companion), the folder stays and the
        // next scan will see it again.
        removeIfEmpty(folder)
        return result
    }

    /// Remove `folder` only if it has truly no remaining contents — including
    /// hidden files like iCloud `.<filename>.icloud` placeholders. iCloud
    /// Drive uses leading-dot placeholders for files that haven't downloaded
    /// yet, so a "hidden-files-skipped" view of the directory can look empty
    /// while real files are still pending in the cloud. Using
    /// `[.skipsHiddenFiles]` here led to the watcher cleaning up dropped
    /// folders mid-download and leaving the user with no records imported.
    private func removeIfEmpty(_ folder: URL) {
        let fm = FileManager.default
        let remaining = (try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        let nonSystem = remaining.filter { url in
            // `.DS_Store` is the only hidden file we treat as ignorable —
            // iCloud placeholders, dot-files the user dropped on purpose, etc.
            // all count as "still pending."
            url.lastPathComponent != ".DS_Store"
        }
        guard nonSystem.isEmpty else { return }
        try? fm.removeItem(at: folder)
    }
}
