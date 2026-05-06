import Foundation
import Dependencies
import GRDB
@preconcurrency import SQLiteData
import OSLog

/// True iff `bootstrapKeystoneDatabase` configured a real CloudKit `SyncEngine`.
/// Read by `SyncEngineClient` to decide whether to observe sync state or stay
/// in the `.local` state.
nonisolated(unsafe) var keystoneSyncEngineConfigured: Bool = false

extension DependencyValues {
    /// Configure the default database (and optionally the CloudKit sync engine)
    /// once at app launch. Mirrors the AuralystApp pattern.
    mutating func bootstrapKeystoneDatabase(configureSyncEngine: Bool = true) throws {
        let writer = try AppDatabase.make()
        defaultDatabase = writer

        guard configureSyncEngine else {
            keystoneSyncEngineConfigured = false
            return
        }

        defaultSyncEngine = try SyncEngine(
            for: writer,
            tables:
                Workspace.self,
                Area.self,
                ObjectDatabase.self,
                PropertyDef.self,
                Record.self,
                PropertyValueRow.self,
                Block.self,
                TagRow.self,
                RecordTag.self,
                RelationRow.self,
                ViewDef.self,
                AssetRow.self,
            containerIdentifier: CloudKitConfig.containerIdentifier,
            logger: Logger(subsystem: "Keystone", category: "CloudKit")
        )
        keystoneSyncEngineConfigured = true
    }
}
