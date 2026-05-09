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

    // MARK: - Behavior

    /// Whether picking a candidate from the lookup-first creation sheet
    /// (Books / Movies / TV / Vendors) navigates straight into the new
    /// record's detail view. Default `false` — the rapid-add flow keeps
    /// the user on the gallery so they can add another record without
    /// a back-button round-trip. Toggle in Settings → Behavior.
    static let openInDetailAfterAddKey = "openInDetailAfterAdd"

    static var openInDetailAfterAdd: Bool {
        UserDefaults.standard.bool(forKey: openInDetailAfterAddKey)
    }

    // MARK: - Privacy

    /// When true, Keystone shows a biometric lock screen on launch (and
    /// after a manual "Lock now") that blocks the workspace until the
    /// user authenticates. Independent of per-record protection — see
    /// `protectedRecordsHiddenWhenAppLockOff` for the policy that
    /// governs whether protected records are filtered while app lock
    /// itself is off. Default `false`; toggle in Settings → Privacy.
    static let appLockEnabledKey = "appLockEnabled"

    static var appLockEnabled: Bool {
        UserDefaults.standard.bool(forKey: appLockEnabledKey)
    }

    /// When true (default), records flagged `is_protected = true` are
    /// hidden from every UI surface even when app-launch lock is OFF.
    /// Lets a user use per-record protection without forcing biometrics
    /// on launch. When false AND `appLockEnabled` is false, protection
    /// becomes a no-op — the property is preserved but no filtering
    /// happens.
    static let protectedRecordsHiddenWhenAppLockOffKey = "protectedRecordsHiddenWhenAppLockOff"

    static var protectedRecordsHiddenWhenAppLockOff: Bool {
        // Default true — explicit registration so a user who has never
        // touched the toggle still gets the protective behavior.
        if UserDefaults.standard.object(forKey: protectedRecordsHiddenWhenAppLockOffKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: protectedRecordsHiddenWhenAppLockOffKey)
    }

    /// True when protected records should currently be filtered from UI:
    /// either because app lock is on (so we always filter when locked),
    /// or because the user opted in to filtering even with app lock off.
    static var protectionFilteringActive: Bool {
        appLockEnabled || protectedRecordsHiddenWhenAppLockOff
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
