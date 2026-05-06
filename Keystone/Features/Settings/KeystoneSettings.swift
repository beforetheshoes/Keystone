import Foundation
#if os(iOS)
import UIKit
#endif

enum KeystoneSettings {
    static let displayNameKey = "displayName"

    /// The OS-provided full name when available. Empty string if there's no
    /// reliable system source (iOS doesn't expose a user full name).
    static var systemDisplayName: String {
        #if os(macOS)
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        if !full.isEmpty { return full }
        return NSUserName()
        #else
        return ""
        #endif
    }

    /// Resolved name to greet the user with: the override they set in Settings,
    /// falling back to the system name. May be empty.
    static func resolvedDisplayName() -> String {
        let override = UserDefaults.standard
            .string(forKey: displayNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !override.isEmpty { return override }
        return systemDisplayName
    }

    /// Just the first word of the resolved name — useful for short greetings.
    static func resolvedFirstName() -> String {
        let full = resolvedDisplayName()
        return full.split(separator: " ").first.map(String.init) ?? full
    }
}
