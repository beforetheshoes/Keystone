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

    // MARK: - Per-record key lifecycle

    func testHasRecordKeyFalseUntilFirstUse() throws {
        let (client, _) = freshClient()
        XCTAssertFalse(client.hasRecordKey("rec-A"))
        _ = try client.recordKey("rec-A")
        XCTAssertTrue(client.hasRecordKey("rec-A"))
    }

    func testRecordKeyIsIdempotent() throws {
        let (client, _) = freshClient()
        let k1 = try client.recordKey("rec-A")
        let k2 = try client.recordKey("rec-A")
        XCTAssertEqual(k1.dataRepresentation, k2.dataRepresentation)
    }

    func testEachRecordHasItsOwnKey() throws {
        let (client, _) = freshClient()
        let kA = try client.recordKey("rec-A")
        let kB = try client.recordKey("rec-B")
        XCTAssertNotEqual(
            kA.dataRepresentation, kB.dataRepresentation,
            "different recordIDs must produce different keys"
        )
    }

    func testDeleteRecordKeyRemovesIt() throws {
        let (client, _) = freshClient()
        _ = try client.recordKey("rec-A")
        XCTAssertTrue(client.hasRecordKey("rec-A"))
        try client.deleteRecordKey("rec-A")
        XCTAssertFalse(client.hasRecordKey("rec-A"))
    }

    func testInstallRecordKeyAcceptsExternalKey() throws {
        let (clientA, storeA) = freshClient()
        let kA = try clientA.recordKey("rec-A")
        let exported = try XCTUnwrap(try clientA.exportRecordKey("rec-A"))

        // Different store (simulating a different device) — installing
        // the same bytes lets it decrypt ciphertext from clientA.
        let storeB = InMemoryProtectionKeyStore()
        let clientB = ProtectionKeyClient.makeClient(store: storeB)
        XCTAssertFalse(clientB.hasRecordKey("rec-A"))
        try clientB.installRecordKey("rec-A", exported)
        XCTAssertTrue(clientB.hasRecordKey("rec-A"))

        let plaintext = Data("hello".utf8)
        let cipher = try clientA.encryptForRecord("rec-A", plaintext)
        let recovered = try clientB.decryptForRecord("rec-A", cipher)
        XCTAssertEqual(recovered, plaintext)
        XCTAssertEqual(kA.dataRepresentation, exported)
        _ = storeA  // silence unused warning
    }

    // MARK: - Encrypt / decrypt round-trip

    func testEncryptDecryptRoundTrip() throws {
        let (client, _) = freshClient()
        let plaintext = "The quick brown fox jumps over the lazy dog 🦊".data(using: .utf8)!
        let cipher = try client.encryptForRecord("rec-A", plaintext)
        XCTAssertNotEqual(cipher, plaintext, "ciphertext must differ from plaintext")
        let recovered = try client.decryptForRecord("rec-A", cipher)
        XCTAssertEqual(recovered, plaintext)
    }

    func testEncryptProducesNoncedOutputEachCall() throws {
        let (client, _) = freshClient()
        let plaintext = "stable input".data(using: .utf8)!
        let c1 = try client.encryptForRecord("rec-A", plaintext)
        let c2 = try client.encryptForRecord("rec-A", plaintext)
        XCTAssertNotEqual(c1, c2, "AES-GCM nonce randomization should make repeated encryptions differ")
        XCTAssertEqual(try client.decryptForRecord("rec-A", c1), plaintext)
        XCTAssertEqual(try client.decryptForRecord("rec-A", c2), plaintext)
    }

    func testDecryptingTamperedCiphertextThrows() throws {
        let (client, _) = freshClient()
        let plaintext = "secret".data(using: .utf8)!
        var cipher = try client.encryptForRecord("rec-A", plaintext)
        // Flip a byte well past the 12-byte nonce, well before the
        // 16-byte tag at the end.
        let tamperIndex = cipher.count / 2
        cipher[tamperIndex] ^= 0xFF
        XCTAssertThrowsError(try client.decryptForRecord("rec-A", cipher))
    }

    func testDecryptingWithDifferentRecordKeyThrows() throws {
        let (client, _) = freshClient()
        _ = try client.recordKey("rec-A")
        _ = try client.recordKey("rec-B")
        let plaintext = "same message".data(using: .utf8)!
        let cipherFromA = try client.encryptForRecord("rec-A", plaintext)
        // Decrypting under rec-B's key should fail. With no legacy
        // workspace key in the store, the fall-back path doesn't kick
        // in either.
        XCTAssertThrowsError(try client.decryptForRecord("rec-B", cipherFromA))
    }

    // MARK: - Cross-instance persistence (same store = same device)

    func testKeyPersistsAcrossClientInstancesBackedBySameStore() throws {
        let store = InMemoryProtectionKeyStore()
        let c1 = ProtectionKeyClient.makeClient(store: store)
        let key1 = try c1.recordKey("rec-A")

        let c2 = ProtectionKeyClient.makeClient(store: store)
        let key2 = try c2.recordKey("rec-A")
        XCTAssertEqual(key1.dataRepresentation, key2.dataRepresentation)

        let cipher = try c1.encryptForRecord("rec-A", Data([1, 2, 3, 4]))
        XCTAssertEqual(try c2.decryptForRecord("rec-A", cipher), Data([1, 2, 3, 4]))
    }

    func testDecryptThrowsKeychainItemMissingWhenNoKey() throws {
        let (client, store) = freshClient()
        let plaintext = Data([5, 6, 7])
        let cipher = try client.encryptForRecord("rec-A", plaintext)
        // Wipe the key out from under the client; decrypt should fail
        // with the dedicated case so callers can distinguish "no key
        // here yet" from "wrong key / tampered ciphertext".
        try store.delete(service: ProtectionKeyClient.recordKeyService, account: "rec-A")
        XCTAssertThrowsError(try client.decryptForRecord("rec-A", cipher)) { error in
            guard let typed = error as? ProtectionKeyClient.Error else {
                return XCTFail("Expected ProtectionKeyClient.Error, got \(error)")
            }
            XCTAssertEqual(typed, .keychainItemMissing)
        }
    }

    // MARK: - Legacy workspace key + rotation fallback

    func testLegacyWorkspaceKeyAbsentByDefault() throws {
        let (client, _) = freshClient()
        XCTAssertNil(try client.legacyWorkspaceKey())
    }

    func testFallsBackToWorkspaceKeyWhenPerRecordMissing() throws {
        // Simulate the mid-rotation state: a row is still encrypted
        // under the workspace key, but the per-record key hasn't been
        // generated yet for that record.
        let store = InMemoryProtectionKeyStore()
        let workspaceKey = SymmetricKey(size: .bits256)
        let workspaceKeyData = workspaceKey.withUnsafeBytes { Data($0) }
        try store.write(
            workspaceKeyData,
            service: ProtectionKeyClient.workspaceKeyService,
            account: ProtectionKeyClient.workspaceKeyAccount
        )

        // Encrypt a row under the workspace key directly (i.e. how a
        // pre-#14 build would have written it).
        let plaintext = Data("legacy row".utf8)
        let sealed = try AES.GCM.seal(plaintext, using: workspaceKey)
        let cipher = try XCTUnwrap(sealed.combined)

        let client = ProtectionKeyClient.makeClient(store: store)
        // No per-record key exists for "rec-A" yet. decryptForRecord
        // should still recover plaintext via the workspace fallback.
        let recovered = try client.decryptForRecord("rec-A", cipher)
        XCTAssertEqual(recovered, plaintext)
    }

    func testDropLegacyWorkspaceKeyRemovesIt() throws {
        let (client, store) = freshClient()
        // Seed a workspace key.
        try store.write(
            SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) },
            service: ProtectionKeyClient.workspaceKeyService,
            account: ProtectionKeyClient.workspaceKeyAccount
        )
        XCTAssertNotNil(try client.legacyWorkspaceKey())
        try client.dropLegacyWorkspaceKey()
        XCTAssertNil(try client.legacyWorkspaceKey())
    }
}

private extension SymmetricKey {
    var dataRepresentation: Data {
        withUnsafeBytes { Data($0) }
    }
}
