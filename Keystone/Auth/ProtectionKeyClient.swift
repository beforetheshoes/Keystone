import Foundation
import CryptoKit
import Security
import Dependencies
import DependenciesMacros

/// Protocol for the underlying secret storage. The live impl talks to the
/// system Keychain; tests inject an in-memory replacement so they don't
/// pollute the real keychain or require iCloud Keychain Sync.
protocol ProtectionKeyStore: Sendable {
    /// Read the persisted 32-byte key, or nil if it hasn't been
    /// generated yet. Throws on Keychain errors that aren't
    /// "item not found" (which is `nil`, not an error).
    func read() throws -> Data?
    /// Persist a 32-byte key. Existing item is replaced.
    func write(_ data: Data) throws
    /// Remove the stored key entirely. Used by tests + the future
    /// "rotate keys" / "delete protection" paths.
    func delete() throws
}

/// CryptoKit + Keychain dependency that backs the privacy-lock
/// encryption-at-rest layer. One symmetric key per user, generated on
/// demand and persisted in the Keychain.
///
/// **iCloud Keychain Sync**: items are written with
/// `kSecAttrSynchronizable = true` and `kSecAttrAccessibleAfterFirstUnlock`
/// — required for sync-eligible items. This means: any device signed
/// into the same iCloud account with iCloud Keychain enabled
/// automatically gets the key and can decrypt records. Devices without
/// iCloud Keychain see a per-device key (same access flags, just no
/// cross-device propagation), and protected records won't decrypt on
/// secondary devices until the user re-syncs Keychain.
///
/// **Biometric**: The Keychain item itself is NOT biometric-gated
/// (because `.biometryCurrentSet` is incompatible with sync). The
/// app's `BiometricAuthClient` gates access at the UI layer instead —
/// the user has to authenticate through `AppFeature` before this
/// client will be invoked. This matches the threat model documented
/// in the privacy help doc: defends against off-device attackers
/// (leaked iCloud Drive folder, recovered backup, breached CloudKit
/// zone) but does NOT defend against an unlocked device + working
/// biometric.
@DependencyClient
struct ProtectionKeyClient: Sendable {
    /// True when we have a key on file. UI uses this to decide whether
    /// "encrypt now" needs to generate one or just unlock an existing.
    var hasKey: @Sendable () -> Bool = { false }
    /// Fetch the existing key. Returns nil if none has been generated
    /// yet — caller decides whether to create or fail.
    var loadKey: @Sendable () throws -> SymmetricKey?
    /// Get-or-create the key. Used by the encryption write path.
    var ensureKey: @Sendable () throws -> SymmetricKey
    /// Encrypt arbitrary bytes with AES-GCM. Output is the combined
    /// representation: nonce ‖ ciphertext ‖ tag, ready to round-trip
    /// through SQLite's BLOB column without separate framing.
    var encrypt: @Sendable (_ plaintext: Data) throws -> Data
    /// Decrypt bytes produced by `encrypt`. Throws on any tampering /
    /// missing-key / wrong-key.
    var decrypt: @Sendable (_ ciphertext: Data) throws -> Data
    /// Wipe the stored key. Reserved for tests + future
    /// "delete all protected data" UX. Does NOT decrypt existing
    /// protected records — the caller must run the full decrypt pass
    /// first or accept that protected content becomes unrecoverable.
    var resetKey: @Sendable () throws -> Void
}

extension ProtectionKeyClient {
    /// Errors callers can pattern-match on.
    enum Error: Swift.Error, Equatable {
        case keychainStatus(OSStatus)
        case keychainItemMissing
        case decryptFailed
    }
}

extension ProtectionKeyClient: DependencyKey {
    static var liveValue: ProtectionKeyClient {
        let store = SecItemProtectionKeyStore()
        return makeClient(store: store)
    }

    /// In tests, default to an ephemeral in-memory store + working
    /// crypto. Tests that care about the missing-key path explicitly
    /// pre-empty the store.
    static let testValue: ProtectionKeyClient = makeClient(
        store: InMemoryProtectionKeyStore()
    )

    /// Shared factory used by both liveValue and testValue. Pulled out
    /// so the encrypt/decrypt closures don't have to be duplicated and
    /// the test store can exercise the exact same code path.
    static func makeClient(store: ProtectionKeyStore) -> ProtectionKeyClient {
        return ProtectionKeyClient(
            hasKey: {
                (try? store.read()) ?? nil != nil
            },
            loadKey: {
                guard let raw = try store.read() else { return nil }
                return SymmetricKey(data: raw)
            },
            ensureKey: {
                if let raw = try store.read() {
                    return SymmetricKey(data: raw)
                }
                let key = SymmetricKey(size: .bits256)
                try key.withUnsafeBytes { try store.write(Data($0)) }
                return key
            },
            encrypt: { plaintext in
                let raw = try store.read() ?? {
                    let key = SymmetricKey(size: .bits256)
                    try key.withUnsafeBytes { try store.write(Data($0)) }
                    return key.withUnsafeBytes { Data($0) }
                }()
                let key = SymmetricKey(data: raw)
                let sealed = try AES.GCM.seal(plaintext, using: key)
                guard let combined = sealed.combined else {
                    throw Error.decryptFailed
                }
                return combined
            },
            decrypt: { ciphertext in
                guard let raw = try store.read() else {
                    throw Error.keychainItemMissing
                }
                let key = SymmetricKey(data: raw)
                do {
                    let sealed = try AES.GCM.SealedBox(combined: ciphertext)
                    return try AES.GCM.open(sealed, using: key)
                } catch {
                    throw Error.decryptFailed
                }
            },
            resetKey: {
                try store.delete()
            }
        )
    }
}

extension DependencyValues {
    var protectionKeyClient: ProtectionKeyClient {
        get { self[ProtectionKeyClient.self] }
        set { self[ProtectionKeyClient.self] = newValue }
    }
}

// MARK: - Stores

/// Production Keychain backend. Service+account keyed; sync-eligible.
/// `kSecAttrAccessibleAfterFirstUnlock` is the strictest access class
/// compatible with `kSecAttrSynchronizable=true` — `…ThisDeviceOnly`
/// variants reject sync.
struct SecItemProtectionKeyStore: ProtectionKeyStore {
    static let serviceName = "com.ryanleewilliams.keystone.protection-key"
    static let accountName = "master"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String:                 kSecClassGenericPassword,
            kSecAttrService as String:           Self.serviceName,
            kSecAttrAccount as String:           Self.accountName,
            kSecAttrSynchronizable as String:    true,
        ]
    }

    func read() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw ProtectionKeyClient.Error.keychainStatus(status)
        }
    }

    func write(_ data: Data) throws {
        // Try update first; fall back to add on item-not-found. Same
        // upsert pattern used by APIKeys.SecItemKeychainStore.
        let updateQuery = baseQuery
        let attributesToUpdate: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw ProtectionKeyClient.Error.keychainStatus(updateStatus)
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ProtectionKeyClient.Error.keychainStatus(addStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw ProtectionKeyClient.Error.keychainStatus(status)
        }
    }
}

/// In-memory store used by tests (and by the testValue dependency).
/// Atomic via NSLock so a write from one async task can't race a read
/// from another.
final class InMemoryProtectionKeyStore: ProtectionKeyStore, @unchecked Sendable {
    private var data: Data?
    private let lock = NSLock()

    func read() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return data
    }
    func write(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        self.data = data
    }
    func delete() throws {
        lock.lock(); defer { lock.unlock() }
        self.data = nil
    }
}
