import SwiftUI
import ImageIO
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Drop-in replacement for `AsyncImage` against a local file URL.
/// Decodes once into the requested pixel envelope via the
/// `ThumbnailDecoder` actor, then renders. While the decode is in
/// flight, renders `placeholder`.
///
/// The decode + cache pipeline used to live as static methods in this
/// file (`ThumbnailLoader.image / .decode / .invalidate`) wrapped in
/// `await Task.detached(...).value`. That pattern broke under heavy
/// CloudKit + SQLite sync at launch — the detached task could be
/// unscheduled indefinitely, leaving every cover stuck on its
/// placeholder. The decode now lives inside `ThumbnailDecoder` (an
/// actor); calls are plain `await`s with no `Task.detached` anywhere
/// in the path.
struct CoverThumbnail<Placeholder: View>: View {
    let url: URL?
    /// Logical (point) size of the cell. The loader doubles to pixels
    /// for Retina; pass the cell's actual layout size, not an
    /// already-scaled pixel count.
    let displaySize: CGSize
    let contentMode: ContentMode
    let placeholder: () -> Placeholder

    @State private var image: CGImage?
    @State private var loadedFor: String?
    @Environment(\.displayScale) private var displayScale

    init(
        url: URL?,
        displaySize: CGSize,
        contentMode: ContentMode = .fit,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.displaySize = displaySize
        self.contentMode = contentMode
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: taskID) { await load() }
    }

    /// Re-runs the task only when the URL or the target pixel size
    /// changes — not every layout pass. SwiftUI calls `body` very
    /// frequently during scroll; without this guard each call would
    /// kick off a fresh decode.
    private var taskID: String {
        guard let url else { return "nil" }
        return "\(url.absoluteString)|\(targetPixelSize)"
    }

    private var targetPixelSize: Int {
        let longest = max(displaySize.width, displaySize.height)
        // `displayScale` from the environment is the modern,
        // non-deprecated way to read the screen's native scale —
        // `UIScreen.main` was removed in iOS 26 and `NSScreen.main`
        // doesn't reflect the window's actual screen reliably.
        // Falls back to 2.0 on platforms / contexts where the env
        // value is 0 (e.g. previews before layout).
        let scale: CGFloat = displayScale > 0 ? displayScale : 2.0
        // 2× the display-size longest edge in pixels — matches the
        // device's native scale on Retina. Floor at 200 so a tiny
        // initial layout doesn't yield a postage-stamp thumbnail.
        return max(200, Int((longest * scale).rounded()))
    }

    private func load() async {
        guard let url else {
            image = nil
            return
        }
        let key = "\(url.absoluteString)|\(targetPixelSize)"
        if loadedFor == key, image != nil { return }

        // Fast path: if the bytes are already on disk, skip the
        // iCloud-materialization roundtrip entirely. This is the
        // common case on macOS (the device that wrote the file) —
        // covers appear within one decode round-trip instead of
        // waiting for `awaitMaterialization`'s 500ms-poll heartbeat.
        //
        // The cache check is also async now (the `ThumbnailCache`
        // actor serializes cache lookups for `Sendable` safety), but
        // the actor hop is microseconds vs the decode's milliseconds,
        // so a single `await ThumbnailDecoder.image(...)` covers both
        // cache-hit and cache-miss paths in one round-trip.
        if FileManager.default.fileExists(atPath: url.path) {
            let result = await ThumbnailDecoder.image(at: url, maxPixelSize: targetPixelSize)
            image = result
            loadedFor = key
            return
        }

        // Slow path: iCloud Drive may have the file as a placeholder
        // (`.<filename>.icloud`) on another device. Kick the download
        // and poll until ready or 30s elapses. Without this, the disk
        // read returns nil and the view shows its placeholder forever.
        guard await UbiquityFile.awaitMaterialization(url) else {
            // Download didn't complete within the timeout — keep the
            // placeholder up; the next `.task` cycle (next layout) can
            // retry naturally.
            return
        }
        let result = await ThumbnailDecoder.image(at: url, maxPixelSize: targetPixelSize)
        image = result
        loadedFor = key
    }
}
