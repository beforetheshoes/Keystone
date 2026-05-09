import Foundation

/// CLI command implementation for `--cli backfill-sidecar-frontmatter`.
/// Walks `<root>/<vehicle>/<date>/*.pdf-processed-markdown.md`, parses
/// each file's frontmatter + body, and writes back any of vendor /
/// mileage / cost / services that the body reveals but the frontmatter
/// is missing. Existing frontmatter values are never overwritten — the
/// user is the authority on what's correct.
///
/// Output is a per-file summary plus a JSON summary at the end. The
/// command is idempotent: running it twice produces no further diff.
enum BackfillSidecarFrontmatterCLI {
    struct FileResult {
        let path: String
        let added: [String]    // keys we added (e.g. ["vendor", "cost"])
        let alreadyHad: [String]
        let stillMissing: [String]
    }

    /// Returns the per-file results plus an aggregate summary.
    static func run(rootURL: URL, dryRun: Bool) -> [String: Any] {
        let fm = FileManager.default
        let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var results: [FileResult] = []
        var totalScanned = 0
        var totalChanged = 0
        var perVendorTotals: [String: Int] = [:]

        while let item = enumerator?.nextObject() as? URL {
            guard item.lastPathComponent.hasSuffix(".pdf-processed-markdown.md") else { continue }
            totalScanned += 1
            do {
                let result = try processFile(at: item, dryRun: dryRun)
                results.append(result)
                if !result.added.isEmpty { totalChanged += 1 }
                for key in result.added {
                    perVendorTotals[key, default: 0] += 1
                }
            } catch {
                results.append(FileResult(
                    path: item.path,
                    added: [],
                    alreadyHad: [],
                    stillMissing: ["error: \(error.localizedDescription)"]
                ))
            }
        }

        return [
            "scanned": totalScanned,
            "changed": totalChanged,
            "dry_run": dryRun,
            "fields_added": perVendorTotals,
            "files": results.map { r -> [String: Any] in
                [
                    "path": r.path,
                    "added": r.added,
                    "already_had": r.alreadyHad,
                    "still_missing": r.stillMissing,
                ]
            },
        ]
    }

    /// Process a single sidecar markdown file. Reads, parses, attempts
    /// extraction, writes back when changed (unless `dryRun` is true).
    /// Returns a structured per-file result.
    static func processFile(at url: URL, dryRun: Bool) throws -> FileResult {
        let source = try String(contentsOf: url, encoding: .utf8)
        var doc = SidecarFrontmatter.parse(source)
        let extracted = InvoiceExtraction.extract(from: doc.body)
        let services = MaintenanceVocab.match(in: doc.body)

        var added: [String] = []
        var alreadyHad: [String] = []
        var stillMissing: [String] = []

        // Vendor — string. Skip if user already set a non-empty value.
        if let v = extracted.vendor, !v.isEmpty {
            if let existing = doc.value(for: "vendor"), !existing.isEmpty {
                alreadyHad.append("vendor")
            } else {
                doc.set("vendor", to: .string(v))
                added.append("vendor")
            }
        } else if doc.value(for: "vendor") == nil || doc.value(for: "vendor")?.isEmpty == true {
            stillMissing.append("vendor")
        } else {
            alreadyHad.append("vendor")
        }

        // Mileage — integer.
        if let m = extracted.mileage {
            if let existing = doc.value(for: "mileage"), !existing.isEmpty {
                alreadyHad.append("mileage")
            } else {
                doc.set("mileage", to: .integer(m))
                added.append("mileage")
            }
        } else if doc.value(for: "mileage") == nil || doc.value(for: "mileage")?.isEmpty == true {
            stillMissing.append("mileage")
        } else {
            alreadyHad.append("mileage")
        }

        // Cost — string with two-decimal dollar formatting. Stored as
        // a string (rather than a YAML float) so existing manually-
        // entered values like "72.81" don't change shape on round-trip.
        if let c = extracted.cost {
            if let existing = doc.value(for: "cost"), !existing.isEmpty {
                alreadyHad.append("cost")
            } else {
                let formatted = String(format: "%.2f", c)
                doc.set("cost", to: .string(formatted))
                added.append("cost")
            }
        } else if doc.value(for: "cost") == nil || doc.value(for: "cost")?.isEmpty == true {
            stillMissing.append("cost")
        } else {
            alreadyHad.append("cost")
        }

        // Services — string list. The frontmatter is the user's
        // source of truth. If they've ever set this field (even to an
        // empty list), don't touch it. Only auto-populate when the
        // field is absent entirely.
        if doc.value(for: "services") != nil {
            alreadyHad.append("services")
        } else if !services.isEmpty {
            doc.set("services", to: .stringList(services))
            added.append("services")
        } else {
            stillMissing.append("services")
        }

        if !added.isEmpty, !dryRun {
            let rendered = SidecarFrontmatter.write(doc)
            try rendered.write(to: url, atomically: true, encoding: .utf8)
        }

        return FileResult(
            path: url.path,
            added: added,
            alreadyHad: alreadyHad,
            stillMissing: stillMissing
        )
    }
}
