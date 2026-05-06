import Foundation

enum CloudKitConfig {
    /// Must match the `com.apple.developer.icloud-container-identifiers`
    /// entry in `Keystone.entitlements`. Apple's convention is
    /// `iCloud.<bundle-id>`.
    static let containerIdentifier = "iCloud.com.ryanleewilliams.keystone"
}
