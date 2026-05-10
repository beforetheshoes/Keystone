import XCTest
import CryptoKit
import Dependencies
@testable import Keystone

/// Crypto correctness + key-lifecycle tests for ProtectionKeyClient.
/// All exercise the in-memory store so they don't touch the real
/// Keychain — required because CI doesn't run inside a logged-in
/// keychain context anyway.
final class ProtectionKeyClientTests: XCTestCase {

    // MARK: - Setup helpers

    /// Build a fresh client backed by a fresh in-memory store. Each
    /// test gets its own instance so cross-test state can't leak.
    private func freshClient() -> (client: ProtectionKeyClient, store: InMemoryProtectionKeyStore) {
        let store = InMemoryProtectionKeyStore()
        let client = ProtectionKeyClient.makeClient(store: store)
        return (client, store)
    }

    // MARK: - Key lifecycle

    func testHasKeyFalseInitiallyTrueAfterEnsure() throws {
        let (client, _) = freshClient()
        XCTAssertFalse(client.hasKey())
        _ = try client.ensureKey()
        XCTAssertTrue(client.hasKey())
    }

    func testEnsureKeyIsIdempotent() throws {
        let (client, _) = freshClient()
        let k1 = try client.ensureKey()
        let k2 = try client.ensureKey()
        XCTAssertEqual(k1.dataRepresentation, k2.dataRepresentation)
    }

    func testLoadKeyReturnsNilBeforeEnsure() throws {
        let (client, _) = freshClient()
        XCTAssertNil(try client.loadKey())
    }

    func testResetKeyRemovesIt() throws {
        let (client, _) = freshClient()
        _ = try client.ensureKey()
        XCTAssertTrue(client.hasKey())
        try client.resetKey()
        XCTAssertFalse(client.hasKey())
        XCTAssertNil(try client.loadKey())
    }

    // MARK: - Encrypt / decrypt round-trip

    func testEncryptDecryptRoundTrip() throws {
        let (client, _) = freshClient()
        let plaintext = "The quick brown fox jumps over the lazy dog 🦊".data(using: .utf8)!
        let cipher = try client.encrypt(plaintext)
        XCTAssertNotEqual(cipher, plaintext, "ciphertext must differ from plaintext")
        let recovered = try client.decrypt(cipher)
        XCTAssertEqual(recovered, plaintext)
    }

    func testEncryptProducesNoncedOutputEachCall() throws {
        let (client, _) = freshClient()
        let plaintext = "stable input".data(using: .utf8)!
        let c1 = try client.encrypt(plaintext)
        let c2 = try client.encrypt(plaintext)
        XCTAssertNotEqual(c1, c2, "AES-GCM nonce randomization should make repeated encryptions differ")
        // But both should decrypt back to the same input.
        XCTAssertEqual(try client.decrypt(c1), plaintext)
        XCTAssertEqual(try client.decrypt(c2), plaintext)
    }

    func testDecryptingTamperedCiphertextThrows() throws {
        let (client, _) = freshClient()
        let plaintext = "secret".data(using: .utf8)!
        var cipher = try client.encrypt(plaintext)
        // Flip a byte in the middle of the ciphertext (well past the
        // 12-byte nonce, well before the 16-byte tag at the end).
        let tamperIndex = cipher.count / 2
        cipher[tamperIndex] ^= 0xFF
        XCTAssertThrowsError(try client.decrypt(cipher))
    }

    func testDecryptingWithDifferentKeyThrows() throws {
        let (clientA, _) = freshClient()
        let (clientB, _) = freshClient()
        let plaintext = "same message".data(using: .utf8)!
        let cipherFromA = try clientA.encrypt(plaintext)
        XCTAssertThrowsError(try clientB.decrypt(cipherFromA))
    }

    // MARK: - Key persistence

    func testKeyPersistsAcrossClientInstancesBackedBySameStore() throws {
        let store = InMemoryProtectionKeyStore()
        let c1 = ProtectionKeyClient.makeClient(store: store)
        let key1 = try c1.ensureKey()

        // Build a fresh client backed by the same store — same key.
        let c2 = ProtectionKeyClient.makeClient(store: store)
        let key2 = try XCTUnwrap(try c2.loadKey())
        XCTAssertEqual(key1.dataRepresentation, key2.dataRepresentation)

        // And ciphertext from c1 is decryptable by c2.
        let cipher = try c1.encrypt(Data([1, 2, 3, 4]))
        XCTAssertEqual(try c2.decrypt(cipher), Data([1, 2, 3, 4]))
    }

    func testDecryptThrowsKeychainItemMissingWhenNoKey() throws {
        let (client, store) = freshClient()
        let plaintext = Data([5, 6, 7])
        let cipher = try client.encrypt(plaintext)
        // Wipe the key out from under the client; decrypt should fail
        // with the dedicated case so callers can distinguish "no key
        // here yet" from "wrong key / tampered ciphertext".
        try store.delete()
        XCTAssertThrowsError(try client.decrypt(cipher)) { error in
            guard let typed = error as? ProtectionKeyClient.Error else {
                return XCTFail("Expected ProtectionKeyClient.Error, got \(error)")
            }
            XCTAssertEqual(typed, .keychainItemMissing)
        }
    }
}

private extension SymmetricKey {
    var dataRepresentation: Data {
        withUnsafeBytes { Data($0) }
    }
}
