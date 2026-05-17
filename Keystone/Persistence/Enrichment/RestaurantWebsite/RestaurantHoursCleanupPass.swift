import Foundation
import GRDB
import OSLog
@preconcurrency import SQLiteData

private let log = Logger(subsystem: "Keystone", category: "RestaurantHoursCleanup")

/// One-shot cleanup that nulls out garbage `hours` values left on
/// restaurant records by the earlier enrichment passes (before the
/// JSON-LD-empty-array fix and the write-side sanitizer landed).
///
/// "Garbage" means: contains no alphanumeric content, or starts with
/// a punctuation/whitespace separator that no legitimate hours string
/// ever would. Examples: `", , , , , , "`, `", Tu 15:00-23:00, …"`,
/// or even just `","`. Any cleanly-parseable value is left alone.
///
/// Guarded by a `UserDefaults` flag so it runs exactly once per
/// device. Safe to ship alongside the live write-side sanitizer —
/// new values can't reach this state anymore, but pre-existing rows
/// need a one-time purge or else the user sees commas on their
/// Restaurants table forever.
enum RestaurantHoursCleanupPass {
    private static let userDefaultsKey = "kRestaurantHoursCleanupV1Done"

    static var hasRun: Bool {
        UserDefaults.standard.bool(forKey: userDefaultsKey)
    }

    static func markComplete() {
        UserDefaults.standard.set(true, forKey: userDefaultsKey)
    }

    /// Schedule the cleanup to run shortly after launch. Tiny SQL pass
    /// so the delay is mostly courtesy — it just keeps cleanup out of
    /// the boot-critical path.
    static func start() {
        guard !hasRun else { return }
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await runOnce()
        }
    }

    /// Run synchronously. Used by the at-boot scheduler above and is
    /// available to tests / CLI for direct invocation.
    static func runOnce() async {
        @Dependency(\.defaultDatabase) var database
        do {
            let cleared = try await database.write { db -> Int in
                // Pull every restaurant's current hours value alongside
                // the property_values row id so we can null the bad
                // ones without re-resolving the join per row.
                let rows = try Row.fetchAll(db, sql: """
                    SELECT pv.id AS pv_id, pv.text_value AS text_value
                    FROM property_values pv
                    JOIN properties p ON p.id = pv.property_id
                    WHERE p.database_id = 'vendors'
                      AND p.key = 'hours'
                      AND pv.text_value IS NOT NULL
                      AND pv.text_value != ''
                """)
                var nulled = 0
                let now = AppDatabase.isoFormatter.string(from: Date())
                for row in rows {
                    let value: String = row["text_value"] ?? ""
                    guard looksLikeGarbage(value) else { continue }
                    let pvID: String = row["pv_id"]
                    try db.execute(
                        sql: "UPDATE property_values SET text_value = NULL, updated_at = ? WHERE id = ?",
                        arguments: [now, pvID]
                    )
                    nulled += 1
                }
                return nulled
            }
            if cleared > 0 {
                log.info("nulled \(cleared, privacy: .public) garbage hours value(s)")
            }
            markComplete()
        } catch {
            log.error("cleanup failed: \(error.localizedDescription, privacy: .public)")
            // Don't mark complete on failure — we'll retry next launch.
        }
    }

    /// True when `value` is empty or pure punctuation/whitespace —
    /// no letters, no digits. Matches the write-side sanitizer's
    /// intent.
    ///
    /// Earlier versions also returned true when the trimmed value
    /// *started* with a non-alphanumeric character. That was an
    /// over-tight filter from the empty-string-array bug era — it
    /// short-circuited the display layer's hours parsing before the
    /// OSM-fallback path had a chance to run, even on values that
    /// parsed cleanly. The OSM parser's own normalization now
    /// handles leading-separator / comma-rule-separator shapes, so
    /// we only filter pure-garbage strings here.
    static func looksLikeGarbage(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let hasContent = trimmed.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }
        return !hasContent
    }
}
