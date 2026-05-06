import Foundation
import Dependencies
import DependenciesMacros
@preconcurrency import SQLiteData

/// Thin TCA wrapper around sqlite-data's `SyncEngine`. Provides start/stop
/// lifecycle and an `AsyncStream` of `AppFeature.SyncStatus` values for the
/// sidebar badge.
///
/// When CloudKit isn't configured (the default for dev builds without iCloud
/// entitlements), `observeStatus()` yields a single `.local` value and ends.
/// When CloudKit IS configured, the stream observes the SyncEngine's
/// `isRunning` / `isSendingChanges` / `isFetchingChanges` properties via
/// SwiftUI's Observation framework.
@DependencyClient
struct SyncEngineClient: Sendable {
    var start: @Sendable () async throws -> Void
    var stop: @Sendable () -> Void
    var observeStatus: @Sendable () -> AsyncStream<AppFeature.SyncStatus> = { AsyncStream { $0.finish() } }
}

extension SyncEngineClient: DependencyKey {
    static let liveValue: SyncEngineClient = SyncEngineClient(
        start: {
            guard keystoneSyncEngineConfigured else { return }
            @Dependency(\.defaultSyncEngine) var engine
            try await engine.start()
        },
        stop: {
            guard keystoneSyncEngineConfigured else { return }
            @Dependency(\.defaultSyncEngine) var engine
            engine.stop()
        },
        observeStatus: {
            AsyncStream { continuation in
                guard keystoneSyncEngineConfigured else {
                    continuation.yield(.local)
                    continuation.finish()
                    return
                }

                @Dependency(\.defaultSyncEngine) var engine
                let task = Task { @MainActor in
                    var lastStatus: AppFeature.SyncStatus = .local
                    var lastSyncedAt: Date? = nil
                    while !Task.isCancelled {
                        let status: AppFeature.SyncStatus = await readStatus(engine: engine, lastSyncedAt: &lastSyncedAt)
                        if status != lastStatus {
                            continuation.yield(status)
                            lastStatus = status
                        }
                        try? await Task.sleep(nanoseconds: 800_000_000)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    )

    static let testValue = SyncEngineClient()
}

@MainActor
private func readStatus(engine: SyncEngine, lastSyncedAt: inout Date?) async -> AppFeature.SyncStatus {
    if !engine.isRunning {
        return .local
    }
    if engine.isSendingChanges || engine.isFetchingChanges {
        return .syncing
    }
    // Sync is running and idle — record this moment as the last "synced" time.
    lastSyncedAt = Date()
    return .synced(lastAt: lastSyncedAt)
}

extension DependencyValues {
    var syncEngineClient: SyncEngineClient {
        get { self[SyncEngineClient.self] }
        set { self[SyncEngineClient.self] = newValue }
    }
}
