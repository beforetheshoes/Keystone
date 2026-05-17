import SwiftUI
import ImageIO
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// In-memory thumbnail cache for cover images. SwiftUI's `AsyncImage`
/// is fine for remote URLs but for our local `Assets/` files it does
/// two expensive things on every scroll: decodes the full-resolution
/// source (often a 1500-pixel-wide JPEG for a 200-pixel cell — ~25×
/// wasted pixel work) and forgets the result the moment the view
/// goes off-screen.
///
/// This loader fixes both:
///
/// - **Downsamples via `CGImageSourceCreateThumbnailAtIndex`.** ImageIO
///   decodes the file once and emits a bitmap at the requested pixel
///   size. No GPU scaling, ~1/15th the memory of a full decode.
/// - **Caches the decoded `CGImage`** keyed on `(URL × pixel size)`,
///   capped by cost (sum of bitmap byte sizes) so it self-evicts on
///   memory pressure.
///
/// The loader is platform-agnostic — `CGImage` works on macOS and iOS
/// alike — and synchronous on a cache hit, which lets a gallery card
/// render its thumbnail in the same frame as the layout itself when
/// the user scrolls back to an already-seen card.
enum ThumbnailLoader {
    /// Hard cap on the cached bitmap pool — 64 MB. With each cover
    /// taking ~250–600 KB decoded at 2× display size, this comfortably
    /// holds the entire 271-book gallery in cache. Under memory
    /// pressure NSCache evicts to fit.
    private static let cacheCostLimit = 64 * 1024 * 1024

    // `NSCache` is thread-safe internally (Apple's docs and headers
    // are explicit on this) but not declared `Sendable`. Same pattern
    // the rest of the codebase uses for SDK types whose safety is
    // documented but not surfaced via the type system.
    nonisolated(unsafe) private static let cache: NSCache<NSString, CachedThumbnail> = {
        let c = NSCache<NSString, CachedThumbnail>()
        c.totalCostLimit = cacheCostLimit
        return c
    }()

    /// Decode the file at `url` into a `CGImage` whose largest dimension
    /// is at most `maxPixelSize` pixels. Returns nil if the file can't
    /// be opened as an image. A cache hit returns immediately; a miss
    /// reads + decodes on the current actor (callers should hop off the
    /// main actor for the miss path — see `image(at:maxPixelSize:)`).
    static func cachedImage(at url: URL, maxPixelSize: Int) -> CGImage? {
        let key = cacheKey(url: url, maxPixelSize: maxPixelSize)
        return cache.object(forKey: key)?.image
    }

    /// Async cover-decode wrapper. Returns the cached image if present;
    /// otherwise decodes on a background queue (off the main actor) and
    /// stores the result in the cache before returning.
    static func image(at url: URL, maxPixelSize: Int) async -> CGImage? {
        if let hit = cachedImage(at: url, maxPixelSize: maxPixelSize) { return hit }
        return await Task.detached(priority: .userInitiated) {
            decode(url: url, maxPixelSize: maxPixelSize)
        }.value
    }

    /// Synchronous decode + cache-store. Public for the boot-time
    /// backfill / re-encoder code paths that want to prime the cache.
    @discardableResult
    static func decode(url: URL, maxPixelSize: Int) -> CGImage? {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform:   true,
            kCGImageSourceShouldCacheImmediately:         true,
            kCGImageSourceThumbnailMaxPixelSize:          maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        // Bytes-per-row × height is the bitmap memory footprint; use
        // it as the NSCache cost so the eviction policy is honest.
        let cost = cg.bytesPerRow * cg.height
        let key = cacheKey(url: url, maxPixelSize: maxPixelSize)
        cache.setObject(CachedThumbnail(image: cg, cost: cost), forKey: key, cost: cost)
        return cg
    }

    /// Drop a single URL across every cached size. Used by the boot
    /// re-encoder so a freshly-compacted cover doesn't keep serving
    /// the stale full-res thumbnail from cache.
    static func invalidate(url: URL) {
        // NSCache has no enumeration API, so the cheapest correct fix
        // is to drop everything. Cover compaction is one-shot at boot;
        // the warm-up cost is negligible.
        cache.removeAllObjects()
    }

    private static func cacheKey(url: URL, maxPixelSize: Int) -> NSString {
        "\(url.absoluteString)|\(maxPixelSize)" as NSString
    }
}

/// `CGImage` isn't `NSObject`, so NSCache needs a reference-typed wrapper.
private final class CachedThumbnail: NSObject {
    let image: CGImage
    let cost: Int
    init(image: CGImage, cost: Int) {
        self.image = image
        self.cost = cost
    }
}

// MARK: - SwiftUI view

/// Drop-in replacement for `AsyncImage` against a local file URL.
/// Decodes once into the requested pixel envelope, caches in
/// `ThumbnailLoader`, and renders without going through URLSession.
/// While the decode is in flight, renders `placeholder`.
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
                #if canImport(AppKit)
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                #else
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                #endif
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
        let scale: CGFloat
        #if canImport(AppKit)
        scale = NSScreen.main?.backingScaleFactor ?? 2.0
        #else
        scale = UIScreen.main.scale
        #endif
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
        // Cache-hit fast path stays on the calling actor; the
        // detached miss path falls back through `image(at:)`.
        if let cached = ThumbnailLoader.cachedImage(at: url, maxPixelSize: targetPixelSize) {
            image = cached
            loadedFor = key
            return
        }
        let result = await ThumbnailLoader.image(at: url, maxPixelSize: targetPixelSize)
        image = result
        loadedFor = key
    }
}
