import XCTest
import Dependencies
import GRDB
@preconcurrency import SQLiteData
@testable import Keystone

final class CollectionsTests: XCTestCase {
    private func withDB<T>(_ body: () throws -> T) rethrows -> T {
        try withHermeticDB(body)
    }

    // MARK: - Migration / seed

    func testCollectionsAreaSeeded() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue
            let dbs = try dbClient.databases()
            // Restaurants is no longer a database — it's a view over
            // `vendors` (v41). The three real Collections databases
            // remain.
            for id in ["books", "movies", "tv_shows"] {
                XCTAssertTrue(dbs.contains { $0.id == id }, "missing seeded database: \(id)")
                XCTAssertEqual(dbs.first { $0.id == id }?.areaID, "area-collections")
            }
            XCTAssertFalse(dbs.contains { $0.id == "restaurants" },
                           "restaurants should no longer be a database post-v41")
        }
    }

    func testGalleryDefaultForMedia() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue
            let dbs = try dbClient.databases()
            XCTAssertEqual(dbs.first { $0.id == "books" }?.defaultView, .gallery)
            XCTAssertEqual(dbs.first { $0.id == "movies" }?.defaultView, .gallery)
            XCTAssertEqual(dbs.first { $0.id == "tv_shows" }?.defaultView, .gallery)
        }
    }

    // MARK: - Property contracts (pin against provider expectations)

    func testProviderPropertyKeysExist() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue
            let booksProps = try dbClient.properties("books")
            XCTAssertNotNil(booksProps.first { $0.key == "isbn" && $0.type == .text },
                            "GoogleBooksProvider trigger key 'isbn' is missing")
            XCTAssertNotNil(booksProps.first { $0.key == "author" && $0.type == .text })

            let moviesProps = try dbClient.properties("movies")
            XCTAssertNotNil(moviesProps.first { $0.key == "tmdb_id" && $0.type == .text },
                            "TMDBMovieProvider trigger key 'tmdb_id' is missing")
            XCTAssertNotNil(moviesProps.first { $0.key == "year" && $0.type == .number })

            let tvProps = try dbClient.properties("tv_shows")
            XCTAssertNotNil(tvProps.first { $0.key == "tmdb_id" && $0.type == .text },
                            "TMDBTVProvider trigger key 'tmdb_id' is missing")
            XCTAssertNotNil(tvProps.first { $0.key == "year" && $0.type == .number })
        }
    }

    // MARK: - Select options round-trip

    func testStatusOptionsRoundTrip() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue
            let booksProps = try dbClient.properties("books")
            let status = try XCTUnwrap(booksProps.first { $0.key == "status" })
            XCTAssertEqual(status.config.options, ["to_read", "reading", "read", "abandoned"])

            // Restaurant-specific options now live on `vendors` (v41).
            let vendorProps = try dbClient.properties("vendors")
            let priceProp = try XCTUnwrap(vendorProps.first { $0.key == "price_range" })
            XCTAssertEqual(priceProp.config.options, ["$", "$$", "$$$", "$$$$"])
        }
    }

    func testFreeFormSelectHasNoOptions() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue
            // Cuisine ships free-form for now (vendors.cuisine, post-v41).
            let vendorProps = try dbClient.properties("vendors")
            let cuisine = try XCTUnwrap(vendorProps.first { $0.key == "cuisine" })
            XCTAssertNil(cuisine.config.options,
                         "cuisine ships free-form for now; users fill organically")
        }
    }

    // MARK: - SelectCycle

    func testSelectCycleAdvances() {
        let opts = ["to_read", "reading", "read", "abandoned"]
        XCTAssertEqual(SelectCycle.next(current: "to_read",   in: opts), "reading")
        XCTAssertEqual(SelectCycle.next(current: "reading",   in: opts), "read")
        XCTAssertEqual(SelectCycle.next(current: "read",      in: opts), "abandoned")
    }

    func testSelectCycleWrapsAtEnd() {
        let opts = ["to_read", "reading", "read", "abandoned"]
        XCTAssertEqual(SelectCycle.next(current: "abandoned", in: opts), "to_read")
    }

    func testSelectCycleEmptyPicksFirst() {
        let opts = ["to_read", "reading"]
        XCTAssertEqual(SelectCycle.next(current: "", in: opts), "to_read")
    }

    func testSelectCycleUnrecognizedPicksFirst() {
        let opts = ["a", "b", "c"]
        XCTAssertEqual(SelectCycle.next(current: "garbage", in: opts), "a")
    }

    func testSelectCycleEmptyOptionsReturnsCurrent() {
        XCTAssertEqual(SelectCycle.next(current: "anything", in: []), "anything")
    }
}
