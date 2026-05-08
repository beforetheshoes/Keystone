import XCTest
import Dependencies
@testable import Keystone

final class EnrichmentTests: XCTestCase {
    private var savedRegistry: [any EnrichmentProvider] = []
    private var savedKeychainStore: KeychainStore = SecItemKeychainStore()

    override func setUp() {
        super.setUp()
        savedRegistry = EnrichmentService.registry
        savedKeychainStore = APIKeys.store
        APIKeys.store = InMemoryKeychainStore()
    }

    override func tearDown() {
        EnrichmentService.registry = savedRegistry
        APIKeys.store = savedKeychainStore
        super.tearDown()
    }

    // MARK: - APIKeys round-trip

    func testAPIKeysRoundTrip() {
        XCTAssertNil(APIKeys.get(.tmdb))

        APIKeys.set(.tmdb, "abc123")
        XCTAssertEqual(APIKeys.get(.tmdb), "abc123")

        // Empty/whitespace deletes the entry.
        APIKeys.set(.tmdb, "   ")
        XCTAssertNil(APIKeys.get(.tmdb))

        // Explicit nil deletes too.
        APIKeys.set(.tmdb, "back-again")
        XCTAssertEqual(APIKeys.get(.tmdb), "back-again")
        APIKeys.set(.tmdb, nil)
        XCTAssertNil(APIKeys.get(.tmdb))

        // Different kinds don't collide.
        APIKeys.set(.tmdb, "tmdb-key")
        APIKeys.set(.googleBooks, "books-key")
        XCTAssertEqual(APIKeys.get(.tmdb), "tmdb-key")
        XCTAssertEqual(APIKeys.get(.googleBooks), "books-key")
    }

    // MARK: - Provider gating

    func testSkipsUnavailableProvider() async throws {
        let spy = SpyProvider(databaseKey: "vendors", available: false)
        EnrichmentService.registry = [spy]

        try await withBootstrappedDB {
            let dbClient = DatabaseClient.liveValue
            let v = try dbClient.createRecord("vendors", "Should Not Enrich")
            defer { try? dbClient.deleteRecord(v.id) }

            await EnrichmentService.shared.enrichPending()
            XCTAssertEqual(spy.enrichCount, 0)
        }
    }

    func testEnrichesPendingRecordsForRegisteredProvider() async throws {
        let spy = SpyProvider(
            databaseKey: "vendors",
            available: true,
            response: .resolved(EnrichmentApply(
                propertyUpdates: ["phone": "555-0100", "place_id": "fake-place-1"]
            ))
        )
        EnrichmentService.registry = [spy]

        try await withBootstrappedDB {
            let dbClient = DatabaseClient.liveValue
            let v = try dbClient.createRecord("vendors", "Test Coffee Shop")
            defer { try? dbClient.deleteRecord(v.id) }

            await EnrichmentService.shared.enrichPending()
            XCTAssertEqual(spy.enrichCount, 1)
            XCTAssertEqual(spy.lastRecord?.title, "Test Coffee Shop")

            let after = try dbClient.record(v.id)
            XCTAssertEqual(after?.values["phone"], "555-0100")
            XCTAssertEqual(after?.values["place_id"], "fake-place-1")
        }
    }

    func testApplyIsBlanksOnly() async throws {
        let spy = SpyProvider(
            databaseKey: "vendors",
            available: true,
            response: .resolved(EnrichmentApply(propertyUpdates: [
                "phone":    "ENRICHED",
                "website":  "https://example.test",
                "place_id": "stable-id-42",
            ]))
        )
        EnrichmentService.registry = [spy]

        try await withBootstrappedDB {
            let dbClient = DatabaseClient.liveValue
            let v = try dbClient.createRecord("vendors", "Pre-filled Vendor")
            defer { try? dbClient.deleteRecord(v.id) }
            try dbClient.updatePropertyValue(v.id, "phone", "USER-OWNED")

            await EnrichmentService.shared.enrichPending()
            let after = try dbClient.record(v.id)
            XCTAssertEqual(after?.values["phone"], "USER-OWNED",
                           "user-set value should never be overwritten")
            XCTAssertEqual(after?.values["website"], "https://example.test")
            XCTAssertEqual(after?.values["place_id"], "stable-id-42")
        }
    }

    func testTriggerPropertyGatesPasses() async throws {
        let spy = SpyProvider(
            databaseKey: "vendors",
            available: true,
            response: .resolved(EnrichmentApply(propertyUpdates: ["place_id": "fake-id"]))
        )
        EnrichmentService.registry = [spy]

        try await withBootstrappedDB {
            let dbClient = DatabaseClient.liveValue
            let v = try dbClient.createRecord("vendors", "Already Enriched")
            defer { try? dbClient.deleteRecord(v.id) }
            try dbClient.updatePropertyValue(v.id, "place_id", "existing-place-id")

            await EnrichmentService.shared.enrichPending()
            XCTAssertEqual(spy.enrichCount, 0,
                           "records with the trigger property already filled should be skipped")
        }
    }

    func testFiltersToSingleDatabase() async throws {
        let vendorsSpy = SpyProvider(databaseKey: "vendors", available: true)
        let booksSpy = SpyProvider(databaseKey: "books", available: true)
        EnrichmentService.registry = [vendorsSpy, booksSpy]

        try await withBootstrappedDB {
            let dbClient = DatabaseClient.liveValue
            let v = try dbClient.createRecord("vendors", "OnlyVendor")
            defer { try? dbClient.deleteRecord(v.id) }

            await EnrichmentService.shared.enrichPending(onlyDatabase: "books")
            XCTAssertEqual(vendorsSpy.enrichCount, 0,
                           "filter by databaseKey should not invoke other providers")
        }
    }

    // MARK: - Helpers

    private func withBootstrappedDB(_ body: @Sendable () async throws -> Void) async throws {
        try await withDependencies { values in
            do {
                try values.bootstrapKeystoneDatabase(configureSyncEngine: false)
            } catch {
                XCTFail("Bootstrap failed: \(error)")
            }
        } operation: {
            try await body()
        }
    }
}

/// Test double for `EnrichmentProvider`. Tracks call counts and the last
/// record it saw so tests can assert which records the service handed off.
final class SpyProvider: EnrichmentProvider, @unchecked Sendable {
    let databaseKey: String
    let triggerPropertyKey: String
    private let available: Bool
    private let response: EnrichmentResult

    private(set) var enrichCount: Int = 0
    private(set) var lastRecord: EnrichmentRecord?

    init(
        databaseKey: String,
        triggerPropertyKey: String = "place_id",
        available: Bool = true,
        response: EnrichmentResult = .notFound
    ) {
        self.databaseKey = databaseKey
        self.triggerPropertyKey = triggerPropertyKey
        self.available = available
        self.response = response
    }

    func isAvailable() async -> Bool { available }

    func enrich(record: EnrichmentRecord) async -> EnrichmentResult {
        enrichCount += 1
        lastRecord = record
        return response
    }
}
