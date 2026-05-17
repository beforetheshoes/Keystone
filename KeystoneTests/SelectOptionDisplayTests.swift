import XCTest
@testable import Keystone

final class SelectOptionDisplayTests: XCTestCase {

    func testSnakeCaseBecomesSentenceCase() {
        XCTAssertEqual(SelectOptionDisplay.format("want_to_try"), "Want to try")
        XCTAssertEqual(SelectOptionDisplay.format("to_read"), "To read")
        XCTAssertEqual(SelectOptionDisplay.format("in_progress"), "In progress")
        XCTAssertEqual(SelectOptionDisplay.format("watched"), "Watched")
    }

    func testKebabCaseBecomesSentenceCase() {
        XCTAssertEqual(SelectOptionDisplay.format("first-class"), "First class")
    }

    func testCurrencySymbolsPassThrough() {
        XCTAssertEqual(SelectOptionDisplay.format("$"), "$")
        XCTAssertEqual(SelectOptionDisplay.format("$$"), "$$")
        XCTAssertEqual(SelectOptionDisplay.format("$$$$"), "$$$$")
    }

    func testAlreadyDisplayReadyValuesUnchanged() {
        // Contains a space → display-ready, leave alone.
        XCTAssertEqual(SelectOptionDisplay.format("Open Now"), "Open Now")
        // Contains a non-ASCII letter → leave alone.
        XCTAssertEqual(SelectOptionDisplay.format("café"), "café")
        // Pure digits — likely a year or count, not an identifier.
        XCTAssertEqual(SelectOptionDisplay.format("404"), "404")
    }

    func testEmptyAndWhitespaceTrim() {
        XCTAssertEqual(SelectOptionDisplay.format(""), "")
        XCTAssertEqual(SelectOptionDisplay.format("   "), "")
    }

    func testPreservesIntentionalLowercase() {
        // A single-word lowercase identifier still gets sentence-cased
        // — that's the whole point.
        XCTAssertEqual(SelectOptionDisplay.format("abandoned"), "Abandoned")
        // Multi-word with an already-uppercase second word keeps its
        // existing casing.
        XCTAssertEqual(SelectOptionDisplay.format("on_TV"), "On TV")
    }

    func testTrimsLeadingTrailingWhitespace() {
        XCTAssertEqual(SelectOptionDisplay.format("  want_to_try  "), "Want to try")
    }
}
