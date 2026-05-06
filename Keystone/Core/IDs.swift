import Foundation

public protocol KeystoneID: Hashable, Codable, Sendable, RawRepresentable where RawValue == String {
    init(rawValue: String)
}

public extension KeystoneID {
    static func generate() -> Self { Self(rawValue: UUID().uuidString) }
}

public struct WorkspaceID: KeystoneID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct DatabaseID:  KeystoneID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct RecordID:    KeystoneID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct PropertyID:  KeystoneID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct BlockID:     KeystoneID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct AssetID:     KeystoneID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct TagID:       KeystoneID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct ViewID:      KeystoneID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct TemplateID:  KeystoneID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct AreaID:      KeystoneID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
