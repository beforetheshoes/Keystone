import Foundation

/// Thin glue between Keystone's string-keyed property values and the
/// AES-GCM ciphertext stored in `property_values.enc_value` /
/// `blocks.enc_content`. Built around two opaque closures so the
/// underlying ProtectionKeyClient can be injected via TCA deps without
/// every call site importing CryptoKit.
///
/// `disabled` is the no-op variant used by code paths that don't have
/// access to the key (current concern: tests that don't need to
/// exercise crypto at all). The live DatabaseClient binds these
/// closures to the real ProtectionKeyClient so production reads/writes
/// just work; the abstraction exists so DBReads/DBWrites stay testable
/// in isolation.
struct ValueEncryptor: Sendable {
    /// Encrypt a UTF-8 string to AES-GCM ciphertext (combined nonce ‖
    /// ct ‖ tag, ready to round-trip through SQLite as a BLOB).
    var encrypt: @Sendable (String) throws -> Data
    /// Decrypt a combined-form ciphertext back to UTF-8.
    var decrypt: @Sendable (Data) throws -> String

    /// No-op used by tests + read paths that explicitly want to see
    /// raw `[encrypted]` placeholders. Both closures throw, so any
    /// accidental real use trips loudly.
    static let disabled = ValueEncryptor(
        encrypt: { _ in throw EncryptorError.disabled },
        decrypt: { _ in throw EncryptorError.disabled }
    )

    enum EncryptorError: Error, Equatable {
        case disabled
        case nonUTF8
    }
}
