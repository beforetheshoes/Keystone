import Foundation
import CryptoKit
import Security
import Synchronization
import Dependencies
import DependenciesMacros

/// Protocol for the underlying secret storage. The live impl talks to the
/// system Keychain; tests inject an in-memory replacement so they don't
/// pollute the real keychain or require iCloud Keychain Sync.
///
/// Items are addressed by `(service, account)` — service identifies the
/// purpose (workspace key vs per-record key), account identifies the
/// instance (constant `"master"` for the legacy workspace key, the
/// `record_id` for per-record keys).
protocol ProtectionKeyStore: Sendable {
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

/// CryptoKit + Keychain dependency that backs the privacy-lock
/// encryption-at-rest layer. v1 of #9 used a single workspace-wide
/// symmetric key. CKShare cross-user sharing (#14) required moving to
/// **per-record symmetric keys** so that sharing one protected record
/// hands the recipient only that record's key — never any other
/// protected record's data.
///
/// **Storage layout:**
///
/// - Per-record keys live under
///   `kSecAttrService = "com.ryanleewilliams.keystone.record-key"`,
///   `kSecAttrAccount = <recordID>`. iCloud-Keychain-synced so the
///   owner's other devices automatically get the same keys.
/// - The legacy workspace key (#9 vintage) lives under
///   `kSecAttrService = "com.ryanleewilliams.keystone.protection-key"`,
///   `kSecAttrAccount = "master"`. Read by the one-shot rotation job in
///   `Bootstrap.runProtectionKeyRotationIfNeeded`; deleted at the end
///   of rotation. Its absence is the durable signal that rotation is
///   complete on this account.
///
/// **iCloud Keychain Sync**: items are written with
/// `kSecAttrSynchronizable = true` and `kSecAttrAccessibleAfterFirstUnlock`
/// — required for sync-eligible items. Devices signed into the same
/// iCloud account with iCloud Keychain enabled automatically replicate
/// keys, so a record encrypted on Mac1 decrypts on Mac2 once the
/// keychain syncs.
///
/// **Biometric**: Keychain items are NOT biometric-gated
/// (`.biometryCurrentSet` is incompatible with sync). The app's
/// `BiometricAuthClient` gates access at the UI layer. Threat model
/// matches #9: defends against off-device attackers (leaked iCloud
/// Drive folder, recovered backup, breached CloudKit zone) but does
/// NOT defend against an unlocked device + working biometric.
@DependencyClient
struct ProtectionKeyClient: Sendable {
    // MARK: - Per-record keys (the v1 surface used by all encrypt/decrypt)

    /// Get-or-create a symmetric key for `recordID`. Always succeeds:
    /// generates a fresh AES-256-GCM key on first call and stores it in
    /// iCloud Keychain. Idempotent across the user's devices because
    /// the keychain item syncs.
    var recordKey: @Sendable (_ recordID: String) throws -> SymmetricKey

    /// Store an externally-supplied key under `recordID`. Used by the
    /// share-acceptance path: when a CKShare carries
    /// `encryptedValues["keystone_record_key"]`, the recipient calls
    /// this to install the key locally so subsequent reads decrypt.
    var installRecordKey: @Sendable (_ recordID: String, _ keyData: Data) throws -> Void

    /// Remove a record's key entirely. Called when a record's
    /// `is_protected` toggles back to false — once decrypt-then-clear
    /// has run, no future encryption will need this key.
    var deleteRecordKey: @Sendable (_ recordID: String) throws -> Void

    /// Encrypt UTF-8 plaintext under `recordID`'s key. Output is the
    /// AES-GCM combined representation (nonce ‖ ct ‖ tag). Generates
    /// the key on first call.
    var encryptForRecord: @Sendable (_ recordID: String, _ plaintext: Data) throws -> Data

    /// Decrypt ciphertext for `recordID`. Tries the per-record key
    /// first; if that fails AND a legacy workspace key still exists in
    /// the keychain (mid-rotation), retries with the workspace key so
    /// not-yet-rotated rows still read correctly. Once rotation
    /// completes the workspace key is gone and only the per-record
    /// path runs.
    var decryptForRecord: @Sendable (_ recordID: String, _ ciphertext: Data) throws -> Data

    /// True iff a per-record key exists for `recordID`. Used by the
    /// share path to decide whether to wrap a key into the CKShare.
    var hasRecordKey: @Sendable (_ recordID: String) -> Bool = { _ in false }

    /// Read the raw key bytes for `recordID` so the share path can wrap
    /// them into `CKShare.encryptedValues`. Returns nil if no key
    /// exists yet (record was never encrypted).
    var exportRecordKey: @Sendable (_ recordID: String) throws -> Data?

    // MARK: - Legacy workspace key (rotation-only)

    /// Returns the legacy workspace key if it still exists, nil
    /// otherwise. Nil is the durable signal that rotation has completed
    /// on this account (the keychain item, once deleted, syncs the
    /// deletion to every other device of the same iCloud account).
    var legacyWorkspaceKey: @Sendable () throws -> SymmetricKey?

    /// Wipe the legacy workspace key. Called at the end of the
    /// `Bootstrap.runProtectionKeyRotationIfNeeded` job, after every
    /// pre-existing protected row has been re-encrypted under its
    /// per-record key.
    var dropLegacyWorkspaceKey: @Sendable () throws -> Void
}

extension ProtectionKeyClient {
    enum Error: Swift.Error, Equatable {
        case keychainStatus(OSStatus)
        case keychainItemMissing
        case decryptFailed
    }

    static let recordKeyService = "com.ryanleewilliams.keystone.record-key"
    static let workspaceKeyService = "com.ryanleewilliams.keystone.protection-key"
    static let workspaceKeyAccount = "master"
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

    /// Shared factory used by both liveValue and testValue.
    static func makeClient(store: ProtectionKeyStore) -> ProtectionKeyClient {
        // Internal helpers — closed-over by the closures below.
        @Sendable func ensureRecord(_ recordID: String) throws -> SymmetricKey {
            if let raw = try store.read(service: recordKeyService, account: recordID) {
                return SymmetricKey(data: raw)
            }
            let key = SymmetricKey(size: .bits256)
            let data = key.withUnsafeBytes { Data($0) }
            try store.write(data, service: recordKeyService, account: recordID)
            return key
        }

        @Sendable func loadRecord(_ recordID: String) throws -> SymmetricKey? {
            guard let raw = try store.read(service: recordKeyService, account: recordID) else {
                return nil
            }
            return SymmetricKey(data: raw)
        }

        @Sendable func loadWorkspace() throws -> SymmetricKey? {
            guard let raw = try store.read(service: workspaceKeyService, account: workspaceKeyAccount) else {
                return nil
            }
            return SymmetricKey(data: raw)
        }

        return ProtectionKeyClient(
            recordKey: { recordID in
                try ensureRecord(recordID)
            },
            installRecordKey: { recordID, keyData in
                try store.write(keyData, service: recordKeyService, account: recordID)
            },
            deleteRecordKey: { recordID in
                try store.delete(service: recordKeyService, account: recordID)
            },
            encryptForRecord: { recordID, plaintext in
                let key = try ensureRecord(recordID)
                let sealed = try AES.GCM.seal(plaintext, using: key)
                guard let combined = sealed.combined else {
                    throw Error.decryptFailed
                }
                return combined
            },
            decryptForRecord: { recordID, ciphertext in
                // Per-record key first. Mid-rotation rows may still be
                // workspace-key-encrypted; fall back if the per-record
                // open throws.
                if let key = try loadRecord(recordID) {
                    if let sealed = try? AES.GCM.SealedBox(combined: ciphertext),
                       let plain = try? AES.GCM.open(sealed, using: key) {
                        return plain
                    }
                }
                if let workspace = try loadWorkspace() {
                    do {
                        let sealed = try AES.GCM.SealedBox(combined: ciphertext)
                        return try AES.GCM.open(sealed, using: workspace)
                    } catch {
                        throw Error.decryptFailed
                    }
                }
                throw Error.keychainItemMissing
            },
            hasRecordKey: { recordID in
                ((try? store.read(service: recordKeyService, account: recordID)) ?? nil) != nil
            },
            exportRecordKey: { recordID in
                try store.read(service: recordKeyService, account: recordID)
            },
            legacyWorkspaceKey: {
                try loadWorkspace()
            },
            dropLegacyWorkspaceKey: {
                try store.delete(service: workspaceKeyService, account: workspaceKeyAccount)
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
    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String:                 kSecClassGenericPassword,
            kSecAttrService as String:           service,
            kSecAttrAccount as String:           account,
            kSecAttrSynchronizable as String:    true,
        ]
    }

    func read(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
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

    func write(_ data: Data, service: String, account: String) throws {
        let updateQuery = baseQuery(service: service, account: account)
        let attributesToUpdate: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw ProtectionKeyClient.Error.keychainStatus(updateStatus)
        }

        var addQuery = baseQuery(service: service, account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ProtectionKeyClient.Error.keychainStatus(addStatus)
        }
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw ProtectionKeyClient.Error.keychainStatus(status)
        }
    }
}

/// In-memory store used by tests + the testValue dependency. All
/// mutable state lives inside a `Mutex`, so the compiler synthesizes
/// `Sendable` conformance automatically — no `@unchecked` escape.
final class InMemoryProtectionKeyStore: ProtectionKeyStore {
    private let items = Mutex<[String: Data]>([:])

    private nonisolated static func key(service: String, account: String) -> String {
        "\(service)|\(account)"
    }

    func read(service: String, account: String) throws -> Data? {
        items.withLock { $0[Self.key(service: service, account: account)] }
    }

    func write(_ data: Data, service: String, account: String) throws {
        items.withLock { $0[Self.key(service: service, account: account)] = data }
    }

    func delete(service: String, account: String) throws {
        items.withLock { $0[Self.key(service: service, account: account)] = nil }
    }
}

private let recordKeyService = ProtectionKeyClient.recordKeyService
private let workspaceKeyService = ProtectionKeyClient.workspaceKeyService
private let workspaceKeyAccount = ProtectionKeyClient.workspaceKeyAccount
