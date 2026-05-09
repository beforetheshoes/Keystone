import Foundation
import CoreServices
import OSLog

private let watcherLog = Logger(subsystem: "Keystone", category: "CarsWatcher")

/// Watches `<workspace>/Cars/` recursively and re-imports any sidecar
/// `.md` whose contents change on disk — completes the
/// bidirectional sync started by `SidecarWriter`. Files written by
/// our own DB → file path are recognized via the
/// `SidecarHashCache` and skipped, so DB → file → watcher → DB loops
/// can't form.
///
/// Uses FSEventStream (recursive by design on macOS) rather than
/// per-folder DispatchSourceFileSystemObject watchers — a Cars/ tree
/// of N event folders would otherwise need N+1 file descriptors and
/// dispatch sources, with no help from the kernel for changes deep
/// in subdirectories.
///
/// Lifecycle:
/// - `start()` opens the stream and runs a coalescing 0.5 s scan loop
///   on the main run loop.
/// - The callback receives a flat list of changed paths (recursive)
///   and dispatches a debounced import pass on a utility queue.
/// - `stop()` invalidates the stream cleanly. Safe to call multiple
///   times.
final class CarsWatcher: @unchecked Sendable {
    static let shared = CarsWatcher()

    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var debounceTask: Task<Void, Never>?
    private var pendingPaths: Set<String> = []
    private let workQueue = DispatchQueue(label: "com.ryanleewilliams.keystone.cars-watcher", qos: .utility)

    private init() {}

    func start() {
        let carsRoot = AppDatabase.workspaceFolder.appendingPathComponent("Cars", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: carsRoot.path) {
            try? fm.createDirectory(at: carsRoot, withIntermediateDirectories: true)
        }

        lock.lock(); defer { lock.unlock() }
        if stream != nil { return }   // already running

        watcherLog.info("CarsWatcher.start watching \(carsRoot.path, privacy: .public)")

        let paths = [carsRoot.path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot
        )

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            CarsWatcher.callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,    // latency in seconds — coalesces bursts from iCloud sync
            flags
        ) else {
            watcherLog.error("FSEventStreamCreate failed")
            return
        }

        FSEventStreamSetDispatchQueue(s, workQueue)
        FSEventStreamStart(s)
        self.stream = s
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        debounceTask?.cancel()
        debounceTask = nil
    }

    // MARK: - Event handling

    /// FSEventStream's C callback. Unpacks paths from the CFArray and
    /// hands them to the Swift instance, which queues a debounced
    /// scan/import pass.
    private static let callback: FSEventStreamCallback = {
        _, contextInfo, numEvents, eventPaths, _, _ in
        guard let info = contextInfo else { return }
        let watcher = Unmanaged<CarsWatcher>.fromOpaque(info).takeUnretainedValue()
        // With kFSEventStreamCreateFlagUseCFTypes, eventPaths is a
        // CFArray of CFString delivered as a `void *`. The canonical
        // Swift bridge: take it back as an unretained CFArray, then
        // cast through NSArray to get `[String]`.
        let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        guard let pathsArray = cfArray as? [String] else {
            watcherLog.debug("FSEvent callback fired but path array decode failed (\(numEvents, privacy: .public) events)")
            return
        }
        watcherLog.debug("FSEvent callback: \(pathsArray.count, privacy: .public) path(s), first=\(pathsArray.first ?? "?", privacy: .public)")
        watcher.absorb(paths: pathsArray, count: numEvents)
    }

    private func absorb(paths: [String], count: Int) {
        lock.lock()
        for path in paths {
            // Only consider markdown sidecars and folders that
            // contain them. We scan parent folders rather than
            // enumerate every event from FSEventStream — a single
            // edit can produce multiple events (write, rename, etc.)
            // and the import is idempotent so dedup is cheap.
            pendingPaths.insert(path)
        }
        debounceTask?.cancel()
        debounceTask = Task.detached(priority: .utility) { [weak self] in
            // Debounce 0.5 s on top of FSEventStream's own latency to
            // catch atomic-rename storms and editor-save bursts.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self?.processPending()
        }
        lock.unlock()
    }

    private func processPending() async {
        let paths: [String] = {
            lock.lock(); defer { lock.unlock() }
            let snapshot = pendingPaths
            pendingPaths.removeAll()
            return Array(snapshot)
        }()
        guard !paths.isEmpty else { return }

        // Identify markdown sidecars whose current content doesn't
        // match what `SidecarWriter` last wrote. Each one's parent
        // folder gets handed to ImportSidecarsCLI.run for re-import.
        let sidecarSuffixes = [".pdf-processed-markdown.md", ".png-processed-markdown.md", ".jpg-processed-markdown.md"]
        let fm = FileManager.default
        var foldersToReimport: Set<String> = []

        for path in paths {
            // The path could be a file or a folder. If it's a folder,
            // we'll process its contents during the parent-folder
            // scan below (the importer recurses anyway).
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: path, isDirectory: &isDir)
            guard exists else { continue }   // file deleted; nothing to import

            if isDir.boolValue {
                // FSEventStream sometimes only reports the parent dir.
                // Walk it shallowly looking for sidecars whose hash
                // diverges from cache.
                if let entries = try? fm.contentsOfDirectory(atPath: path) {
                    for entry in entries where sidecarSuffixes.contains(where: entry.hasSuffix) {
                        let absolute = (path as NSString).appendingPathComponent(entry)
                        if !SidecarHashCache.shared.matchesLastWrite(absolutePath: absolute) {
                            foldersToReimport.insert(path)
                        }
                    }
                }
                continue
            }

            // Regular file event. Only act on sidecar markdown.
            guard sidecarSuffixes.contains(where: path.hasSuffix) else { continue }
            // If the bytes match what we just wrote ourselves, skip.
            if SidecarHashCache.shared.matchesLastWrite(absolutePath: path) { continue }

            let parentFolder = (path as NSString).deletingLastPathComponent
            foldersToReimport.insert(parentFolder)
        }

        guard !foldersToReimport.isEmpty else { return }
        watcherLog.info("CarsWatcher: re-importing \(foldersToReimport.count, privacy: .public) folder(s) from external edits")

        for folder in foldersToReimport {
            do {
                let folderURL = URL(fileURLWithPath: folder, isDirectory: true)
                _ = try ImportSidecarsCLI.run(rootURL: folderURL)
            } catch {
                watcherLog.error("CarsWatcher re-import failed for \(folder, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
