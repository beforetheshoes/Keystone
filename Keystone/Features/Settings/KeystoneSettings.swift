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

    // MARK: - Recent time zones

    static let recentTimeZonesKey = "kst.recentTimeZones"
    static let recentTimeZonesLimit = 8

    /// Most-recently-used IANA time-zone identifiers, newest first. Capped
    /// at `recentTimeZonesLimit`. Used by `TimeZonePickerSheet` to pin
    /// frequent picks above the alphabetized list.
    static var recentTimeZones: [String] {
        let raw = UserDefaults.standard.array(forKey: recentTimeZonesKey) as? [String]
        return raw ?? []
    }

    /// Push `identifier` to the front of the recents list; drop dupes; cap
    /// to `recentTimeZonesLimit`. No-op when `identifier` isn't a known
    /// time zone (defensive — shouldn't happen, but a typo'd id never
    /// makes it into the persisted list).
    static func bumpRecentTimeZone(_ identifier: String) {
        guard TimeZone(identifier: identifier) != nil else { return }
        var list = recentTimeZones
        list.removeAll { $0 == identifier }
        list.insert(identifier, at: 0)
        if list.count > recentTimeZonesLimit { list.removeLast(list.count - recentTimeZonesLimit) }
        UserDefaults.standard.set(list, forKey: recentTimeZonesKey)
    }
}
