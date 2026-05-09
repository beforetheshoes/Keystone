import XCTest
import Dependencies
import GRDB
@preconcurrency import SQLiteData
@testable import Keystone

final class ProtectedReadsTests: XCTestCase {
    private func withDB<T>(_ body: () throws -> T) rethrows -> T {
        try withHermeticDB(body)
    }

    // MARK: - Helpers

    /// Create a Trip and return its id.
    private func makeTrip(_ db: Database, name: String) throws -> String {
        let row = try DBWrites.createRecord(db, databaseID: "trips", title: name)
        return row.id
    }

    /// Create an Activity linked to `tripID` (via the activities.trip
    /// relation) and return its id.
    private func makeActivity(_ db: Database, name: String, tripID: String) throws -> String {
        let row = try DBWrites.createRecord(db, databaseID: "activities", title: name)
        // The relation property's value goes through updatePropertyValue
        // which auto-creates the relations row when the target id matches.
        try DBWrites.updatePropertyValue(db, recordID: row.id, propertyKey: "trip", value: tripID)
        return row.id
    }

    /// Mark a record's `is_protected` truthy or clear.
    private func setProtected(_ db: Database, recordID: String, _ value: Bool) throws {
        try DBWrites.updatePropertyValue(
            db,
            recordID: recordID,
            propertyKey: "is_protected",
            value: value ? "true" : ""
        )
    }

    // MARK: - Direct seed

    func testNoProtectedRecordsReturnsEmpty() throws {
        try withDB {
            try withDependency { db in
                _ = try makeTrip(db, name: "Paris")
                let hidden = try ProtectedReads.hiddenRecordIDs(db, unlocked: [], filteringActive: true)
                XCTAssertEqual(hidden, [])
            }
        }
    }

    func testFilteringDisabledReturnsEmptyEvenWithProtected() throws {
        try withDB {
            try withDependency { db in
                let trip = try makeTrip(db, name: "Tokyo")
                try setProtected(db, recordID: trip, true)
                let hidden = try ProtectedReads.hiddenRecordIDs(db, unlocked: [], filteringActive: false)
                XCTAssertEqual(hidden, [])
            }
        }
    }

    func testProtectedTripAppearsInHiddenSet() throws {
        try withDB {
            try withDependency { db in
                let trip = try makeTrip(db, name: "Berlin")
                try setProtected(db, recordID: trip, true)
                let hidden = try ProtectedReads.hiddenRecordIDs(db, unlocked: [], filteringActive: true)
                XCTAssertEqual(hidden, [trip])
            }
        }
    }

    func testUnlockedTripDropsOutOfHiddenSet() throws {
        try withDB {
            try withDependency { db in
                let trip = try makeTrip(db, name: "Madrid")
                try setProtected(db, recordID: trip, true)
                let hidden = try ProtectedReads.hiddenRecordIDs(db, unlocked: [trip], filteringActive: true)
                XCTAssertEqual(hidden, [])
            }
        }
    }

    // MARK: - Cascade

    func testProtectedTripHidesLinkedActivity() throws {
        try withDB {
            try withDependency { db in
                let trip = try makeTrip(db, name: "Lisbon")
                let activity = try makeActivity(db, name: "Tram tour", tripID: trip)
                try setProtected(db, recordID: trip, true)
                let hidden = try ProtectedReads.hiddenRecordIDs(db, unlocked: [], filteringActive: true)
                XCTAssertEqual(hidden, [trip, activity])
            }
        }
    }

    func testUnlockingParentReleasesCascadedChildren() throws {
        try withDB {
            try withDependency { db in
                let trip = try makeTrip(db, name: "Rome")
                let a1 = try makeActivity(db, name: "Forum walk", tripID: trip)
                let a2 = try makeActivity(db, name: "Pasta dinner", tripID: trip)
                try setProtected(db, recordID: trip, true)

                let locked = try ProtectedReads.hiddenRecordIDs(db, unlocked: [], filteringActive: true)
                XCTAssertEqual(locked, [trip, a1, a2])

                let unlocked = try ProtectedReads.hiddenRecordIDs(db, unlocked: [trip], filteringActive: true)
                XCTAssertEqual(unlocked, [])
            }
        }
    }

    func testUnrelatedTripStaysVisibleWhenAnotherIsProtected() throws {
        try withDB {
            try withDependency { db in
                let secret = try makeTrip(db, name: "Surprise")
                let public_ = try makeTrip(db, name: "Public")
                try setProtected(db, recordID: secret, true)

                let hidden = try ProtectedReads.hiddenRecordIDs(db, unlocked: [], filteringActive: true)
                XCTAssertEqual(hidden, [secret])
                XCTAssertFalse(hidden.contains(public_))
            }
        }
    }

    func testTogglingProtectionOffRemovesFromHiddenSet() throws {
        try withDB {
            try withDependency { db in
                let trip = try makeTrip(db, name: "Amsterdam")
                try setProtected(db, recordID: trip, true)
                XCTAssertTrue(try ProtectedReads.hiddenRecordIDs(db, unlocked: [], filteringActive: true).contains(trip))

                try setProtected(db, recordID: trip, false)
                XCTAssertEqual(try ProtectedReads.hiddenRecordIDs(db, unlocked: [], filteringActive: true), [])
            }
        }
    }

    // MARK: - Idempotent / consistency

    func testRunningTwiceReturnsSameSet() throws {
        try withDB {
            try withDependency { db in
                let trip = try makeTrip(db, name: "Vienna")
                let act = try makeActivity(db, name: "Opera", tripID: trip)
                try setProtected(db, recordID: trip, true)
                let first = try ProtectedReads.hiddenRecordIDs(db, unlocked: [], filteringActive: true)
                let second = try ProtectedReads.hiddenRecordIDs(db, unlocked: [], filteringActive: true)
                XCTAssertEqual(first, second)
                XCTAssertEqual(first, [trip, act])
            }
        }
    }

    // MARK: - allProtectedSeedIDs / isProtected

    func testAllProtectedSeedIDsReturnsLiteralFlaggedSet() throws {
        try withDB {
            try withDependency { db in
                let t1 = try makeTrip(db, name: "Cairo")
                let t2 = try makeTrip(db, name: "Athens")
                let _ = try makeActivity(db, name: "Pyramids", tripID: t1)
                try setProtected(db, recordID: t1, true)
                try setProtected(db, recordID: t2, true)
                // Cascaded children are NOT in seed-set — only directly flagged records.
                let seeds = try ProtectedReads.allProtectedSeedIDs(db)
                XCTAssertEqual(seeds, [t1, t2])
            }
        }
    }

    func testIsProtectedReflectsFlag() throws {
        try withDB {
            try withDependency { db in
                let trip = try makeTrip(db, name: "Oslo")
                XCTAssertFalse(try ProtectedReads.isProtected(db, recordID: trip))
                try setProtected(db, recordID: trip, true)
                XCTAssertTrue(try ProtectedReads.isProtected(db, recordID: trip))
                try setProtected(db, recordID: trip, false)
                XCTAssertFalse(try ProtectedReads.isProtected(db, recordID: trip))
            }
        }
    }

    // MARK: - Plumbing

    /// Run `body` with a sync read on the default database — same shape
    /// as the live read path so DBWrites used inside test setup get the
    /// same connection as the assertions.
    private func withDependency(_ body: (Database) throws -> Void) throws {
        @Dependency(\.defaultDatabase) var database
        try database.write { db in
            try body(db)
        }
    }
}
