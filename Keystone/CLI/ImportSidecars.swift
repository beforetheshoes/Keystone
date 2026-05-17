import Foundation
import GRDB
import Dependencies
@preconcurrency import SQLiteData
import CryptoKit

/// CLI command implementation for `--cli import-sidecars`. Walks the
/// Cars folder, reads each sidecar's (already-augmented) YAML
/// frontmatter, and upserts a `vehicle_maintenance` record per file.
/// Service catalog links flow from the `services:` list. After all
/// records are upserted, recomputes each vehicle's `current_mileage`
/// and `current_mileage_as_of` snapshots.
///
/// Sidecars are the canonical source of truth (per the user); the DB
/// is treated as derived. Re-running the importer must produce the
/// same DB state — keys are deterministic SHA-1 digests of the source
/// path, so updates land on the same rows.
enum ImportSidecarsCLI {
    struct ImportResult {
        var imported: Int = 0
        var updated: Int = 0
        var skipped: Int = 0
        var failed: Int = 0
        var perVehicle: [String: Int] = [:]
        var notes: [String] = []
    }

    static func run(rootURL: URL) throws -> [String: Any] {
        @Dependency(\.defaultDatabase) var database
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

        var result = ImportResult()

        try database.write { db in
            // Confirm the schema is in place.
            let svcExists = (try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM databases WHERE id = 'service_catalog'"
            ) ?? 0) > 0
            guard svcExists else {
                throw NSError(
                    domain: "Keystone", code: 28,
                    userInfo: [NSLocalizedDescriptionKey: "service_catalog database missing — run migrations first"]
                )
            }

            while let item = enumerator?.nextObject() as? URL {
                guard item.lastPathComponent.hasSuffix(".pdf-processed-markdown.md") else { continue }
                do {
                    // Suppress per-mutation sidecar regenerates for the
                    // duration of one record's processing; we issue a
                    // single explicit `forceWrite` at the end instead.
                    // Without this, ~6 disk writes fire per record
                    // (date, kind, vendor, mileage, cost, blocks…).
                    try SidecarWriter.suppress {
                    let source = try String(contentsOf: item, encoding: .utf8)
                    let doc = SidecarFrontmatter.parse(source)

                    guard let vehicleTitle = stringField(doc, "vehicle"),
                          !vehicleTitle.isEmpty else {
                        result.skipped += 1
                        result.notes.append("\(item.lastPathComponent): no vehicle frontmatter")
                        return
                    }
                    guard let title = stringField(doc, "title") ?? deriveTitle(from: item),
                          !title.isEmpty else {
                        result.skipped += 1
                        return
                    }
                    let date = stringField(doc, "date")
                    let kind = stringField(doc, "kind")
                    let vendor = stringField(doc, "vendor")
                    let mileage = intField(doc, "mileage")
                    let cost = numberField(doc, "cost")
                    let services = stringListField(doc, "services")

                    // Resolve / auto-create the vehicle record.
                    // Side-effect-only: ensures a `vehicles` row exists
                    // for `vehicleTitle`. The maintenance record below
                    // links by title via the relations promoter, so we
                    // don't need the returned ID locally.
                    _ = try resolveOrCreateVehicle(db, title: vehicleTitle)

                    // Stable record id: prefer the `id:` field
                    // written into the frontmatter by `SidecarWriter`.
                    // That binds the row to the file regardless of
                    // where on disk the file lives — folder rename or
                    // move in Finder is safe. Fall back to a sha1 of
                    // `<vehicle>/<folder>` for legacy files that
                    // haven't been regenerated yet; on this import
                    // they pick up an `id:` and self-heal.
                    let folder = item.deletingLastPathComponent().lastPathComponent
                    let recordID = resolveRecordID(doc: doc, vehicleTitle: vehicleTitle, folder: folder)

                    let existed = (try Int.fetchOne(
                        db, sql: "SELECT COUNT(*) FROM records WHERE id = ?",
                        arguments: [recordID]
                    ) ?? 0) > 0

                    // Compute sidecar_path relative to the workspace
                    // folder so the value survives workspace
                    // relocation. The sandboxed app can only write
                    // inside the workspace, so a path outside it gets
                    // stored as nil — write-back will then be a
                    // no-op for that record, and the user can
                    // relocate the source files into
                    // `<workspace>/Cars/` to enable bidirectional
                    // sync.
                    let workspaceRoot = AppDatabase.workspaceFolder.path
                    let absolutePath = item.path
                    let relativePath: String? = {
                        guard absolutePath.hasPrefix(workspaceRoot + "/") else { return nil }
                        return String(absolutePath.dropFirst(workspaceRoot.count + 1))
                    }()

                    if !existed {
                        let nextSort = (try Double.fetchOne(
                            db, sql: "SELECT MAX(sort_index) FROM records WHERE database_id = 'vehicle_maintenance'"
                        ) ?? -1) + 1
                        let now = AppDatabase.isoFormatter.string(from: Date())
                        try db.execute(
                            sql: """
                                INSERT INTO records
                                    (id, database_id, title, glyph, tone, created_at, updated_at, sort_index, sidecar_path)
                                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                            arguments: [recordID, "vehicle_maintenance", title, glyph(from: title), "iris", now, now, nextSort, relativePath]
                        )
                        result.imported += 1
                    } else {
                        try DBWrites.updateRecordTitle(db, recordID: recordID, title: title)
                        // Re-imports may have a moved file; refresh
                        // the path so future write-backs target the
                        // current location.
                        try db.execute(
                            sql: "UPDATE records SET sidecar_path = ? WHERE id = ?",
                            arguments: [relativePath, recordID]
                        )
                        result.updated += 1
                    }

                    // Property values. Use updatePropertyValue for
                    // non-multi-relation fields; it handles auto-create
                    // for `vendor` and `vehicle` relation targets.
                    if let date { try DBWrites.updatePropertyValue(db, recordID: recordID, propertyKey: "date", value: date) }
                    if let kind { try DBWrites.updatePropertyValue(db, recordID: recordID, propertyKey: "kind", value: kind) }
                    if let vendor { try DBWrites.updatePropertyValue(db, recordID: recordID, propertyKey: "vendor", value: vendor) }
                    if let mileage { try DBWrites.updatePropertyValue(db, recordID: recordID, propertyKey: "mileage", value: String(mileage)) }
                    if let cost { try DBWrites.updatePropertyValue(db, recordID: recordID, propertyKey: "cost", value: String(cost)) }
                    // Vehicle relation — single, by title.
                    try DBWrites.updatePropertyValue(db, recordID: recordID, propertyKey: "vehicle", value: vehicleTitle)

                    // services — multi-relation. Bypass
                    // updatePropertyValue (which clears prior links by
                    // design) and call addRelation directly so existing
                    // user-curated links survive across imports. Only
                    // catalog IDs that actually exist are linked; the
                    // rest are recorded as notes.
                    for catalogID in services {
                        let catalogExists = (try Int.fetchOne(
                            db, sql: "SELECT COUNT(*) FROM records WHERE id = ? AND database_id = 'service_catalog'",
                            arguments: [catalogID]
                        ) ?? 0) > 0
                        guard catalogExists else {
                            result.notes.append("\(item.lastPathComponent): unknown service id \(catalogID)")
                            continue
                        }
                        _ = try DBWrites.addRelation(
                            db,
                            sourceRecordID: recordID,
                            targetRecordID: catalogID,
                            propertyID: "vehicle_maintenance.services"
                        )
                    }

                    // Convert the markdown body into editor blocks so the
                    // record's NOTES section shows the transcribed
                    // content in-app. Mirrors what InboxImporter does
                    // — without this the record looks empty in the UI.
                    // On a re-import (record already had blocks), wipe
                    // and re-create from the canonical sidecar so any
                    // curated changes in the markdown propagate.
                    try db.execute(
                        sql: "DELETE FROM blocks WHERE record_id = ?",
                        arguments: [recordID]
                    )
                    let parsedBlocks = MarkdownBlockConverter.parse(doc.body)
                    var lastBlockID: String? = nil
                    for parsed in parsedBlocks {
                        let inserted: BlockRow
                        if parsed.kind == .table, let table = parsed.tableData {
                            inserted = try DBWrites.createTableBlock(
                                db, recordID: recordID, after: lastBlockID, table: table
                            )
                        } else {
                            inserted = try DBWrites.createBlock(
                                db, recordID: recordID, after: lastBlockID,
                                kind: parsed.kind, text: parsed.text, checked: parsed.checked
                            )
                        }
                        lastBlockID = inserted.id
                    }

                    // Attach the sidecar's PDF/PNG/JPG companion (if
                    // present in the same folder) so the user can
                    // open the original scan from the record. Use
                    // `registerInPlace` rather than `importFile` —
                    // the file already lives canonically inside the
                    // sidecar bundle, so duplicating it into
                    // `Assets/` would just double our disk + iCloud
                    // footprint without adding any value. The asset
                    // row points at the bundle file directly.
                    let bundleFolder = item.deletingLastPathComponent()
                    let baseName = item.lastPathComponent
                        .replacingOccurrences(of: ".pdf-processed-markdown.md", with: "")
                    let candidates = ["\(baseName).pdf", "\(baseName).png", "\(baseName).jpg"]
                    for candidate in candidates {
                        let candidateURL = bundleFolder.appendingPathComponent(candidate)
                        guard FileManager.default.fileExists(atPath: candidateURL.path) else { continue }
                        let alreadyAttached = (try? Int.fetchOne(
                            db,
                            sql: """
                                SELECT COUNT(*) FROM assets
                                WHERE record_id = ? AND original_filename = ?
                            """,
                            arguments: [recordID, candidate]
                        ) ?? 0) ?? 0
                        if alreadyAttached == 0 {
                            _ = try? AssetImporter.registerInPlace(
                                db, fileURL: candidateURL,
                                recordID: recordID, workspaceID: Seed.workspaceID
                            )
                        }
                    }

                    // Final, definitive sidecar write for this record.
                    // `forceWrite` bypasses the surrounding `suppress`
                    // so this single call replaces the dozens of
                    // per-mutation writes that would otherwise fire.
                    SidecarWriter.forceWrite(db, recordID: recordID)

                    // Per-vehicle current_mileage is now derived on
                    // read from MAX(event mileage) — see
                    // `MaintenanceReads.vehicleSnapshots`. No
                    // per-import snapshot pass needed; freshness is
                    // automatic.

                    result.perVehicle[vehicleTitle, default: 0] += 1
                    } // end SidecarWriter.suppress
                } catch {
                    result.failed += 1
                    result.notes.append("\(item.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        return [
            "imported": result.imported,
            "updated": result.updated,
            "skipped": result.skipped,
            "failed": result.failed,
            "per_vehicle": result.perVehicle,
            "notes": result.notes,
        ]
    }

    // MARK: - Helpers

    private static func stringField(_ doc: SidecarDocument, _ key: String) -> String? {
        switch doc.value(for: key) {
        case .string(let s): return s.isEmpty ? nil : s
        case .integer(let n): return String(n)
        default: return nil
        }
    }

    private static func intField(_ doc: SidecarDocument, _ key: String) -> Int? {
        switch doc.value(for: key) {
        case .integer(let n): return n
        case .string(let s): return Int(s.replacingOccurrences(of: ",", with: ""))
        default: return nil
        }
    }

    private static func numberField(_ doc: SidecarDocument, _ key: String) -> Double? {
        switch doc.value(for: key) {
        case .integer(let n): return Double(n)
        case .string(let s): return Double(s.replacingOccurrences(of: ",", with: ""))
        default: return nil
        }
    }

    private static func stringListField(_ doc: SidecarDocument, _ key: String) -> [String] {
        if case .stringList(let xs) = doc.value(for: key) { return xs }
        return []
    }

    private static func deriveTitle(from url: URL) -> String? {
        url.deletingPathExtension().deletingPathExtension().lastPathComponent
    }

    /// Look up a vehicle by title. Auto-create a stub record if
    /// missing — the canonical Cars folder names already match how the
    /// user has the vehicles named (e.g. "2018 Honda CR-V"), so this
    /// only fires when the workspace is brand new.
    private static func resolveOrCreateVehicle(_ db: Database, title: String) throws -> String {
        if let existing = try String.fetchOne(
            db,
            sql: "SELECT id FROM records WHERE database_id = 'vehicles' AND LOWER(title) = LOWER(?) LIMIT 1",
            arguments: [title]
        ) {
            return existing
        }
        return try DBWrites.createRecord(db, databaseID: "vehicles", title: title).id
    }

    private static func glyph(from title: String) -> String {
        let words = title.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).prefix(2)
        let chars = words.compactMap { $0.first.map(String.init) }.joined().uppercased()
        return chars.isEmpty ? String(title.prefix(2)).uppercased() : String(chars.prefix(2))
    }

    /// Stable rendezvous between sidecar file and DB row. The `id:`
    /// frontmatter field is authoritative when present — that's what
    /// makes folder rename and external file moves safe. The
    /// folder-hash fallback exists only for sidecars that predate the
    /// `id:` convention; once they're rewritten by `SidecarWriter`
    /// they get an explicit `id:` and never hit the fallback again.
    private static func resolveRecordID(doc: SidecarDocument, vehicleTitle: String, folder: String) -> String {
        if case .string(let id) = doc.value(for: "id"), !id.isEmpty {
            return id
        }
        return "vm-" + sha1("\(vehicleTitle)/\(folder)")
    }

    private static func sha1(_ s: String) -> String {
        Insecure.SHA1.hash(data: Data(s.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
