import Foundation

/// Resolve iCloud Drive placeholder files into materialized local bytes.
///
/// When a Mac writes a file into its ubiquity container, iCloud Drive
/// uploads it to Apple's servers. On every other signed-in device, the
/// file appears as a *placeholder* (`.<filename>.icloud`) — the
/// metadata is there, the bytes aren't, and the file URL points at a
/// path that returns nil from any normal read API until something
/// asks the OS to materialize the bytes.
///
/// `FileManager.startDownloadingUbiquitousItem(at:)` is what does the
/// asking. This helper wraps that call in a "check status → kick →
/// poll until ready or timeout" loop suitable for SwiftUI `.task`
/// modifiers: views show their fallback while the bytes arrive, then
/// re-render when the read succeeds.
///
/// Non-ubiquity files (anything outside iCloud Drive, including the
/// sandbox-private workspace folder) short-circuit to "already
/// materialized" so the same code path works for every storage
/// location choice.
enum UbiquityFile {
    /// True when the file is either non-ubiquitous (local) or fully
    /// downloaded (`ubiquitousItemDownloadingStatus == .current`).
    /// False for placeholders, in-progress downloads, and read errors.
    static func isMaterialized(_ url: URL) -> Bool {
        guard let vals = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]) else {
            // resourceValues throws for non-existent files; that's
            // "not materialized" as far as we're concerned.
            return FileManager.default.fileExists(atPath: url.path)
        }
        // Files outside any ubiquity container don't have a downloading
        // status — they're either there or they aren't.
        guard vals.isUbiquitousItem == true else {
            return FileManager.default.fileExists(atPath: url.path)
        }
        return vals.ubiquitousItemDownloadingStatus == .current
    }

    /// Kick off an iCloud download for a placeholder. Fire-and-forget;
    /// the OS handles retries and progress. No-op for materialized
    /// items and for non-iCloud paths.
    static func requestDownload(_ url: URL) {
        guard !isMaterialized(url) else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    /// Suspend until the file is fully downloaded, or `timeout` elapses.
    /// Returns true on materialization, false on timeout. Polls every
    /// 500ms after kicking the download — fine for cover-image-sized
    /// payloads (tens of KB) which usually arrive within a second of
    /// the request.
    ///
    /// Use from a SwiftUI `.task` so cancellation on view-disappear
    /// propagates correctly; the poll loop honors `Task.isCancelled`.
    static func awaitMaterialization(
        _ url: URL,
        timeout: TimeInterval = 30
    ) async -> Bool {
        if isMaterialized(url) { return true }
        requestDownload(url)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 500_000_000)
            if isMaterialized(url) { return true }
        }
        return false
    }
}
