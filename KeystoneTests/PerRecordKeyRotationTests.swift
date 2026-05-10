import XCTest
import CryptoKit
import Dependencies
import GRDB
@testable import Keystone

/// Exercises the per-record-key rotation job. Idempotency, restart
/// semantics, and key isolation are all property invariants that
/// `Bootstrap.runProtectionKeyRotationIfNeeded` depends on.
final class PerRecordKeyRotationTests: XCTestCase {

    /// Build a fresh in-memory keychain stub seeded with a workspace
    /// key that simulates a pre-#14 install. Returns the matching
    /// `ProtectionKeyClient` and the `SymmetricKey` so tests can
    /// hand-craft "old-style" ciphertext.
    private func clientWithLegacyKey() -> (ProtectionKeyClient, SymmetricKey, InMemoryProtectionKeyStore) {
        let store = InMemoryProtectionKeyStore()
        let workspace = SymmetricKey(size: .bits256)
        let raw = workspace.withUnsafeBytes { Data($0) }
        try! store.write(
            raw,
            service: ProtectionKeyClient.workspaceKeyService,
            account: ProtectionKeyClient.workspaceKeyAccount
        )
        let client = ProtectionKeyClient.makeClient(store: store)
        return (client, workspace, store)
    }

    /// Encrypt a string under the legacy workspace key so the test
    /// data round-trips byte-identically to what #9 would have stored.
    private func legacySeal(_ plaintext: String, key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        return sealed.combined!
    }

    func testRotationReKeysAndDropsWorkspaceKey() throws {
        try withHermeticDB {
            let (client, workspaceKey, store) = clientWithLegacyKey()
            @Dependency(\.defaultDatabase) var db

            // Hand-craft two protected rows under the workspace key.
            let dbClient = DatabaseClient.liveValue
            let trip = try dbClient.createRecord("trips", "Tokyo")
            // Mark protected via the property_value layer so the
            // is_protected guard passes.
            try dbClient.updatePropertyValue(trip.id, "is_protected", "true")

            let cipher1 = try legacySeal("private notes for tokyo", key: workspaceKey)
            try db.write { d in
                let pvID = "\(trip.id).notes"
                try d.execute(sql: """
                    INSERT INTO property_values (id, record_id, property_id, enc_value, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    pvID, trip.id, "trips.notes", cipher1,
                    AppDatabase.isoFormatter.string(from: Date()),
                    AppDatabase.isoFormatter.string(from: Date())
                ])
            }

            // Sanity: workspace key is present pre-rotation.
            XCTAssertNotNil(try client.legacyWorkspaceKey())

            // Run rotation. Resolve the writer via the same dependency
            // path Bootstrap uses — synchronous read is fine because
            // the runIfNeeded helper drives writer.write/read directly.
            ProtectionKeyRotation.runIfNeeded(writer: db as! any DatabaseWriter, keys: client)

            // Workspace key gone.
            XCTAssertNil(try client.legacyWorkspaceKey())

            // Per-record key now present and decrypts the row.
            XCTAssertTrue(client.hasRecordKey(trip.id))
            let plaintext: Data = try db.read { d in
                let row = try Row.fetchOne(d, sql: "SELECT enc_value FROM property_values WHERE record_id = ? AND property_id = ?",
                    arguments: [trip.id, "trips.notes"])
                return row?["enc_value"] ?? Data()
            }
            XCTAssertFalse(plaintext.isEmpty)
            let recovered = try client.decryptForRecord(trip.id, plaintext)
            XCTAssertEqual(String(data: recovered, encoding: .utf8), "private notes for tokyo")
            _ = store
        }
    }

    func testRotationIsNoOpWhenWorkspaceKeyAbsent() throws {
        try withHermeticDB {
            let store = InMemoryProtectionKeyStore()
            let client = ProtectionKeyClient.makeClient(store: store)
            @Dependency(\.defaultDatabase) var db
            // No workspace key in the keychain → early return, no work.
            ProtectionKeyRotation.runIfNeeded(writer: db as! any DatabaseWriter, keys: client)
            XCTAssertNil(try client.legacyWorkspaceKey())
        }
    }

    func testRotationSkipsAlreadyRotatedRowsAndStillCompletes() throws {
        try withHermeticDB {
            let (client, workspaceKey, _) = clientWithLegacyKey()
            @Dependency(\.defaultDatabase) var db
            let dbClient = DatabaseClient.liveValue

            // Two records: one already-rotated (encrypted under its
            // per-record key from a prior interrupted pass), one still
            // on the workspace key.
            let r1 = try dbClient.createRecord("trips", "Already rotated")
            let r2 = try dbClient.createRecord("trips", "Pending rotation")

            // r1 — encrypt under r1's per-record key
            let r1Key = try client.recordKey(r1.id)
            let r1Sealed = try AES.GCM.seal(Data("rotated already".utf8), using: r1Key)
            let r1Cipher = r1Sealed.combined!
            // r2 — encrypt under workspace key
            let r2Cipher = try legacySeal("still on workspace", key: workspaceKey)

            try db.write { d in
                try d.execute(sql: """
                    INSERT INTO property_values (id, record_id, property_id, enc_value, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "\(r1.id).notes", r1.id, "trips.notes", r1Cipher,
                    AppDatabase.isoFormatter.string(from: Date()),
                    AppDatabase.isoFormatter.string(from: Date())
                ])
                try d.execute(sql: """
                    INSERT INTO property_values (id, record_id, property_id, enc_value, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "\(r2.id).notes", r2.id, "trips.notes", r2Cipher,
                    AppDatabase.isoFormatter.string(from: Date()),
                    AppDatabase.isoFormatter.string(from: Date())
                ])
            }

            ProtectionKeyRotation.runIfNeeded(writer: db as! any DatabaseWriter, keys: client)

            // Both rows decrypt under their per-record keys; workspace
            // key is gone.
            XCTAssertNil(try client.legacyWorkspaceKey())
            try db.read { d in
                let row1: Data = try Row.fetchOne(d, sql: "SELECT enc_value FROM property_values WHERE id = ?",
                    arguments: ["\(r1.id).notes"])?["enc_value"] ?? Data()
                let row2: Data = try Row.fetchOne(d, sql: "SELECT enc_value FROM property_values WHERE id = ?",
                    arguments: ["\(r2.id).notes"])?["enc_value"] ?? Data()
                let p1 = try client.decryptForRecord(r1.id, row1)
                let p2 = try client.decryptForRecord(r2.id, row2)
                XCTAssertEqual(String(data: p1, encoding: .utf8), "rotated already")
                XCTAssertEqual(String(data: p2, encoding: .utf8), "still on workspace")
            }
        }
    }
}
