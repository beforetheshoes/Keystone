import Foundation
import Security

/// User-supplied API keys for third-party enrichment providers. Stored in
/// the system Keychain (service `com.ryanleewilliams.keystone.api-keys`)
/// rather than `UserDefaults` so they round-trip safely and never end up
/// in app-state backups.
///
/// Tests inject a memory-backed store via `APIKeys.store = …` so the real
/// keychain stays untouched.
enum APIKeyKind: String, CaseIterable, Sendable {
    case googleBooks = "google_books"
    case tmdb = "tmdb"

    var displayName: String {
        switch self {
        case .googleBooks:  return "Google Books"
        case .tmdb:         return "The Movie Database (TMDB)"
        }
    }

    /// Human description of what this key unlocks. Shown as the section
    /// footer in Settings → API Keys.
    var purpose: String {
        switch self {
        case .googleBooks:
            return "Optional. Books enrichment works without a key — adding one raises the daily request limit."
        case .tmdb:
            return "Required for Movies and TV enrichment. Create a free account at themoviedb.org and copy the v4 read-access token."
        }
    }
}

/// Abstraction layered over `SecItem*` so tests can swap in a memory-backed
/// store via `APIKeys.store`.
protocol KeychainStore: Sendable {
    func get(account: String, service: String) -> String?
    func set(_ value: String?, account: String, service: String)
}

enum APIKeys {
    static let serviceName = "com.ryanleewilliams.keystone.api-keys"

    /// Mutable for tests — production code reads/writes the real keychain.
    nonisolated(unsafe) static var store: KeychainStore = SecItemKeychainStore()

    static func get(_ kind: APIKeyKind) -> String? {
        store.get(account: kind.rawValue, service: serviceName)
    }

    /// Pass `nil` (or empty after trimming) to delete the entry.
    static func set(_ kind: APIKeyKind, _ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        store.set(trimmed?.isEmpty == true ? nil : trimmed,
                  account: kind.rawValue, service: serviceName)
    }
}

/// Production keychain backend. Writes a `kSecClassGenericPassword` item per
/// (service, account) pair; updates are upsert-style (Update first, Add on
/// errSecItemNotFound).
struct SecItemKeychainStore: KeychainStore {
    func get(account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    func set(_ value: String?, account: String, service: String) {
        let baseQuery: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]

        if let value, let data = value.data(using: .utf8) {
            let attributesToUpdate: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributesToUpdate as CFDictionary)
            if updateStatus == errSecItemNotFound {
                var addQuery = baseQuery
                addQuery[kSecValueData as String] = data
                addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                _ = SecItemAdd(addQuery as CFDictionary, nil)
            }
        } else {
            _ = SecItemDelete(baseQuery as CFDictionary)
        }
    }
}

/// In-memory backend used by tests. Swap in via `APIKeys.store = InMemoryKeychainStore()`.
final class InMemoryKeychainStore: KeychainStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()

    func get(account: String, service: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values["\(service)|\(account)"]
    }

    func set(_ value: String?, account: String, service: String) {
        lock.lock(); defer { lock.unlock() }
        let key = "\(service)|\(account)"
        if let value { values[key] = value } else { values.removeValue(forKey: key) }
    }
}
