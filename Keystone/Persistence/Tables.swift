import Foundation
@preconcurrency import SQLiteData

// `@Table` row types for sqlite-data's CloudKit SyncEngine. These are
// purely additive to the existing raw-SQL reads/writes — the SyncEngine
// references these structs via metatype to know which tables to mirror
// to CloudKit.
//
// Snake_case columns in the schema are mapped to camelCase Swift
// properties via the `@Column` macro from swift-structured-queries.

@Table("workspaces")
struct Workspace: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    @Column("created_at") var createdAt: String
    @Column("updated_at") var updatedAt: String
    @Column("schema_version") var schemaVersion: Int
}

@Table("areas")
struct Area: Identifiable, Equatable, Sendable {
    let id: String
    @Column("workspace_id") var workspaceID: String
    var title: String
    var accent: String
    @Column("sort_index") var sortIndex: Double
}

@Table("databases")
struct ObjectDatabase: Identifiable, Equatable, Sendable {
    let id: String
    @Column("workspace_id") var workspaceID: String
    @Column("area_id") var areaID: String?
    var name: String
    @Column("plural_name") var pluralName: String?
    var icon: String?
    var color: String?
    var accent: String
    var description: String?
    @Column("default_view") var defaultView: String
    @Column("created_at") var createdAt: String
    @Column("updated_at") var updatedAt: String
    @Column("sort_index") var sortIndex: Double
}

@Table("properties")
struct PropertyDef: Identifiable, Equatable, Sendable {
    let id: String
    @Column("database_id") var databaseID: String
    var key: String
    var name: String
    var type: String
    @Column("config_json") var configJSON: String
    @Column("is_required") var isRequired: Int
    @Column("is_archived") var isArchived: Int
    @Column("created_at") var createdAt: String
    @Column("updated_at") var updatedAt: String
    @Column("sort_index") var sortIndex: Double
}

@Table("records")
struct Record: Identifiable, Equatable, Sendable {
    let id: String
    @Column("database_id") var databaseID: String
    var title: String
    var subtitle: String?
    var glyph: String
    var tone: String
    var icon: String?
    @Column("cover_asset_id") var coverAssetID: String?
    @Column("template_id") var templateID: String?
    @Column("created_at") var createdAt: String
    @Column("updated_at") var updatedAt: String
    @Column("archived_at") var archivedAt: String?
    @Column("deleted_at") var deletedAt: String?
    @Column("sort_index") var sortIndex: Double
    /// Workspace-relative path to the markdown sidecar this record
    /// is mirrored to (added in migration v33). `nil` for records
    /// that have no on-disk twin.
    @Column("sidecar_path") var sidecarPath: String?
}

@Table("property_values")
struct PropertyValueRow: Identifiable, Equatable, Sendable {
    let id: String
    @Column("record_id") var recordID: String
    @Column("property_id") var propertyID: String
    @Column("text_value") var textValue: String?
    @Column("number_value") var numberValue: Double?
    @Column("bool_value") var boolValue: Int?
    @Column("date_value") var dateValue: String?
    @Column("json_value") var jsonValue: String?
    @Column("created_at") var createdAt: String
    @Column("updated_at") var updatedAt: String
}

@Table("blocks")
struct Block: Identifiable, Equatable, Sendable {
    let id: String
    @Column("record_id") var recordID: String
    @Column("parent_block_id") var parentBlockID: String?
    var type: String
    @Column("content_json") var contentJSON: String
    @Column("sort_index") var sortIndex: Double
    @Column("created_at") var createdAt: String
    @Column("updated_at") var updatedAt: String
    @Column("deleted_at") var deletedAt: String?
}

@Table("tags")
struct TagRow: Identifiable, Equatable, Sendable {
    let id: String
    @Column("workspace_id") var workspaceID: String
    var name: String
    @Column("scope_type") var scopeType: String
    @Column("scope_id") var scopeID: String?
    var color: String?
    var description: String?
    @Column("created_at") var createdAt: String
    @Column("updated_at") var updatedAt: String
}

@Table("record_tags")
struct RecordTag: Identifiable, Equatable, Sendable {
    let id: String
    @Column("record_id") var recordID: String
    @Column("tag_id") var tagID: String
    @Column("created_at") var createdAt: String
}

@Table("relations")
struct RelationRow: Identifiable, Equatable, Sendable {
    let id: String
    @Column("source_record_id") var sourceRecordID: String
    @Column("target_record_id") var targetRecordID: String
    @Column("relation_type") var relationType: String?
    @Column("property_id") var propertyID: String?
    @Column("created_at") var createdAt: String
    @Column("updated_at") var updatedAt: String
}

@Table("assets")
struct AssetRow: Identifiable, Equatable, Sendable {
    let id: String
    @Column("workspace_id") var workspaceID: String
    @Column("record_id") var recordID: String?
    @Column("original_filename") var originalFilename: String
    @Column("stored_filename") var storedFilename: String
    @Column("relative_path") var relativePath: String
    @Column("mime_type") var mimeType: String?
    @Column("file_extension") var fileExtension: String?
    @Column("byte_size") var byteSize: Int64?
    @Column("content_hash") var contentHash: String?
    @Column("extracted_text") var extractedText: String?
    @Column("metadata_json") var metadataJSON: String
    @Column("created_at") var createdAt: String
    @Column("updated_at") var updatedAt: String
}

@Table("views")
struct ViewDef: Identifiable, Equatable, Sendable {
    let id: String
    @Column("database_id") var databaseID: String?
    @Column("workspace_id") var workspaceID: String
    var name: String
    var type: String
    @Column("query_json") var queryJSON: String
    @Column("presentation_json") var presentationJSON: String
    @Column("created_at") var createdAt: String
    @Column("updated_at") var updatedAt: String
    /// Sidebar grouping (added v41). Optional; when set, the view renders
    /// as a sidebar row inside the named area alongside databases.
    @Column("area_id") var areaID: String?
    @Column("sort_index") var sortIndex: Double
    var icon: String?
    var accent: String
    @Column("plural_name") var pluralName: String?
}
