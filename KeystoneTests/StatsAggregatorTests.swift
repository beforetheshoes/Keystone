import XCTest
@testable import Keystone

final class StatsAggregatorTests: XCTestCase {

    // MARK: - Helpers

    private func record(
        id: String = UUID().uuidString,
        values: [String: String] = [:]
    ) -> RecordRow {
        RecordRow(
            id: id,
            databaseID: "books",
            title: id,
            glyph: "X",
            tone: .graphite,
            sortIndex: 0,
            values: values
        )
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // MARK: - paceByMonth

    func testPaceByMonthBucketsRecordsAndZeroFillsMissingMonths() {
        let records = [
            record(values: ["status": "read", "finished_date": "2026-01-15"]),
            record(values: ["status": "read", "finished_date": "2026-01-22"]),
            record(values: ["status": "read", "finished_date": "2026-03-04"]),
        ]
        let buckets = StatsAggregator.paceByMonth(
            records: records,
            dateKey: "finished_date",
            statusKey: "status",
            validStatuses: ["read"],
            in: date(2026, 1, 1)...date(2026, 3, 31)
        )
        // Three months: Jan, Feb, Mar — Feb should be present with count 0.
        XCTAssertEqual(buckets.count, 3)
        XCTAssertEqual(buckets[0].count, 2)
        XCTAssertEqual(buckets[1].count, 0)
        XCTAssertEqual(buckets[2].count, 1)
    }

    func testPaceByMonthSkipsUnparseableDates() {
        let records = [
            record(values: ["status": "read", "finished_date": "2026-04-10"]),
            record(values: ["status": "read", "finished_date": "garbage"]),
            record(values: ["status": "read"]),
        ]
        let buckets = StatsAggregator.paceByMonth(
            records: records,
            dateKey: "finished_date",
            statusKey: "status",
            validStatuses: ["read"],
            in: date(2026, 4, 1)...date(2026, 4, 30)
        )
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].count, 1)
    }

    func testPaceByMonthFiltersByStatus() {
        let records = [
            record(values: ["status": "read",      "finished_date": "2026-02-01"]),
            record(values: ["status": "abandoned", "finished_date": "2026-02-15"]),
            record(values: ["status": "reading",   "finished_date": "2026-02-20"]),
        ]
        let buckets = StatsAggregator.paceByMonth(
            records: records,
            dateKey: "finished_date",
            statusKey: "status",
            validStatuses: ["read"],
            in: date(2026, 2, 1)...date(2026, 2, 28)
        )
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].count, 1)
    }

    func testPaceByMonthSumsVolume() {
        let records = [
            record(values: ["status": "read", "finished_date": "2026-05-10", "page_count": "300"]),
            record(values: ["status": "read", "finished_date": "2026-05-20", "page_count": "150"]),
        ]
        let buckets = StatsAggregator.paceByMonth(
            records: records,
            dateKey: "finished_date",
            statusKey: "status",
            validStatuses: ["read"],
            volumeKey: "page_count",
            in: date(2026, 5, 1)...date(2026, 5, 31)
        )
        XCTAssertEqual(buckets[0].volume, 450)
    }

    // MARK: - statusMix

    func testStatusMixFollowsOptionOrder() {
        let records = [
            record(values: ["status": "read"]),
            record(values: ["status": "read"]),
            record(values: ["status": "to_read"]),
            record(values: ["status": "reading"]),
        ]
        let slices = StatsAggregator.statusMix(
            records: records,
            statusKey: "status",
            options: ["to_read", "reading", "read", "abandoned"]
        )
        XCTAssertEqual(slices.map(\.value), ["to_read", "reading", "read"])
        XCTAssertEqual(slices.map(\.count), [1, 1, 2])
    }

    func testStatusMixPutsEmptyBucketLast() {
        let records = [
            record(values: ["status": "read"]),
            record(values: ["status": ""]),
            record(values: [:]),
        ]
        let slices = StatsAggregator.statusMix(
            records: records,
            statusKey: "status",
            options: ["to_read", "reading", "read"]
        )
        XCTAssertEqual(slices.last?.value, StatsAggregator.emptyLabel)
        XCTAssertEqual(slices.last?.count, 2)
    }

    // MARK: - topValues

    func testTopValuesMultiSelectSplitsAndCounts() {
        let records = [
            record(values: ["tags": "fiction|mystery"]),
            record(values: ["tags": "mystery"]),
            record(values: ["tags": "fiction|thriller"]),
        ]
        let rows = StatsAggregator.topValues(
            records: records,
            key: "tags",
            multiSelect: true,
            limit: 10
        )
        let dict = Dictionary(uniqueKeysWithValues: rows.map { ($0.value, $0.count) })
        XCTAssertEqual(dict["fiction"], 2)
        XCTAssertEqual(dict["mystery"], 2)
        XCTAssertEqual(dict["thriller"], 1)
    }

    func testTopValuesSingleSelectCountsRawString() {
        let records = [
            record(values: ["author": "Ursula K. Le Guin"]),
            record(values: ["author": "Ursula K. Le Guin"]),
            record(values: ["author": "N.K. Jemisin"]),
        ]
        let rows = StatsAggregator.topValues(
            records: records,
            key: "author",
            multiSelect: false,
            limit: 10
        )
        XCTAssertEqual(rows.first?.value, "Ursula K. Le Guin")
        XCTAssertEqual(rows.first?.count, 2)
    }

    func testTopValuesRespectsLimit() {
        let records = (0..<25).map { idx in
            record(values: ["tags": "tag\(idx)"])
        }
        let rows = StatsAggregator.topValues(
            records: records,
            key: "tags",
            multiSelect: true,
            limit: 5
        )
        XCTAssertEqual(rows.count, 5)
    }

    // MARK: - decadeDistribution

    func testDecadeDistributionBuckets() {
        let records = [
            record(values: ["published_date": "1989-03-14"]),
            record(values: ["published_date": "1995-06-01"]),
            record(values: ["published_date": "2020-01-01"]),
            record(values: ["published_date": "2024-11-30"]),
        ]
        let buckets = StatsAggregator.decadeDistribution(
            records: records,
            dateKey: "published_date"
        )
        let dict = Dictionary(uniqueKeysWithValues: buckets.map { ($0.decadeStart, $0.count) })
        XCTAssertEqual(dict[1980], 1)
        XCTAssertEqual(dict[1990], 1)
        XCTAssertEqual(dict[2020], 2)
    }

    // MARK: - runtimeBuckets

    func testRuntimeBucketsClassifyMovies() {
        let records = [
            record(values: ["runtime_minutes": "85"]),
            record(values: ["runtime_minutes": "100"]),
            record(values: ["runtime_minutes": "120"]),
            record(values: ["runtime_minutes": "180"]),
        ]
        let buckets = StatsAggregator.runtimeBuckets(records: records, runtimeKey: "runtime_minutes")
        let dict = Dictionary(uniqueKeysWithValues: buckets.map { ($0.label, $0.count) })
        XCTAssertEqual(dict["< 90 min"], 1)
        XCTAssertEqual(dict["90–120 min"], 1)
        XCTAssertEqual(dict["120–150 min"], 1)
        XCTAssertEqual(dict["150+ min"], 1)
    }

    // MARK: - sumNumeric

    func testSumNumericWithPredicate() {
        let records = [
            record(values: ["status": "read", "page_count": "300"]),
            record(values: ["status": "read", "page_count": "200"]),
            record(values: ["status": "reading", "page_count": "999"]),  // excluded
        ]
        let total = StatsAggregator.sumNumeric(
            records: records,
            key: "page_count",
            where: { ($0.values["status"] ?? "") == "read" }
        )
        XCTAssertEqual(total, 500)
    }

    // MARK: - inProgress

    func testInProgressBooksFiltersByReadingStatus() {
        let records = [
            record(values: [
                "status": "reading",
                "current_page": "120",
                "page_count": "300",
                "started_date": "2026-04-01",
            ]),
            record(values: ["status": "read"]),
        ]
        let inProgress = StatsAggregator.inProgressBooks(records: records)
        XCTAssertEqual(inProgress.count, 1)
        XCTAssertEqual(inProgress[0].currentPage, 120)
        XCTAssertEqual(inProgress[0].totalPages, 300)
    }

    // MARK: - yearMonthGrid (Chart3D heatmap data)

    func testYearMonthGridZeroFillsAcrossSpannedYears() {
        let records = [
            record(values: ["status": "read", "finished_date": "2023-03-04"]),
            record(values: ["status": "read", "finished_date": "2023-03-12"]),
            record(values: ["status": "read", "finished_date": "2024-08-15"]),
            record(values: ["status": "read", "finished_date": "2025-01-20"]),
        ]
        let cells = StatsAggregator.yearMonthGrid(
            records: records,
            dateKey: "finished_date",
            statusKey: "status",
            validStatuses: ["read"]
        )
        // Grid spans from the earliest year with data to today's
        // year inclusive — so the front edge of the 3D chart always
        // shows "this year so far" even when the user hasn't yet
        // logged activity in it. Count is `(today - earliest + 1) ×
        // 12`. Test asserts that boundary behavior holds without
        // hard-coding today's year.
        let calendar = Calendar(identifier: .gregorian)
        let currentYear = calendar.component(.year, from: Date())
        let expectedYears = max(1, currentYear - 2023 + 1)
        XCTAssertEqual(cells.count, expectedYears * 12)
        // March 2023 should carry both records.
        let mar2023 = cells.first { $0.year == 2023 && $0.month == 3 }
        XCTAssertEqual(mar2023?.count, 2)
        // A month with no records returns a zero cell, not nil.
        let apr2024 = cells.first { $0.year == 2024 && $0.month == 4 }
        XCTAssertEqual(apr2024?.count, 0)
        // First year is the earliest with data — even though the
        // year extends to today, the chart shouldn't pad backwards.
        XCTAssertEqual(cells.first?.year, 2023)
    }

    func testYearMonthGridFiltersByStatus() {
        let records = [
            record(values: ["status": "read",      "finished_date": "2024-05-01"]),
            record(values: ["status": "abandoned", "finished_date": "2024-05-15"]),
        ]
        let cells = StatsAggregator.yearMonthGrid(
            records: records,
            dateKey: "finished_date",
            statusKey: "status",
            validStatuses: ["read"]
        )
        let may2024 = cells.first { $0.year == 2024 && $0.month == 5 }
        XCTAssertEqual(may2024?.count, 1)
    }

    func testYearMonthGridEmptyWhenNoDates() {
        let records = [
            record(values: ["status": "read", "finished_date": ""]),
            record(values: ["status": "read"]),
        ]
        let cells = StatsAggregator.yearMonthGrid(
            records: records,
            dateKey: "finished_date",
            statusKey: "status",
            validStatuses: ["read"]
        )
        XCTAssertTrue(cells.isEmpty)
    }

    func testInProgressBooksPrefersReadablePagesWhenSet() {
        let records = [
            record(values: [
                "status": "reading",
                "current_page": "100",
                "page_count": "400",
                "readable_pages": "350",
            ]),
        ]
        let inProgress = StatsAggregator.inProgressBooks(records: records)
        XCTAssertEqual(inProgress[0].totalPages, 350)
    }
}
