import Foundation

/// Thin glue between Keystone's string-keyed property values and the
/// AES-GCM ciphertext stored in `property_values.enc_value` /
/// `blocks.enc_content`. Built around two opaque closures so the
/// underlying ProtectionKeyClient can be injected via TCA deps without
/// every call site importing CryptoKit.
///
/// **Per-record binding** (#14): each `ValueEncryptor` instance is tied
/// to a single `recordID`. Construction goes through
/// `ValueEncryptor.live(recordID:keys:)` which closes over the record
/// id, so the encrypt/decrypt closures can resolve the right per-record
/// key without each call site passing it through.
///
/// `disabled` is the no-op variant used by code paths that don't have
/// access to the key (current concern: tests that don't need to
/// exercise crypto at all). Both closures throw, so any accidental real
/// use trips loudly.
struct ValueEncryptor: Sendable {
    /// Encrypt a UTF-8 string to AES-GCM ciphertext (combined nonce ‖
    /// ct ‖ tag, ready to round-trip through SQLite as a BLOB).
    var encrypt: @Sendable (String) throws -> Data
    /// Decrypt a combined-form ciphertext back to UTF-8.
    var decrypt: @Sendable (Data) throws -> String

    static let disabled = ValueEncryptor(
        encrypt: { _ in throw EncryptorError.disabled },
        decrypt: { _ in throw EncryptorError.disabled }
    )

    enum EncryptorError: Error, Equatable {
        case disabled
        case nonUTF8
    }
}

extension ValueEncryptor {
    /// Build an encryptor bound to `recordID` against the live
    /// ProtectionKeyClient. All encrypt/decrypt calls on the returned
    /// instance use that record's per-record symmetric key.
    static func live(recordID: String, keys: ProtectionKeyClient) -> ValueEncryptor {
        ValueEncryptor(
            encrypt: { plain in
                try keys.encryptForRecord(recordID, Data(plain.utf8))
            },
            decrypt: { cipher in
                let bytes = try keys.decryptForRecord(recordID, cipher)
                guard let s = String(data: bytes, encoding: .utf8) else {
                    throw EncryptorError.nonUTF8
                }
                return s
            }
        )
    }
}

/// Resolves a `ValueEncryptor` for any given `recordID`. Multi-record
/// read paths (e.g. `DBReads.records(databaseID:)`) take one of these
/// instead of a fixed encryptor so each row decrypts under its own
/// per-record key.
typealias ValueEncryptorProvider = @Sendable (_ recordID: String) -> ValueEncryptor

extension ValueEncryptor {
    /// Provider that returns a live per-record encryptor against
    /// `keys`. Safe to capture by value — `ProtectionKeyClient` is
    /// `Sendable`.
    static func liveProvider(keys: ProtectionKeyClient) -> ValueEncryptorProvider {
        return { recordID in
            ValueEncryptor.live(recordID: recordID, keys: keys)
        }
    }
}
