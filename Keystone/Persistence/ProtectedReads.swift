import Foundation
import GRDB

/// Compute the set of record IDs that should be hidden from UI surfaces
/// because the user has marked them (or a record they reference) as
/// protected.
///
/// **Direct seeds:** any record whose `is_protected` checkbox property
/// resolves truthy (text_value `"true"` / `"1"` / `"yes"`, mirroring
/// `CheckboxField`'s parser).
///
/// **Cascade:** if record A is protected and record B has an outgoing
/// relation pointing to A (e.g. an Activity → Trip), B is also hidden —
/// otherwise the activity's existence in lists/calendar would leak the
/// protected trip's title and date range. Computed via fixed-point
/// expansion: keep walking incoming relations until the set stops
/// growing. Bounded in practice by chain depth (Trips → Activities →
/// nothing else, so ~2 iterations).
///
/// **Unlock:** the caller passes the in-memory `unlocked` allow-list
/// from `AppFeature.State.unlockedRecordIDs`. IDs in `unlocked` are
/// excluded from the seed set, which means their dependents drop out of
/// the cascade too.
///
/// **Filtering disabled:** when `filteringActive` is false, returns the
/// empty set regardless of protection flags — the user has opted out of
/// the hide behavior entirely (Settings → Privacy → "Hide protected
/// records when app lock is off" off, with app lock also off).
enum ProtectedReads {
    static func hiddenRecordIDs(
        _ db: Database,
        unlocked: Set<String>,
        filteringActive: Bool
    ) throws -> Set<String> {
        guard filteringActive else { return [] }

        // Seed: every record currently flagged is_protected truthy.
        let seedRows = try String.fetchAll(db, sql: """
            SELECT pv.record_id
            FROM property_values pv
            JOIN properties p ON p.id = pv.property_id
            WHERE p.key = 'is_protected'
              AND p.type = 'checkbox'
              AND pv.text_value IS NOT NULL
              AND (pv.text_value = 'true'
                OR pv.text_value = '1'
                OR LOWER(pv.text_value) = 'yes')
        """)
        var hidden = Set(seedRows).subtracting(unlocked)
        guard !hidden.isEmpty else { return [] }

        // Cascade: walk outgoing relations from any hidden record's
        // children. A record B is hidden if ANY of its outgoing
        // relations targets a hidden record A. Repeat until the set
        // stabilizes.
        //
        // Hard cap on iterations as a safety net — a hand-crafted
        // pathological cycle in the relations graph shouldn't be able
        // to spin this loop forever even if the schema's normally
        // acyclic.
        let maxIterations = 8
        for _ in 0..<maxIterations {
            let placeholders = Array(repeating: "?", count: hidden.count).joined(separator: ",")
            let dependents = try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT source_record_id
                    FROM relations
                    WHERE target_record_id IN (\(placeholders))
                """,
                arguments: StatementArguments(Array(hidden))
            )
            let newDependents = Set(dependents).subtracting(hidden).subtracting(unlocked)
            if newDependents.isEmpty { break }
            hidden.formUnion(newDependents)
        }

        return hidden
    }

    /// Returns the IDs of every record currently flagged is_protected
    /// (truthy). Used by the "Show all protected" affordance to
    /// pre-fill the unlock set in one biometric prompt, and by
    /// per-database "N hidden" footer counts.
    ///
    /// Unlike `hiddenRecordIDs`, this does NOT subtract `unlocked` and
    /// does NOT cascade — it's the literal set of records the user has
    /// flagged.
    static func allProtectedSeedIDs(_ db: Database) throws -> Set<String> {
        let rows = try String.fetchAll(db, sql: """
            SELECT pv.record_id
            FROM property_values pv
            JOIN properties p ON p.id = pv.property_id
            WHERE p.key = 'is_protected'
              AND p.type = 'checkbox'
              AND pv.text_value IS NOT NULL
              AND (pv.text_value = 'true'
                OR pv.text_value = '1'
                OR LOWER(pv.text_value) = 'yes')
        """)
        return Set(rows)
    }

    /// True iff the given record id is currently flagged is_protected
    /// (truthy). Used by `RecordLockView` mounting to know whether a
    /// nil-from-record-lookup means "doesn't exist" vs. "exists but
    /// hidden" — same surface, different copy.
    static func isProtected(_ db: Database, recordID: String) throws -> Bool {
        let row = try String.fetchOne(db, sql: """
            SELECT pv.text_value
            FROM property_values pv
            JOIN properties p ON p.id = pv.property_id
            WHERE p.key = 'is_protected'
              AND p.type = 'checkbox'
              AND pv.record_id = ?
              LIMIT 1
        """, arguments: [recordID])
        guard let v = row else { return false }
        return v == "true" || v == "1" || v.lowercased() == "yes"
    }
}
