import XCTest
@testable import Keystone

/// Verifies the Phase 1 sidecar backfill against synthesized fixtures
/// that mirror the layouts seen in the real `Cars/` tree. Synthesized
/// inputs keep the test independent of the user's hand-curated
/// frontmatter (which becomes the source of truth once filled in) and
/// pin the regex extractor's behavior in isolation.
final class SidecarBackfillTests: XCTestCase {
    private func write(_ body: String) throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ks-sidecar-test-\(UUID().uuidString).pdf-processed-markdown.md")
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        return tmp
    }

    func testExtractsVendorMileageCostServicesFromTake5Layout() throws {
        let body = """
        ---
        type: vehicle_maintenance
        title: "2021-06-12 - Oil and filter change"
        vehicle: "2018 Honda CR-V"
        date: "2021-06-12"
        kind: "service"
        mileage: 36696
        ---
        [scan](2021-06-12 - Oil and filter change.pdf)

        TAKE 5 OIL CHANGE #1047
        940 INLET SQUARE DR
        MURRELLS INLET, SC 29576

        Vehicle
        2018 HONDA CR-V
        Present Mileage: 36,696

        Services performed: oil change with oil filter and air filter replacement.

        | **TOTAL (MASTER CARD)** | | | | | **$72.81** |
        """
        let url = try write(body)

        let dryResult = try BackfillSidecarFrontmatterCLI.processFile(at: url, dryRun: true)
        XCTAssertTrue(dryResult.added.contains("vendor"), "vendor should be detected — added: \(dryResult.added)")
        XCTAssertTrue(dryResult.added.contains("cost"),   "cost should be detected — added: \(dryResult.added)")
        XCTAssertTrue(dryResult.added.contains("services"), "services should be detected — added: \(dryResult.added)")
        XCTAssertTrue(dryResult.alreadyHad.contains("mileage"), "mileage was preset")

        // Round-trip: write, reparse, assert clean values.
        _ = try BackfillSidecarFrontmatterCLI.processFile(at: url, dryRun: false)
        let written = try String(contentsOf: url, encoding: .utf8)
        let doc = SidecarFrontmatter.parse(written)
        if case .string(let v) = doc.value(for: "vendor") {
            XCTAssertTrue(v.lowercased().contains("take 5"), "vendor should be Take 5; got \(v)")
        } else { XCTFail("vendor not written as string") }
        if case .string(let cost) = doc.value(for: "cost") {
            XCTAssertEqual(cost, "72.81", "cost should be the post-tax total")
        } else { XCTFail("cost not written as string") }
        if case .stringList(let svcs) = doc.value(for: "services") {
            XCTAssertTrue(svcs.contains("svc-honda-engine-oil-normal"))
            XCTAssertTrue(svcs.contains("svc-honda-oil-filter-normal"))
            XCTAssertTrue(svcs.contains("svc-honda-air-cleaner-normal"))
            // No severe variants — the vocab now tags Normal only.
            XCTAssertFalse(svcs.contains(where: { $0.contains("severe") }))
        } else { XCTFail("services not written as list") }
    }

    func testIdempotencyRoundTrip() throws {
        let body = """
        ---
        type: vehicle_maintenance
        title: "test"
        vehicle: "2018 Honda CR-V"
        date: "2024-01-01"
        kind: "service"
        ---
        TAKE 5 OIL CHANGE #1047
        Mileage: 80,000
        Total: $50.00
        Oil change and oil filter performed.
        """
        let url = try write(body)
        _ = try BackfillSidecarFrontmatterCLI.processFile(at: url, dryRun: false)
        let firstPass = try String(contentsOf: url, encoding: .utf8)
        let secondPassResult = try BackfillSidecarFrontmatterCLI.processFile(at: url, dryRun: false)
        let secondPass = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(firstPass, secondPass, "Second pass should produce no diff")
        XCTAssertTrue(secondPassResult.added.isEmpty, "Second pass should add nothing; got \(secondPassResult.added)")
    }

    func testExtractsBoldMileagePattern() throws {
        // `**Mileage:** 41417` style — bold-wrapped key/value. The
        // extractor strips `**` from the search corpus before matching.
        let body = """
        ---
        type: vehicle_maintenance
        title: "test"
        vehicle: "2018 Honda CR-V"
        date: "2022-03-04"
        kind: "inspection"
        ---
        **East Coast Honda**
        **Mileage:** 41417
        Multi-point inspection report.
        """
        let url = try write(body)
        let result = try BackfillSidecarFrontmatterCLI.processFile(at: url, dryRun: true)
        XCTAssertTrue(result.added.contains("mileage"),
                      "Should extract mileage from bold-wrapped pattern — added: \(result.added)")
    }

    func testPreservesUserSetValues() throws {
        // User-set vendor must survive even when the body would yield
        // a different one.
        let body = """
        ---
        type: vehicle_maintenance
        title: "test"
        vehicle: "2018 Honda CR-V"
        date: "2024-01-01"
        vendor: "User Hand-Edit"
        ---
        **East Coast Honda**
        Mileage: 99,000
        Total: $50.00
        """
        let url = try write(body)
        _ = try BackfillSidecarFrontmatterCLI.processFile(at: url, dryRun: false)
        let after = try String(contentsOf: url, encoding: .utf8)
        let doc = SidecarFrontmatter.parse(after)
        if case .string(let v) = doc.value(for: "vendor") {
            XCTAssertEqual(v, "User Hand-Edit", "User-set vendor must survive backfill")
        } else { XCTFail() }
    }

    func testServicesUserCuratedListSurvives() throws {
        // If `services:` is already present (even as a single-element
        // list), the backfill must not append additional auto-detected
        // matches — the user's list is canonical.
        let body = """
        ---
        type: vehicle_maintenance
        title: "test"
        vehicle: "2018 Honda CR-V"
        date: "2024-01-01"
        kind: "service"
        services: [svc-honda-engine-oil-normal]
        ---
        Oil change with oil filter and tire rotation.
        Total: $0.00
        """
        let url = try write(body)
        let result = try BackfillSidecarFrontmatterCLI.processFile(at: url, dryRun: false)
        XCTAssertFalse(result.added.contains("services"), "services list shouldn't be modified — added: \(result.added)")
        let after = try String(contentsOf: url, encoding: .utf8)
        let doc = SidecarFrontmatter.parse(after)
        if case .stringList(let svcs) = doc.value(for: "services") {
            XCTAssertEqual(svcs, ["svc-honda-engine-oil-normal"], "Curated services list must survive intact")
        } else { XCTFail() }
    }

    func testVocabTagsNormalNotSevere() throws {
        let hits = MaintenanceVocab.match(in: "Performed engine oil change with oil filter replacement, multi-point inspection.")
        XCTAssertTrue(hits.contains("svc-honda-engine-oil-normal"))
        XCTAssertTrue(hits.contains("svc-honda-oil-filter-normal"))
        XCTAssertTrue(hits.contains("svc-honda-multi-inspect-normal"))
        XCTAssertFalse(hits.contains(where: { $0.contains("severe") }), "Vocab should tag Normal only by default")
    }
}
