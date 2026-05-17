import XCTest
@testable import Keystone

final class SchemaOrgLDParserTests: XCTestCase {

    func testTopLevelRestaurantWithAllFields() {
        let json = """
        {
          "@context": "https://schema.org",
          "@type": "Restaurant",
          "name": "Acme Diner",
          "priceRange": "$$",
          "aggregateRating": { "@type": "AggregateRating", "ratingValue": "4.3", "reviewCount": "201" },
          "hasMenu": "https://acme.example/menu",
          "openingHoursSpecification": [
            {"@type":"OpeningHoursSpecification","dayOfWeek":["Monday","Tuesday","Wednesday","Thursday","Friday"],"opens":"11:00","closes":"22:00"},
            {"@type":"OpeningHoursSpecification","dayOfWeek":["Saturday","Sunday"],"opens":"09:00","closes":"23:00"}
          ]
        }
        """
        let parsed = SchemaOrgLDParser.parse(jsonStrings: [json])
        XCTAssertEqual(parsed.hours, "Mon–Fri 11:00–22:00, Sat–Sun 09:00–23:00")
        XCTAssertEqual(parsed.rating, 4.3)
        XCTAssertEqual(parsed.priceRange, "$$")
        XCTAssertEqual(parsed.menuURL?.absoluteString, "https://acme.example/menu")
    }

    func testGraphWrapperWithFastFoodSubtype() {
        let json = """
        {
          "@context": "https://schema.org",
          "@graph": [
            {"@type": "Organization", "name": "Parent Co"},
            {
              "@type": "FastFoodRestaurant",
              "priceRange": "$",
              "openingHoursSpecification": {
                "@type":"OpeningHoursSpecification",
                "dayOfWeek":"https://schema.org/Monday",
                "opens":"06:00:00",
                "closes":"23:00:00-05:00"
              }
            }
          ]
        }
        """
        let parsed = SchemaOrgLDParser.parse(jsonStrings: [json])
        XCTAssertEqual(parsed.hours, "Mon 06:00–23:00")
        XCTAssertEqual(parsed.priceRange, "$")
        XCTAssertNil(parsed.rating)
    }

    func testArrayTypedNodeIsAccepted() {
        let json = """
        {
          "@type": ["LocalBusiness", "Restaurant"],
          "priceRange": "$$$",
          "openingHours": "Mo-Fr 09:00-17:00"
        }
        """
        let parsed = SchemaOrgLDParser.parse(jsonStrings: [json])
        XCTAssertEqual(parsed.priceRange, "$$$")
        XCTAssertEqual(parsed.hours, "Mo-Fr 09:00-17:00")
    }

    func testNonRestaurantNodeIsIgnored() {
        let json = """
        {
          "@type": "BlogPosting",
          "headline": "We opened a restaurant",
          "priceRange": "$$"
        }
        """
        let parsed = SchemaOrgLDParser.parse(jsonStrings: [json])
        XCTAssertNil(parsed.hours)
        XCTAssertNil(parsed.priceRange)
    }

    func testPriceRangeRejectsNonDollarStrings() {
        let json = """
        { "@type": "Restaurant", "priceRange": "Moderate" }
        """
        XCTAssertNil(SchemaOrgLDParser.parse(jsonStrings: [json]).priceRange)
    }

    func testMenuFallsBackToMenuKey() {
        let json = """
        { "@type": "Restaurant", "menu": { "@id": "https://acme.example/menu.pdf" } }
        """
        let parsed = SchemaOrgLDParser.parse(jsonStrings: [json])
        XCTAssertEqual(parsed.menuURL?.absoluteString, "https://acme.example/menu.pdf")
    }

    func testTwentyFourHourVenue() {
        let json = """
        {
          "@type": "Restaurant",
          "openingHoursSpecification": [
            {"dayOfWeek": ["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"], "opens": "00:00", "closes": "00:00"}
          ]
        }
        """
        let parsed = SchemaOrgLDParser.parse(jsonStrings: [json])
        XCTAssertEqual(parsed.hours, "Mon–Sun open 24h")
    }

    func testMultiBlockMerges() {
        let priceBlock = """
        { "@type": "Restaurant", "priceRange": "$$" }
        """
        let hoursBlock = """
        {
          "@type": "Restaurant",
          "openingHoursSpecification": {"dayOfWeek":"Friday","opens":"17:00","closes":"22:00"}
        }
        """
        let parsed = SchemaOrgLDParser.parse(jsonStrings: [priceBlock, hoursBlock])
        XCTAssertEqual(parsed.priceRange, "$$")
        XCTAssertEqual(parsed.hours, "Fri 17:00–22:00")
    }

    func testEmptyInputReturnsEmptyParsed() {
        XCTAssertEqual(SchemaOrgLDParser.parse(jsonStrings: []), .init())
        XCTAssertEqual(SchemaOrgLDParser.parse(jsonStrings: ["not json"]), .init())
    }

    /// Regression: a JSON-LD page that emits an empty-string placeholder
    /// array for `openingHours` used to slip through the
    /// `parseOpeningHoursStrings` fallback as `", , , , , , "` —
    /// which the detail view then rendered as visible garbage.
    func testEmptyStringArrayOpeningHoursReturnsNilNotCommas() {
        let json = """
        {
          "@type": "Restaurant",
          "openingHours": ["", "", "", "", "", "", ""]
        }
        """
        let parsed = SchemaOrgLDParser.parse(jsonStrings: [json])
        XCTAssertNil(parsed.hours)
    }

    func testStringArrayWithSomeRealEntriesJoinsOnlyThose() {
        let json = """
        {
          "@type": "Restaurant",
          "openingHours": ["Mo-Fr 11:00-22:00", "", "Sa 09:00-23:00", "  "]
        }
        """
        let parsed = SchemaOrgLDParser.parse(jsonStrings: [json])
        XCTAssertEqual(parsed.hours, "Mo-Fr 11:00-22:00, Sa 09:00-23:00")
    }
}
