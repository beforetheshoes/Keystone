import XCTest
import Dependencies
import GRDB
@testable import Keystone

/// Round-trip tests for the local-first sync invariants:
///
///   1. **Block round-trip**: parse(serialize(blocks)) == blocks.
///      The DB → file write produces markdown that the file → DB
///      reader interprets back to the same block list. Without this,
///      every external read after an in-app edit would re-import as
///      a "change" — drift, not sync.
///
///   2. **Frontmatter round-trip**: parse(write(doc)) == doc, modulo
///      key ordering. Frontmatter survives serialization without
///      losing fields or coercing types.
final class SidecarRoundTripTests: XCTestCase {

    // MARK: - Block round-trip

    /// Construct blocks the way `MarkdownBlockConverter` would (for
    /// fixture clarity). Sort indices are arbitrary positive numbers
    /// in increasing order — only the relative order matters for the
    /// serializer.
    private func block(_ kind: BlockKind, _ text: String, sortIndex: Double, checked: Bool? = nil) -> BlockRow {
        BlockRow(
            id: UUID().uuidString,
            recordID: "rec-test",
            kind: kind,
            text: AttributedString(text),
            checked: checked,
            tableData: nil,
            sortIndex: sortIndex
        )
    }

    func testHeadingsRoundTrip() {
        let blocks = [
            block(.heading1, "Top",      sortIndex: 1),
            block(.heading2, "Section",  sortIndex: 2),
            block(.heading3, "Subsection", sortIndex: 3),
            block(.paragraph, "Body text", sortIndex: 4),
        ]
        let md = BlockMarkdownSerializer.serialize(blocks)
        let parsed = MarkdownBlockConverter.parse(md)
        XCTAssertEqual(parsed.map(\.kind), [.heading1, .heading2, .heading3, .paragraph])
        XCTAssertEqual(parsed.map { String($0.text.characters) }, ["Top", "Section", "Subsection", "Body text"])
    }

    func testListsCoalesce() {
        // Multiple consecutive bulleted blocks should serialize WITHOUT
        // blank lines between them, and re-parse back as the same
        // list of bulleted blocks (markdown convention).
        let blocks = [
            block(.bulleted, "alpha", sortIndex: 1),
            block(.bulleted, "beta",  sortIndex: 2),
            block(.bulleted, "gamma", sortIndex: 3),
        ]
        let md = BlockMarkdownSerializer.serialize(blocks)
        XCTAssertFalse(md.contains("\n\n"), "Bullets shouldn't have blank lines between them — got:\n\(md)")
        let parsed = MarkdownBlockConverter.parse(md)
        XCTAssertEqual(parsed.map(\.kind), [.bulleted, .bulleted, .bulleted])
        XCTAssertEqual(parsed.map { String($0.text.characters) }, ["alpha", "beta", "gamma"])
    }

    func testNumberedListRenumbers() {
        let blocks = [
            block(.numbered, "first",  sortIndex: 1),
            block(.numbered, "second", sortIndex: 2),
            block(.numbered, "third",  sortIndex: 3),
        ]
        let md = BlockMarkdownSerializer.serialize(blocks)
        XCTAssertTrue(md.contains("1. first"))
        XCTAssertTrue(md.contains("2. second"))
        XCTAssertTrue(md.contains("3. third"))
        let parsed = MarkdownBlockConverter.parse(md)
        XCTAssertEqual(parsed.map(\.kind), [.numbered, .numbered, .numbered])
    }

    func testChecklistPreservesChecked() {
        let blocks = [
            block(.checklist, "todo one", sortIndex: 1, checked: false),
            block(.checklist, "done one", sortIndex: 2, checked: true),
        ]
        let md = BlockMarkdownSerializer.serialize(blocks)
        XCTAssertTrue(md.contains("- [ ] todo one"))
        XCTAssertTrue(md.contains("- [x] done one"))
        let parsed = MarkdownBlockConverter.parse(md)
        XCTAssertEqual(parsed.map(\.kind), [.checklist, .checklist])
        XCTAssertEqual(parsed.map(\.checked), [false, true])
    }

    func testQuoteAndDivider() {
        let blocks = [
            block(.paragraph, "Above",   sortIndex: 1),
            block(.divider,   "",        sortIndex: 2),
            block(.quote,     "Wisdom",  sortIndex: 3),
            block(.paragraph, "Below",   sortIndex: 4),
        ]
        let md = BlockMarkdownSerializer.serialize(blocks)
        let parsed = MarkdownBlockConverter.parse(md)
        XCTAssertEqual(parsed.map(\.kind), [.paragraph, .divider, .quote, .paragraph])
    }

    func testTableRoundTrip() {
        let table = BlockTableData(
            headers: ["Job #", "Description", "Cost"],
            rows: [
                ["1", "Oil change", "$45.00"],
                ["2", "Tire rotation", "$0.00"],
            ]
        )
        let blocks = [
            BlockRow(
                id: UUID().uuidString, recordID: "rec",
                kind: .table, text: AttributedString(),
                checked: nil, tableData: table, sortIndex: 1
            ),
        ]
        let md = BlockMarkdownSerializer.serialize(blocks)
        let parsed = MarkdownBlockConverter.parse(md)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.kind, .table)
        XCTAssertEqual(parsed.first?.tableData?.headers, ["Job #", "Description", "Cost"])
        XCTAssertEqual(parsed.first?.tableData?.rows.first, ["1", "Oil change", "$45.00"])
    }

    func testTableEscapesPipeInCell() {
        let table = BlockTableData(
            headers: ["A", "B"],
            rows: [["pipe | inside", "ok"]]
        )
        let blocks = [
            BlockRow(
                id: UUID().uuidString, recordID: "rec",
                kind: .table, text: AttributedString(),
                checked: nil, tableData: table, sortIndex: 1
            ),
        ]
        let md = BlockMarkdownSerializer.serialize(blocks)
        XCTAssertTrue(md.contains("pipe \\| inside"), "pipes inside cells need to be escaped — got:\n\(md)")
    }

    func testInlineMarkdownRoundTrip() throws {
        // Build an AttributedString with bold + a link, the way the
        // SwiftUI markdown parser produces it.
        let attr = try AttributedString(
            markdown: "Replaced **front pads** at [East Coast Honda](https://example.com).",
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        let block = BlockRow(
            id: "b", recordID: "r",
            kind: .paragraph, text: attr, checked: nil, tableData: nil, sortIndex: 1
        )
        let md = BlockMarkdownSerializer.serialize([block])
        XCTAssertTrue(md.contains("**front pads**"), "bold should re-emit; got:\n\(md)")
        XCTAssertTrue(md.contains("[East Coast Honda](https://example.com)"), "link should re-emit; got:\n\(md)")
    }

    // MARK: - Frontmatter round-trip

    func testFrontmatterPreservesAllScalars() {
        let doc = SidecarDocument(
            fields: [
                .init(key: "type",    value: .string("vehicle_maintenance")),
                .init(key: "title",   value: .string("2021-06-12 - Oil change")),
                .init(key: "vehicle", value: .string("2018 Honda CR-V")),
                .init(key: "date",    value: .string("2021-06-12")),
                .init(key: "kind",    value: .string("service")),
                .init(key: "vendor",  value: .string("Take 5 Oil Change")),
                .init(key: "mileage", value: .integer(36696)),
                .init(key: "cost",    value: .string("72.81")),
                .init(key: "services", value: .stringList(["svc-honda-engine-oil-normal", "svc-honda-oil-filter-normal"])),
            ],
            body: "[scan](2021-06-12 - Oil change.pdf)\n\nBody content here.\n"
        )
        let written = SidecarFrontmatter.write(doc)
        let reparsed = SidecarFrontmatter.parse(written)

        XCTAssertEqual(reparsed.fields.count, doc.fields.count)
        for (orig, parsed) in zip(doc.fields, reparsed.fields) {
            XCTAssertEqual(orig.key, parsed.key)
            XCTAssertEqual(orig.value, parsed.value, "field \(orig.key) drifted")
        }
        XCTAssertEqual(reparsed.body.trimmingCharacters(in: .whitespacesAndNewlines),
                       doc.body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testFrontmatterIntegerMileagePreservedAsInt() {
        let doc = SidecarDocument(
            fields: [.init(key: "mileage", value: .integer(82111))],
            body: ""
        )
        let written = SidecarFrontmatter.write(doc)
        XCTAssertTrue(written.contains("mileage: 82111"), "mileage should round-trip as bare integer; got:\n\(written)")
        let reparsed = SidecarFrontmatter.parse(written)
        XCTAssertEqual(reparsed.value(for: "mileage"), .integer(82111))
    }

    func testFrontmatterListWithStableIDsNotQuoted() {
        let doc = SidecarDocument(
            fields: [.init(key: "services", value: .stringList(["svc-honda-engine-oil-normal", "svc-gmc-oil-filter"]))],
            body: ""
        )
        let written = SidecarFrontmatter.write(doc)
        XCTAssertTrue(written.contains("[svc-honda-engine-oil-normal, svc-gmc-oil-filter]"),
                      "stable IDs shouldn't need quoting in flow lists; got:\n\(written)")
    }

    // MARK: - id rendezvous

    /// `id:` is the stable rendezvous between sidecar file and DB row.
    /// It MUST be the first frontmatter field — folder rename in
    /// Finder is only safe because the importer can find this value
    /// before doing anything else with the file.
    func testSidecarWriterEmitsIdAsFirstField() throws {
        try withHermeticDB {
            @Dependency(\.defaultDatabase) var database

            // Create a vehicle_maintenance record, give it a sidecar
            // path, regenerate, and read the file off disk.
            let recordID = "vm-roundtrip-test-\(UUID().uuidString)"
            let relativePath = "Cars/_test/\(recordID)/\(recordID).pdf-processed-markdown.md"

            try database.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO records
                            (id, database_id, title, glyph, tone, created_at, updated_at, sort_index, sidecar_path)
                        VALUES (?, 'vehicle_maintenance', 'Round-trip test', 'RT', 'iris', ?, ?, 0, ?)
                    """,
                    arguments: [recordID, AppDatabase.isoFormatter.string(from: Date()), AppDatabase.isoFormatter.string(from: Date()), relativePath]
                )
                SidecarWriter.forceWrite(db, recordID: recordID)
            }

            let absolute = AppDatabase.workspaceFolder.appendingPathComponent(relativePath)
            defer {
                try? FileManager.default.removeItem(at: absolute.deletingLastPathComponent())
            }

            let written = try String(contentsOf: absolute, encoding: .utf8)
            let doc = SidecarFrontmatter.parse(written)

            XCTAssertEqual(doc.fields.first?.key, "id",
                           "id must be the first frontmatter field; got order: \(doc.fields.map(\.key))")
            XCTAssertEqual(doc.value(for: "id"), .string(recordID),
                           "id field must equal the record's id")

            // Cleanup
            try database.write { db in
                try db.execute(sql: "DELETE FROM records WHERE id = ?", arguments: [recordID])
            }
        }
    }

    /// `AssetImporter.registerInPlace` records an asset row that
    /// points directly at an existing in-workspace file — no copy is
    /// made under `Assets/`. This is what spares us a duplicate copy
    /// of every PDF in `Cars/` when sidecars are imported. Verifies
    /// that the asset row stores a workspace-relative path matching
    /// the source file and that no file lands in the Assets/ tree.
    func testRegisterInPlaceUsesSourcePathAndDoesNotCopy() throws {
        try withHermeticDB {
            @Dependency(\.defaultDatabase) var database
            @Dependency(\.workspaceFolder) var workspace

            // Drop a synthetic PDF inside the workspace at a sidecar-bundle-shaped
            // path. The exact subtree doesn't matter to registerInPlace; it
            // accepts any path inside the workspace.
            let bundle = workspace.appendingPathComponent("Cars/Test/2024-01-01 Synthetic", isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let pdf = bundle.appendingPathComponent("synthetic.pdf")
            try Data("PDF".utf8).write(to: pdf)

            // Create a vehicle_maintenance record so registerInPlace
            // has somewhere to attach.
            let recordID = "vm-registerinplace-\(UUID().uuidString)"
            try database.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO records
                            (id, database_id, title, glyph, tone, created_at, updated_at, sort_index)
                        VALUES (?, 'vehicle_maintenance', 'In-place test', 'IP', 'iris', ?, ?, 0)
                    """,
                    arguments: [recordID, AppDatabase.isoFormatter.string(from: Date()), AppDatabase.isoFormatter.string(from: Date())]
                )
                _ = try AssetImporter.registerInPlace(
                    db, fileURL: pdf, recordID: recordID, workspaceID: Seed.workspaceID
                )
            }

            let storedRelative = try database.read { db in
                try String.fetchOne(
                    db, sql: "SELECT relative_path FROM assets WHERE record_id = ?",
                    arguments: [recordID]
                )
            }
            XCTAssertEqual(storedRelative, "Cars/Test/2024-01-01 Synthetic/synthetic.pdf",
                           "asset row must store the workspace-relative source path, not an Assets/ copy")

            // No copy should appear anywhere under Assets/.
            let assetsTree = workspace.appendingPathComponent("Assets")
            let nothingCopied = !FileManager.default.fileExists(atPath: assetsTree.path)
                || ((try? FileManager.default.contentsOfDirectory(atPath: assetsTree.path))?.isEmpty ?? true)
            XCTAssertTrue(nothingCopied, "registerInPlace must NOT create files under Assets/")

            // The original file must still be where we put it.
            XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.path),
                          "registerInPlace must not move or modify the source file")

            // Cleanup
            try database.write { db in
                try db.execute(sql: "DELETE FROM assets WHERE record_id = ?", arguments: [recordID])
                try db.execute(sql: "DELETE FROM records WHERE id = ?", arguments: [recordID])
            }
        }
    }

    /// `attachFile` is the canonical "user attached a file" entry
    /// point. For sidecar-backed records (those with `sidecar_path`),
    /// the file MUST land in the bundle folder, not under `Assets/`.
    /// Otherwise the user ends up with one record's files split
    /// across two locations — exactly the asymmetry that makes
    /// "files are canonical" untrustworthy.
    func testAttachFileSidecarBackedLandsInBundleFolder() throws {
        try withHermeticDB {
            @Dependency(\.defaultDatabase) var database
            @Dependency(\.workspaceFolder) var workspace

            // Sidecar-backed record. The bundle folder is the parent
            // of the sidecar's relative path.
            let recordID = "vm-attach-bundle-\(UUID().uuidString)"
            let bundleRelative = "Cars/Test/\(recordID)"
            let sidecarRelative = "\(bundleRelative)/\(recordID).pdf-processed-markdown.md"
            try FileManager.default.createDirectory(
                at: workspace.appendingPathComponent(bundleRelative),
                withIntermediateDirectories: true
            )

            // Synthetic source file outside the workspace simulating
            // a file the user dragged in from elsewhere.
            let source = FileManager.default.temporaryDirectory
                .appendingPathComponent("source-\(UUID().uuidString).pdf")
            try Data("PDF".utf8).write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }

            try database.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO records
                            (id, database_id, title, glyph, tone, created_at, updated_at, sort_index, sidecar_path)
                        VALUES (?, 'vehicle_maintenance', 'Bundle attach test', 'BA', 'iris', ?, ?, 0, ?)
                    """,
                    arguments: [recordID, AppDatabase.isoFormatter.string(from: Date()), AppDatabase.isoFormatter.string(from: Date()), sidecarRelative]
                )
                _ = try AssetImporter.attachFile(
                    db, fileURL: source, recordID: recordID, workspaceID: Seed.workspaceID
                )
            }

            let stored = try database.read { db in
                try String.fetchOne(
                    db, sql: "SELECT relative_path FROM assets WHERE record_id = ?",
                    arguments: [recordID]
                )
            }
            XCTAssertEqual(stored, "\(bundleRelative)/\(source.lastPathComponent)",
                           "sidecar-backed attachment must land in the bundle folder")

            // Nothing should appear under Assets/.
            let assetsTree = workspace.appendingPathComponent("Assets/Vehicle Maintenance")
            XCTAssertFalse(FileManager.default.fileExists(atPath: assetsTree.path),
                           "Assets/Vehicle Maintenance/ must not be created for sidecar-backed attachments")
        }
    }

    /// For non-sidecar databases (cover images, books, etc.) the
    /// existing `Assets/<Database>/<Title>-<id>/…` path is preserved.
    /// Routing is on a record-by-record basis: presence of
    /// `sidecar_path` is the sole switch.
    func testAttachFileNonSidecarFallsThroughToAssets() throws {
        try withHermeticDB {
            @Dependency(\.defaultDatabase) var database
            @Dependency(\.workspaceFolder) var workspace

            let recordID = "doc-attach-fallthrough-\(UUID().uuidString)"
            let source = FileManager.default.temporaryDirectory
                .appendingPathComponent("source-\(UUID().uuidString).pdf")
            try Data("PDF".utf8).write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }

            try database.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO records
                            (id, database_id, title, glyph, tone, created_at, updated_at, sort_index)
                        VALUES (?, 'documents', 'Plain doc', 'PD', 'iris', ?, ?, 0)
                    """,
                    arguments: [recordID, AppDatabase.isoFormatter.string(from: Date()), AppDatabase.isoFormatter.string(from: Date())]
                )
                _ = try AssetImporter.attachFile(
                    db, fileURL: source, recordID: recordID, workspaceID: Seed.workspaceID
                )
            }

            let stored = try database.read { db in
                try String.fetchOne(
                    db, sql: "SELECT relative_path FROM assets WHERE record_id = ?",
                    arguments: [recordID]
                )
            }
            XCTAssertNotNil(stored)
            XCTAssertTrue(stored?.hasPrefix("Assets/") ?? false,
                          "non-sidecar records keep using the Assets/ tree; got \(stored ?? "nil")")
        }
    }

    /// Verifies the importer's id-vs-folder-hash precedence at the
    /// frontmatter level (no DB needed). The presence of an `id:`
    /// field is what makes folder rename safe — without this guarantee
    /// the rendezvous falls back to a path-derived hash and a Finder
    /// rename produces a duplicate row.
    func testFrontmatterParsesExplicitIdField() {
        let source = """
        ---
        id: vm-explicit-12345
        type: vehicle_maintenance
        title: Test
        ---
        Body
        """
        let doc = SidecarFrontmatter.parse(source)
        XCTAssertEqual(doc.value(for: "id"), .string("vm-explicit-12345"))
        XCTAssertEqual(doc.fields.first?.key, "id")
    }
}
