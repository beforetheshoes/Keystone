import XCTest
import Synchronization
@testable import Keystone

final class OverpassClientTests: XCTestCase {

    func testExactNameMatchReturnsTags() async {
        let json = """
        {
          "version": 0.6,
          "elements": [
            { "type": "node", "id": 1, "tags": {
                "amenity": "restaurant",
                "name": "Acme Diner",
                "opening_hours": "Mo-Fr 11:00-22:00; Sa,Su 09:00-23:00",
                "website": "https://acme.example",
                "phone": "+1-555-0100"
            }}
          ]
        }
        """
        let client = OverpassClient(http: StubOverpassHTTP(json))
        let tags = await client.lookup(name: "Acme Diner", latitude: 40.0, longitude: -74.0)
        XCTAssertEqual(tags?.openingHours, "Mo-Fr 11:00-22:00; Sa,Su 09:00-23:00")
        XCTAssertEqual(tags?.website, "https://acme.example")
        XCTAssertEqual(tags?.phone, "+1-555-0100")
        XCTAssertEqual(tags?.matchKind, "name+amenity")
    }

    func testPrefersExactOverFuzzy() async {
        let json = """
        {
          "elements": [
            { "type": "node", "id": 1, "tags": { "name": "Acme Diner of Brooklyn", "opening_hours": "Mo-Fr 09:00-17:00" }},
            { "type": "node", "id": 2, "tags": { "name": "Acme Diner",            "opening_hours": "Mo-Fr 11:00-22:00" }}
          ]
        }
        """
        let client = OverpassClient(http: StubOverpassHTTP(json))
        let tags = await client.lookup(name: "Acme Diner", latitude: 40.0, longitude: -74.0)
        XCTAssertEqual(tags?.openingHours, "Mo-Fr 11:00-22:00")
        XCTAssertEqual(tags?.matchKind, "name+amenity")
    }

    func testNoNameMatchReturnsNil() async {
        let json = """
        {
          "elements": [
            { "type": "node", "id": 1, "tags": { "name": "Totally Different", "opening_hours": "Mo-Fr 11:00-22:00" }}
          ]
        }
        """
        let client = OverpassClient(http: StubOverpassHTTP(json))
        let tags = await client.lookup(name: "Acme Diner", latitude: 40.0, longitude: -74.0)
        XCTAssertNil(tags)
    }

    func testContactPrefixWebsiteAndPhoneRespected() async {
        let json = """
        {
          "elements": [
            { "type": "node", "id": 1, "tags": {
                "name": "Acme Diner",
                "contact:website": "https://contact.example",
                "contact:phone": "+1-555-0200"
            }}
          ]
        }
        """
        let client = OverpassClient(http: StubOverpassHTTP(json))
        let tags = await client.lookup(name: "Acme Diner", latitude: 40.0, longitude: -74.0)
        XCTAssertEqual(tags?.website, "https://contact.example")
        XCTAssertEqual(tags?.phone, "+1-555-0200")
    }

    func testHTTPFailureReturnsNil() async {
        let client = OverpassClient(http: StubOverpassHTTP(nil))
        let tags = await client.lookup(name: "Acme Diner", latitude: 40.0, longitude: -74.0)
        XCTAssertNil(tags)
    }

    func testBlankNameOrBadCoordReturnsNilWithoutQuery() async {
        let stub = StubOverpassHTTP("{}")
        let client = OverpassClient(http: stub)
        let blank = await client.lookup(name: "", latitude: 40, longitude: -74)
        let bad   = await client.lookup(name: "X", latitude: 100, longitude: -74)
        XCTAssertNil(blank)
        XCTAssertNil(bad)
        XCTAssertEqual(stub.callCount, 0)
    }

    func testQueryShapeContainsBboxAndAmenityRegex() {
        let bbox = (south: 40.0, west: -74.001, north: 40.002, east: -73.999)
        let q = OverpassClient.query(name: "Acme", bbox: bbox)
        XCTAssertTrue(q.contains("[bbox:40.0,-74.001,40.002,-73.999]"))
        XCTAssertTrue(q.contains("amenity~"))
        XCTAssertTrue(q.contains("name~\"Acme\""))
    }
}

// MARK: - Stub

final class StubOverpassHTTP: OverpassHTTP, Sendable {
    private let payload: String?
    private let _callCount = Atomic<Int>(0)
    var callCount: Int { _callCount.load(ordering: .relaxed) }

    init(_ payload: String?) { self.payload = payload }

    func post(query: String) async -> Data? {
        _callCount.wrappingAdd(1, ordering: .relaxed)
        return payload?.data(using: .utf8)
    }
}
