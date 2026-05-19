import Foundation
import GRDB
import OSLog
import Synchronization

private let sidecarLog = Logger(subsystem: "Keystone", category: "Sidecar")

/// Writes a record's current DB state back to its on-disk Markdown
/// sidecar. Called from `DBWrites` after every mutation that affects
/// a record with `sidecar_path` set, so the Finder-visible file stays
/// in sync with the in-app data.
///
/// **Architecture**: this is the DB → file half of the bidirectional
/// sync the user asked for. The file → DB half is the existing
/// InboxWatcher / `import-sidecars` path. They're symmetric: parser
/// and serializer round-trip stably, so re-importing a freshly
/// written sidecar produces no diff.
///
/// **What gets written**:
///   - YAML frontmatter regenerated from the record's properties +
///     relations (vehicle, vendor, services list, mileage, cost,
///     date, kind, title)
///   - Markdown body regenerated from the record's blocks via
///     `BlockMarkdownSerializer`
///   - The leading `[scan](filename)` link (if a PDF/PNG/JPG asset
///     is attached) is preserved at the top of the body
///
/// **Atomic writes**: we write to a temp file in the same directory
/// then `replaceItem`, so a crashed write never leaves a partial
/// file in place.
enum SidecarWriter {
    /// "Suppress sidecar writes" flag. Set to `true` for the duration
    /// of a bulk import — without it, every `updatePropertyValue` /
    /// relation add / block create during the import fires its own
    /// regenerate, racking up ~6 disk writes per record. The importer
    /// triggers one explicit `writeIfNeeded` at the end of each
    /// record's processing (outside the suppression scope), so the
    /// final sidecar still reflects the imported state.
    ///
    /// `Atomic<Bool>` is `Sendable` by declaration and gives us
    /// compiler-verified concurrent access. GRDB serializes writes per
    /// writer, so contention is zero in practice — but the atomic also
    /// keeps reads from other threads (e.g. the CLI's import path
    /// running outside a `database.write` block) honest.
    private static let _suppressed = Atomic<Bool>(false)
    static var suppressed: Bool { _suppressed.load(ordering: .acquiring) }

    /// Run `body` with sidecar regenerates suppressed. Restores the
    /// previous suppression state on exit so nested suppressors
    /// behave correctly even if we don't expect them in practice.
    static func suppress<T>(_ body: () throws -> T) rethrows -> T {
        let prior = _suppressed.exchange(true, ordering: .acquiringAndReleasing)
        defer { _suppressed.store(prior, ordering: .releasing) }
        return try body()
    }

    /// Regenerate and write the sidecar for `recordID` if it has a
    /// `sidecar_path` set. No-op for records without a sidecar
    /// (e.g. records created in-app that never had an associated
    /// file), or when called inside a `suppress { … }` block.
    /// Errors are logged but never thrown — a sidecar write failure
    /// must not prevent the underlying DB write from succeeding.
    static func writeIfNeeded(_ db: Database, recordID: String) {
        if suppressed { return }
        do {
            try writeIfPresent(db, recordID: recordID)
        } catch {
            sidecarLog.error("sidecar write failed for \(recordID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drop the sidecar file for `recordID` if it exists. Used by
    /// `writeIfPresent` when the record is encrypted so the
    /// Finder-visible markdown doesn't lag the privacy state. Errors
    /// are swallowed — the worst case is leaving a stale sidecar on
    /// disk, which the user can delete manually.
    private static func removeExistingSidecarFile(_ db: Database, recordID: String) throws {
        guard let relPath = try String.fetchOne(
            db,
            sql: "SELECT sidecar_path FROM records WHERE id = ?",
            arguments: [recordID]
        ), !relPath.isEmpty else { return }
        let url = AppDatabase.workspaceFolder.appendingPathComponent(relPath)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Like `writeIfNeeded` but ignores the suppression flag. Used by
    /// the bulk importer to fire ONE definitive sidecar write per
    /// record after all the per-write regenerates have been
    /// suppressed during the per-record processing block.
    static func forceWrite(_ db: Database, recordID: String) {
        do {
            try writeIfPresent(db, recordID: recordID)
        } catch {
            sidecarLog.error("sidecar force-write failed for \(recordID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func writeIfPresent(_ db: Database, recordID: String) throws {
        // Privacy check — when a record is currently encrypted (the
        // user toggled it protected and the encryption pass ran), the
        // sidecar would publish plaintext property values + body to a
        // Finder-visible markdown file, defeating the at-rest
        // encryption. Delete any existing sidecar and bail. The
        // user's choice to protect implicitly accepts losing the
        // sidecar's role as a portable copy; a regenerate on
        // un-protect rebuilds it.
        if (try? DBWrites.recordIsEncrypted(db, recordID: recordID)) == true {
            try removeExistingSidecarFile(db, recordID: recordID)
            return
        }
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT r.id, r.database_id, r.title, r.sidecar_path,
                       d.name AS db_name
                FROM records r
                LEFT JOIN databases d ON d.id = r.database_id
                WHERE r.id = ? AND r.deleted_at IS NULL
            """,
            arguments: [recordID]
        ) else { return }

        guard let relativePath = row["sidecar_path"] as String?, !relativePath.isEmpty else {
            return
        }

        let absoluteURL = AppDatabase.workspaceFolder.appendingPathComponent(relativePath)
        let dbName: String = row["db_name"] ?? "records"
        let title: String = row["title"]
        let databaseID: String = row["database_id"]

        // Build frontmatter from properties + relations.
        // `id` is the first field by convention — the importer reads
        // it as the stable rendezvous between file and DB row, so a
        // user can rename or move the sidecar's folder in Finder
        // without orphaning the record.
        var fields: [SidecarDocument.Field] = []
        fields.append(.init(key: "id", value: .string(recordID)))
        fields.append(.init(key: "type", value: .string(databaseID)))
        fields.append(.init(key: "title", value: .string(title)))

        // Property values, in property sort order.
        let propertyRows = try Row.fetchAll(
            db,
            sql: """
                SELECT p.key, p.type, p.config_json, p.sort_index,
                       pv.text_value, pv.number_value, pv.date_value
                FROM properties p
                LEFT JOIN property_values pv
                  ON pv.property_id = p.id AND pv.record_id = ?
                WHERE p.database_id = ?
                  AND p.is_archived = 0
                  AND p.type != 'title'
                ORDER BY p.sort_index
            """,
            arguments: [recordID, databaseID]
        )

        for propRow in propertyRows {
            let key: String = propRow["key"]
            let propType: String = propRow["type"]
            let configJSON: String = propRow["config_json"] ?? "{}"

            // Relation properties: fetch from `relations` table, not
            // property_values. Output single-relation as a string,
            // multi-relation as a flow list.
            if propType == "relation" {
                let relations = try String.fetchAll(
                    db,
                    sql: """
                        SELECT t.id FROM relations rel
                        JOIN records t ON t.id = rel.target_record_id
                        WHERE rel.source_record_id = ? AND rel.property_id = ?
                        ORDER BY t.title COLLATE NOCASE
                    """,
                    arguments: [recordID, "\(databaseID).\(key)"]
                )
                if relations.isEmpty { continue }

                let isMulti: Bool = {
                    guard let data = configJSON.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                    return (obj["multi"] as? Bool) ?? false
                }()

                if isMulti {
                    // For multi-relation, we want the SOURCE-of-truth
                    // identifier in the YAML — stable IDs (svc-honda-…)
                    // when the target uses them, titles otherwise.
                    let identifiers = try relations.map { targetID -> String in
                        // Stable IDs for the seeded service catalog
                        // are short and obviously not titles. Use the
                        // ID directly if it's not a UUID.
                        if !targetID.contains("-") || targetID.hasPrefix("svc-") {
                            return targetID
                        }
                        // For UUID-keyed targets, fall back to the
                        // title (resolves on re-import).
                        let title = (try String.fetchOne(
                            db,
                            sql: "SELECT title FROM records WHERE id = ?",
                            arguments: [targetID]
                        )) ?? targetID
                        return title
                    }
                    fields.append(.init(key: key, value: .stringList(identifiers)))
                } else {
                    // Single-relation: emit the target's title (the
                    // import path resolves by title via auto-create).
                    let firstID = relations[0]
                    let title = (try String.fetchOne(
                        db,
                        sql: "SELECT title FROM records WHERE id = ?",
                        arguments: [firstID]
                    )) ?? firstID
                    fields.append(.init(key: key, value: .string(title)))
                }
                continue
            }

            // Non-relation properties read from property_values.
            switch propType {
            case "number", "currency":
                if let n = propRow["number_value"] as Double? {
                    // Whole-number mileage stays an integer; cost
                    // emits as a 2-decimal string for currency. The
                    // YAML parser accepts both forms.
                    if propType == "currency" || n != n.rounded() {
                        fields.append(.init(key: key, value: .string(String(format: "%.2f", n))))
                    } else {
                        fields.append(.init(key: key, value: .integer(Int(n))))
                    }
                }
            case "date", "date_tz":
                if let d = propRow["date_value"] as String?, !d.isEmpty {
                    fields.append(.init(key: key, value: .string(d)))
                } else if let t = propRow["text_value"] as String?, !t.isEmpty {
                    fields.append(.init(key: key, value: .string(t)))
                }
            default:
                if let t = propRow["text_value"] as String?, !t.isEmpty {
                    // Try integer round-trip for fields that came in
                    // as a stringified int (mileage on legacy records).
                    if propType == "number", let n = Int(t) {
                        fields.append(.init(key: key, value: .integer(n)))
                    } else {
                        fields.append(.init(key: key, value: .string(t)))
                    }
                }
            }
        }

        // Build body: leading `[scan](file)` link if there's an
        // attached PDF/PNG/JPG, then the serialized blocks.
        var body = ""
        let scanFilename = try String.fetchOne(
            db,
            sql: """
                SELECT a.original_filename FROM assets a
                WHERE a.record_id = ?
                  AND (a.original_filename LIKE '%.pdf'
                    OR a.original_filename LIKE '%.png'
                    OR a.original_filename LIKE '%.jpg'
                    OR a.original_filename LIKE '%.jpeg')
                ORDER BY a.created_at
                LIMIT 1
            """,
            arguments: [recordID]
        )
        if let scanFilename {
            body += "[scan](\(scanFilename))\n"
        }

        let blocks = try BlockReads.blocks(db, recordID: recordID)
        if !blocks.isEmpty {
            if !body.isEmpty { body += "\n" }
            body += BlockMarkdownSerializer.serialize(blocks)
        } else if !body.isEmpty {
            // PDF link only — leave a trailing newline.
            if !body.hasSuffix("\n") { body += "\n" }
        }

        // Render and write atomically.
        let doc = SidecarDocument(fields: fields, body: body)
        let rendered = SidecarFrontmatter.write(doc)

        let fm = FileManager.default
        let parent = absoluteURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        let tmp = absoluteURL.appendingPathExtension("ks-tmp-\(UUID().uuidString)")
        guard let bytes = rendered.data(using: .utf8) else { return }
        try bytes.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: absoluteURL.path) {
            _ = try fm.replaceItemAt(absoluteURL, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: absoluteURL)
        }

        // Record the hash so the Cars/ file watcher can recognize
        // this write as our own and not loop-import it back. Without
        // this, every DB → file write triggers a file → DB import
        // that triggers another DB → file write…
        SidecarHashCache.shared.recordWrite(absolutePath: absoluteURL.path, data: bytes)

        sidecarLog.info("wrote sidecar \(relativePath, privacy: .public) for record \(recordID, privacy: .public) (\(dbName, privacy: .public)/\(title, privacy: .public))")
    }
}
