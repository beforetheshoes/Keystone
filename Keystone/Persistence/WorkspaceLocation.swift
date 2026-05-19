import Foundation
import Synchronization

/// Where the user's `workspace.sqlite` + `Assets/` live on this device.
/// Stored in UserDefaults, defaulting to `.container` for first-launch
/// users (which preserves all existing behavior — current installs read
/// and write to the sandbox container exactly as before).
enum WorkspaceLocation: Codable, Equatable, Sendable {
    /// Sandboxed app-support container (the historical default). Hidden
    /// from Finder; private to this device. Recommended only when the
    /// user values strict privacy / sandboxing over file visibility.
    case container

    /// User-picked folder somewhere they can see in Finder / Files.app.
    /// `bookmark` is a security-scoped bookmark blob the OS lets us
    /// resolve back into a URL with permission to read/write across
    /// launches even under the sandbox.
    case userFolder(bookmark: Data)

    /// `iCloud Drive/Keystone/`. Visible in Finder's iCloud Drive
    /// section and on iPhone/iPad in Files.app. Cross-device sync of
    /// the actual files (database + assets) is handled by iCloud Drive
    /// at the file system level. Note that *row-level* sync via
    /// CloudKit (the `SyncEngine`) is a separate, additive system —
    /// having both is fine.
    case iCloudDrive

    private static let userDefaultsKey = "keystoneWorkspaceLocation.v1"

    static var current: WorkspaceLocation {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let loc = try? JSONDecoder().decode(WorkspaceLocation.self, from: data) else {
            return .container
        }
        return loc
    }

    static func save(_ loc: WorkspaceLocation) throws {
        let data = try JSONEncoder().encode(loc)
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    var isContainer: Bool { if case .container = self { return true } else { return false } }
    var isUserFolder: Bool { if case .userFolder = self { return true } else { return false } }
    var isICloud: Bool { if case .iCloudDrive = self { return true } else { return false } }
}

enum WorkspaceLocationError: LocalizedError {
    case staleBookmark
    case scopedAccessDenied
    case iCloudUnavailable
    case directoryCreationFailed(URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .staleBookmark:
            return "The custom Keystone folder reference is out of date. Please re-select it in Settings."
        case .scopedAccessDenied:
            return "Couldn't get access to the custom Keystone folder. Please re-select it in Settings."
        case .iCloudUnavailable:
            return "iCloud Drive isn't available. Sign into iCloud and enable iCloud Drive, or pick a different storage location."
        case .directoryCreationFailed(let url, let err):
            return "Couldn't create folder at \(url.path): \(err.localizedDescription)"
        }
    }
}

/// Resolves the active `WorkspaceLocation` to a concrete `URL` and manages
/// security-scoped resource access for user-picked folders. A single
/// instance is shared across the app and held alive for the whole
/// session — releasing it would close the scoped resource and break
/// the open SQLite connection.
///
/// All mutable state (the cached resolved URL and the active scoped
/// URL) is bundled inside a `Mutex`, so the compiler synthesizes
/// `Sendable` conformance from the stored properties — no
/// `@unchecked` escape.
final class WorkspaceLocationManager: Sendable {
    static let shared = WorkspaceLocationManager()

    private struct Resolution {
        var cachedURL: URL?
        var scopedURL: URL?
    }
    private let state = Mutex<Resolution>(Resolution())

    /// Resolve the current location to a concrete on-disk URL, creating
    /// the directory if needed. Caches the result; call `invalidate()`
    /// after switching the active location.
    func resolve() throws -> URL {
        try state.withLock { resolution in
            if let cached = resolution.cachedURL { return cached }
            let url = try Self.resolveLocked(WorkspaceLocation.current, resolution: &resolution)
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                do {
                    try fm.createDirectory(at: url, withIntermediateDirectories: true)
                } catch {
                    throw WorkspaceLocationError.directoryCreationFailed(url, underlying: error)
                }
            }
            resolution.cachedURL = url
            return url
        }
    }

    /// Resolve an arbitrary location without touching the cache or the
    /// scoped-resource state — useful during migration so we can resolve
    /// both source and destination side-by-side.
    func resolve(_ location: WorkspaceLocation) throws -> URL {
        try state.withLock { resolution in
            try Self.resolveLocked(location, resolution: &resolution)
        }
    }

    func invalidate() {
        state.withLock { resolution in
            resolution.cachedURL = nil
            if let scopedURL = resolution.scopedURL {
                scopedURL.stopAccessingSecurityScopedResource()
            }
            resolution.scopedURL = nil
        }
    }

    private static func resolveLocked(_ location: WorkspaceLocation, resolution: inout Resolution) throws -> URL {
        switch location {
        case .container:
            return Self.containerWorkspaceFolder

        case .userFolder(let bookmark):
            var stale = false
            #if os(macOS)
            let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let resolveOptions: URL.BookmarkResolutionOptions = []
            #endif
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: resolveOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            if stale { throw WorkspaceLocationError.staleBookmark }
            if !url.startAccessingSecurityScopedResource() {
                throw WorkspaceLocationError.scopedAccessDenied
            }
            // Release the previously-scoped URL (if any) so we don't leak
            // an access count when the same manager is asked to resolve
            // multiple times across location changes.
            if let prior = resolution.scopedURL, prior != url {
                prior.stopAccessingSecurityScopedResource()
            }
            resolution.scopedURL = url
            return url

        case .iCloudDrive:
            // Pass the explicit container ID — `nil` works most of the time
            // but is fragile when multiple iCloud-using apps run in the same
            // process tree (Xcode previews, debugger). The ID must match the
            // primary entry in `com.apple.developer.ubiquity-container-identifiers`.
            guard let container = FileManager.default.url(
                forUbiquityContainerIdentifier: CloudKitConfig.containerIdentifier
            ) else {
                throw WorkspaceLocationError.iCloudUnavailable
            }
            return container.appendingPathComponent("Documents", isDirectory: true)
        }
    }

    /// Sandboxed default — `~/Library/Application Support/Keystone/`.
    static var containerWorkspaceFolder: URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("Keystone", isDirectory: true)
    }

    /// True when iCloud Drive is reachable from this device right now.
    /// Used by the Settings UI to decide whether to enable the iCloud
    /// option or grey it out. Note that the first call after install can
    /// block for a few seconds while the OS provisions the container —
    /// callers should not invoke this on the main thread during launch.
    static var isICloudAvailable: Bool {
        FileManager.default.url(forUbiquityContainerIdentifier: CloudKitConfig.containerIdentifier) != nil
    }
}

// MARK: - Migration

enum WorkspaceMigration {
    /// Copy the contents of `source` into `destination`. If a file already
    /// exists at the destination, we keep the **newer** copy by mtime —
    /// switching back and forth between locations without this rule would
    /// silently keep stale data because the old `if fileExists { skip }`
    /// behavior preferred whichever copy happened to land first.
    /// Throws if any single file copy fails so the caller can abort the
    /// switch and leave the preference pointed at the old (still-intact)
    /// location.
    static func copy(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path) {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        guard let enumerator = fm.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let item as URL in enumerator {
            let relative = item.path.replacingOccurrences(of: source.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let target = destination.appendingPathComponent(relative)
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                if !fm.fileExists(atPath: target.path) {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                }
                continue
            }

            if fm.fileExists(atPath: target.path) {
                let sourceMtime = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let targetMtime = (try? target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if targetMtime >= sourceMtime { continue }
                // Source is newer — replace the destination.
                try fm.removeItem(at: target)
            }
            try fm.copyItem(at: item, to: target)
        }
    }

    /// Compare two folders for size/file equivalence. Used to gate
    /// post-migration cleanup of the source.
    static func equivalent(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        guard let aFiles = fm.enumerator(at: a, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]),
              let bFiles = fm.enumerator(at: b, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return false
        }
        let aMap = Dictionary(uniqueKeysWithValues: aFiles.compactMap { (item) -> (String, Int64)? in
            guard let url = item as? URL,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
            return (url.lastPathComponent, Int64(size))
        })
        let bMap = Dictionary(uniqueKeysWithValues: bFiles.compactMap { (item) -> (String, Int64)? in
            guard let url = item as? URL,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
            return (url.lastPathComponent, Int64(size))
        })
        return aMap == bMap
    }
}
