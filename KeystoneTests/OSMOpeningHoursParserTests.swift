import XCTest
@testable import Keystone

final class OSMOpeningHoursParserTests: XCTestCase {

    func testSimpleWeekdayRange() {
        XCTAssertEqual(
            OSMOpeningHoursParser.parse("Mo-Fr 11:00-22:00"),
            "Mon–Fri 11:00–22:00"
        )
    }

    func testMultiRuleWeekdayAndWeekend() {
        XCTAssertEqual(
            OSMOpeningHoursParser.parse("Mo-Fr 11:00-22:00; Sa,Su 09:00-23:00"),
            "Mon–Fri 11:00–22:00, Sat–Sun 09:00–23:00"
        )
    }

    func testOffDayOverridesEarlierRule() {
        XCTAssertEqual(
            OSMOpeningHoursParser.parse("Mo-Su 11:00-22:00; Mo off"),
            "Tue–Sun 11:00–22:00"
        )
    }

    func testClosedDayKeyword() {
        XCTAssertEqual(
            OSMOpeningHoursParser.parse("Tu-Su 17:00-23:00; Mo closed"),
            "Tue–Sun 17:00–23:00"
        )
    }

    func test24SlashSeven() {
        XCTAssertEqual(
            OSMOpeningHoursParser.parse("24/7"),
            "Mon–Sun open 24h"
        )
    }

    func testMultiWindowKeepsFirstWindow() {
        // OSM allows split shifts; the `hours` property is text-typed
        // and meant to be glanceable, so we collapse to the first window.
        XCTAssertEqual(
            OSMOpeningHoursParser.parse("Mo-Fr 11:00-14:00,17:00-22:00"),
            "Mon–Fri 11:00–14:00"
        )
    }

    func testDayListExpands() {
        XCTAssertEqual(
            OSMOpeningHoursParser.parse("Mo,We,Fr 18:00-22:00"),
            "Mon 18:00–22:00, Wed 18:00–22:00, Fri 18:00–22:00"
        )
    }

    func testWrapAroundDayRange() {
        // Fr-Mo wraps through the weekend; covers Fri, Sat, Sun, Mon.
        XCTAssertEqual(
            OSMOpeningHoursParser.parse("Fr-Mo 17:00-23:00"),
            "Mon 17:00–23:00, Fri–Sun 17:00–23:00"
        )
    }

    func testAllClosedReturnsClosed() {
        XCTAssertEqual(OSMOpeningHoursParser.parse("Mo-Su off"), "Closed")
    }

    func testInlineQuotedCommentStripped() {
        XCTAssertEqual(
            OSMOpeningHoursParser.parse("Mo-Fr 09:00-17:00 \"by appointment\""),
            "Mon–Fri 09:00–17:00"
        )
    }

    func testUnparseableReturnsNil() {
        // Sunrise/sunset is out of scope. The new contract is to
        // return nil so the enrichment writer doesn't pollute the
        // `hours` column with raw OSM grammar that the display
        // layer can't render. The caller decides whether to fall
        // back (the display layer does; the writer doesn't).
        XCTAssertNil(OSMOpeningHoursParser.parse("sunrise-sunset"))
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(OSMOpeningHoursParser.parse(""))
        XCTAssertNil(OSMOpeningHoursParser.parse("   "))
    }

    func testCaseInsensitiveDayTokens() {
        XCTAssertEqual(
            OSMOpeningHoursParser.parse("mo-fr 11:00-22:00"),
            "Mon–Fri 11:00–22:00"
        )
    }

    // MARK: - Real-world comma-as-rule-separator + multi-window

    /// Real-world data lifted from a ChowNow-style menu provider:
    /// every distinct day-time pair is its own comma-separated
    /// chunk. Strict OSM uses `;` between rules; we normalize the
    /// comma form to match.
    func testCommaSeparatedDayTimePairsAcrossWeek() {
        let raw = """
        Mo 09:00-15:00, Mo 17:00-19:00, Tu 09:00-15:00, Tu 17:00-19:00, \
        We 09:00-15:00, We 17:00-19:00, Th 09:00-15:00, Th 17:00-19:00, \
        Fr 09:00-15:00, Fr 17:00-19:00, Sa 09:00-15:00, Sa 17:00-19:00, \
        Su 09:00-15:00, Su 17:00-19:00
        """
        XCTAssertEqual(
            OSMOpeningHoursParser.parse(raw),
            "Mon–Sun 09:00–15:00, 17:00–19:00"
        )
    }

    /// Two same-day rules accumulate into a multi-window entry
    /// instead of one overwriting the other.
    func testMultipleSameDayRulesAccumulate() {
        XCTAssertEqual(
            OSMOpeningHoursParser.parse("Mo 09:00-15:00; Mo 17:00-19:00"),
            "Mon 09:00–15:00, 17:00–19:00"
        )
    }

    func testMixedSemicolonAndCommaRuleSeparators() {
        // Comma between day-time pairs, semicolon between groups —
        // sometimes seen in OSM data that was hand-edited.
        XCTAssertEqual(
            OSMOpeningHoursParser.parse(
                "Mo-Fr 09:00-17:00; Sa 10:00-14:00, Sa 16:00-20:00"
            ),
            "Mon–Fri 09:00–17:00, Sat 10:00–14:00, 16:00–20:00"
        )
    }

    /// Real-world: closed-day rule followed by an open-day rule,
    /// separated by commas instead of semicolons (`Mo off, Tu-Sa
    /// 11:00-21:00, Su off`). Earlier behavior left this as a single
    /// unparseable rule because the comma after `off` is preceded
    /// by a letter and the digit-only lookbehind missed it.
    func testCommaSeparatedClosedAndOpenRules() {
        XCTAssertEqual(
            OSMOpeningHoursParser.parse("Mo off, Tu-Sa 11:00-21:00, Su off"),
            "Tue–Sat 11:00–21:00"
        )
    }

    /// Within a single rule, a comma followed by a digit is still a
    /// multi-window time spec — we mustn't convert that into a rule
    /// separator.
    func testCommaInsideTimeSpecStaysIntact() {
        // OSM-canonical: lunch + dinner inside a single rule.
        // parseTimeSpec currently keeps only the first window for an
        // individual rule's time spec — the multi-window
        // accumulation in `parse` is what gives us both. Verify the
        // canonical single-rule form still yields ONE window
        // (preserving the existing per-rule contract).
        XCTAssertEqual(
            OSMOpeningHoursParser.parse("Mo 11:00-14:00,17:00-22:00"),
            "Mon 11:00–14:00"
        )
    }
}
