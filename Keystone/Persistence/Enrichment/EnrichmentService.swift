import Foundation
import GRDB
import OSLog
@preconcurrency import SQLiteData

private let log = Logger(subsystem: "Keystone", category: "Enrichment")

/// Walks every registered `EnrichmentProvider` and applies blanks-only
/// updates to records that haven't been enriched yet. Single in-flight
/// pass — re-entrant calls coalesce into the running task. Sequential
/// across providers and within each provider, by design: third-party
/// APIs throttle on bursts and we'd rather take a few seconds for a
/// handful of records than burn rate-limit budget.
///
/// Trigger surfaces:
/// - **App launch** — `start()` runs an initial pass after a short delay.
/// - **After Inbox import** — `AppFeature` calls `enrichPending()` so
///   records auto-created from frontmatter (`vendor: <name>`,
///   `book: <title>`, etc.) get linked immediately.
/// - **CLI** — `enrich-all-vendors --database <key>` runs a one-shot pass.
actor EnrichmentService {
    static let shared = EnrichmentService()

    /// Production registry. Kept here rather than in a method so the
    /// list is easy to find and amend; new providers slot into the array.
    /// MapKit provider is gated to 26+; the rest are version-agnostic.
    ///
    /// Marked `nonisolated(unsafe)` so tests can swap in spy providers in
    /// `setUp` without going through the actor. In production this value
    /// is set once at process start and never reassigned, so the unsafety
    /// is bounded to the test entry point.
    nonisolated(unsafe) static var registry: [any EnrichmentProvider] = {
        var providers: [any EnrichmentProvider] = []
        #if canImport(MapKit)
        if #available(iOS 26.0, macOS 26.0, *) {
            providers.append(MapKitVendorProvider())
        }
        #endif
        // Restaurants: website-scrape pass for logo, hours, rating,
        // price band, and menu URL. Runs after the MapKit vendor pass
        // so `website` is already populated for restaurants created
        // via the lookup sheet.
        providers.append(RestaurantWebsiteEnrichmentProvider())
        providers.append(GoogleBooksProvider())
        providers.append(TMDBMovieProvider())
        providers.append(TMDBTVProvider())
        return providers
    }()

    private var inFlight: Task<Void, Never>?

    private init() {}

    /// Kick off an initial pass shortly after launch. Non-blocking.
    nonisolated func start() {
        log.info("EnrichmentService.start")
        Task.detached {
            try? await Task.sleep(for: .seconds(8))
            await Self.shared.enrichPending()
        }
    }

    /// Apply a `LookupCandidate`-shaped payload directly to a record.
    /// Used by the lookup-first creation flow (`overwrite: false` —
    /// blanks-only) and the right-click "re-enrich" flow (`overwrite:
    /// true` — overwrite provider-owned metadata, leaving keys the
    /// provider didn't return alone, so user-edited fields like
    /// `notes`, `status`, `rating` are preserved automatically).
    func applyForLookup(
        _ apply: EnrichmentApply,
        databaseID: String,
        recordID: String,
        title: String,
        overwrite: Bool = false
    ) async {
        let synthetic = EnrichmentRecord(
            id: recordID,
            databaseID: databaseID,
            title: title,
            propertyValues: [:]
        )
        await applyEnrichment(apply, to: synthetic, overwrite: overwrite)
    }

    /// Run one pass across every available provider. Pass `onlyDatabase`
    /// to filter to a specific provider (CLI `--database <key>`); when
    /// nil, every registered provider runs.
    func enrichPending(onlyDatabase: String? = nil) async {
        if let existing = inFlight {
            await existing.value
            return
        }
        let task = Task { await self.runPass(onlyDatabase: onlyDatabase) }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// Run every applicable provider against a single record in
    /// overwrite mode, bypassing both the in-flight coalescing gate
    /// and the trigger-property "already enriched" check.
    ///
    /// The "Re-enrich…" UI gesture lands here: the user is explicitly
    /// asking for fresh data on one record, so we don't want them to
    /// be silently no-op'd when a background pass happens to be in
    /// flight, and we don't want providers to skip the record just
    /// because its trigger marker is still set from the previous run.
    /// Provider-owned columns get rewritten; columns the providers
    /// don't return (notes, status, …) stay put.
    func enrichSingleRecord(recordID: String, databaseID: String) async {
        @Dependency(\.defaultDatabase) var database
        let snapshot: EnrichmentRecord
        do {
            snapshot = try await database.read { db in
                let row = try Row.fetchOne(db, sql: """
                    SELECT id, title, database_id FROM records WHERE id = ?
                """, arguments: [recordID])
                let title = (row?["title"] as String?) ?? ""
                let actualDB = (row?["database_id"] as String?) ?? databaseID
                let valueRows = try Row.fetchAll(db, sql: """
                    SELECT p.key AS key, pv.text_value AS t, pv.number_value AS n, pv.date_value AS d
                    FROM property_values pv
                    JOIN properties p ON p.id = pv.property_id
                    WHERE pv.record_id = ?
                """, arguments: [recordID])
                var values: [String: String] = [:]
                for row in valueRows {
                    let key: String = row["key"]
                    if let t: String = row["t"], !t.isEmpty {
                        values[key] = t
                    } else if let n: Double = row["n"] {
                        values[key] = (n.rounded() == n) ? String(Int(n)) : String(n)
                    } else if let d: String = row["d"], !d.isEmpty {
                        values[key] = d
                    }
                }
                return EnrichmentRecord(id: recordID, databaseID: actualDB, title: title, propertyValues: values)
            }
        } catch {
            log.error("enrichSingleRecord fetch failed for \(recordID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        for provider in Self.registry where provider.databaseKey == snapshot.databaseID {
            guard await provider.isAvailable() else { continue }
            switch await provider.enrich(record: snapshot) {
            case .resolved(let apply):
                await applyEnrichment(apply, to: snapshot, overwrite: true)
            case .ambiguous, .notFound, .unavailable:
                continue
            }
        }
    }

    private func runPass(onlyDatabase: String?) async {
        let providers: [any EnrichmentProvider]
        if let onlyDatabase {
            providers = Self.registry.filter { $0.databaseKey == onlyDatabase }
            if providers.isEmpty {
                log.info("no provider registered for database \(onlyDatabase, privacy: .public)")
                return
            }
        } else {
            providers = Self.registry
        }
        for provider in providers {
            if Task.isCancelled { break }
            await runProvider(provider)
        }
    }

    private func runProvider(_ provider: any EnrichmentProvider) async {
        guard await provider.isAvailable() else {
            log.info("\(provider.databaseKey, privacy: .public): unavailable, skipping")
            return
        }

        let pending: [EnrichmentRecord]
        do {
            pending = try await fetchPending(databaseKey: provider.databaseKey,
                                             triggerKey: provider.triggerPropertyKey)
        } catch {
            log.error("\(provider.databaseKey, privacy: .public): fetch pending failed — \(error.localizedDescription, privacy: .public)")
            return
        }

        guard !pending.isEmpty else {
            log.debug("\(provider.databaseKey, privacy: .public): nothing pending")
            return
        }
        log.info("\(provider.databaseKey, privacy: .public): \(pending.count) record(s) to enrich")

        var resolved = 0, ambiguous = 0, notFound = 0, unavailable = 0
        for (idx, rec) in pending.enumerated() {
            if Task.isCancelled { break }
            // Small inter-request delay so a 200+ row batch (e.g.
            // after a CSV import) doesn't burn the provider's rate
            // budget in one tight loop. Google Books and TMDB both
            // start returning 429 / 503 under sustained load; pacing
            // here keeps the interactive cover picker and other
            // user-driven flows usable while a background pass runs.
            // First iteration is unthrottled — no point sleeping
            // before the very first request.
            if idx > 0 {
                try? await Task.sleep(nanoseconds: 250 * 1_000_000)
            }
            switch await provider.enrich(record: rec) {
            case .resolved(let apply):
                await applyEnrichment(apply, to: rec)
                resolved += 1
            case .ambiguous:
                ambiguous += 1
                log.info("\(rec.title, privacy: .public): ambiguous, skipped")
            case .notFound:
                notFound += 1
            case .unavailable(let reason):
                unavailable += 1
                log.info("\(rec.title, privacy: .public): unavailable — \(reason, privacy: .public)")
            }
        }
        log.info("\(provider.databaseKey, privacy: .public): resolved=\(resolved) ambiguous=\(ambiguous) notFound=\(notFound) unavailable=\(unavailable)")
    }

    /// SELECT records in `databaseKey` whose `triggerKey` property is
    /// missing or empty, plus a snapshot of every property value so the
    /// provider has what it needs to query.
    private func fetchPending(
        databaseKey: String,
        triggerKey: String
    ) async throws -> [EnrichmentRecord] {
        @Dependency(\.defaultDatabase) var database
        return try await database.read { db in
            let triggerPropID = "\(databaseKey).\(triggerKey)"
            let recRows = try Row.fetchAll(db, sql: """
                SELECT r.id AS id, r.title AS title, r.database_id AS database_id
                FROM records r
                WHERE r.database_id = ?
                  AND r.deleted_at IS NULL
                  AND r.id NOT IN (
                    SELECT pv.record_id FROM property_values pv
                    WHERE pv.property_id = ?
                      AND pv.text_value IS NOT NULL
                      AND pv.text_value != ''
                  )
                ORDER BY r.created_at DESC
            """, arguments: [databaseKey, triggerPropID])

            guard !recRows.isEmpty else { return [] }

            // Bulk-fetch property values for every candidate record, avoiding
            // a per-record round-trip.
            let recIDs = recRows.map { $0["id"] as String }
            let placeholders = Array(repeating: "?", count: recIDs.count).joined(separator: ",")
            let valueRows = try Row.fetchAll(db, sql: """
                SELECT pv.record_id, p.key, pv.text_value, pv.number_value, pv.date_value
                FROM property_values pv
                JOIN properties p ON p.id = pv.property_id
                WHERE pv.record_id IN (\(placeholders))
            """, arguments: StatementArguments(recIDs))

            var byRecord: [String: [String: String]] = [:]
            for row in valueRows {
                let rid: String = row["record_id"]
                let key: String = row["key"]
                if let t: String = row["text_value"], !t.isEmpty {
                    byRecord[rid, default: [:]][key] = t
                } else if let n: Double = row["number_value"] {
                    byRecord[rid, default: [:]][key] = (n.rounded() == n) ? String(Int(n)) : String(n)
                } else if let d: String = row["date_value"], !d.isEmpty {
                    byRecord[rid, default: [:]][key] = d
                }
            }

            return recRows.map { row -> EnrichmentRecord in
                let id: String = row["id"]
                return EnrichmentRecord(
                    id: id,
                    databaseID: row["database_id"],
                    title: row["title"],
                    propertyValues: byRecord[id] ?? [:]
                )
            }
        }
    }

    /// Write the enrichment payload. Mirrors the pre-refactor vendor
    /// behavior: only blank fields get the new value; existing user-set
    /// values are preserved. Cover image (when present) is downloaded
    /// and attached after the property writes complete.
    ///
    /// `overwrite: false` (default) is the background-pass behavior —
    /// a value is written only when the existing column is null/empty.
    /// `overwrite: true` is what the right-click "re-enrich" flow
    /// passes: every key in `apply.propertyUpdates` is written even if
    /// the column already has a value. Keys the provider doesn't return
    /// (e.g. `notes`, `status`, `rating`) are untouched in either mode.
    private func applyEnrichment(
        _ apply: EnrichmentApply,
        to rec: EnrichmentRecord,
        overwrite: Bool = false
    ) async {
        @Dependency(\.defaultDatabase) var database

        let written: [String]
        do {
            written = try await database.write { db in
                var keysWritten: [String] = []
                for (key, value) in apply.propertyUpdates {
                    guard !value.isEmpty else { continue }
                    let propID = "\(rec.databaseID).\(key)"
                    if !overwrite {
                        let existing = try String.fetchOne(
                            db,
                            sql: """
                                SELECT pv.text_value FROM property_values pv
                                WHERE pv.record_id = ? AND pv.property_id = ?
                                  AND pv.text_value IS NOT NULL AND pv.text_value != ''
                                LIMIT 1
                            """,
                            arguments: [rec.id, propID]
                        )
                        if existing != nil { continue }
                    }
                    try DBWrites.updatePropertyValue(
                        db,
                        recordID: rec.id,
                        propertyKey: key,
                        value: value
                    )
                    keysWritten.append(key)
                }
                return keysWritten
            }
        } catch {
            log.error("\(rec.title, privacy: .public): apply failed — \(error.localizedDescription, privacy: .public)")
            return
        }
        log.info("\(rec.title, privacy: .public): resolved — \(written.joined(separator: ", "), privacy: .public)")

        if let coverURL = apply.coverImageURL {
            await CoverImageImporter.attachAsCover(coverURL, to: rec.id)
        }
    }
}
