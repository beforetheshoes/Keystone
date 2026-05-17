import Foundation
import Dependencies

/// Bridges `SyncEngineClient.observeStatus()` transitions into rows in
/// the local `sync_events` log, with a `SyncRecoveryGuard` snapshot
/// taken on entry into `.syncing` and diffed when the engine returns
/// to `.synced`. The name "delegate" is deliberate even though this
/// isn't a `CKSyncEngineDelegate`: the underlying CKSyncEngine is owned
/// by SQLiteData's `SyncEngine`, not us. This is the layer at which
/// Keystone-level diagnostics ride on top of the SDK's status surface.
///
/// Lifecycle: started from `AppFeature.task` as a long-lived `.run`
/// effect. When CloudKit isn't configured, `observeStatus()` yields
/// `.local` once and ends, so `run()` returns immediately — the
/// observer is a no-op in CLI bootstraps and tests using
/// `configureSyncEngine: false`.
enum AppSyncEngineDelegate {
    /// Subscribe to status transitions for the lifetime of the task.
    /// Cancellation drains naturally through the AsyncStream's
    /// `onTermination` handler in `SyncEngineClient`.
    static func run() async {
        @Dependency(\.syncEngineClient) var syncClient

        var lastStatus: AppFeature.SyncStatus = .local
        var inflightSnapshot: SyncRecoveryGuard.Snapshot?

        for await status in syncClient.observeStatus() {
            // Edge-trigger on transitions; the underlying poll yields
            // every 800 ms, but we only log when the state class
            // actually changes.
            let prior = lastStatus
            lastStatus = status

            if Self.isSameClass(status, prior) { continue }

            switch status {
            case .syncing:
                // Going INTO a sync cycle — capture a snapshot we can
                // diff against once it completes. Snapshot failure is
                // non-fatal (we just lose loss-detection for this
                // cycle); log the failure so it's visible.
                do {
                    inflightSnapshot = try SyncRecoveryGuard.takeSnapshot()
                } catch {
                    inflightSnapshot = nil
                    SyncEventLogger.log(
                        type: SyncEventType.syncFailed,
                        details: "snapshot_failed: \(error.localizedDescription)"
                    )
                }
                SyncEventLogger.log(type: SyncEventType.syncBegan)

            case .synced:
                // Returned to idle — diff against the snapshot if one
                // was taken, then log success. If we never saw the
                // `.syncing` transition (e.g. a fast cycle) the
                // snapshot is nil and we just log success.
                if let snapshot = inflightSnapshot {
                    let lost = (try? SyncRecoveryGuard.recoverIfNeeded(snapshot: snapshot)) ?? 0
                    if lost > 0 {
                        SyncEventLogger.log(
                            type: SyncEventType.syncFailed,
                            details: "post_sync_diff_detected_loss=\(lost)"
                        )
                    }
                }
                inflightSnapshot = nil

                if case .local = prior {
                    // First settled state after engine start.
                    SyncEventLogger.log(type: SyncEventType.engineStarted)
                }
                SyncEventLogger.log(type: SyncEventType.syncSucceeded)

            case .local:
                // Engine fell back to local-only (sync stopped, or
                // never started). Drop any in-flight snapshot — it's
                // meaningless without a follow-up `.synced`.
                inflightSnapshot = nil
                if case .local = prior { /* no-op */ } else {
                    SyncEventLogger.log(type: SyncEventType.engineStopped)
                }
            }
        }
    }

    /// Treat `.synced(lastAt:)` cases with different timestamps as the
    /// same status class — we only care about transitions between
    /// `.local` / `.syncing` / `.synced`, not refreshes within an
    /// already-synced state.
    private static func isSameClass(_ a: AppFeature.SyncStatus, _ b: AppFeature.SyncStatus) -> Bool {
        switch (a, b) {
        case (.local, .local), (.syncing, .syncing), (.synced, .synced): return true
        default: return false
        }
    }
}
