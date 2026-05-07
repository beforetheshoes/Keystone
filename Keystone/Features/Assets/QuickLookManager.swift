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

    private override init() {
        super.init()
    }

    /// Show the panel populated with `urls`. If the panel is already
    /// open, reload its content with the new URLs (no flicker, same
    /// window position).
    ///
    /// `@MainActor` because every `QLPreviewPanel` API we touch
    /// (`shared()`, `dataSource`, `delegate`, `reloadData`, `isVisible`,
    /// `makeKeyAndOrderFront`) is main-actor isolated. The class itself
    /// can't be `@MainActor` without breaking the QL protocols (their
    /// callbacks are imported as `nonisolated`), so we annotate at the
    /// method level and let the caller hop to main.
    @MainActor
    func present(urls: [URL]) {
        items = urls
        guard !urls.isEmpty else { return }
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
