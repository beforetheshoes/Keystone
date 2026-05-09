import XCTest
import Dependencies
import GRDB
@preconcurrency import SQLiteData
@testable import Keystone

final class AddressTests: XCTestCase {
    private func withDB<T>(_ body: () throws -> T) rethrows -> T {
        try withHermeticDB(body)
    }

    // MARK: - Codec

    func testEncodeParseRoundTripFull() throws {
        let original = AddressValue(
            display: "123 Main St, San Francisco, CA",
            street:  "123 Main St",
            city:    "San Francisco",
            region:  "CA",
            postal:  "94110",
            country: "US",
            lat:     37.7637,
            lon:     -122.4140,
            placeID: "I3F8.opaque.identifier"
        )
        let encoded = AddressValueCodec.encode(original)
        let parsed = try XCTUnwrap(AddressValueCodec.parse(encoded))
        XCTAssertEqual(parsed, original)
    }

    func testEncodeOmitsEmptyOptionalFields() throws {
        let value = AddressValue(display: "Bob's Place")
        let encoded = AddressValueCodec.encode(value)
        // The encoded JSON shouldn't include the optional fields at all.
        XCTAssertFalse(encoded.contains("\"street\""))
        XCTAssertFalse(encoded.contains("\"lat\""))
        // But it should round-trip.
        let parsed = try XCTUnwrap(AddressValueCodec.parse(encoded))
        XCTAssertEqual(parsed.display, "Bob's Place")
        XCTAssertNil(parsed.street)
        XCTAssertNil(parsed.lat)
    }

    func testParseRejectsMalformed() {
        XCTAssertNil(AddressValueCodec.parse(""))
        XCTAssertNil(AddressValueCodec.parse("plain text — not JSON"))
        XCTAssertNil(AddressValueCodec.parse("{}"))                          // missing display
        XCTAssertNil(AddressValueCodec.parse(#"{"display":""}"#))            // empty display
        XCTAssertNil(AddressValueCodec.parse(#"{"street":"123 Main St"}"#))  // missing display
    }

    func testOneLineComposition() {
        let v = AddressValue(
            display: "fallback",
            street: "123 Main",
            city: "SF",
            region: "CA",
            postal: "94110",
            country: nil
        )
        XCTAssertEqual(AddressValueCodec.oneLine(from: v), "123 Main, SF, CA, 94110")
    }

    func testOneLineFallsBackToDisplayWhenAllFieldsEmpty() {
        let v = AddressValue(display: "Just a name")
        XCTAssertEqual(AddressValueCodec.oneLine(from: v), "Just a name")
    }

    // MARK: - Migration v25

    func testV25FlipsAddressProperties() throws {
        try withDB {
            @Dependency(\.defaultDatabase) var database
            try database.read { db in
                XCTAssertEqual(
                    try String.fetchOne(db, sql: "SELECT type FROM properties WHERE id = 'vendors.address'"),
                    "address"
                )
                XCTAssertEqual(
                    try String.fetchOne(db, sql: "SELECT type FROM properties WHERE id = 'homes.address'"),
                    "address"
                )
            }
        }
    }

    // MARK: - Storage round-trip

    func testWriteStructuredSplitsTextAndJson() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue
            let v = try dbClient.createRecord("vendors", "Acme")
            defer { try? dbClient.deleteRecord(v.id) }

            let payload = #"{"display":"123 Main St, SF, CA","street":"123 Main St","city":"SF","region":"CA","place_id":"opaque-id-1"}"#
            try dbClient.updatePropertyValue(v.id, "address", payload)

            @Dependency(\.defaultDatabase) var database
            try database.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT text_value, json_value
                        FROM property_values
                        WHERE record_id = ? AND property_id = 'vendors.address'
                    """,
                    arguments: [v.id]
                )
                XCTAssertEqual(row?["text_value"], "123 Main St, SF, CA")
                XCTAssertEqual(row?["json_value"], payload)
            }

            // Reads should surface the one-line in the values map.
            let after = try dbClient.record(v.id)
            XCTAssertEqual(after?.values["address"], "123 Main St, SF, CA")

            // propertyJSON should return the full JSON.
            let json = try dbClient.propertyJSON(v.id, "address")
            XCTAssertEqual(json, payload)
        }
    }

    func testWriteFreeFormStoresOnlyText() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue
            let v = try dbClient.createRecord("vendors", "Bob's Garage")
            defer { try? dbClient.deleteRecord(v.id) }

            try dbClient.updatePropertyValue(v.id, "address", "Out past the old mill")

            @Dependency(\.defaultDatabase) var database
            try database.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT text_value, json_value
                        FROM property_values
                        WHERE record_id = ? AND property_id = 'vendors.address'
                    """,
                    arguments: [v.id]
                )
                XCTAssertEqual(row?["text_value"], "Out past the old mill")
                XCTAssertNil(row?["json_value"] as String?)
            }

            let after = try dbClient.record(v.id)
            XCTAssertEqual(after?.values["address"], "Out past the old mill")
            let json = try dbClient.propertyJSON(v.id, "address")
            XCTAssertNil(json)
        }
    }
}
