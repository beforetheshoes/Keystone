import Foundation
import ImageIO

/// Off-main thumbnail decoder with a shared in-memory cache.
///
/// The cache lives in an `actor ThumbnailCache` so the compiler can
/// verify `Sendable` safety end-to-end — no `nonisolated(unsafe)`, no
/// `@unchecked Sendable`. The actor only serializes `NSCache` lookups
/// (microsecond work), which is fine.
///
/// The decode itself is a `@concurrent` async function — it runs on
/// the cooperative pool but is a *child* of the caller's task, so
/// cancellation propagates. Earlier this lived in `Task.detached`,
/// which gave concurrent decodes but didn't see cancellation when the
/// owning SwiftUI cell scrolled away — so a fast scroll over hundreds
/// of cards accumulated hundreds of un-cancellable decodes, each
/// allocating ~500 KB and saturating the cooperative pool. With a
/// child task, the SwiftUI `.task(id:)` cancellation reaches the
/// decode body. The decode checks `Task.isCancelled` before paying
/// the `CGImageSourceCreateThumbnailAtIndex` cost (which is a single
/// synchronous C call and can't be interrupted mid-flight, so the
/// best we can do is bail before/after).
///
/// Caller drives parallelism — multiple awaiters hitting `image(at:)`
/// concurrently run their decodes in parallel because the decode body
/// is `@concurrent` (executor: global pool, not main). The actor
/// `get`/`set` calls serialize only the cache touches, not the
/// decodes themselves.
actor ThumbnailCache {
    static let shared = ThumbnailCache()

    /// Hard cap on the cached bitmap pool — 64 MB. With each cover
    /// taking ~250–600 KB decoded at 2× display size, this comfortably
    /// holds a populated gallery (271 books) in cache. Under memory
    /// pressure `NSCache` evicts to fit.
    private static let cacheCostLimit = 64 * 1024 * 1024

    private let cache: NSCache<NSString, CachedThumbnail> = {
        let c = NSCache<NSString, CachedThumbnail>()
        c.totalCostLimit = cacheCostLimit
        return c
    }()

    func get(key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    func set(key: String, image: CGImage, cost: Int) {
        cache.setObject(CachedThumbnail(image: image, cost: cost), forKey: key as NSString, cost: cost)
    }

    func clear() {
        cache.removeAllObjects()
    }
}

enum ThumbnailDecoder {
    /// Return the cached image if present, otherwise decode on the
    /// cooperative pool. The decode is a child task of the caller, so
    /// cancellation (e.g. from a SwiftUI `.task(id:)` whose host cell
    /// scrolled away) propagates: the decode bails on the cancellation
    /// check before paying the `CGImageSourceCreateThumbnailAtIndex`
    /// cost.
    ///
    /// Note: if the decode completes before the cancellation is
    /// observed, the result is still cached. The motivation for
    /// cancelling isn't to discard work — it's to *avoid starting* new
    /// decodes for cells that have already scrolled past.
    static func image(at url: URL, maxPixelSize: Int) async -> CGImage? {
        let key = cacheKey(url: url, maxPixelSize: maxPixelSize)
        if let hit = await ThumbnailCache.shared.get(key: key) {
            return hit
        }
        guard let cg = await decode(url: url, maxPixelSize: maxPixelSize) else {
            return nil
        }
        let cost = cg.bytesPerRow * cg.height
        await ThumbnailCache.shared.set(key: key, image: cg, cost: cost)
        return cg
    }

    /// Drop every cached entry. Called when a cover file is replaced
    /// on disk (e.g. by `CoverCompactionPass` re-encoding to HEIC), so
    /// the next decode picks up the new bytes instead of serving the
    /// stale thumbnail.
    static func invalidateAll() async {
        await ThumbnailCache.shared.clear()
    }

    // MARK: - Internals

    private static func cacheKey(url: URL, maxPixelSize: Int) -> String {
        "\(url.absoluteString)|\(maxPixelSize)"
    }

    /// `@concurrent` forces this off the caller's actor (typically
    /// MainActor when invoked from a SwiftUI `.task` body) onto the
    /// cooperative pool — without this annotation, under
    /// `SWIFT_APPROACHABLE_CONCURRENCY=YES` the nonisolated-async
    /// default keeps the function on the caller's actor, which would
    /// put the synchronous `CGImageSourceCreateThumbnailAtIndex` call
    /// on MainActor.
    ///
    /// Cancellation is cooperative: `Task.isCancelled` checks before
    /// and after the C call let us bail when the awaiting cell has
    /// scrolled away. The C call itself can't be interrupted mid-flight.
    @concurrent
    private static func decode(url: URL, maxPixelSize: Int) async -> CGImage? {
        if Task.isCancelled { return nil }
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        if Task.isCancelled { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform:   true,
            kCGImageSourceShouldCacheImmediately:         true,
            kCGImageSourceThumbnailMaxPixelSize:          maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// `CGImage` isn't `NSObject`, so `NSCache` needs a reference-typed
/// wrapper.
private final class CachedThumbnail {
    let image: CGImage
    let cost: Int
    init(image: CGImage, cost: Int) {
        self.image = image
        self.cost = cost
    }
}
