import SwiftUI
import ComposableArchitecture

/// Statistics body for a Collections database. Used directly as the
/// `ViewKind.dashboard` body on macOS / iPad (via `DashboardView`'s
/// dispatcher) and as a top-level page on iPhone (via
/// `iPhoneStatsHost`, which wraps it for the `Nav.stats` route since
/// iPhone has no view switcher). No internal header — the parent
/// provides the chrome (DatabaseDetailView's toolbar on macOS,
/// NavigationStack's title on iPhone).
struct StatsDetailView: View {
    @Bindable var store: StoreOf<AppFeature>
    var db: DBRow
    var properties: [PropertyRow]
    var records: [RecordRow]

    /// Single page-level time window. Affects every section that
    /// reasons over activity dates (pace, top tags / authors, decade
    /// distribution, runtime, hero totals like "completed", "pages
    /// read", "hours watched"). State-only widgets (currently reading
    /// list, in-progress hero tile, total-library tile) ignore it.
    @State private var window: StatsTimeWindow = .last12Months

    private static let palette: [Color] = [
        AccentTone.cerulean.base,
        AccentTone.amber.base,
        AccentTone.sage.base,
        AccentTone.graphite.base,
    ]

    private var statusOptions: [String] {
        properties.first { $0.key == "status" }?.config.options ?? []
    }

    /// Date-key on the record that determines "activity" for windowing
    /// purposes: when the record was *completed* for books / movies,
    /// or last touched for TV. Used by `windowedRecords` to decide
    /// what's in scope for the active window.
    private var activityDateKey: String {
        switch db.id {
        case "books":     return "finished_date"
        case "movies":    return "watched_date"
        case "tv_shows":  return "last_watched"
        default:          return "created_at"
        }
    }

    /// Records narrowed to the active time window. When `window` is
    /// `.allTime`, this is just `records`. Otherwise: records whose
    /// `activityDateKey` value parses to a date inside the lookback
    /// range. Records with no parseable activity date are excluded —
    /// they have no temporal locus.
    private var windowedRecords: [RecordRow] {
        guard let lookback = window.lookback() else { return records }
        return records.filter { record in
            guard let raw = record.values[activityDateKey],
                  let date = DateValueCodec.parse(raw) else { return false }
            return lookback.contains(date)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Page-level window selector. Sits at the top of the
                // scrolling body (not in a separate chrome strip) so
                // it's the same on every platform — DatabaseDetailView
                // on macOS / iPad supplies the toolbar above, and
                // NavigationStack on iPhone supplies its own title.
                HStack {
                    Spacer()
                    TimeWindowPicker(selection: $window)
                }
                heroSection
                paceSection
                sideBySidePair
                topTagsSection
                perDatabaseSection
                activity3DSection
            }
            .padding(24)
        }
        .background(KstColor.paper0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// On wide screens (macOS / iPad), show the status donut and
    /// decade chart side by side. On iPhone-narrow widths, stack them
    /// so each gets full width and the donut/legend stay readable.
    @ViewBuilder
    private var sideBySidePair: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                statusSection
                decadeSection
            }
            VStack(spacing: 16) {
                statusSection
                decadeSection
            }
        }
    }

    // MARK: - Shared sections

    @ViewBuilder
    private var heroSection: some View {
        switch db.id {
        case "books":     bookHero
        case "movies":    movieHero
        case "tv_shows":  tvHero
        default:          EmptyView()
        }
    }

    private var paceSection: some View {
        let (dateKey, statusKey, validStatuses, volumeKey, unit, title): (String, String?, Set<String>?, String?, String, String) = {
            switch db.id {
            case "books":
                return ("finished_date", "status", ["read"], "page_count", "books", "READ PER MONTH")
            case "movies":
                return ("watched_date", "status", ["watched"], "runtime_minutes", "movies", "WATCHED PER MONTH")
            case "tv_shows":
                return ("last_watched", nil, nil, nil, "shows", "TV ACTIVITY")
            default:
                return ("created_at", nil, nil, nil, "records", "PACE")
            }
        }()

        // Aggregator already does its own lookback-driven bucketing
        // and zero-fill — give it the raw records so empty months
        // inside the window are still represented on the X axis,
        // even when no record's activity date landed there.
        let buckets = StatsAggregator.paceByMonth(
            records: records,
            dateKey: dateKey,
            statusKey: statusKey,
            validStatuses: validStatuses,
            volumeKey: volumeKey,
            in: window.lookback()
        )

        return StatsCard(title: title, subtitle: window.subtitle) {
            PaceBarChart(
                buckets: buckets,
                accent: db.accent,
                scrollable: true,
                visibleMonths: window.visibleMonths,
                unitLabel: unit
            )
        }
    }

    private var statusSection: some View {
        // Status donut respects the window so "1 yr" shows the
        // breakdown of activity in that period (mostly `read` for
        // books, mostly `watched` for movies/TV). On `.allTime` this
        // is the canonical library status mix.
        StatsCard(title: "STATUS", subtitle: window.subtitle) {
            StatusDonut(
                slices: StatsAggregator.statusMix(
                    records: windowedRecords,
                    statusKey: "status",
                    options: statusOptions
                ),
                palette: Self.palette
            )
        }
    }

    private var decadeSection: some View {
        let dateKey: String = {
            switch db.id {
            case "books":     return "published_date"
            case "movies":    return "release_date"
            case "tv_shows":  return "first_air_date"
            default:          return "created_at"
            }
        }()
        let label: String = {
            switch db.id {
            case "books":     return "WHEN PUBLISHED"
            case "movies":    return "WHEN RELEASED"
            case "tv_shows":  return "FIRST AIRED"
            default:          return "DECADE"
            }
        }()
        return StatsCard(title: label, subtitle: window.subtitle) {
            DecadeBarChart(
                buckets: StatsAggregator.decadeDistribution(records: windowedRecords, dateKey: dateKey),
                accent: db.accent
            )
        }
    }

    private var topTagsSection: some View {
        let label: String = db.id == "books" ? "TOP TAGS" : "TOP GENRES"
        return StatsCard(
            title: label,
            subtitle: "\(window.subtitle) · tap a tag to filter \(db.name) by it"
        ) {
            TopValuesChart(
                items: StatsAggregator.topValues(
                    records: windowedRecords,
                    key: "tags",
                    multiSelect: true,
                    limit: 20
                ),
                accent: db.accent
            ) { tappedRow in
                store.send(.navigateAndPresetTagFilter(
                    databaseID: db.id,
                    propertyKey: "tags",
                    value: tappedRow.value
                ))
            }
        }
    }

    /// WWDC25 `Chart3D` activity heatmap — year × month × count
    /// extruded into 3D bars. Hidden unless the user's dataset
    /// spans at least two years (the chart shape doesn't pay off
    /// with one year's worth of data). Available only on macOS 26+
    /// / iOS 26+; the `@available` gate falls through to nothing on
    /// older toolchains.
    @ViewBuilder
    private var activity3DSection: some View {
        let (dateKey, statusKey, validStatuses, unit, title): (String, String?, Set<String>?, String, String) = {
            switch db.id {
            case "books":
                return ("finished_date", "status", ["read"], "Books", "READING PATTERN")
            case "movies":
                return ("watched_date", "status", ["watched"], "Movies", "WATCHING PATTERN")
            case "tv_shows":
                return ("last_watched", nil, nil, "Shows", "ACTIVITY PATTERN")
            default:
                return ("", nil, nil, "", "")
            }
        }()
        if !dateKey.isEmpty {
            let cells = StatsAggregator.yearMonthGrid(
                records: windowedRecords,
                dateKey: dateKey,
                statusKey: statusKey,
                validStatuses: validStatuses
            )
            StatsCard(
                title: title,
                subtitle: "\(window.subtitle) · year × month — drag to rotate"
            ) {
                if #available(macOS 26.0, iOS 26.0, *) {
                    ActivityHeatmap3D(
                        cells: cells,
                        accent: db.accent,
                        unitLabel: unit
                    )
                } else {
                    EmptyState(
                        symbol: "cube.transparent",
                        message: "3D charts require macOS 26 or later."
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var perDatabaseSection: some View {
        switch db.id {
        case "books":
            currentlyReadingSection
            topAuthorsSection
        case "movies":
            runtimeSection
        case "tv_shows":
            currentlyWatchingSection
        default:
            EmptyView()
        }
    }

    // MARK: - Books-specific

    private var bookHero: some View {
        // Library-state tiles ignore the window (Total / Reading
        // reflect *now*); activity tiles (Read / Pages read) honor it.
        let total = records.count
        let reading = records.filter { ($0.values["status"] ?? "") == "reading" }.count
        let readInWindow = windowedRecords.filter {
            ($0.values["status"] ?? "") == "read"
        }.count
        let pages = StatsAggregator.sumNumeric(
            records: windowedRecords, key: "page_count",
            where: { ($0.values["status"] ?? "") == "read" }
        )
        return adaptiveHero {
            HeroStatTile(label: "TOTAL", value: "\(total)", accent: db.accent, caption: "library")
            HeroStatTile(label: "READING", value: "\(reading)", accent: .amber, caption: "now")
            HeroStatTile(label: "READ", value: "\(readInWindow)", accent: .sage, caption: window.captionLabel)
            HeroStatTile(label: "PAGES READ", value: pages.formatted(), accent: .cerulean, caption: window.captionLabel)
        }
    }

    private var currentlyReadingSection: some View {
        let books = StatsAggregator.inProgressBooks(records: records)
        return Group {
            if !books.isEmpty {
                StatsCard(title: "CURRENTLY READING") {
                    VStack(spacing: 8) {
                        ForEach(books) { book in
                            InProgressBookRow(book: book) {
                                store.send(.setNav(.record(
                                    databaseID: db.id, recordID: book.recordID
                                )))
                            }
                        }
                    }
                }
            }
        }
    }

    private var topAuthorsSection: some View {
        StatsCard(title: "TOP AUTHORS", subtitle: window.subtitle) {
            TopValuesChart(
                items: StatsAggregator.topValues(
                    records: windowedRecords,
                    key: "author",
                    multiSelect: false,
                    limit: 20
                ),
                accent: db.accent
            )
        }
    }

    // MARK: - Movies-specific

    private var movieHero: some View {
        // Total = library size (state). Watched / Hours / Dropped =
        // activity, all windowed.
        let total = records.count
        let watchedInWindow = windowedRecords.filter {
            ($0.values["status"] ?? "") == "watched"
        }.count
        let hours = StatsAggregator.sumNumeric(
            records: windowedRecords, key: "runtime_minutes",
            where: { ($0.values["status"] ?? "") == "watched" }
        ) / 60
        let droppedInWindow = windowedRecords.filter {
            ($0.values["status"] ?? "") == "dropped"
        }.count
        return adaptiveHero {
            HeroStatTile(label: "TOTAL", value: "\(total)", accent: db.accent, caption: "library")
            HeroStatTile(label: "WATCHED", value: "\(watchedInWindow)", accent: .sage, caption: window.captionLabel)
            HeroStatTile(label: "HOURS", value: hours.formatted(), accent: .cerulean, caption: window.captionLabel)
            HeroStatTile(label: "DROPPED", value: "\(droppedInWindow)", accent: .graphite, caption: window.captionLabel)
        }
    }

    private var runtimeSection: some View {
        StatsCard(title: "RUNTIME DISTRIBUTION", subtitle: window.subtitle) {
            RuntimeBucketChart(
                buckets: StatsAggregator.runtimeBuckets(records: windowedRecords, runtimeKey: "runtime_minutes"),
                accent: db.accent
            )
        }
    }

    // MARK: - TV-specific

    private var tvHero: some View {
        let total = records.count
        let watching = records.filter { ($0.values["status"] ?? "") == "watching" }.count
        let watchedInWindow = windowedRecords.filter {
            ($0.values["status"] ?? "") == "watched"
        }.count
        let episodes = StatsAggregator.sumNumeric(
            records: windowedRecords, key: "episode_count",
            where: { ($0.values["status"] ?? "") == "watched" }
        )
        return adaptiveHero {
            HeroStatTile(label: "TOTAL", value: "\(total)", accent: db.accent, caption: "library")
            HeroStatTile(label: "WATCHING", value: "\(watching)", accent: .amber, caption: "now")
            HeroStatTile(label: "WATCHED", value: "\(watchedInWindow)", accent: .sage, caption: window.captionLabel)
            HeroStatTile(label: "EPISODES", value: episodes.formatted(), accent: .cerulean, caption: window.captionLabel)
        }
    }

    private var currentlyWatchingSection: some View {
        let shows = StatsAggregator.inProgressShows(records: records)
        return Group {
            if !shows.isEmpty {
                StatsCard(title: "CURRENTLY WATCHING") {
                    VStack(spacing: 8) {
                        ForEach(shows) { show in
                            InProgressShowRow(show: show) {
                                store.send(.setNav(.record(
                                    databaseID: db.id, recordID: show.recordID
                                )))
                            }
                        }
                    }
                }
            }
        }
    }
}

private extension StatsTimeWindow {
    /// Used in section subtitles ("Last 12 months", "Last 5 years",
    /// "All time"). Repeated across many cards so the user can scan
    /// the page and see the window at a glance.
    var subtitle: String {
        switch self {
        case .last12Months: return "Last 12 months"
        case .last5Years:   return "Last 5 years"
        case .allTime:      return "All time"
        }
    }

    /// Compact caption shown under a hero tile's big number ("last
    /// 12 mo" / "last 5 yr" / "lifetime"). Shorter than `subtitle`
    /// since the hero card only has room for ~10 characters.
    var captionLabel: String {
        switch self {
        case .last12Months: return "last 12 mo"
        case .last5Years:   return "last 5 yr"
        case .allTime:      return "lifetime"
        }
    }
}

/// Hero-row layout helper. `LazyVGrid` with `adaptive(minimum:)`
/// gives us automatic wrapping: 4 tiles in a row on macOS / iPad,
/// 2×2 on iPhone Portrait, 1-wide on very narrow widths. The 150-pt
/// minimum is chosen so a 32-pt big number always fits with its
/// label + caption above and below.
@ViewBuilder
private func adaptiveHero<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
        spacing: 12
    ) {
        content()
    }
}
