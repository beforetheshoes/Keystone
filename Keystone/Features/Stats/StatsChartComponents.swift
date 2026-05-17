import SwiftUI
import Charts

// MARK: - Card wrapper

/// Visual wrapper for a stats panel. Mirrors `DashCard` from
/// `DashboardView` but lighter — no big-number presentation, since
/// stats cards usually contain a chart. Optional `accessory` slot
/// in the header is used by the deep page for the time-window
/// segmented control.
struct StatsCard<Content: View, Accessory: View>: View {
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content
    @ViewBuilder var accessory: () -> Accessory

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.kstText(size: 11, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(KstColor.ink2)
                    if let subtitle {
                        Text(subtitle)
                            .font(.kstText(size: 11))
                            .foregroundStyle(KstColor.ink3)
                    }
                }
                Spacer(minLength: 8)
                accessory()
            }
            .padding(.bottom, 12)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KstColor.paper1)
        .overlay(
            RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous))
    }
}

// MARK: - Hero tiles

/// Compact stat tile shown in the hero row above the chart cards.
/// Big number + small label.
struct HeroStatTile: View {
    var label: String
    var value: String
    var accent: AccentTone
    /// Optional small caption under the value ("of 271" / "this year").
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.kstText(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(KstColor.ink2)
            Text(value)
                .font(.kstDisplay(size: 32, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(accent.base)
                .padding(.top, 6)
            if let caption {
                Text(caption)
                    .font(.kstText(size: 11))
                    .foregroundStyle(KstColor.ink3)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KstColor.paper1)
        .overlay(
            RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous))
    }
}

// MARK: - Pace bar chart

/// Bar chart over monthly buckets. Used for "books finished per month",
/// "movies watched per month", "TV activity per month". When
/// `scrollable` is true the chart shows a fixed visible domain of the
/// most recent N months and the user can drag horizontally back through
/// older data — the WWDC23 pattern. When false the entire range is
/// fit to the chart bounds.
struct PaceBarChart: View {
    var buckets: [PaceBucket]
    var accent: AccentTone
    var scrollable: Bool = false
    /// Number of months in the initial visible window when `scrollable`
    /// is true. Ignored otherwise.
    var visibleMonths: Int = 12
    /// Y-axis label. e.g. "books", "movies", "episodes" — pluralized
    /// for the legend / accessibility.
    var unitLabel: String = "items"

    var body: some View {
        let nonEmpty = buckets.filter { $0.count > 0 }
        if nonEmpty.isEmpty {
            EmptyState(symbol: "calendar", message: "No activity yet.")
        } else {
            chart
                .frame(minHeight: 140, idealHeight: 160)
        }
    }

    @ViewBuilder
    private var chart: some View {
        let chartView = Chart(buckets) { bucket in
            BarMark(
                x: .value("Month", bucket.monthStart, unit: .month),
                y: .value(unitLabel.capitalized, bucket.count)
            )
            .foregroundStyle(accent.base)
            .cornerRadius(2)
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(KstColor.paper3)
                AxisValueLabel().font(.kstText(size: 10))
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month, count: max(1, buckets.count / 12))) { value in
                AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits))
                    .font(.kstText(size: 10))
            }
        }
        if scrollable {
            chartView
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: visibleMonthsAsTimeInterval)
                .chartScrollPosition(initialX: latestMonthStart)
        } else {
            chartView
        }
    }

    private var visibleMonthsAsTimeInterval: TimeInterval {
        // `chartXVisibleDomain(length:)` takes the X axis's native
        // delta. For Date axes that's seconds; 30.44 days per month
        // is the standard astronomical approximation Apple's own
        // samples use.
        return Double(visibleMonths) * 30.44 * 86_400
    }

    private var latestMonthStart: Date {
        buckets.last?.monthStart ?? Date()
    }
}

// MARK: - Status donut

/// `SectorMark` donut chart with the total count rendered in the
/// center. Slices follow the order the aggregator returned, which
/// is the property's option order (so books cycle to_read → reading
/// → read → abandoned in the donut just like the cycle pill).
struct StatusDonut: View {
    var slices: [StatusSlice]
    var palette: [Color]
    /// Optional override for the center number — useful when the donut
    /// represents a *subset* of records and the caller wants to show
    /// the total of the parent set instead of the slice sum.
    var centerOverride: Int? = nil

    private var total: Int {
        slices.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        if slices.isEmpty {
            EmptyState(symbol: "circle.dashed", message: "No data yet.")
        } else {
            HStack(alignment: .center, spacing: 18) {
                chart
                legend
            }
        }
    }

    private var chart: some View {
        Chart(slices) { slice in
            SectorMark(
                angle: .value("Count", slice.count),
                innerRadius: .ratio(0.65),
                angularInset: 1.5
            )
            .cornerRadius(2)
            .foregroundStyle(by: .value("Status", slice.value))
        }
        .chartForegroundStyleScale(range: palette)
        .chartLegend(.hidden)
        .frame(width: 140, height: 140)
        .overlay {
            VStack(spacing: 2) {
                Text("\(centerOverride ?? total)")
                    .font(.kstDisplay(size: 24, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(KstColor.ink0)
                Text("total")
                    .font(.kstText(size: 10))
                    .foregroundStyle(KstColor.ink3)
            }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(slices.enumerated()), id: \.element.id) { idx, slice in
                HStack(spacing: 8) {
                    Circle()
                        .fill(palette[idx % palette.count])
                        .frame(width: 8, height: 8)
                    Text(slice.value)
                        .font(.kstText(size: 12))
                        .foregroundStyle(KstColor.ink1)
                    Spacer(minLength: 8)
                    Text("\(slice.count)")
                        .font(.kstText(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(KstColor.ink0)
                }
            }
        }
    }
}

// MARK: - Top values (horizontal bar)

/// Horizontal bar chart used for top tags / top authors. When `onTap`
/// is non-nil each row is clickable — the deep page wires that to
/// "filter the database by this tag" via `AppFeature.addFilter`.
struct TopValuesChart: View {
    var items: [TopValueRow]
    var accent: AccentTone
    var onTap: ((TopValueRow) -> Void)? = nil

    var body: some View {
        if items.isEmpty {
            EmptyState(symbol: "tag", message: "No values to rank yet.")
        } else {
            chart
                .frame(minHeight: CGFloat(items.count) * 22 + 18)
        }
    }

    private var chart: some View {
        Chart(items) { row in
            BarMark(
                x: .value("Count", row.count),
                y: .value("Value", row.value)
            )
            .foregroundStyle(accent.base)
            .cornerRadius(2)
            .annotation(position: .trailing, alignment: .leading) {
                Text("\(row.count)")
                    .font(.kstText(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(KstColor.ink2)
                    .padding(.leading, 4)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisValueLabel()
                    .font(.kstText(size: 11))
            }
        }
        .chartXAxis(.hidden)
        // Tap handling — the chart proxy + spatial tap give us a row
        // hit-test without rolling a custom List.
        .chartOverlay { proxy in
            if let onTap {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            // Resolve which row the y position fell
                            // in. Newer SDKs expose `plotFrame` as
                            // Optional; older ones (and the
                            // deprecated path) use `plotAreaFrame`.
                            // Explicit unwrap avoids a
                            // type-mismatched `??` between Optional
                            // and non-Optional anchors.
                            let anchor: Anchor<CGRect>? = proxy.plotFrame
                            guard let anchor else { return }
                            let plotFrame = geo[anchor]
                            let relativeY = location.y - plotFrame.minY
                            guard relativeY >= 0 && relativeY < plotFrame.height else { return }
                            if let value: String = proxy.value(atY: relativeY),
                               let row = items.first(where: { $0.value == value }) {
                                onTap(row)
                            }
                        }
                }
            }
        }
    }
}

// MARK: - Decade buckets

struct DecadeBarChart: View {
    var buckets: [DecadeBucket]
    var accent: AccentTone

    var body: some View {
        if buckets.isEmpty {
            EmptyState(symbol: "calendar", message: "No dated records yet.")
        } else {
            chart
                .frame(minHeight: 140, idealHeight: 160)
        }
    }

    private var chart: some View {
        Chart(buckets) { bucket in
            BarMark(
                x: .value("Decade", "\(bucket.decadeStart)s"),
                y: .value("Count", bucket.count)
            )
            .foregroundStyle(accent.base)
            .cornerRadius(2)
            .annotation(position: .top, alignment: .center) {
                Text("\(bucket.count)")
                    .font(.kstText(size: 9, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(KstColor.ink3)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(KstColor.paper3)
                AxisValueLabel().font(.kstText(size: 10))
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel().font(.kstText(size: 10))
            }
        }
    }
}

// MARK: - Runtime buckets (movies)

struct RuntimeBucketChart: View {
    var buckets: [RuntimeBucket]
    var accent: AccentTone

    var body: some View {
        let nonEmpty = buckets.filter { $0.count > 0 }
        if nonEmpty.isEmpty {
            EmptyState(symbol: "clock", message: "No runtime data yet.")
        } else {
            chart
                .frame(minHeight: 140, idealHeight: 160)
        }
    }

    private var chart: some View {
        Chart(buckets) { bucket in
            BarMark(
                x: .value("Bucket", bucket.label),
                y: .value("Count", bucket.count)
            )
            .foregroundStyle(accent.base)
            .cornerRadius(2)
            .annotation(position: .top, alignment: .center) {
                Text("\(bucket.count)")
                    .font(.kstText(size: 9, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(KstColor.ink3)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(KstColor.paper3)
                AxisValueLabel().font(.kstText(size: 10))
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel().font(.kstText(size: 10))
            }
        }
    }
}

// MARK: - Empty state

/// Tiny placeholder used by every chart when the underlying series is
/// empty. Keeps the card's height stable rather than collapsing.
struct EmptyState: View {
    var symbol: String
    var message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(KstColor.ink3)
            Text(message)
                .font(.kstText(size: 12))
                .foregroundStyle(KstColor.ink3)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 100)
    }
}

// MARK: - In-progress rows

/// Compact row shown in the "Currently reading" / "Currently watching"
/// stats card. Reuses the shared `ProgressBar` from
/// `BookProgressField.swift` (promoted to internal). Tone follows the
/// record's accent so the fill bar isn't always the database default.
struct InProgressBookRow: View {
    var book: InProgressBook
    var onTap: () -> Void

    private var fraction: Double {
        guard book.totalPages > 0 else { return 0 }
        return min(1.0, Double(book.currentPage) / Double(book.totalPages))
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                CoverThumbnail(
                    url: book.coverImageURL,
                    displaySize: CGSize(width: 28, height: 42),
                    contentMode: .fill
                ) { KstColor.paper2 }
                .frame(width: 28, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title)
                        .font(.kstText(size: 12, weight: .semibold))
                        .foregroundStyle(KstColor.ink0)
                        .lineLimit(1)
                    if book.totalPages > 0 {
                        HStack(spacing: 6) {
                            ProgressBar(fraction: fraction, tone: book.tone)
                                .frame(height: 4)
                            Text("\(book.currentPage)/\(book.totalPages)")
                                .font(.kstText(size: 10))
                                .monospacedDigit()
                                .foregroundStyle(KstColor.ink2)
                        }
                    } else {
                        Text("In progress")
                            .font(.kstText(size: 10))
                            .foregroundStyle(KstColor.ink3)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct InProgressShowRow: View {
    var show: InProgressShow
    var onTap: () -> Void

    private var fraction: Double {
        guard show.totalEpisodes > 0 else { return 0 }
        return min(1.0, Double(show.currentEpisode) / Double(show.totalEpisodes))
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                CoverThumbnail(
                    url: show.coverImageURL,
                    displaySize: CGSize(width: 28, height: 42),
                    contentMode: .fill
                ) { KstColor.paper2 }
                .frame(width: 28, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(show.title)
                        .font(.kstText(size: 12, weight: .semibold))
                        .foregroundStyle(KstColor.ink0)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text("S\(show.currentSeason) · E\(show.currentEpisode)")
                            .font(.kstText(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(KstColor.ink2)
                        if show.totalEpisodes > 0 {
                            ProgressBar(fraction: fraction, tone: show.tone)
                                .frame(height: 4)
                            Text("of \(show.totalEpisodes)")
                                .font(.kstText(size: 10))
                                .monospacedDigit()
                                .foregroundStyle(KstColor.ink3)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Time window control

/// Segmented selector for the "Last 12 months / 5 years / All time"
/// window on the deep stats page. Drives `chartXVisibleDomain` on the
/// pace chart it accompanies.
struct TimeWindowPicker: View {
    @Binding var selection: StatsTimeWindow

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(StatsTimeWindow.allCases, id: \.self) { window in
                Text(window.shortLabel).tag(window)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

enum StatsTimeWindow: String, CaseIterable, Hashable {
    case last12Months
    case last5Years
    case allTime

    var shortLabel: String {
        switch self {
        case .last12Months: return "1 yr"
        case .last5Years:   return "5 yr"
        case .allTime:      return "All"
        }
    }

    /// Lookback range applied to `paceByMonth`. `allTime` returns nil
    /// — the aggregator falls back to the earliest record's month.
    func lookback(now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date>? {
        switch self {
        case .last12Months:
            let start = calendar.date(byAdding: .month, value: -11, to: now) ?? now
            return start...now
        case .last5Years:
            let start = calendar.date(byAdding: .year, value: -5, to: now) ?? now
            return start...now
        case .allTime:
            return nil
        }
    }

    /// Months in the initial visible window for the scrollable
    /// variant of the pace chart.
    var visibleMonths: Int {
        switch self {
        case .last12Months: return 12
        case .last5Years:   return 60
        case .allTime:      return 24
        }
    }
}
