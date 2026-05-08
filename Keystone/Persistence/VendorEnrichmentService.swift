import Foundation
import GRDB
import OSLog
@preconcurrency import SQLiteData

#if canImport(MapKit)
import MapKit

private let log = Logger(subsystem: "Keystone", category: "VendorEnrichment")

/// Background service that walks the `vendors` database and fills in
/// MapKit-derived fields (phone, website, address, locality, kind,
/// place_id) on records that don't have them yet.
///
/// Trigger surfaces:
/// - **App launch** — `start()` runs an initial pass after a short
///   delay so any vendors that arrived via CloudKit or were created
///   while the app was offline get caught up.
/// - **After Inbox import** — `AppFeature` calls `enrichPending()`
///   when an import completes, so vendors auto-created from
///   `vendor: <name>` frontmatter get linked immediately.
///
/// Policy:
/// - Only **confident** MapKit matches auto-apply (the same bar as the
///   CLI `enrich-all-vendors` command — top result's name must match
///   the vendor title case-insensitively, with at most a suffix). This
///   avoids silently linking "Honda dealer" to a random Honda location.
/// - **Ambiguous** matches are left alone — the user disambiguates via
///   the "Look up on Apple Maps" sheet on the vendor's detail page.
/// - **Sequential, never concurrent** — Apple's `MKLocalSearch`
///   throttles on bursts and we'd rather take a few seconds for a
///   handful of vendors than burn rate-limit budget. Re-entrant calls
///   coalesce into the in-flight pass.
@available(iOS 26.0, macOS 26.0, *)
actor VendorEnrichmentService {
    static let shared = VendorEnrichmentService()

    private var inFlight: Task<Void, Never>?

    private init() {}

    /// Kick off an initial enrichment pass shortly after launch.
    /// Non-blocking — fires the work off detached.
    nonisolated func start() {
        log.info("VendorEnrichmentService.start")
        Task.detached {
            // Small delay so the initial CloudKit pull has a chance to
            // settle before we run the first scan.
            try? await Task.sleep(for: .seconds(8))
            await Self.shared.enrichPending()
        }
    }

    /// Find every vendor record without a `place_id` and attempt to
    /// enrich it via MapKit. Idempotent. Re-entrant calls await the
    /// in-flight pass instead of starting a duplicate one.
    func enrichPending() async {
        if let existing = inFlight {
            await existing.value
            return
        }
        let task = Task { await self.runPass() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// One enrichment pass — pulls candidate IDs, walks them
    /// sequentially, applies confident matches.
    private func runPass() async {
        @Dependency(\.defaultDatabase) var database

        let pending: [(id: String, title: String, address: String?)]
        do {
            pending = try await database.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT r.id AS id, r.title AS title,
                           (SELECT pv.text_value
                              FROM property_values pv
                             WHERE pv.record_id = r.id
                               AND pv.property_id = 'vendors.address'
                               AND pv.text_value IS NOT NULL
                               AND pv.text_value != ''
                             LIMIT 1) AS addr
                    FROM records r
                    WHERE r.database_id = 'vendors'
                      AND r.deleted_at IS NULL
                      AND r.id NOT IN (
                        SELECT pv.record_id FROM property_values pv
                         WHERE pv.property_id = 'vendors.place_id'
                           AND pv.text_value IS NOT NULL
                           AND pv.text_value != ''
                      )
                    ORDER BY r.created_at DESC
                """)
                return rows.map { row -> (id: String, title: String, address: String?) in
                    let id: String = row["id"]
                    let title: String = row["title"]
                    let addr: String? = row["addr"]
                    return (id: id, title: title, address: addr)
                }
            }
        } catch {
            log.error("enrichPending: failed to fetch pending vendors: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard !pending.isEmpty else {
            log.debug("enrichPending: no vendors need enrichment")
            return
        }
        log.info("enrichPending: starting pass for \(pending.count) vendor(s)")

        var resolved = 0
        var ambiguous = 0
        var notFound = 0
        for vendor in pending {
            if Task.isCancelled { break }
            let outcome = await VendorLookupService.enrich(
                name: vendor.title,
                address: vendor.address
            )
            switch outcome {
            case .resolved(let enrichment):
                await apply(enrichment, to: vendor.id, vendorTitle: vendor.title)
                resolved += 1
            case .ambiguous:
                ambiguous += 1
                log.info("\(vendor.title, privacy: .public): ambiguous, skipped")
            case .notFound:
                notFound += 1
                log.info("\(vendor.title, privacy: .public): no MapKit match")
            }
        }
        log.info("enrichPending: done — resolved=\(resolved), ambiguous=\(ambiguous), notFound=\(notFound)")
    }

    /// Write enriched fields to the vendor record. Only writes blanks —
    /// existing user-set values are preserved. Uses `DBWrites.updatePropertyValue`
    /// for type coercion / relation semantics consistency.
    private func apply(_ enrichment: VendorEnrichment, to vendorID: String, vendorTitle: String) async {
        @Dependency(\.defaultDatabase) var database
        let fields: [(String, String?)] = [
            ("phone",    enrichment.phone),
            ("website",  enrichment.website),
            ("address",  enrichment.address),
            ("locality", enrichment.locality),
            ("kind",     enrichment.kind),
            ("place_id", enrichment.placeID),
        ]
        // Compute applied list inside the write closure and return it
        // so we don't capture a mutable var across an actor hop.
        let applied: [String]
        do {
            applied = try await database.write { db in
                var written: [String] = []
                for (key, valueOpt) in fields {
                    guard let value = valueOpt, !value.isEmpty else { continue }
                    let propID = "vendors.\(key)"
                    let existing = try String.fetchOne(
                        db,
                        sql: """
                            SELECT pv.text_value FROM property_values pv
                            WHERE pv.record_id = ? AND pv.property_id = ?
                              AND pv.text_value IS NOT NULL AND pv.text_value != ''
                            LIMIT 1
                        """,
                        arguments: [vendorID, propID]
                    )
                    if existing != nil { continue }
                    try DBWrites.updatePropertyValue(
                        db,
                        recordID: vendorID,
                        propertyKey: key,
                        value: value
                    )
                    written.append(key)
                }
                return written
            }
        } catch {
            log.error("\(vendorTitle, privacy: .public): apply failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        log.info("\(vendorTitle, privacy: .public): resolved — \(applied.joined(separator: ", "), privacy: .public)")
    }
}

#endif
