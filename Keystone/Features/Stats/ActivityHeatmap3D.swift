import SwiftUI
import Charts

/// WWDC25 `Chart3D` — a year × month activity heatmap rendered as a
/// field of 3D bars. Each `RectangleMark` is positioned at
/// `(month, year)` on the floor, with the record count extruded
/// upward on the Y axis. The user can rotate the chart with a drag
/// gesture (Chart3D handles this automatically) to compare years
/// from different angles.
///
/// Why this specifically: a year × month grid is genuinely 3D data —
/// two categorical/temporal axes plus a magnitude — and the WWDC25
/// session ([313](https://developer.apple.com/videos/play/wwdc2025/313))
/// explicitly calls out this shape as a "good representation for 3D"
/// (interactive, shape > exact values). It's also legitimately
/// useful: "do I read more in summer", "did 2024 outpace 2023",
/// "which months are my dry spells" all read off the rendered surface
/// at a glance, where in 2D the same information would need either a
/// heatmap (less intuitive) or N stacked yearly bar charts.
///
/// Falls back to a friendly empty state when the dataset has fewer
/// than two years of activity (a 3D chart of one year is just a 2D
/// bar chart with extra rotation).
@available(macOS 26.0, iOS 26.0, *)
struct ActivityHeatmap3D: View {
    var cells: [YearMonthCell]
    var accent: AccentTone
    /// Label used in the Y axis legend — "Books" / "Movies" / "Shows".
    var unitLabel: String

    private var distinctYears: Set<Int> { Set(cells.map(\.year)) }
    private var anyActivity: Bool { cells.contains { $0.count > 0 } }

    var body: some View {
        if distinctYears.count < 2 || !anyActivity {
            EmptyState(
                symbol: "cube.transparent",
                message: "Need at least two years of activity to plot in 3D."
            )
        } else {
            chart
                .frame(minHeight: 320, idealHeight: 360)
        }
    }

    private var chart: some View {
        // Minimal Chart3D matching the WWDC25 sample pattern
        // (PointMark with numeric x/y/z, no extra style scales).
        // RectangleMark + `chartForegroundStyleScale(range: Gradient)`
        // was tripping a SwiftUI AttributeGraph assertion at first
        // render — gradients are continuous and the scale's range
        // wants discrete styles. PointMark with a flat foreground
        // is what the WWDC penguin sample shipped, so we stay close
        // to that shape.
        Chart3D(cells) { cell in
            PointMark(
                x: .value("Month", cell.month),
                y: .value(unitLabel, cell.count),
                z: .value("Year", cell.year)
            )
            .foregroundStyle(accent.base)
        }
        .chart3DPose(
            // 35° azimuth + 25° inclination matches Apple's penguin-
            // dataset default from the WWDC25 session — gives the
            // user a depth-cued first render without having to
            // interact.
            .init(azimuth: .degrees(35), inclination: .degrees(25))
        )
        .chart3DCameraProjection(.orthographic)
    }
}
