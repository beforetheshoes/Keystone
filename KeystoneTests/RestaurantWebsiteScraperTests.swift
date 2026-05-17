import XCTest
@testable import Keystone

final class HTMLHeadExtractorTests: XCTestCase {

    func testExtractsAppleTouchAndFavicon() {
        let html = """
        <html><head>
        <link rel="apple-touch-icon" sizes="180x180" href="/static/touch.png">
        <link rel="icon" type="image/png" sizes="32x32" href="/static/favicon-32.png">
        <link rel="icon" sizes="16x16" href='/favicon-16.png'>
        <link rel="shortcut icon" href="/favicon.ico">
        </head><body></body></html>
        """
        let head = HTMLHeadExtractor.extract(from: html)
        XCTAssertEqual(head.iconLinks.count, 4)
        XCTAssertEqual(head.iconLinks[0].pixelSize, 180)
        XCTAssertEqual(head.iconLinks[1].pixelSize, 32)
        XCTAssertEqual(head.iconLinks[2].href, "/favicon-16.png")
    }

    func testExtractsOGImages() {
        let html = """
        <head>
        <meta property="og:image" content="https://cdn.example/og.jpg">
        <meta name="og:image:secure_url" content="https://cdn.example/og-secure.jpg">
        <meta property="og:title" content="Ignored">
        </head>
        """
        let head = HTMLHeadExtractor.extract(from: html)
        XCTAssertEqual(head.ogImageURLs, ["https://cdn.example/og.jpg", "https://cdn.example/og-secure.jpg"])
    }

    func testExtractsJSONLDFromBody() {
        let html = """
        <html><head><title>X</title></head><body>
        <script type="application/ld+json">{"@type":"Restaurant","name":"A"}</script>
        <script type="application/javascript">/* not ld+json */</script>
        <script type="application/ld+json">
          { "@type": "Restaurant", "priceRange": "$$" }
        </script>
        </body></html>
        """
        let head = HTMLHeadExtractor.extract(from: html)
        XCTAssertEqual(head.jsonLDBlocks.count, 2)
        XCTAssertTrue(head.jsonLDBlocks[0].contains("\"name\":\"A\""))
        XCTAssertTrue(head.jsonLDBlocks[1].contains("\"$$\""))
    }

    func testIgnoresNonIconLinks() {
        let html = #"<head><link rel="stylesheet" href="/x.css"><link rel="preload" href="/y"></head>"#
        XCTAssertTrue(HTMLHeadExtractor.extract(from: html).iconLinks.isEmpty)
    }
}

// MARK: - Scraper

final class RestaurantWebsiteScraperTests: XCTestCase {

    func testChainWithJSONLDAndIcons() async {
        let html = """
        <html><head>
        <link rel="apple-touch-icon" sizes="180x180" href="/static/touch.png">
        <link rel="icon" sizes="32x32" href="/static/fav32.png">
        <script type="application/ld+json">
        {
          "@type":"Restaurant",
          "priceRange":"$$",
          "aggregateRating":{"ratingValue":4.5},
          "hasMenu":"https://chain.example/menu",
          "openingHoursSpecification":[
            {"dayOfWeek":["Monday","Tuesday","Wednesday","Thursday","Friday"],"opens":"11:00","closes":"22:00"},
            {"dayOfWeek":["Saturday","Sunday"],"opens":"09:00","closes":"23:00"}
          ]
        }
        </script>
        </head><body></body></html>
        """
        let touchIcon = pngBytes(of: 2048)
        let stub = StubScrapingHTTP(
            html: [URL(string: "https://chain.example/")!: html],
            bytes: [
                URL(string: "https://chain.example/static/touch.png")!: touchIcon
            ]
        )
        let scraper = RestaurantWebsiteScraper(http: stub)

        let result = await scraper.scrape(websiteURL: URL(string: "https://chain.example/")!)

        XCTAssertEqual(result.logo?.fileExtension, "png")
        XCTAssertEqual(result.parsed.priceRange, "$$")
        XCTAssertEqual(result.parsed.rating, 4.5)
        XCTAssertEqual(result.parsed.hours, "Mon–Fri 11:00–22:00, Sat–Sun 09:00–23:00")
        XCTAssertEqual(result.parsed.menuURL?.absoluteString, "https://chain.example/menu")
        XCTAssertNil(result.probedMenuURL, "JSON-LD menu was present; should not probe")
    }

    func testHTTPUpgradedToHTTPS() async {
        let url = URL(string: "https://example.com/")!
        let stub = StubScrapingHTTP(html: [url: "<html></html>"])
        let scraper = RestaurantWebsiteScraper(http: stub)
        _ = await scraper.scrape(websiteURL: URL(string: "http://example.com/")!)
        XCTAssertEqual(stub.fetchedHTMLURLs.map(\.absoluteString), [url.absoluteString])
    }

    func testIndieWithFaviconOnlyAndMenuProbeHit() async {
        let html = """
        <html><head>
        <link rel="icon" href="/favicon.png">
        </head><body></body></html>
        """
        let stub = StubScrapingHTTP(
            html: [URL(string: "https://indie.example/")!: html],
            bytes: [URL(string: "https://indie.example/favicon.png")!: pngBytes(of: 1500)],
            htmlProbeOK: [URL(string: "https://indie.example/menu")!]
        )
        let scraper = RestaurantWebsiteScraper(http: stub)

        let result = await scraper.scrape(websiteURL: URL(string: "https://indie.example/")!)

        XCTAssertNotNil(result.logo)
        XCTAssertEqual(result.parsed, .init())
        XCTAssertEqual(result.probedMenuURL?.absoluteString, "https://indie.example/menu")
    }

    func testTinyImageRejected() async {
        let html = #"<head><link rel="icon" href="/favicon.png"></head>"#
        let tinyPNG = pngBytes(of: 200) // below 1KB floor
        let stub = StubScrapingHTTP(
            html: [URL(string: "https://tiny.example/")!: html],
            bytes: [URL(string: "https://tiny.example/favicon.png")!: tinyPNG,
                    URL(string: "https://tiny.example/apple-touch-icon.png")!: tinyPNG,
                    URL(string: "https://tiny.example/favicon.ico")!: tinyPNG]
        )
        let scraper = RestaurantWebsiteScraper(http: stub)
        let result = await scraper.scrape(websiteURL: URL(string: "https://tiny.example/")!)
        XCTAssertNil(result.logo)
    }

    func testSVGUnderOneKBStillAccepted() async {
        // ~300-byte SVG: above the 200-byte SVG floor, below the 1KB
        // floor that applies to raster formats.
        let svg = ("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 200 200\">"
                   + "<title>Acme Logo</title>"
                   + "<circle cx=\"100\" cy=\"100\" r=\"80\" fill=\"#ff8800\"/>"
                   + "<rect x=\"40\" y=\"40\" width=\"120\" height=\"120\" fill=\"none\" stroke=\"#222\" stroke-width=\"6\"/>"
                   + "<text x=\"100\" y=\"110\" text-anchor=\"middle\" font-size=\"32\">A</text>"
                   + "</svg>").data(using: .utf8)!
        let html = #"<head><link rel="icon" href="/logo.svg"></head>"#
        let stub = StubScrapingHTTP(
            html: [URL(string: "https://svg.example/")!: html],
            bytes: [URL(string: "https://svg.example/logo.svg")!: svg]
        )
        let scraper = RestaurantWebsiteScraper(http: stub)
        let result = await scraper.scrape(websiteURL: URL(string: "https://svg.example/")!)
        XCTAssertEqual(result.logo?.fileExtension, "svg")
    }

    func testFetchFailureReturnsEmptyResult() async {
        let stub = StubScrapingHTTP(html: [:])
        let scraper = RestaurantWebsiteScraper(http: stub)
        let result = await scraper.scrape(websiteURL: URL(string: "https://nope.example/")!)
        XCTAssertNil(result.logo)
        XCTAssertEqual(result.parsed, .init())
        XCTAssertNil(result.probedMenuURL)
    }

    // MARK: - Helpers

    private func pngBytes(of size: Int) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        if size > data.count {
            data.append(Data(repeating: 0, count: size - data.count))
        }
        return data
    }
}

// MARK: - Test double

final class StubScrapingHTTP: RestaurantScrapingHTTP, @unchecked Sendable {
    private let htmlByURL: [URL: String]
    private let bytesByURL: [URL: Data]
    private let htmlProbeOK: Set<URL>
    private(set) var fetchedHTMLURLs: [URL] = []
    private(set) var fetchedByteURLs: [URL] = []

    init(html: [URL: String] = [:],
         bytes: [URL: Data] = [:],
         htmlProbeOK: [URL] = []) {
        self.htmlByURL = html
        self.bytesByURL = bytes
        self.htmlProbeOK = Set(htmlProbeOK)
    }

    func fetchHTML(_ url: URL) async -> (html: String, finalURL: URL)? {
        fetchedHTMLURLs.append(url)
        guard let html = htmlByURL[url] else { return nil }
        return (html, url)
    }

    func fetchBytes(_ url: URL) async -> Data? {
        fetchedByteURLs.append(url)
        return bytesByURL[url]
    }

    func probeHTML(_ url: URL) async -> Bool {
        htmlProbeOK.contains(url)
    }
}
