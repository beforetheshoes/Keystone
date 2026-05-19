import Foundation
import CryptoKit
import Synchronization

/// Thread-safe cache of "what `SidecarWriter` last wrote to a given
/// path." The Cars/ file watcher consults this before treating a
/// filesystem event as an external edit:
///
/// - **Match** (current file hash == last-written hash): the change
///   was caused by our own DB → file write. No-op.
/// - **Mismatch** (hash differs or path absent): a real external edit.
///   Trigger a re-import so the DB picks up the change.
///
/// Without this, every in-app edit triggers a DB → file write, which
/// fires the file watcher, which re-imports the (already-current)
/// file, which triggers a DB write that fires the watcher again — a
/// soft infinite loop. Hash-based gating breaks the cycle without
/// resorting to fragile timing windows.
///
/// The cache lives only in-memory: on app restart it's empty, and the
/// first scan of each file flows through as a re-import. That's
/// harmless because the re-import is idempotent and the resulting DB
/// → file write produces the same bytes (so the second scan after
/// restart finds the cache populated).
final class SidecarHashCache: Sendable {
    static let shared = SidecarHashCache()

    /// All mutable state bundled inside a `Mutex`. The class itself
    /// has only `Sendable` stored properties, so the compiler
    /// synthesizes `Sendable` conformance — no `@unchecked` escape.
    private let hashes = Mutex<[String: String]>([:])

    private init() {}

    /// Compute a SHA-256 hex digest of `data`, suitable for keying
    /// the cache. Cheap on the file sizes we're dealing with (a few
    /// KB per sidecar).
    static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Record the hash of the bytes just written to `absolutePath`.
    /// Called from `SidecarWriter` after every successful write.
    func recordWrite(absolutePath: String, data: Data) {
        let hex = Self.hash(of: data)
        hashes.withLock { $0[absolutePath] = hex }
    }

    /// True if the file currently at `absolutePath` matches what we
    /// last wrote. Used by the file watcher to skip events that
    /// originated from our own writes.
    func matchesLastWrite(absolutePath: String) -> Bool {
        guard let stored = hashes.withLock({ $0[absolutePath] }) else { return false }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: absolutePath)) else { return false }
        return Self.hash(of: data) == stored
    }

    /// Forget the hash for `absolutePath` — used when the path is
    /// reassigned (e.g. record renamed and the sidecar moved).
    func forget(absolutePath: String) {
        hashes.withLock { $0[absolutePath] = nil }
    }
}
