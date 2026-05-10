import XCTest
import Dependencies
import GRDB
import CryptoKit
@preconcurrency import SQLiteData
@testable import Keystone

/// End-to-end round trips for the encryption-at-rest layer:
/// property values, block content, asset files, and the cascade
/// triggered by `is_protected` flips. Inspects the raw SQLite rows
/// after each step so we don't just trust the code that wrote them.
final class EncryptionAtRestTests: XCTestCase {
    // MARK: - Setup helpers

    private func withDB<T>(_ body: () throws -> T) rethrows -> T {
        try withHermeticDB(body)
    }

    private func makeTrip(_ db: Database, name: String) throws -> String {
        let row = try DBWrites.createRecord(db, databaseID: "trips", title: name)
        return row.id
    }

    private func makeActivity(_ db: Database, name: String, tripID: String) throws -> String {
        let row = try DBWrites.createRecord(db, databaseID: "activities", title: name)
        try DBWrites.updatePropertyValue(db, recordID: row.id, propertyKey: "trip", value: tripID)
        return row.id
    }

    /// Hermetic per-test ProtectionKeyClient + helpers for building
    /// per-record encryptors. Tests pre-#14 used a single workspace
    /// key; per-record keys are now mandatory so each test instance
    /// gets its own keychain stub and builds encryptors per recordID.
    private final class TestKeysHandle: @unchecked Sendable {
        let keys: ProtectionKeyClient
        init() {
            self.keys = ProtectionKeyClient.makeClient(store: InMemoryProtectionKeyStore())
        }
        func encryptor(for recordID: String) -> ValueEncryptor {
            ValueEncryptor.live(recordID: recordID, keys: keys)
        }
    }

    private func makeKeys() -> TestKeysHandle { TestKeysHandle() }

    /// Backwards-compatible single-encryptor helper — uses a fixed
    /// pseudo-record-id so existing tests that operate on one record
    /// don't need per-call rewiring. New tests should call
    /// `makeKeys().encryptor(for:)` instead.
    private func makeEncryptor() -> ValueEncryptor {
        return makeKeys().encryptor(for: "test-encryptor-record")
    }

    private func withWrite(_ body: (Database) throws -> Void) throws {
        @Dependency(\.defaultDatabase) var database
        try database.write { try body($0) }
    }

    // MARK: - Property value round trip

    func testEncryptThenDecryptRoundTripsPropertyValues() throws {
        try withDB {
            let encryptor = makeEncryptor()
            try withWrite { db in
                let trip = try makeTrip(db, name: "Surprise Anniversary")
                try DBWrites.updatePropertyValue(db, recordID: trip, propertyKey: "notes", value: "ring + dinner reservation")

                // Sanity: plaintext landed before encryption.
                let beforeRow = try Row.fetchOne(
                    db,
                    sql: "SELECT text_value, enc_value FROM property_values WHERE record_id = ? AND property_id = ?",
                    arguments: [trip, "trips.notes"]
                )
                XCTAssertEqual(beforeRow?["text_value"] as String?, "ring + dinner reservation")
                XCTAssertNil(beforeRow?["enc_value"] as Data?)

                // Encrypt — text_value cleared, enc_value populated.
                try DBWrites.encryptRecordValues(db, recordID: trip, encryptor: encryptor)
                let afterRow = try Row.fetchOne(
                    db,
                    sql: "SELECT text_value, number_value, date_value, json_value, enc_value FROM property_values WHERE record_id = ? AND property_id = ?",
                    arguments: [trip, "trips.notes"]
                )
                XCTAssertNil(afterRow?["text_value"] as String?, "plaintext column should be NULL post-encrypt")
                XCTAssertNil(afterRow?["number_value"] as Double?)
                XCTAssertNil(afterRow?["date_value"] as String?)
                XCTAssertNil(afterRow?["json_value"] as String?)
                let cipher = afterRow?["enc_value"] as Data?
                XCTAssertNotNil(cipher)
                XCTAssertGreaterThan(cipher?.count ?? 0, 28, "AES-GCM combined output is 12-byte nonce + ct + 16-byte tag")

                // Read with encryptor → plaintext recovers.
                let rec = try XCTUnwrap(DBReads.record(db, id: trip, encryptor: encryptor))
                XCTAssertEqual(rec.values["notes"], "ring + dinner reservation")

                // Read without encryptor → placeholder.
                let recNoKey = try XCTUnwrap(DBReads.record(db, id: trip))
                XCTAssertEqual(recNoKey.values["notes"], "[encrypted]")

                // Decrypt back — round trip lands the same plaintext.
                try DBWrites.decryptRecordValues(db, recordID: trip, encryptor: encryptor)
                let restored = try Row.fetchOne(
                    db,
                    sql: "SELECT text_value, enc_value FROM property_values WHERE record_id = ? AND property_id = ?",
                    arguments: [trip, "trips.notes"]
                )
                XCTAssertEqual(restored?["text_value"] as String?, "ring + dinner reservation")
                XCTAssertNil(restored?["enc_value"] as Data?)
            }
        }
    }

    // MARK: - Block content round trip

    func testEncryptThenDecryptRoundTripsBlockContent() throws {
        try withDB {
            let encryptor = makeEncryptor()
            try withWrite { db in
                let trip = try makeTrip(db, name: "Berlin")
                let block = try DBWrites.createBlock(
                    db, recordID: trip, after: nil, kind: .paragraph,
                    text: AttributedString("hotel reservation #ABC123"),
                    checked: nil
                )

                try DBWrites.encryptRecordBlocks(db, recordID: trip, encryptor: encryptor)
                let after = try Row.fetchOne(
                    db,
                    sql: "SELECT content_json, enc_content FROM blocks WHERE id = ?",
                    arguments: [block.id]
                )
                XCTAssertEqual(after?["content_json"] as String?, "{}", "content_json should be reset post-encrypt")
                XCTAssertNotNil(after?["enc_content"] as Data?)

                let blocks = try BlockReads.blocks(db, recordID: trip, encryptor: encryptor)
                XCTAssertEqual(blocks.count, 1)
                XCTAssertEqual(String(blocks[0].text.characters), "hotel reservation #ABC123")

                // Without encryptor, the placeholder body kicks in.
                let blocksNoKey = try BlockReads.blocks(db, recordID: trip)
                XCTAssertEqual(String(blocksNoKey[0].text.characters), "[encrypted]")

                try DBWrites.decryptRecordBlocks(db, recordID: trip, encryptor: encryptor)
                let restored = try Row.fetchOne(
                    db,
                    sql: "SELECT content_json, enc_content FROM blocks WHERE id = ?",
                    arguments: [block.id]
                )
                XCTAssertNotNil(restored?["content_json"] as String?)
                XCTAssertNotEqual(restored?["content_json"] as String?, "{}")
                XCTAssertNil(restored?["enc_content"] as Data?)
            }
        }
    }

    // MARK: - Cascade

    func testCascadeFromSeedIncludesActivityChild() throws {
        try withDB {
            try withWrite { db in
                let trip = try makeTrip(db, name: "Tokyo")
                let activity = try makeActivity(db, name: "Sushi", tripID: trip)
                let cascade = try ProtectedReads.cascadeFromSeed(db, seedID: trip)
                XCTAssertEqual(cascade, [trip, activity])
            }
        }
    }

    func testCascadeWithNoChildrenReturnsJustSeed() throws {
        try withDB {
            try withWrite { db in
                let trip = try makeTrip(db, name: "Lone")
                let cascade = try ProtectedReads.cascadeFromSeed(db, seedID: trip)
                XCTAssertEqual(cascade, [trip])
            }
        }
    }

    // MARK: - Asset round trip

    func testAssetFileEncryptDecryptRoundTrip() throws {
        try withDB {
            let encryptor = makeEncryptor()
            try withWrite { db in
                let trip = try makeTrip(db, name: "Receipts")
                // Stage a fake asset file in the workspace.
                let workspace = AppDatabase.workspaceFolder
                let assetsDir = workspace.appendingPathComponent("Assets/Trips/Receipts-\(String(trip.suffix(8)))")
                try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
                let originalBytes = Data("this is a confidential receipt PDF".utf8)
                let assetURL = assetsDir.appendingPathComponent("receipt.txt")
                try originalBytes.write(to: assetURL)

                let relPath = "Assets/Trips/Receipts-\(String(trip.suffix(8)))/receipt.txt"
                let id = UUID().uuidString
                let now = AppDatabase.isoFormatter.string(from: Date())
                try db.execute(
                    sql: """
                        INSERT INTO assets (
                            id, workspace_id, record_id,
                            original_filename, stored_filename, relative_path,
                            mime_type, file_extension, byte_size, content_hash,
                            extracted_text, metadata_json, created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, '{}', ?, ?)
                    """,
                    arguments: [
                        id, Seed.workspaceID, trip,
                        "receipt.txt", "receipt.txt", relPath,
                        "text/plain", "txt", Int64(originalBytes.count), "deadbeef",
                        now, now
                    ]
                )

                // Encrypt the asset file in place.
                try DBWrites.encryptRecordAssets(db, recordID: trip, encryptor: encryptor)
                let encryptedBytes = try Data(contentsOf: assetURL)
                XCTAssertNotEqual(encryptedBytes, originalBytes)
                XCTAssertEqual(encryptedBytes.prefix(7), Data("KSTENC1".utf8), "magic prefix should mark the file as Keystone-encrypted")

                let row = try Row.fetchOne(db, sql: "SELECT is_encrypted FROM assets WHERE id = ?", arguments: [id])
                XCTAssertEqual(row?["is_encrypted"] as Int?, 1)

                // Decrypt → original bytes restored.
                try DBWrites.decryptRecordAssets(db, recordID: trip, encryptor: encryptor)
                let restored = try Data(contentsOf: assetURL)
                XCTAssertEqual(restored, originalBytes)
                let row2 = try Row.fetchOne(db, sql: "SELECT is_encrypted FROM assets WHERE id = ?", arguments: [id])
                XCTAssertEqual(row2?["is_encrypted"] as Int?, 0)
            }
        }
    }
}
