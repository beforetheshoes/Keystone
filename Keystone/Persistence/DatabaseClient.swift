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
    var records: @Sendable (_ databaseID: String) throws -> [RecordRow]
    var record: @Sendable (_ id: String) throws -> RecordRow?
    var relatedRecords: @Sendable (_ sourceID: String) throws -> [RecordRow]
    var paletteItems: @Sendable () throws -> [PaletteItem]

    var createRecord: @Sendable (_ databaseID: String, _ title: String) throws -> RecordRow
    var updateRecordTitle: @Sendable (_ recordID: String, _ title: String) throws -> Void
    var updatePropertyValue: @Sendable (_ recordID: String, _ key: String, _ value: String) throws -> Void
    var deleteRecord: @Sendable (_ recordID: String) throws -> Void
    var changeRecordDatabase: @Sendable (_ recordID: String, _ newDatabaseID: String) throws -> Void

    var blocks: @Sendable (_ recordID: String) throws -> [BlockRow]
    var createBlock: @Sendable (_ recordID: String, _ after: String?, _ kind: BlockKind, _ text: AttributedString, _ checked: Bool?) throws -> BlockRow
    var updateBlockText: @Sendable (_ blockID: String, _ text: AttributedString) throws -> Void
    var updateBlockKind: @Sendable (_ blockID: String, _ kind: BlockKind, _ text: AttributedString?) throws -> Void
    var updateBlockChecked: @Sendable (_ blockID: String, _ checked: Bool) throws -> Void
    var deleteBlock: @Sendable (_ blockID: String) throws -> Void

    // Tags
    var allTags: @Sendable (_ workspaceID: String) throws -> [TagModel]
    var tagsForRecord: @Sendable (_ recordID: String) throws -> [TagModel]
    var tagsAvailable: @Sendable (_ workspaceID: String, _ databaseID: String) throws -> [TagModel]
    var recordsForTag: @Sendable (_ tagID: String) throws -> [(record: RecordRow, dbName: String)]
    var createTag: @Sendable (_ workspaceID: String, _ name: String, _ scope: TagScope, _ scopeID: String?, _ color: AccentTone) throws -> TagModel
    var deleteTag: @Sendable (_ tagID: String) throws -> Void
    var attachTag: @Sendable (_ recordID: String, _ tagID: String) throws -> Void
    var detachTag: @Sendable (_ recordID: String, _ tagID: String) throws -> Void

    // Assets
    var assetsForRecord: @Sendable (_ recordID: String) throws -> [AssetRecord]
    var importAsset: @Sendable (_ fileURL: URL, _ recordID: String?, _ workspaceID: String) throws -> AssetRecord
    var deleteAsset: @Sendable (_ assetID: String) throws -> Void

    // Cover image
    var importCoverImage: @Sendable (_ fileURL: URL, _ recordID: String, _ workspaceID: String) throws -> AssetRecord
    var setRecordCover: @Sendable (_ recordID: String, _ assetID: String?) throws -> Void

    // Relations
    var outgoingRelations: @Sendable (_ recordID: String) throws -> [RelationLink]
    var outgoingRelationsForProperty: @Sendable (_ recordID: String, _ propertyID: String) throws -> [RelationLink]
    var incomingRelations: @Sendable (_ recordID: String) throws -> [RelationLink]
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

extension DatabaseClient: DependencyKey {
    static let liveValue: DatabaseClient = DatabaseClient(
        areas:           { try dbRead { try DBReads.areas($0) } },
        databases:       { try dbRead { try DBReads.databases($0) } },
        database:        { id in try dbRead { try DBReads.database($0, id: id) } },
        properties:      { dbID in try dbRead { try DBReads.properties($0, databaseID: dbID) } },
        records:         { dbID in try dbRead { try DBReads.records($0, databaseID: dbID) } },
        record:          { id in try dbRead { try DBReads.record($0, id: id) } },
        relatedRecords:  { id in try dbRead { try DBReads.relatedRecords($0, sourceID: id) } },
        paletteItems:    { try dbRead { try DBReads.paletteItems($0) } },
        createRecord:    { dbID, title in try dbWrite { try DBWrites.createRecord($0, databaseID: dbID, title: title) } },
        updateRecordTitle: { id, title in try dbWrite { try DBWrites.updateRecordTitle($0, recordID: id, title: title) } },
        updatePropertyValue: { id, key, value in try dbWrite { try DBWrites.updatePropertyValue($0, recordID: id, propertyKey: key, value: value) } },
        deleteRecord:    { id in try dbWrite { try DBWrites.deleteRecord($0, recordID: id) } },
        changeRecordDatabase: { id, newDB in try dbWrite { try DBWrites.changeRecordDatabase($0, recordID: id, newDatabaseID: newDB) } },
        blocks:          { id in try dbRead { try BlockReads.blocks($0, recordID: id) } },
        createBlock:     { rid, after, kind, text, checked in try dbWrite { try DBWrites.createBlock($0, recordID: rid, after: after, kind: kind, text: text, checked: checked) } },
        updateBlockText: { id, text in try dbWrite { try DBWrites.updateBlockText($0, blockID: id, text: text) } },
        updateBlockKind: { id, kind, text in try dbWrite { try DBWrites.updateBlockKind($0, blockID: id, kind: kind, text: text) } },
        updateBlockChecked: { id, checked in try dbWrite { try DBWrites.updateBlockChecked($0, blockID: id, checked: checked) } },
        deleteBlock:     { id in try dbWrite { try DBWrites.deleteBlock($0, blockID: id) } },

        allTags:         { wsID in try dbRead { try TagReads.tags($0, workspaceID: wsID) } },
        tagsForRecord:   { id in try dbRead { try TagReads.tagsForRecord($0, recordID: id) } },
        tagsAvailable:   { wsID, dbID in try dbRead { try TagReads.tagsAvailable($0, workspaceID: wsID, databaseID: dbID) } },
        recordsForTag:   { id in try dbRead { try TagReads.recordsForTag($0, tagID: id) } },
        createTag:       { wsID, name, scope, scopeID, color in try dbWrite { try DBWrites.createTag($0, workspaceID: wsID, name: name, scope: scope, scopeID: scopeID, color: color) } },
        deleteTag:       { id in try dbWrite { try DBWrites.deleteTag($0, tagID: id) } },
        attachTag:       { recID, tagID in try dbWrite { try DBWrites.attachTag($0, recordID: recID, tagID: tagID) } },
        detachTag:       { recID, tagID in try dbWrite { try DBWrites.detachTag($0, recordID: recID, tagID: tagID) } },

        assetsForRecord: { id in try dbRead { try AssetReads.assets($0, recordID: id) } },
        importAsset:     { url, recID, wsID in try dbWrite { try AssetImporter.importFile($0, fileURL: url, recordID: recID, workspaceID: wsID) } },
        deleteAsset:     { id in try dbWrite { try DBWrites.deleteAsset($0, assetID: id) } },

        importCoverImage: { url, recID, wsID in try dbWrite { try DBWrites.importCoverImage($0, fileURL: url, recordID: recID, workspaceID: wsID) } },
        setRecordCover:   { recID, assetID in try dbWrite { try DBWrites.setRecordCover($0, recordID: recID, assetID: assetID) } },

        outgoingRelations:            { id in try dbRead { try RelationReads.outgoing($0, recordID: id, propertyID: nil) } },
        outgoingRelationsForProperty: { id, propID in try dbRead { try RelationReads.outgoing($0, recordID: id, propertyID: propID) } },
        incomingRelations:            { id in try dbRead { try RelationReads.incoming($0, recordID: id) } },
        relationTargetDatabaseID:     { propID in try dbRead { try RelationReads.relationTargetDB($0, propertyID: propID) } },
        addRelation:                  { src, tgt, propID in try dbWrite { try DBWrites.addRelation($0, sourceRecordID: src, targetRecordID: tgt, propertyID: propID) } },
        removeRelation:               { id in try dbWrite { try DBWrites.removeRelation($0, relationID: id) } }
    )

    static let testValue = DatabaseClient()
}

extension DependencyValues {
    var databaseClient: DatabaseClient {
        get { self[DatabaseClient.self] }
        set { self[DatabaseClient.self] = newValue }
    }
}
