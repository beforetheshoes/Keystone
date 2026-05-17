import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import OSLog

private let log = Logger(subsystem: "Keystone", category: "CoverImageReencoder")

/// Downsamples + re-encodes a freshly-downloaded cover image to HEIC
/// at most 800px on the longest edge, quality 0.7. Why:
///
/// - **Size**: HEIC at q=0.7 is ~60–75% smaller than the source JPEG.
///   88 MB of covers → ~25 MB.
/// - **Decode speed**: HEIC decodes ~as fast as JPEG on Apple Silicon
///   (hardware-accelerated). Not slower like WebP would be.
/// - **Native**: `ImageIO` has supported HEIC end-to-end since macOS
///   10.13 / iOS 11. No third-party dep.
///
/// 800px is the smallest target that's still crisp at the largest
/// gallery preset (320pt × 2x = 640px) plus a margin for the detail
/// view. Going lower would soften the detail-page cover; going higher
/// gives no visual benefit and undoes the savings.
///
/// Falls back to the original bytes on any error so a failed re-encode
/// never blocks the import — same belt-and-braces stance as the rest
/// of the enrichment pipeline.
enum CoverImageReencoder {
    /// Longest-edge pixel cap. See file-level comment.
    static let maxPixelSize: Int = 800

    /// HEIC encode quality. 0.7 is visually transparent for thumbnail
    /// covers; bumping to 0.8 grows file size ~30% with no visible
    /// difference at gallery sizes.
    static let quality: CGFloat = 0.7

    /// HEIC UTI. We resolve via `UTType` rather than caching a static
    /// `CFString` constant — `CFString` is non-`Sendable` under strict
    /// concurrency, and the resolution is essentially free.
    private static var heicType: CFString {
        UTType.heic.identifier as CFString
    }

    /// Encode `data` (any ImageIO-readable image format) as HEIC, no
    /// larger than `maxPixelSize` on the longest edge. Returns
    /// `(data, fileExtension, mimeType)` on success; nil if the source
    /// can't be decoded or HEIC encoding isn't available on this
    /// platform.
    struct Output: Equatable {
        let data: Data
        let fileExtension: String
        let mimeType: String
    }

    static func reencode(_ data: Data) -> Output? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            log.error("reencoder: source decode failed (\(data.count) bytes)")
            return nil
        }
        // `kCGImageSourceThumbnailMaxPixelSize` does the heavy lifting:
        // ImageIO decodes once at native resolution and emits a single
        // bitmap at the requested envelope. No two-pass cost.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform:   true,
            kCGImageSourceShouldCacheImmediately:         true,
            kCGImageSourceThumbnailMaxPixelSize:          maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            log.error("reencoder: thumbnail emit failed")
            return nil
        }

        let outBuf = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(outBuf, heicType, 1, nil) else {
            // HEIC encoding not available on this device (very old
            // hardware). Caller falls back to the unmodified bytes.
            log.info("reencoder: HEIC destination unavailable, keeping source")
            return nil
        }
        let writeOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(destination, cg, writeOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            log.error("reencoder: HEIC finalize failed")
            return nil
        }
        return Output(
            data: outBuf as Data,
            fileExtension: "heic",
            mimeType: "image/heic"
        )
    }

    /// Convenience: read `url`, re-encode, write the result back to a
    /// new sibling file with `.heic` extension. Returns the destination
    /// URL on success, nil otherwise. The original is left in place —
    /// callers responsible for cleanup once the new file's row is in
    /// the database.
    static func reencodeFile(at url: URL) -> URL? {
        guard let data = try? Data(contentsOf: url),
              let out = reencode(data) else { return nil }
        let dest = url.deletingPathExtension().appendingPathExtension(out.fileExtension)
        do {
            try out.data.write(to: dest, options: .atomic)
            return dest
        } catch {
            log.error("reencoder: write \(dest.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
