import SwiftUI

/// 6×7 month grid. Each cell carries up to 3 single-day pills + a "+N
/// more" overflow indicator. Range events render as continuous bars
/// overlaid per week-row, splitting at week boundaries.
struct CalendarMonthView: View {
    let anchor: Date
    let events: [CalendarEvent]
    let accent: AccentTone
    let onOpen: (CalendarEvent) -> Void

    private let weekColumns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        let grid = CalendarLayout.monthGrid(for: anchor)
        let weeks = stride(from: 0, to: 42, by: 7).map { Array(grid[$0..<$0 + 7]) }
        let monthOfAnchor = Calendar.current.component(.month, from: anchor)

        VStack(spacing: 0) {
            weekdayHeader

            VStack(spacing: 0) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    MonthWeekRow(
                        week: week,
                        monthOfAnchor: monthOfAnchor,
                        events: events,
                        accent: accent,
                        onOpen: onOpen
                    )
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var weekdayHeader: some View {
        let symbols = orderedShortWeekdays()
        return LazyVGrid(columns: weekColumns, spacing: 0) {
            ForEach(0..<7, id: \.self) { idx in
                Text(symbols[idx])
                    .font(.kstText(size: 11, weight: .semibold))
                    .foregroundStyle(KstColor.ink3)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(KstColor.paper1)
        .overlay(alignment: .bottom) { KstHairline() }
    }

    private func orderedShortWeekdays() -> [String] {
        let calendar = Calendar.current
        let symbols = calendar.shortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        let rotated = Array(symbols[first...] + symbols[..<first])
        return rotated
    }
}

private struct MonthWeekRow: View {
    let week: [Date]
    let monthOfAnchor: Int
    let events: [CalendarEvent]
    let accent: AccentTone
    let onOpen: (CalendarEvent) -> Void

    var body: some View {
        GeometryReader { geo in
            let cellWidth = geo.size.width / 7
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        MonthDayCell(
                            day: day,
                            monthOfAnchor: monthOfAnchor,
                            singleDayEvents: singleDayEvents(on: day),
                            singleDayCount: rangeBars(forWeek: week).contains(where: { spans($0, day: day) }) ? 0 : singleDayEvents(on: day).count,
                            accent: accent,
                            onOpen: onOpen
                        )
                        .frame(width: cellWidth)
                    }
                }

                ForEach(Array(rangeBars(forWeek: week).enumerated()), id: \.offset) { idx, bar in
                    rangeBarView(bar, cellWidth: cellWidth, laneIndex: idx)
                }
            }
        }
        .frame(minHeight: 92)
        .overlay(alignment: .bottom) { KstHairline() }
    }

    private func singleDayEvents(on day: Date) -> [CalendarEvent] {
        events.filter { $0.end == nil && CalendarEventBuilder.event($0, intersects: day) }
    }

    /// Range bars to render in this week, sorted by start date so taller
    /// stacks render predictably.
    private func rangeBars(forWeek week: [Date]) -> [RangeBar] {
        let weekStart = week.first ?? Date()
        let weekEnd = week.last ?? Date()
        return events
            .filter { $0.end != nil }
            .compactMap { event -> RangeBar? in
                let start = startOfDayInEventTZ(event.start, tz: event.timezone)
                let end = startOfDayInEventTZ(event.end ?? event.start, tz: event.timezone)
                let visibleStart = max(start, startOfDayInEventTZ(weekStart, tz: event.timezone))
                let visibleEnd = min(end, startOfDayInEventTZ(weekEnd, tz: event.timezone))
                guard visibleStart <= visibleEnd else { return nil }
                let startDayIdx = day(startOfDayInEventTZ(weekStart, tz: event.timezone), to: visibleStart)
                let endDayIdx = day(startOfDayInEventTZ(weekStart, tz: event.timezone), to: visibleEnd)
                return RangeBar(event: event, startCol: startDayIdx, span: endDayIdx - startDayIdx + 1)
            }
            .sorted { $0.startCol < $1.startCol }
    }

    private func spans(_ bar: RangeBar, day: Date) -> Bool {
        return CalendarEventBuilder.event(bar.event, intersects: day)
    }

    @ViewBuilder
    private func rangeBarView(_ bar: RangeBar, cellWidth: CGFloat, laneIndex: Int) -> some View {
        Button { onOpen(bar.event) } label: {
            Text(bar.event.title)
                .font(.kstText(size: 11, weight: .semibold))
                .foregroundStyle(accent.ink)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .frame(width: cellWidth * CGFloat(bar.span) - 4, height: 16)
        .background(accent.soft)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .offset(x: cellWidth * CGFloat(bar.startCol) + 2,
                y: 22 + CGFloat(laneIndex) * 18)
    }

    private struct RangeBar {
        let event: CalendarEvent
        let startCol: Int
        let span: Int
    }

    private func startOfDayInEventTZ(_ date: Date, tz: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return calendar.startOfDay(for: date)
    }

    private func day(_ from: Date, to: Date) -> Int {
        Calendar.current.dateComponents([.day], from: from, to: to).day ?? 0
    }
}

private struct MonthDayCell: View {
    let day: Date
    let monthOfAnchor: Int
    let singleDayEvents: [CalendarEvent]
    /// Effective number of single-day pills to show, accounting for
    /// range bars already overlaid in the parent row.
    let singleDayCount: Int
    let accent: AccentTone
    let onOpen: (CalendarEvent) -> Void

    private let maxPills = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(dayNumber)
                    .font(.kstText(size: 12, weight: isToday ? .bold : .medium))
                    .foregroundStyle(numberColor)
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)

            ForEach(Array(singleDayEvents.prefix(maxPills).enumerated()), id: \.offset) { _, event in
                Button { onOpen(event) } label: {
                    Text(event.title)
                        .font(.kstText(size: 11))
                        .foregroundStyle(KstColor.ink1)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                        .frame(height: 16)
                        .background(accent.soft.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 2)
            }

            if singleDayCount > maxPills {
                Text("+\(singleDayCount - maxPills) more")
                    .font(.kstText(size: 10))
                    .foregroundStyle(KstColor.ink3)
                    .padding(.horizontal, 6)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isInMonth ? KstColor.paper0 : KstColor.paper1.opacity(0.5))
        .overlay(alignment: .trailing) {
            Rectangle().fill(KstColor.paper3).frame(width: 0.5)
        }
    }

    private var dayNumber: String {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f.string(from: day)
    }

    private var isInMonth: Bool {
        Calendar.current.component(.month, from: day) == monthOfAnchor
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(day)
    }

    private var numberColor: Color {
        if isToday { return KstColor.cerulean }
        return isInMonth ? KstColor.ink0 : KstColor.ink3
    }
}
