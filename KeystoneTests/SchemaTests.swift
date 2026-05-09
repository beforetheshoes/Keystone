import XCTest
import Dependencies
import CryptoKit
@testable import Keystone

final class SchemaTests: XCTestCase {
    /// Run a test body with the live Keystone database set up against
    /// a per-test temp workspace folder. See `withHermeticDB` for the
    /// rationale — without the workspace override, tests would write
    /// to the user's real `~/Library/Application Support/Keystone/`.
    func withDB<T>(_ body: () throws -> T) rethrows -> T {
        try withHermeticDB(body)
    }


    func testSeedLoadsExpectedDatabases() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue

            let dbs = try dbClient.databases()
            XCTAssertGreaterThanOrEqual(dbs.count, 7, "Expected at least 7 seeded databases")
            XCTAssertTrue(dbs.contains { $0.id == "people" })
            XCTAssertTrue(dbs.contains { $0.id == "pets" })
            XCTAssertTrue(dbs.contains { $0.id == "documents" })

            let peopleProps = try dbClient.properties("people")
            XCTAssertTrue(peopleProps.contains { $0.key == "name" && $0.type == .title })
            XCTAssertTrue(peopleProps.contains { $0.key == "phone" && $0.type == .phone })
        }
    }

    func testCreateUpdateDeleteRecord() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue

            let before = try dbClient.records("pets").count

            // Create
            let created = try dbClient.createRecord("pets", "Goose")
            XCTAssertEqual(created.title, "Goose")
            XCTAssertEqual(created.glyph, "G")
            XCTAssertEqual(created.databaseID, "pets")

            let afterCreate = try dbClient.records("pets")
            XCTAssertEqual(afterCreate.count, before + 1)
            XCTAssertTrue(afterCreate.contains { $0.id == created.id && $0.title == "Goose" })

            // Update title
            try dbClient.updateRecordTitle(created.id, "Goose Marsh")
            let afterRename = try dbClient.record(created.id)
            XCTAssertEqual(afterRename?.title, "Goose Marsh")
            XCTAssertEqual(afterRename?.glyph, "GM")

            // Update property
            try dbClient.updatePropertyValue(created.id, "species", "Bird")
            try dbClient.updatePropertyValue(created.id, "breed", "Canada goose")
            let withValues = try dbClient.record(created.id)
            XCTAssertEqual(withValues?.values["species"], "Bird")
            XCTAssertEqual(withValues?.values["breed"], "Canada goose")

            // Overwrite
            try dbClient.updatePropertyValue(created.id, "species", "Snow goose")
            XCTAssertEqual(try dbClient.record(created.id)?.values["species"], "Snow goose")

            // Clear (empty string deletes the value)
            try dbClient.updatePropertyValue(created.id, "breed", "")
            XCTAssertNil(try dbClient.record(created.id)?.values["breed"])

            // Delete
            try dbClient.deleteRecord(created.id)
            let afterDelete = try dbClient.records("pets")
            XCTAssertEqual(afterDelete.count, before)
            XCTAssertFalse(afterDelete.contains { $0.id == created.id })
        }
    }

    func testBlockCRUDAndAttributedRoundTrip() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue

            // Create a host record (in pets — temporary)
            let host = try dbClient.createRecord("pets", "BlockTestPet")
            defer { try? dbClient.deleteRecord(host.id) }

            // Create with bold text
            var bold = AttributedString("Hello world")
            if let range = bold.range(of: "world") {
                bold[range].inlinePresentationIntent = .stronglyEmphasized
            }
            let b1 = try dbClient.createBlock(host.id, nil, .paragraph, bold, nil)

            // Round-trip: read back, confirm bold preserved
            let blocks = try dbClient.blocks(host.id)
            XCTAssertEqual(blocks.count, 1)
            let read = blocks[0].text
            XCTAssertEqual(String(read.characters), "Hello world")
            // Find the run with stronglyEmphasized intent
            let hasBoldRun = read.runs.contains { run in
                run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            }
            XCTAssertTrue(hasBoldRun, "Bold attribute should survive round-trip")

            // Insert another block after b1, confirm sort_index between b1 and (none) → b1 + 1
            let b2 = try dbClient.createBlock(host.id, b1.id, .heading2, AttributedString("Heading"), nil)
            XCTAssertEqual(b2.sortIndex, b1.sortIndex + 1)

            // Insert between b1 and b2
            let between = try dbClient.createBlock(host.id, b1.id, .paragraph, AttributedString("Between"), nil)
            XCTAssertGreaterThan(between.sortIndex, b1.sortIndex)
            XCTAssertLessThan(between.sortIndex, b2.sortIndex)

            // Update kind
            try dbClient.updateBlockKind(b2.id, .heading3, nil)
            let afterKind = try dbClient.blocks(host.id).first { $0.id == b2.id }
            XCTAssertEqual(afterKind?.kind, .heading3)

            // Update checked on a checklist block
            let cl = try dbClient.createBlock(host.id, b2.id, .checklist, AttributedString("Buy milk"), false)
            try dbClient.updateBlockChecked(cl.id, true)
            let afterChk = try dbClient.blocks(host.id).first { $0.id == cl.id }
            XCTAssertEqual(afterChk?.checked, true)

            // Delete b1
            try dbClient.deleteBlock(b1.id)
            let after = try dbClient.blocks(host.id)
            XCTAssertFalse(after.contains { $0.id == b1.id })
            XCTAssertEqual(after.map(\.id).sorted(), [between.id, b2.id, cl.id].sorted())
        }
    }

    func testSplitTextPreservesAttributesMidRun() throws {
        // Cursor in the middle of a bold run splits both text and attributes.
        var text = AttributedString("Hello brave world")
        if let range = text.range(of: "brave") {
            text[range].inlinePresentationIntent = .stronglyEmphasized
        }

        // Position cursor after "Hello bra"
        let cursorIdx = text.characters.index(text.characters.startIndex, offsetBy: 9)
        let (before, after) = splitText(text, at: cursorIdx)

        XCTAssertEqual(String(before.characters), "Hello bra")
        XCTAssertEqual(String(after.characters), "ve world")

        let beforeHasBold = before.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        let afterHasBold  = after.runs.contains  { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        XCTAssertTrue(beforeHasBold, "Bold should survive into the before-block")
        XCTAssertTrue(afterHasBold,  "Bold should survive into the after-block")
    }

    func testSplitTextAtEndProducesEmptyAfter() throws {
        let text = AttributedString("hello")
        let (before, after) = splitText(text, at: text.endIndex)
        XCTAssertEqual(String(before.characters), "hello")
        XCTAssertTrue(after.characters.isEmpty)
    }

    func testSplitTextAtStartProducesEmptyBefore() throws {
        let text = AttributedString("hello")
        let (before, after) = splitText(text, at: text.startIndex)
        XCTAssertTrue(before.characters.isEmpty)
        XCTAssertEqual(String(after.characters), "hello")
    }

    func testTagCreateApplyDetachDelete() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue

            let tag = try dbClient.createTag(Seed.workspaceID, "shipping", .global, nil, .iris)
            let host = try dbClient.createRecord("documents", "Box of stuff")
            defer { try? dbClient.deleteRecord(host.id) }

            try dbClient.attachTag(host.id, tag.id)
            XCTAssertTrue(try dbClient.tagsForRecord(host.id).contains { $0.id == tag.id })

            try dbClient.detachTag(host.id, tag.id)
            XCTAssertFalse(try dbClient.tagsForRecord(host.id).contains { $0.id == tag.id })

            try dbClient.deleteTag(tag.id)
            XCTAssertFalse(try dbClient.allTags(Seed.workspaceID).contains { $0.id == tag.id })
        }
    }

    func testTagScopePerDatabase() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue
            let petsTag = try dbClient.createTag(Seed.workspaceID, "vaccinated", .database, "pets", .sage)
            defer { try? dbClient.deleteTag(petsTag.id) }

            let petsAvail = try dbClient.tagsAvailable(Seed.workspaceID, "pets")
            XCTAssertTrue(petsAvail.contains { $0.id == petsTag.id })

            let docsAvail = try dbClient.tagsAvailable(Seed.workspaceID, "documents")
            XCTAssertFalse(docsAvail.contains { $0.id == petsTag.id })
        }
    }

    func testRelationCreateAndReverse() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue
            let a = try dbClient.createRecord("people", "Alice")
            let b = try dbClient.createRecord("people", "Bob")
            defer {
                try? dbClient.deleteRecord(a.id)
                try? dbClient.deleteRecord(b.id)
            }

            _ = try dbClient.addRelation(a.id, b.id, nil)

            let outgoingFromA = try dbClient.outgoingRelations(a.id)
            XCTAssertTrue(outgoingFromA.contains { $0.targetRecordID == b.id })

            let incomingToB = try dbClient.incomingRelations(b.id)
            XCTAssertTrue(incomingToB.contains { $0.sourceRecordID == a.id })
        }
    }

    func testRelationPropertyTargetDatabase() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue
            let target = try dbClient.relationTargetDatabaseID("pets.vet")
            XCTAssertEqual(target, "people")
        }
    }

    func testDemoDataRemoved() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue
            // The v7 cleanup migration must have wiped the legacy demo records,
            // tags, and relations from any pre-existing install.
            for legacyID in ["p1", "pet1", "v1", "h1", "d1", "e1", "m1"] {
                XCTAssertNil(try dbClient.record(legacyID), "Demo record \(legacyID) should be gone")
            }
            for tagID in ["tag-family", "tag-medical", "tag-urgent", "tag-property"] {
                XCTAssertFalse(
                    try dbClient.allTags(Seed.workspaceID).contains { $0.id == tagID },
                    "Demo tag \(tagID) should be gone"
                )
            }
        }
    }

    func testAssetImportRoundTrip() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue
            let host = try dbClient.createRecord("documents", "AssetTest")
            defer { try? dbClient.deleteRecord(host.id) }

            // Write a temp file
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("keystone-test-\(UUID().uuidString).txt")
            let payload = "hello, keystone".data(using: .utf8)!
            try payload.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }

            let asset = try dbClient.importAsset(tmp, host.id, Seed.workspaceID)
            XCTAssertEqual(asset.recordID, host.id)
            XCTAssertEqual(asset.byteSize, Int64(payload.count))
            XCTAssertEqual(asset.fileExtension, "txt")
            XCTAssertEqual(asset.mimeType, "text/plain")
            XCTAssertNotNil(asset.contentHash)

            let stored = asset.absoluteURL
            XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))

            let storedData = try Data(contentsOf: stored)
            XCTAssertEqual(storedData, payload)

            // Hash matches the SHA-256 of the bytes
            let expected = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(asset.contentHash, expected)

            // Cleanup
            try dbClient.deleteAsset(asset.id)
        }
    }

    func testAssetMultipleAttachments() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue
            let host = try dbClient.createRecord("documents", "MultiAttach")
            defer { try? dbClient.deleteRecord(host.id) }

            var ids: [String] = []
            for i in 0..<3 {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("keystone-multi-\(i)-\(UUID().uuidString).txt")
                try "file-\(i)".data(using: .utf8)!.write(to: url)
                let a = try dbClient.importAsset(url, host.id, Seed.workspaceID)
                ids.append(a.id)
                try? FileManager.default.removeItem(at: url)
            }

            let assets = try dbClient.assetsForRecord(host.id)
            XCTAssertEqual(assets.count, 3)
            XCTAssertEqual(Set(assets.map(\.id)), Set(ids))

            for id in ids { try dbClient.deleteAsset(id) }
        }
    }

    func testAssetDeleteRemovesFile() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue
            let host = try dbClient.createRecord("documents", "DelTest")
            defer { try? dbClient.deleteRecord(host.id) }

            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("keystone-del-\(UUID().uuidString).txt")
            try "content".data(using: .utf8)!.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }

            let asset = try dbClient.importAsset(tmp, host.id, Seed.workspaceID)
            let stored = asset.absoluteURL
            XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))

            try dbClient.deleteAsset(asset.id)

            XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
            XCTAssertTrue(try dbClient.assetsForRecord(host.id).isEmpty)
        }
    }

    func testRecordCoverImageRoundTrip() throws {
        try withDB {
            let dbClient = DatabaseClient.liveValue
            let host = try dbClient.createRecord("people", "CoverTest")
            defer { try? dbClient.deleteRecord(host.id) }

            // Source image (a tiny PNG-ish blob is fine for the importer's
            // hash/size pipeline — it's never decoded).
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("cover-\(UUID().uuidString).png")
            let payload = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            try payload.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }

            let asset = try dbClient.importCoverImage(tmp, host.id, Seed.workspaceID)
            XCTAssertEqual(asset.recordID, host.id)

            let withCover = try dbClient.record(host.id)
            XCTAssertEqual(withCover?.coverAssetID, asset.id)
            XCTAssertEqual(withCover?.coverRelativePath, asset.relativePath)
            XCTAssertNotNil(withCover?.coverImageURL)

            // Same record shows up in records(databaseID:) with the cover info hydrated.
            let inList = try dbClient.records("people").first { $0.id == host.id }
            XCTAssertEqual(inList?.coverAssetID, asset.id)

            // Clear: cover ID goes to nil but the asset itself stays attached.
            try dbClient.setRecordCover(host.id, nil)
            let cleared = try dbClient.record(host.id)
            XCTAssertNil(cleared?.coverAssetID)
            XCTAssertNil(cleared?.coverImageURL)
            XCTAssertTrue(try dbClient.assetsForRecord(host.id).contains { $0.id == asset.id })

            try dbClient.deleteAsset(asset.id)
        }
    }

    func testHelpTopicsResolve() throws {
        let appBundle = Bundle.allBundles.first { $0.bundleIdentifier == "com.ryanleewilliams.keystone" }
        HelpTopics.bundle = appBundle ?? Bundle(for: type(of: self))

        for topic in HelpTopics.all {
            let url = HelpTopics.resourceURL(for: topic.id)
            XCTAssertNotNil(url, "Help topic missing: \(topic.id).md (title: \(topic.title))")
            if let url {
                let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                XCTAssertFalse(body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "Help topic empty: \(topic.id).md")
            }
        }
    }

    func testNewRecordPropertyEditsPersist() throws {
        try withDB {
            // Regression: create a record, write several property values, navigate
            // away (simulated by re-fetching), confirm values are present.
            let dbClient = DatabaseClient.liveValue

            let created = try dbClient.createRecord("people", "Alex Doe")
            defer { try? dbClient.deleteRecord(created.id) }

            // Simulate the user typing into multiple property fields. These calls
            // are exactly what the detail view's per-keystroke binding fires.
            try dbClient.updatePropertyValue(created.id, "phone", "(415) 555-1234")
            try dbClient.updatePropertyValue(created.id, "email", "alex@example.com")
            try dbClient.updatePropertyValue(created.id, "relationship", "Friend")

            // Simulate navigating back to the table view: re-fetch the record list.
            let people = try dbClient.records("people")
            guard let fetched = people.first(where: { $0.id == created.id }) else {
                XCTFail("Created record missing from refreshed list"); return
            }

            XCTAssertEqual(fetched.title, "Alex Doe")
            XCTAssertEqual(fetched.values["phone"], "(415) 555-1234")
            XCTAssertEqual(fetched.values["email"], "alex@example.com")
            XCTAssertEqual(fetched.values["relationship"], "Friend")
        }
    }
}
