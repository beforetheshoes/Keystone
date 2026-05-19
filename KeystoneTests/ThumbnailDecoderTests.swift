import XCTest
import ImageIO
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif
@testable import Keystone

/// Regression coverage for the gallery-covers-not-loading bug we
/// chased through Spring 2026. The old pipeline was:
///
///     await Task.detached(priority: .userInitiated) { decode(...) }.value
///
/// called from a SwiftUI `.task` body. Under heavy CloudKit + SQLite
/// sync activity at launch the detached task could be unscheduled
/// indefinitely — execution suspended at the `await` and never
/// resumed. `ThumbnailDecoder` (an actor) replaces that pattern with
/// a straight `await decoder.image(at:maxPixelSize:)` call, which
/// is structured concurrency, scheduler-friendly, and can't be lost.
///
/// These tests don't reproduce the original starvation directly
/// (that needed real CloudKit traffic). They cover the contracts the
/// new actor must satisfy so the bug can't come back.
final class ThumbnailDecoderTests: XCTestCase {

    /// Decoding a valid local image returns a non-nil `CGImage`
    /// downsampled to (approximately) the requested envelope.
    func testDecodeValidImage() async throws {
        let url = try makeFixtureImage(width: 800, height: 600)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await ThumbnailDecoder.image(at: url, maxPixelSize: 200)

        guard let image = result else {
            XCTFail("decoder returned nil for a known-good image")
            return
        }
        // The longest edge should be ≤ maxPixelSize. ImageIO sometimes
        // returns slightly larger (it rounds to source DCT block
        // boundaries on JPEG); we accept ≤ 1.5× the request.
        let longest = max(image.width, image.height)
        XCTAssertLessThanOrEqual(longest, 300, "thumbnail not downsampled correctly")
    }

    /// Decoding a path that doesn't exist returns nil — doesn't crash,
    /// doesn't hang.
    func testDecodeNonexistentReturnsNil() async {
        let url = URL(fileURLWithPath: "/tmp/keystone-thumbnaildecoder-doesnotexist-\(UUID().uuidString).jpg")
        let result = await ThumbnailDecoder.image(at: url, maxPixelSize: 200)
        XCTAssertNil(result)
    }

    /// 30 concurrent decodes (matching the worst-case gallery load)
    /// all complete and return non-nil. This is the structural
    /// regression check for the old `Task.detached.value` bug — if
    /// decoder scheduling stalled under concurrency, this test would
    /// time out.
    func testConcurrentDecodes() async throws {
        let url = try makeFixtureImage(width: 800, height: 600)
        defer { try? FileManager.default.removeItem(at: url) }

        // Bust any prior cache state from earlier tests so the work
        // actually hits the decode path, not the cache.
        await ThumbnailDecoder.invalidateAll()

        // Vary maxPixelSize per task so cache keys differ and we
        // force 30 real decodes, not 1 decode + 29 cache hits.
        let results = await withTaskGroup(of: CGImage?.self) { group in
            for i in 0..<30 {
                let pixelSize = 100 + i * 5  // 100, 105, 110, ...
                group.addTask {
                    await ThumbnailDecoder.image(at: url, maxPixelSize: pixelSize)
                }
            }
            var collected: [CGImage?] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        XCTAssertEqual(results.count, 30, "all tasks must complete")
        XCTAssertEqual(results.compactMap { $0 }.count, 30, "every decode should return an image")
    }

    /// Cache hit: a second decode of the same `(url, pixelSize)`
    /// returns the same `CGImage` instance without going through the
    /// disk-decode path.
    func testCacheHitReturnsSameInstance() async throws {
        let url = try makeFixtureImage(width: 400, height: 400)
        defer { try? FileManager.default.removeItem(at: url) }

        await ThumbnailDecoder.invalidateAll()
        let first = await ThumbnailDecoder.image(at: url, maxPixelSize: 150)
        let second = await ThumbnailDecoder.image(at: url, maxPixelSize: 150)

        guard let firstImage = first, let secondImage = second else {
            XCTFail("expected both decodes to return an image")
            return
        }

        // `CGImage` is a CFType — pointer-equality via
        // `Unmanaged.passUnretained(...).toOpaque()` confirms the cache
        // returned the same backing object (no fresh decode).
        let firstPtr = Unmanaged.passUnretained(firstImage).toOpaque()
        let secondPtr = Unmanaged.passUnretained(secondImage).toOpaque()
        XCTAssertEqual(firstPtr, secondPtr, "expected the second decode to reuse the cached CGImage")
    }

    // MARK: - Fixture

    /// Writes a solid-color PNG to a temporary URL and returns it.
    /// PNG works on every Apple platform without HEIC support tags.
    private func makeFixtureImage(width: Int, height: Int) throws -> URL {
        #if canImport(AppKit)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw XCTSkip("Couldn't render fixture image on this platform")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keystone-thumbnaildecoder-\(UUID().uuidString).png")
        try png.write(to: url)
        return url
        #else
        throw XCTSkip("AppKit-only fixture; skip on non-macOS test runs")
        #endif
    }
}
