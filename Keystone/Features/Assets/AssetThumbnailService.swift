import SwiftUI
import QuickLookThumbnailing

#if canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#endif

/// Generates and caches thumbnails for asset files.
///
/// First tries `QLThumbnailGenerator` (works for PDFs, images, video, many
/// system file types). Falls back to a system file icon when QL fails:
/// `NSWorkspace.icon(forFile:)` on macOS, or a generic `doc` SF Symbol on iOS.
@MainActor
final class AssetThumbnailService: ObservableObject {
    static let shared = AssetThumbnailService()

    private struct CacheKey: Hashable {
        let path: String
        let mtime: TimeInterval
        let width: Int
        let height: Int
    }

    private var cache: [CacheKey: PlatformImage] = [:]
    private let cacheLimit = 128

    func thumbnail(for url: URL, size: CGSize, scale: CGFloat = 2) async -> PlatformImage? {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let key = CacheKey(path: url.path, mtime: mtime, width: Int(size.width), height: Int(size.height))
        if let hit = cache[key] { return hit }

        let image = await generate(for: url, size: size, scale: scale)
            ?? fallbackIcon(for: url)

        if let image {
            cache[key] = image
            if cache.count > cacheLimit {
                for k in cache.keys.prefix(16) { cache.removeValue(forKey: k) }
            }
        }
        return image
    }

    func evict(url: URL) {
        cache = cache.filter { $0.key.path != url.path }
    }

    private func generate(for url: URL, size: CGSize, scale: CGFloat) async -> PlatformImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { (cont: CheckedContinuation<PlatformImage?, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                #if canImport(AppKit)
                cont.resume(returning: rep?.nsImage)
                #elseif canImport(UIKit)
                cont.resume(returning: rep?.uiImage)
                #endif
            }
        }
    }

    private func fallbackIcon(for url: URL) -> PlatformImage? {
        #if canImport(AppKit)
        return NSWorkspace.shared.icon(forFile: url.path)
        #elseif canImport(UIKit)
        return UIImage(systemName: "doc")
        #else
        return nil
        #endif
    }
}
