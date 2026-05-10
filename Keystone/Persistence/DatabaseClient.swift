import Foundation
import GRDB
import Dependencies
import DependenciesMacros

@DependencyClient
struct DatabaseClient: Sendable {
    var areas: @Sendable () throws -> [AreaRow]
    var databases: @Sendable () throws -> [DBRow]
    var database: @Sendable (_ id: String) throws -> DBRow?
    var properties: @Sendable (_ databaseID: String) throws -> [PropertyRow]
    /// `excluding` is the privacy-lock hidden set
    /// (`AppFeature.State.hiddenRecordIDs`). Pass `[]` from non-UI call
    /// sites (CLI, sidecar writer, enrichment) to bypass the filter —
    /// the database itself isn't encrypted, this is a UI affordance only.
    var records: @Sendable (_ databaseID: String, _ excluding: Set<String>) throws -> [RecordRow]
    var record: @Sendable (_ id: String) throws -> RecordRow?
    /// Raw `json_value` for a (record, property) pair. Returns nil when
    /// the row is absent or json_value is empty. Used by the address
    /// editor to hydrate structured state without bloating RecordRow.
    var propertyJSON: @Sendable (_ recordID: String, _ propertyKey: String) throws -> String?
    var relatedRecords: @Sendable (_ sourceID: String, _ excluding: Set<String>) throws -> [RecordRow]
    var paletteItems: @Sendable (_ excluding: Set<String>) throws -> [PaletteItem]

    // MARK: - Privacy lock

    /// Compute the closure of record IDs that should be hidden given the
    /// current unlocked allow-list. See `ProtectedReads.hiddenRecordIDs`
    /// for the cascade semantics. `filteringActive` mirrors
    /// `KeystoneSettings.protectionFilteringActive`.
    var protectedHiddenIDs: @Sendable (_ unlocked: Set<String>, _ filteringActive: Bool) throws -> Set<String>
    /// Literal set of record IDs flagged `is_protected = true` (no
    /// cascade, no unlock subtraction). Used by the "Show all protected"
    /// affordance to fill the unlock set in one biometric prompt.
    var allProtectedSeedIDs: @Sendable () throws -> Set<String>
    /// True iff the given record id has its `is_protected` checkbox set
    /// truthy. Used to disambiguate "record nil because deleted" from
    /// "record nil because hidden by filter".
    var isProtected: @Sendable (_ recordID: String) throws -> Bool
    /// Compute the cascade closure starting from a single seed id —
    /// the seed itself plus every record reachable via outgoing
    /// relations. Used by the encrypt/decrypt-on-toggle path so the
    /// dependents get the same encryption treatment as the directly-
    /// flagged record.
    var cascadeFromSeed: @Sendable (_ seedID: String) throws -> Set<String>

    // MARK: - Encryption-at-rest

    /// True iff the record currently has any property_values OR blocks
    /// stored in their encrypted columns. Drives the post-write
    /// encryption path: after a value or block write, if the record is
    /// encrypted, the reducer re-runs `encryptRecord` to re-encrypt
    /// the freshly-written plaintext so storage stays uniform.
    var recordIsEncrypted: @Sendable (_ recordID: String) throws -> Bool
    /// Encrypt every plaintext property_value, block content, AND
    /// asset file for the record. Idempotent; no-op on
    /// already-encrypted rows / files.
    var encryptRecord: @Sendable (_ recordID: String) throws -> Void
    /// Inverse — decrypt all enc_value / enc_content / file bytes
    /// back to plaintext. Used by the toggle-off-protected path.
    var decryptRecord: @Sendable (_ recordID: String) throws -> Void
    /// Resolve an asset's URL for opening / Quick Look. For plaintext
    /// assets returns the original on-disk path; for encrypted assets
    /// decrypts to a per-session temp file under NSTemporaryDirectory.
    /// Throws when the asset doesn't exist or decryption fails.
    var assetDecryptedURL: @Sendable (_ assetID: String) throws -> URL

    var createRecord: @Sendable (_ databaseID: String, _ title: String) throws -> RecordRow
    var updateRecordTitle: @Sendable (_ recordID: String, _ title: String) throws -> Void
    var updatePropertyValue: @Sendable (_ recordID: String, _ key: String, _ value: String) throws -> Void
    var deleteRecord: @Sendable (_ recordID: String) throws -> Void
    /// Hard-delete every record in `databaseID` plus their on-disk
    /// asset files. Returns (recordCount, assetCount) so the caller
    /// can surface a precise summary in confirmation UI.
    var deleteAllRecordsInDatabase: @Sendable (_ databaseID: String) throws -> (deletedRecords: Int, deletedAssets: Int)
    var changeRecordDatabase: @Sendable (_ recordID: String, _ newDatabaseID: String) throws -> Void
    /// Persist a column-alignment override on a property's `config_json`.
    /// Pass `nil` to clear and fall back to the type-aware default.
    var setPropertyAlignment: @Sendable (_ propertyID: String, _ alignment: PropertyAlignment?) throws -> Void

    var blocks: @Sendable (_ recordID: String) throws -> [BlockRow]
    var createBlock: @Sendable (_ recordID: String, _ after: String?, _ kind: BlockKind, _ text: AttributedString, _ checked: Bool?) throws -> BlockRow
    var updateBlockText: @Sendable (_ blockID: String, _ text: AttributedString) throws -> Void
    var updateBlockKind: @Sendable (_ blockID: String, _ kind: BlockKind, _ text: AttributedString?) throws -> Void
    var updateBlockChecked: @Sendable (_ blockID: String, _ checked: Bool) throws -> Void
    var updateBlockTable: @Sendable (_ blockID: String, _ table: BlockTableData) throws -> Void
    var deleteBlock: @Sendable (_ blockID: String) throws -> Void

    // Tags
    var allTags: @Sendable (_ workspaceID: String) throws -> [TagModel]
    var tagsForRecord: @Sendable (_ recordID: String) throws -> [TagModel]
    var tagsAvailable: @Sendable (_ workspaceID: String, _ databaseID: String) throws -> [TagModel]
    var recordsForTag: @Sendable (_ tagID: String, _ excluding: Set<String>) throws -> [(record: RecordRow, dbName: String)]
    var createTag: @Sendable (_ workspaceID: String, _ name: String, _ scope: TagScope, _ scopeID: String?, _ color: AccentTone) throws -> TagModel
    var deleteTag: @Sendable (_ tagID: String) throws -> Void
    var attachTag: @Sendable (_ recordID: String, _ tagID: String) throws -> Void
    var detachTag: @Sendable (_ recordID: String, _ tagID: String) throws -> Void

    // Assets
    var assetsForRecord: @Sendable (_ recordID: String) throws -> [AssetRecord]
    var importAsset: @Sendable (_ fileURL: URL, _ recordID: String?, _ workspaceID: String) throws -> AssetRecord
    var deleteAsset: @Sendable (_ assetID: String) throws -> Void
    /// Aggregate counts + total bytes across every asset in the
    /// workspace, broken down by MIME bucket. Drives the Settings →
    /// Attachments summary cards. Single SQL roundtrip.
    var assetStats: @Sendable (_ workspaceID: String) throws -> AssetStats
    /// Filename + (unencrypted-only) extracted_text search. Returns
    /// at most `limit` rows ordered by created_at DESC. Encrypted
    /// rows match by filename only — never by their plaintext OCR
    /// column — so the global Settings search doesn't leak phrases
    /// from protected records.
    var searchAssets: @Sendable (_ workspaceID: String, _ query: String, _ filter: AssetTypeFilter, _ limit: Int) throws -> [AssetSearchHit]

    // Cover image
    var importCoverImage: @Sendable (_ fileURL: URL, _ recordID: String, _ workspaceID: String) throws -> AssetRecord
    var setRecordCover: @Sendable (_ recordID: String, _ assetID: String?) throws -> Void

    // Relations
    var outgoingRelations: @Sendable (_ recordID: String, _ excluding: Set<String>) throws -> [RelationLink]
    var outgoingRelationsForProperty: @Sendable (_ recordID: String, _ propertyID: String, _ excluding: Set<String>) throws -> [RelationLink]
    var incomingRelations: @Sendable (_ recordID: String, _ excluding: Set<String>) throws -> [RelationLink]
    var relationTargetDatabaseID: @Sendable (_ propertyID: String) throws -> String?
    var addRelation: @Sendable (_ sourceRecordID: String, _ targetRecordID: String, _ propertyID: String?) throws -> RelationLink?
    var removeRelation: @Sendable (_ relationID: String) throws -> Void
}

/// Helpers that look up `@Dependency(\.defaultDatabase)` on each call so the
/// scoped dependency from `withDependencies { ... }` is respected.
@Sendable private func dbRead<T: Sendable>(_ block: @Sendable (Database) throws -> T) throws -> T {
    @Dependency(\.defaultDatabase) var database
    return try database.read(block)
}
@Sendable private func dbWrite<T: Sendable>(_ block: @Sendable (Database) throws -> T) throws -> T {
    @Dependency(\.defaultDatabase) var database
    return try database.write(block)
}

/// Post-block-write reencryption hooks. After any block-modifying
/// write inside an encrypted record, re-encrypt the freshly-written
/// plaintext so storage doesn't drift to a half-encrypted state.
/// Idempotent on already-encrypted blocks. The encryptor is built
/// per-record from the provider so each record uses its own key.
@Sendable private func reencryptBlocksIfRecordProtected(
    _ db: Database,
    recordID: String,
    provider: ValueEncryptorProvider
) throws {
    guard try DBWrites.recordIsEncrypted(db, recordID: recordID) else { return }
    try DBWrites.encryptRecordBlocks(db, recordID: recordID, encryptor: provider(recordID))
}

/// Same hook keyed by blockID — looks up the parent record before
/// dispatching. Used by updateBlockText/Kind/Checked/Table.
@Sendable private func reencryptBlocksForBlockIfProtected(
    _ db: Database,
    blockID: String,
    provider: ValueEncryptorProvider
) throws {
    guard let recID = try String.fetchOne(
        db,
        sql: "SELECT record_id FROM blocks WHERE id = ?",
        arguments: [blockID]
    ) else { return }
    try reencryptBlocksIfRecordProtected(db, recordID: recID, provider: provider)
}

extension DatabaseClient: DependencyKey {
    static let liveValue: DatabaseClient = {
        // Per-record encryption: each call site that has a recordID
        // builds a `ValueEncryptor` bound to that ID. Multi-record
        // reads receive the provider closure so they can resolve
        // per-row.
        @Dependency(\.protectionKeyClient) var keys
        let provider: ValueEncryptorProvider = ValueEncryptor.liveProvider(keys: keys)

        return DatabaseClient(
        areas:           { try dbRead { try DBReads.areas($0) } },
        databases:       { try dbRead { try DBReads.databases($0) } },
        database:        { id in try dbRead { try DBReads.database($0, id: id) } },
        properties:      { dbID in try dbRead { try DBReads.properties($0, databaseID: dbID) } },
        records:         { dbID, excluding in try dbRead { try DBReads.records($0, databaseID: dbID, excluding: excluding, encryptorProvider: provider) } },
        record:          { id in try dbRead { try DBReads.record($0, id: id, encryptor: provider(id)) } },
        propertyJSON:    { recID, key in try dbRead { try DBReads.propertyJSON($0, recordID: recID, propertyKey: key) } },
        relatedRecords:  { id, excluding in try dbRead { try DBReads.relatedRecords($0, sourceID: id, excluding: excluding, encryptorProvider: provider) } },
        paletteItems:    { excluding in try dbRead { try DBReads.paletteItems($0, excluding: excluding) } },
        protectedHiddenIDs: { unlocked, active in try dbRead { try ProtectedReads.hiddenRecordIDs($0, unlocked: unlocked, filteringActive: active) } },
        allProtectedSeedIDs: { try dbRead { try ProtectedReads.allProtectedSeedIDs($0) } },
        isProtected:    { recID in try dbRead { try ProtectedReads.isProtected($0, recordID: recID) } },
        cascadeFromSeed: { seed in try dbRead { try ProtectedReads.cascadeFromSeed($0, seedID: seed) } },
        recordIsEncrypted: { recID in try dbRead { try DBWrites.recordIsEncrypted($0, recordID: recID) } },
        encryptRecord: { recID in
            try dbWrite { db in
                let enc = provider(recID)
                try DBWrites.encryptRecordValues(db, recordID: recID, encryptor: enc)
                try DBWrites.encryptRecordBlocks(db, recordID: recID, encryptor: enc)
                try DBWrites.encryptRecordAssets(db, recordID: recID, encryptor: enc)
            }
        },
        decryptRecord: { recID in
            try dbWrite { db in
                let enc = provider(recID)
                try DBWrites.decryptRecordValues(db, recordID: recID, encryptor: enc)
                try DBWrites.decryptRecordBlocks(db, recordID: recID, encryptor: enc)
                try DBWrites.decryptRecordAssets(db, recordID: recID, encryptor: enc)
                // Once the record is fully decrypted, drop its key from
                // the keychain — the record is no longer protected and
                // future writes will land as plaintext.
                try? keys.deleteRecordKey(recID)
            }
        },
        assetDecryptedURL: { assetID in
            try dbRead { db in
                guard let asset = try AssetReads.asset(db, id: assetID) else {
                    throw NSError(
                        domain: "Keystone", code: 35,
                        userInfo: [NSLocalizedDescriptionKey: "Asset not found: \(assetID)"]
                    )
                }
                return try EncryptedAssetReader.decryptedURL(
                    for: asset,
                    encryptor: provider(asset.recordID ?? "")
                )
            }
        },
        createRecord:    { dbID, title in try dbWrite { try DBWrites.createRecord($0, databaseID: dbID, title: title) } },
        updateRecordTitle: { id, title in try dbWrite { try DBWrites.updateRecordTitle($0, recordID: id, title: title) } },
        updatePropertyValue: { id, key, value in try dbWrite { try DBWrites.updatePropertyValue($0, recordID: id, propertyKey: key, value: value) } },
        deleteRecord:    { id in try dbWrite { try DBWrites.deleteRecord($0, recordID: id) } },
        deleteAllRecordsInDatabase: { dbID in try dbWrite { try DBWrites.deleteAllRecordsInDatabase($0, databaseID: dbID) } },
        changeRecordDatabase: { id, newDB in try dbWrite { try DBWrites.changeRecordDatabase($0, recordID: id, newDatabaseID: newDB) } },
        setPropertyAlignment: { propID, alignment in try dbWrite { try DBWrites.setPropertyAlignment($0, propertyID: propID, alignment: alignment) } },
        blocks:          { id in try dbRead { try BlockReads.blocks($0, recordID: id, encryptor: provider(id)) } },
        createBlock:     { rid, after, kind, text, checked in
            try dbWrite { db in
                let row = try DBWrites.createBlock(db, recordID: rid, after: after, kind: kind, text: text, checked: checked)
                try reencryptBlocksIfRecordProtected(db, recordID: rid, provider: provider)
                return row
            }
        },
        updateBlockText: { id, text in
            try dbWrite { db in
                try DBWrites.updateBlockText(db, blockID: id, text: text)
                try reencryptBlocksForBlockIfProtected(db, blockID: id, provider: provider)
            }
        },
        updateBlockKind: { id, kind, text in
            try dbWrite { db in
                try DBWrites.updateBlockKind(db, blockID: id, kind: kind, text: text)
                try reencryptBlocksForBlockIfProtected(db, blockID: id, provider: provider)
            }
        },
        updateBlockChecked: { id, checked in
            try dbWrite { db in
                try DBWrites.updateBlockChecked(db, blockID: id, checked: checked)
                try reencryptBlocksForBlockIfProtected(db, blockID: id, provider: provider)
            }
        },
        updateBlockTable: { id, table in
            try dbWrite { db in
                try DBWrites.updateBlockTable(db, blockID: id, table: table)
                try reencryptBlocksForBlockIfProtected(db, blockID: id, provider: provider)
            }
        },
        deleteBlock:     { id in try dbWrite { try DBWrites.deleteBlock($0, blockID: id) } },

        allTags:         { wsID in try dbRead { try TagReads.tags($0, workspaceID: wsID) } },
        tagsForRecord:   { id in try dbRead { try TagReads.tagsForRecord($0, recordID: id) } },
        tagsAvailable:   { wsID, dbID in try dbRead { try TagReads.tagsAvailable($0, workspaceID: wsID, databaseID: dbID) } },
        recordsForTag:   { id, excluding in try dbRead { try TagReads.recordsForTag($0, tagID: id, excluding: excluding) } },
        createTag:       { wsID, name, scope, scopeID, color in try dbWrite { try DBWrites.createTag($0, workspaceID: wsID, name: name, scope: scope, scopeID: scopeID, color: color) } },
        deleteTag:       { id in try dbWrite { try DBWrites.deleteTag($0, tagID: id) } },
        attachTag:       { recID, tagID in try dbWrite { try DBWrites.attachTag($0, recordID: recID, tagID: tagID) } },
        detachTag:       { recID, tagID in try dbWrite { try DBWrites.detachTag($0, recordID: recID, tagID: tagID) } },

        assetsForRecord: { id in try dbRead { try AssetReads.assets($0, recordID: id) } },
        importAsset:     { url, recID, wsID in try dbWrite { try AssetImporter.attachFile($0, fileURL: url, recordID: recID, workspaceID: wsID) } },
        deleteAsset:     { id in try dbWrite { try DBWrites.deleteAsset($0, assetID: id) } },
        assetStats:      { wsID in try dbRead { try AssetReads.stats($0, workspaceID: wsID) } },
        searchAssets:    { wsID, q, filter, limit in try dbRead { try AssetReads.search($0, workspaceID: wsID, query: q, typeFilter: filter, limit: limit) } },

        importCoverImage: { url, recID, wsID in try dbWrite { try DBWrites.importCoverImage($0, fileURL: url, recordID: recID, workspaceID: wsID) } },
        setRecordCover:   { recID, assetID in try dbWrite { try DBWrites.setRecordCover($0, recordID: recID, assetID: assetID) } },

        outgoingRelations:            { id, excluding in try dbRead { try RelationReads.outgoing($0, recordID: id, propertyID: nil, excluding: excluding) } },
        outgoingRelationsForProperty: { id, propID, excluding in try dbRead { try RelationReads.outgoing($0, recordID: id, propertyID: propID, excluding: excluding) } },
        incomingRelations:            { id, excluding in try dbRead { try RelationReads.incoming($0, recordID: id, excluding: excluding) } },
        relationTargetDatabaseID:     { propID in try dbRead { try RelationReads.relationTargetDB($0, propertyID: propID) } },
        addRelation:                  { src, tgt, propID in try dbWrite { try DBWrites.addRelation($0, sourceRecordID: src, targetRecordID: tgt, propertyID: propID) } },
        removeRelation:               { id in try dbWrite { try DBWrites.removeRelation($0, relationID: id) } }
        )
    }()

    static let testValue = DatabaseClient()
}

extension DependencyValues {
    var databaseClient: DatabaseClient {
        get { self[DatabaseClient.self] }
        set { self[DatabaseClient.self] = newValue }
    }
}
