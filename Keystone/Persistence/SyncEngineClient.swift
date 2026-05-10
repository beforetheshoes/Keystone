import Foundation
import Dependencies
import DependenciesMacros
import OSLog
@preconcurrency import SQLiteData
#if canImport(CloudKit)
import CloudKit
#endif

/// Thin TCA wrapper around sqlite-data's `SyncEngine`. Provides start/stop
/// lifecycle, an `AsyncStream` of `AppFeature.SyncStatus` values for the
/// sidebar badge, and the CKShare cross-user sharing entry points (#14).
///
/// When CloudKit isn't configured (the default for dev builds without iCloud
/// entitlements), `observeStatus()` yields a single `.local` value and ends.
/// When CloudKit IS configured, the stream observes the SyncEngine's
/// `isRunning` / `isSendingChanges` / `isFetchingChanges` properties via
/// SwiftUI's Observation framework.
///
/// **Sharing methods.** `shareRecord` / `unshareRecord` / `acceptShare`
/// drive the CKShare lifecycle on top of sqlite-data's built-in
/// `SyncEngine.share(record:configure:)`, `unshare(record:)`, and
/// `acceptShare(metadata:)`. `shareRecord` also stashes the record's
/// per-record protection key into `share.encryptedValues` so a recipient
/// can decrypt protected values; `acceptShare` reads that key out and
/// installs it locally via `ProtectionKeyClient`.
@DependencyClient
struct SyncEngineClient: Sendable {
    var start: @Sendable () async throws -> Void
    var stop: @Sendable () -> Void
    var observeStatus: @Sendable () -> AsyncStream<AppFeature.SyncStatus> = { AsyncStream { $0.finish() } }

    /// Share a `records` row. Looks up the row by ID, calls
    /// sqlite-data's `share()` (which handles CKShare creation /
    /// dedupe / metadata persistence), and — if the record is
    /// protected — stashes its per-record symmetric key into
    /// `share.encryptedValues["keystone_record_key"]` so participants
    /// can decrypt. Returns the `SharedRecord` ready to drive a
    /// `CloudSharingView` (iOS) or `MacCloudShareSheet` (macOS).
    var shareRecord: @Sendable (_ recordID: String) async throws -> SharedRecord

    /// Stop sharing a `records` row. Deletes the CKShare on the
    /// server; the participants lose access on their next fetch.
    var unshareRecord: @Sendable (_ recordID: String) async throws -> Void

    /// Accept an incoming share. Calls sqlite-data's
    /// `acceptShare(metadata:)`, then — if the share carries a wrapped
    /// per-record key in `encryptedValues["keystone_record_key"]` —
    /// installs that key into the local Keychain so the shared record
    /// decrypts on this device. Resolution of the record ID happens
    /// after the shared sync engine pulls the row.
    var acceptShare: @Sendable (_ metadata: CKShare.Metadata) async throws -> Void
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
        },
        shareRecord: { recordID in
            guard keystoneSyncEngineConfigured else {
                throw SyncEngineClient.Error.notConfigured
            }
            @Dependency(\.defaultSyncEngine) var engine
            @Dependency(\.defaultDatabase) var database
            @Dependency(\.protectionKeyClient) var keys

            let record: Record? = try await database.read { db in
                try Record.find(#bind(recordID)).fetchOne(db)
            }
            guard let record else {
                throw SyncEngineClient.Error.recordNotFound(recordID)
            }
            let isProtected: Bool = (try? await database.read { db in
                try ProtectedReads.isProtected(db, recordID: recordID)
            }) ?? false

            let title = record.title.isEmpty ? "Record" : record.title
            let keyData: Data? = isProtected
                ? try keys.exportRecordKey(recordID)
                : nil

            return try await engine.share(record: record) { share in
                share[CKShare.SystemFieldKey.title] = title as CKRecordValue
                share.publicPermission = .none
                if let keyData {
                    share.encryptedValues["keystone_record_key"] = keyData as CKRecordValue
                }
            }
        },
        unshareRecord: { recordID in
            guard keystoneSyncEngineConfigured else {
                throw SyncEngineClient.Error.notConfigured
            }
            @Dependency(\.defaultSyncEngine) var engine
            @Dependency(\.defaultDatabase) var database
            let record: Record? = try await database.read { db in
                try Record.find(#bind(recordID)).fetchOne(db)
            }
            guard let record else {
                throw SyncEngineClient.Error.recordNotFound(recordID)
            }
            try await engine.unshare(record: record)
        },
        acceptShare: { metadata in
            guard keystoneSyncEngineConfigured else {
                throw SyncEngineClient.Error.notConfigured
            }
            @Dependency(\.defaultSyncEngine) var engine
            @Dependency(\.protectionKeyClient) var keys

            try await engine.acceptShare(metadata: metadata)

            // The share's encrypted metadata may carry a wrapped
            // per-record key. Install it so the shared row's encrypted
            // columns decrypt locally on this device. The recordID
            // matches the shared root's CKRecord.recordName, which is
            // also the row's primary key in `records`.
            if let keyData = metadata.share.encryptedValues["keystone_record_key"] as? Data {
                let recordID = metadata.hierarchicalRootRecordID?.recordName
                    ?? metadata.share.recordID.recordName
                try keys.installRecordKey(recordID, keyData)
            }
        }
    )

    static let testValue = SyncEngineClient()

    enum Error: Swift.Error, Equatable {
        case notConfigured
        case recordNotFound(String)
    }
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
