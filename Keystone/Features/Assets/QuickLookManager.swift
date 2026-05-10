import Foundation

#if canImport(AppKit)
import AppKit
import Quartz

/// macOS-only adapter around `QLPreviewPanel` that lets us pop a
/// floating Quick Look panel from anywhere in the app — typically by
/// tapping an asset tile while looking at a record's detail page.
///
/// Quick Look's classic responder-chain integration (where you'd
/// implement `QLPreviewPanelController` on a first-responder view and
/// let the system find it) is awkward in SwiftUI because views don't
/// own a stable `NSResponder` we can hook into. Instead we set the
/// shared panel's `dataSource` and `delegate` directly. This works
/// because we never relinquish control to a different controller —
/// `QuickLookManager` is the only thing in this app that ever shows the
/// panel, and the singleton hangs onto the panel reference until the
/// user dismisses it.
///
/// `QLPreviewItem` requires NSURL not URL, so the items are bridged
/// at access time.
/// Marked `nonisolated` because the QuickLook protocols
/// (`QLPreviewPanelDataSource`, `QLPreviewPanelDelegate`) are imported
/// from a Cocoa header without explicit main-actor annotations, and
/// applying `@MainActor` to the class triggers Swift 6's "actor
/// isolation crosses protocol boundary" diagnostic. We only ever touch
/// `items` from the main thread anyway — the AppFeature reducer hops
/// to `MainActor` before calling `present(urls:)` and the panel
/// callbacks fire on main per `QLPreviewPanel`'s contract.
final class QuickLookManager: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate, @unchecked Sendable {
    static let shared = QuickLookManager()

    private var items: [URL] = []

    /// Closure used to surface "this file isn't ready" to the user.
    /// Defaults to a modal `NSAlert`; tests swap in a spy that just
    /// records the call so we can assert the placeholder fired
    /// without a real panel.
    var presentPlaceholder: @MainActor (URL, MissingReason) -> Void = { url, reason in
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Can't preview \(url.lastPathComponent)"
        alert.informativeText = reason.description
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    enum MissingReason: Equatable {
        /// File is missing entirely (not yet downloaded from CloudKit
        /// on a fresh-install Mac, or moved out from under us).
        case notOnDisk
        /// File exists but reports zero bytes — typical mid-download
        /// state for iCloud-managed files.
        case empty
        /// File is unreadable for some other reason (permissions,
        /// detached volume, …).
        case unreadable

        var description: String {
            switch self {
            case .notOnDisk:
                return "This attachment hasn't finished downloading from iCloud yet. Try again in a moment."
            case .empty:
                return "The attachment is still syncing — its file is on disk but not yet filled in. Try again in a moment."
            case .unreadable:
                return "This attachment can't be read right now. Check that the file still exists and is accessible."
            }
        }
    }

    private override init() {
        super.init()
    }

    /// Show the panel populated with `urls`. If the panel is already
    /// open, reload its content with the new URLs (no flicker, same
    /// window position).
    ///
    /// Runs a per-URL preflight first: a non-existent / unreadable /
    /// zero-byte file (e.g. an asset whose CloudKit download hasn't
    /// finished on a fresh-install Mac) is filtered out and surfaced
    /// via `presentPlaceholder` instead of being handed to Quick Look,
    /// which would otherwise show an empty panel or fail silently.
    ///
    /// `@MainActor` because every `QLPreviewPanel` API we touch
    /// (`shared()`, `dataSource`, `delegate`, `reloadData`, `isVisible`,
    /// `makeKeyAndOrderFront`) is main-actor isolated. The class itself
    /// can't be `@MainActor` without breaking the QL protocols (their
    /// callbacks are imported as `nonisolated`), so we annotate at the
    /// method level and let the caller hop to main.
    @MainActor
    func present(urls: [URL]) {
        var ready: [URL] = []
        for url in urls {
            switch Self.preflight(url) {
            case .ok:
                ready.append(url)
            case .missing(let reason):
                presentPlaceholder(url, reason)
            }
        }

        items = ready
        guard !ready.isEmpty else { return }
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        // `makeKeyAndOrderFront` (vs. the previous
        // `orderFrontRegardless`) is required for zoom shortcuts (⌘=, ⌘-),
        // pinch-to-zoom on a trackpad, arrow-key paging, and the toolbar's
        // resize/zoom controls — Quick Look only enables those when the
        // panel is the key window. The user can click back into the
        // record detail when ready; the panel stays open in the
        // background, just like spacebar-Quick Look from Finder.
        panel.makeKeyAndOrderFront(nil)
    }

    enum PreflightResult: Equatable {
        case ok
        case missing(MissingReason)
    }

    /// Pure check usable from tests without invoking Quick Look.
    /// Returns `.ok` only when the file exists, is readable, and
    /// has nonzero bytes. CloudKit-managed files in flight typically
    /// fail the size check (the placeholder file is created before
    /// the bytes arrive).
    static func preflight(_ url: URL) -> PreflightResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return .missing(.notOnDisk) }
        let values = try? url.resourceValues(forKeys: [.isReadableKey, .fileSizeKey])
        let isReadable = values?.isReadable ?? false
        let size = values?.fileSize ?? 0
        if !isReadable { return .missing(.unreadable) }
        if size == 0   { return .missing(.empty) }
        return .ok
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        // QLPreviewItem is an NS-style protocol that NSURL adopts;
        // SwiftUI URL doesn't, so bridge.
        items[index] as NSURL
    }
}
#endif
