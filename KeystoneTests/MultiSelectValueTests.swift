import XCTest
@testable import Keystone

final class MultiSelectValueTests: XCTestCase {
    func testEncodeJoinsWithDelimiter() {
        XCTAssertEqual(MultiSelectValue.encode(["fiction", "mystery"]), "fiction|mystery")
    }

    func testEncodeTrimsAndDropsEmpties() {
        XCTAssertEqual(MultiSelectValue.encode([" fiction ", "", "mystery"]), "fiction|mystery")
    }

    func testEncodeDedupesCaseInsensitive() {
        XCTAssertEqual(MultiSelectValue.encode(["Fiction", "fiction", "Mystery"]), "Fiction|Mystery")
    }

    func testEncodeEmptyProducesEmptyString() {
        XCTAssertEqual(MultiSelectValue.encode([]), "")
        XCTAssertEqual(MultiSelectValue.encode(["", "  "]), "")
    }

    func testDecodeSplitsOnDelimiter() {
        XCTAssertEqual(MultiSelectValue.decode("fiction|mystery"), ["fiction", "mystery"])
    }

    func testDecodeTrimsAndDropsEmpties() {
        XCTAssertEqual(MultiSelectValue.decode(" fiction || mystery "), ["fiction", "mystery"])
    }

    func testDecodeEmptyReturnsEmpty() {
        XCTAssertEqual(MultiSelectValue.decode(""), [])
        XCTAssertEqual(MultiSelectValue.decode("   "), [])
    }

    func testRoundTrip() {
        let original = ["Thriller", "Drama", "Noir"]
        let encoded = MultiSelectValue.encode(original)
        XCTAssertEqual(MultiSelectValue.decode(encoded), original)
    }
}
