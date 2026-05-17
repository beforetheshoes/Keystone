import Foundation

/// One month-anchored bucket in a pace timeline (books finished, movies
/// watched, …). The `monthStart` is the first day of the bucket's
/// month at local midnight — Swift Charts plots it directly as the X
/// axis value, with a `.month` granularity unit.
struct PaceBucket: Equatable, Sendable, Identifiable {
    let monthStart: Date
    let count: Int
    /// Numeric volume on the same time axis (pages read this month,
    /// hours watched, episodes seen). Always summed across the records
    /// that landed in this bucket; zero when the source records have no
    /// numeric volume property.
    let volume: Int

    var id: Date { monthStart }
}

/// One slice in a status mix donut chart. `displayValue` is the option
/// label (already humanized by the caller when relevant); `count` is
/// the number of records.
struct StatusSlice: Equatable, Sendable, Identifiable {
    let value: String
    let count: Int
    var id: String { value }
}

/// One row in a top-values horizontal bar chart (top tags, top
/// authors).
struct TopValueRow: Equatable, Sendable, Identifiable {
    let value: String
    let count: Int
    var id: String { value }
}

/// One bar in a decade-distribution chart. `decadeStart` is the year
/// the decade starts (e.g. `2010` for the 2010s).
struct DecadeBucket: Equatable, Sendable, Identifiable {
    let decadeStart: Int
    let count: Int
    var id: Int { decadeStart }
}

/// One bar in a runtime-bucket chart. `label` is what the axis shows
/// ("< 90 min"); `count` is how many records landed there.
struct RuntimeBucket: Equatable, Sendable, Identifiable {
    let label: String
    /// Sort key — `Int.max` for the "150+" tail bucket.
    let upperBoundMinutes: Int
    let count: Int
    var id: String { label }
}

/// One cell in a year × month activity grid. The `Chart3D` reading
/// heatmap uses these as `RectangleMark` positions: `month` on the X
/// axis (1–12), `year` on the Z axis, `count` extruded as the Y
/// height.
struct YearMonthCell: Equatable, Sendable, Identifiable {
    let year: Int
    /// 1-indexed: 1 = January.
    let month: Int
    let count: Int
    var id: String { "\(year)-\(month)" }
}

/// A book that's currently in progress — surfaced on the deep stats
/// page so the user sees their active reading at a glance with a
/// progress bar and a finish estimate.
struct InProgressBook: Equatable, Sendable, Identifiable {
    var id: String { recordID }
    let recordID: String
    let title: String
    let author: String?
    let currentPage: Int
    /// Total pages used as the denominator. Either `readable_pages`
    /// when set, or `page_count` otherwise. Zero when neither is set
    /// — caller should render that as "in progress" without a bar.
    let totalPages: Int
    /// Days since `started_date` (or `nil` when not started).
    let daysReading: Int?
    /// Tone for the progress bar fill.
    let tone: AccentTone
    let coverImageURL: URL?
}

/// A TV show that's currently in progress (`status == "watching"`).
struct InProgressShow: Equatable, Sendable, Identifiable {
    var id: String { recordID }
    let recordID: String
    let title: String
    let currentSeason: Int
    let currentEpisode: Int
    let totalEpisodes: Int
    let tone: AccentTone
    let coverImageURL: URL?
}

/// Pure aggregation over `[RecordRow]`. The reader (`DBReads.records`)
/// already dehydrates every property into `values: [String: String]`
/// in 3 SQL queries, so all of this runs in Swift in microseconds for
/// the ~300-record case the user has today.
enum StatsAggregator {

    // MARK: - Pace

    /// Build a series of monthly buckets over `records`. Bucketing is
    /// by the parsed date at `dateKey`. Records whose date is missing
    /// or unparseable are skipped silently — the chart legend doesn't
    /// surface them. When `validStatuses` is non-nil, records whose
    /// `statusKey` cell isn't in the set are also skipped (e.g. count
    /// only `read` books when computing books-finished-per-month).
    ///
    /// `lookback` clips the visible range to `[start...end]`. When
    /// nil, returns buckets from the earliest record's month through
    /// today. Months with zero records get a bucket too — Swift
    /// Charts otherwise gaps the X axis where data is missing.
    static func paceByMonth(
        records: [RecordRow],
        dateKey: String,
        statusKey: String? = nil,
        validStatuses: Set<String>? = nil,
        volumeKey: String? = nil,
        in lookback: ClosedRange<Date>? = nil,
        calendar: Calendar = .current
    ) -> [PaceBucket] {
        var byMonth: [Date: (count: Int, volume: Int)] = [:]
        var earliest: Date?
        var latest = Date()

        for record in records {
            if let statusKey, let valid = validStatuses {
                let s = record.values[statusKey] ?? ""
                if !valid.contains(s) { continue }
            }
            let raw = record.values[dateKey] ?? ""
            guard let date = DateValueCodec.parse(raw) else { continue }
            guard let monthStart = calendar.dateInterval(of: .month, for: date)?.start else { continue }
            let volume: Int = {
                guard let volumeKey,
                      let v = Int(record.values[volumeKey] ?? "") else { return 0 }
                return max(0, v)
            }()
            let existing = byMonth[monthStart] ?? (0, 0)
            byMonth[monthStart] = (existing.count + 1, existing.volume + volume)
            if earliest == nil || monthStart < (earliest ?? monthStart) {
                earliest = monthStart
            }
            if monthStart > latest { latest = monthStart }
        }

        // Determine the bucket range we'll fill.
        let rangeStart: Date
        let rangeEnd: Date
        if let lookback {
            rangeStart = calendar.dateInterval(of: .month, for: lookback.lowerBound)?.start ?? lookback.lowerBound
            rangeEnd = calendar.dateInterval(of: .month, for: lookback.upperBound)?.start ?? lookback.upperBound
        } else if let earliest {
            rangeStart = earliest
            rangeEnd = calendar.dateInterval(of: .month, for: latest)?.start ?? latest
        } else {
            return []
        }

        // Zero-fill empty months across the range so the X axis is
        // continuous. Without this, Swift Charts plots discontinuous
        // months which reads as "you took the year off" when really
        // the user just didn't finish a book in that month.
        var buckets: [PaceBucket] = []
        var cursor = rangeStart
        while cursor <= rangeEnd {
            let entry = byMonth[cursor] ?? (0, 0)
            buckets.append(PaceBucket(monthStart: cursor, count: entry.count, volume: entry.volume))
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return buckets
    }

    // MARK: - Status mix

    /// Count records per `statusKey` value, ordered to match the
    /// property's declared options. Values not in the options list
    /// sort to the end alphabetically. Empty values land in an "—"
    /// bucket as their own slice (so the donut accurately reports
    /// "unrated" / "no status set").
    static func statusMix(
        records: [RecordRow],
        statusKey: String,
        options: [String]
    ) -> [StatusSlice] {
        var counts: [String: Int] = [:]
        for record in records {
            let raw = record.values[statusKey] ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.isEmpty ? emptyLabel : trimmed
            counts[key, default: 0] += 1
        }
        var ordered: [StatusSlice] = []
        for option in options where counts[option] != nil {
            ordered.append(StatusSlice(value: option, count: counts[option] ?? 0))
        }
        let known = Set(options + [emptyLabel])
        let unknown = counts.keys
            .filter { !known.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        for value in unknown {
            ordered.append(StatusSlice(value: value, count: counts[value] ?? 0))
        }
        if let emptyCount = counts[emptyLabel], emptyCount > 0 {
            ordered.append(StatusSlice(value: emptyLabel, count: emptyCount))
        }
        return ordered
    }

    /// Display label for missing / empty values across stats outputs.
    /// Distinct from the literal string so a real tag named "—" still
    /// gets counted separately.
    static let emptyLabel = "—"

    // MARK: - Top values

    /// Rank distinct values at `key` by record count. When
    /// `multiSelect` is true the cell is decoded via `MultiSelectValue`
    /// so a record tagged `"fiction|mystery"` counts under both. Empty
    /// values are dropped (no "—" bucket here — the chart is "top
    /// values", not a complete partition).
    static func topValues(
        records: [RecordRow],
        key: String,
        multiSelect: Bool,
        limit: Int
    ) -> [TopValueRow] {
        var counts: [String: Int] = [:]
        for record in records {
            let raw = record.values[key] ?? ""
            let values: [String] = multiSelect
                ? MultiSelectValue.decode(raw)
                : [raw.trimmingCharacters(in: .whitespacesAndNewlines)]
            for v in values where !v.isEmpty {
                counts[v, default: 0] += 1
            }
        }
        return counts
            .sorted {
                $0.value == $1.value
                    ? $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
                    : $0.value > $1.value
            }
            .prefix(limit)
            .map { TopValueRow(value: $0.key, count: $0.value) }
    }

    // MARK: - Decade distribution

    static func decadeDistribution(
        records: [RecordRow],
        dateKey: String,
        calendar: Calendar = .current
    ) -> [DecadeBucket] {
        var counts: [Int: Int] = [:]
        for record in records {
            let raw = record.values[dateKey] ?? ""
            guard let date = DateValueCodec.parse(raw) else { continue }
            let year = calendar.component(.year, from: date)
            let decade = (year / 10) * 10
            counts[decade, default: 0] += 1
        }
        return counts
            .sorted { $0.key < $1.key }
            .map { DecadeBucket(decadeStart: $0.key, count: $0.value) }
    }

    // MARK: - Runtime buckets (movies)

    /// Bucket movie runtimes for a stacked-bar overview. The buckets
    /// are fixed (<90, 90–120, 120–150, 150+) because Apple Health-
    /// style histograms with adaptive bin sizes read confusingly when
    /// the range is so small.
    static func runtimeBuckets(records: [RecordRow], runtimeKey: String) -> [RuntimeBucket] {
        struct Spec { let label: String; let upper: Int }
        let specs: [Spec] = [
            .init(label: "< 90 min",   upper: 90),
            .init(label: "90–120 min", upper: 120),
            .init(label: "120–150 min", upper: 150),
            .init(label: "150+ min",   upper: Int.max),
        ]
        var counts = [Int](repeating: 0, count: specs.count)
        for record in records {
            guard let minutes = Int(record.values[runtimeKey] ?? ""), minutes > 0 else { continue }
            for (idx, spec) in specs.enumerated() where minutes < spec.upper || spec.upper == Int.max {
                if minutes < spec.upper {
                    counts[idx] += 1
                    break
                } else if spec.upper == Int.max {
                    counts[idx] += 1
                    break
                }
            }
        }
        return zip(specs, counts).map { spec, count in
            RuntimeBucket(label: spec.label, upperBoundMinutes: spec.upper, count: count)
        }
    }

    // MARK: - Sums

    /// Sum a numeric property over the records that match the
    /// predicate. Used for "pages read", "hours watched",
    /// "episodes watched" tiles.
    static func sumNumeric(
        records: [RecordRow],
        key: String,
        where predicate: (RecordRow) -> Bool
    ) -> Int {
        var total = 0
        for record in records where predicate(record) {
            if let v = Int(record.values[key] ?? "") { total += max(0, v) }
        }
        return total
    }

    // MARK: - Year × month activity grid

    /// Bucket `records` into a year × month matrix, optionally
    /// filtered by status. Used by the `Chart3D` reading-heatmap
    /// card on the deep stats page — each cell becomes a bar whose
    /// height is `count`. Returns a fully filled grid (every month
    /// of every spanned year, zero-counts included) so the 3D bar
    /// chart shows a continuous floor — without zero-fills, the
    /// chart would have invisible gaps that read as visual holes.
    static func yearMonthGrid(
        records: [RecordRow],
        dateKey: String,
        statusKey: String? = nil,
        validStatuses: Set<String>? = nil,
        calendar: Calendar = .current
    ) -> [YearMonthCell] {
        var counts: [String: Int] = [:]      // key = "\(year)-\(month)"
        var earliestYear: Int?
        var latestYear: Int = calendar.component(.year, from: Date())

        for record in records {
            if let statusKey, let valid = validStatuses {
                let s = record.values[statusKey] ?? ""
                if !valid.contains(s) { continue }
            }
            guard let date = DateValueCodec.parse(record.values[dateKey] ?? "") else { continue }
            let year = calendar.component(.year, from: date)
            let month = calendar.component(.month, from: date)
            counts["\(year)-\(month)", default: 0] += 1
            if earliestYear == nil || year < (earliestYear ?? year) {
                earliestYear = year
            }
            if year > latestYear { latestYear = year }
        }

        guard let earliestYear else { return [] }

        var cells: [YearMonthCell] = []
        for year in earliestYear...latestYear {
            for month in 1...12 {
                let count = counts["\(year)-\(month)"] ?? 0
                cells.append(YearMonthCell(year: year, month: month, count: count))
            }
        }
        return cells
    }

    // MARK: - In-progress

    static func inProgressBooks(records: [RecordRow]) -> [InProgressBook] {
        records
            .filter { ($0.values["status"] ?? "") == "reading" }
            .map { r in
                let currentPage = Int(r.values["current_page"] ?? "") ?? 0
                let readable = Int(r.values["readable_pages"] ?? "") ?? 0
                let pageCount = Int(r.values["page_count"] ?? "") ?? 0
                let totalPages = readable > 0 ? readable : pageCount
                let started = DateValueCodec.parse(r.values["started_date"] ?? "")
                let daysReading: Int? = started.flatMap { s in
                    Calendar.current.dateComponents([.day], from: s, to: Date()).day
                }
                return InProgressBook(
                    recordID: r.id,
                    title: r.title,
                    author: r.values["author"]?.isEmpty == true ? nil : r.values["author"],
                    currentPage: currentPage,
                    totalPages: totalPages,
                    daysReading: daysReading,
                    tone: r.tone,
                    coverImageURL: r.coverImageURL
                )
            }
            // Sort most-recently-started first.
            .sorted { ($0.daysReading ?? .max) < ($1.daysReading ?? .max) }
    }

    static func inProgressShows(records: [RecordRow]) -> [InProgressShow] {
        records
            .filter { ($0.values["status"] ?? "") == "watching" }
            .map { r in
                InProgressShow(
                    recordID: r.id,
                    title: r.title,
                    currentSeason: Int(r.values["current_season"] ?? "") ?? 0,
                    currentEpisode: Int(r.values["current_episode"] ?? "") ?? 0,
                    totalEpisodes: Int(r.values["episode_count"] ?? "") ?? 0,
                    tone: r.tone,
                    coverImageURL: r.coverImageURL
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}
