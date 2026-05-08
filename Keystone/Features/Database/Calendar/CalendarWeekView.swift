import SwiftUI

/// 7-column week strip with an hour grid (00–23) per day. Events render
/// as rectangles positioned by their event-local start hour and sized
/// to their duration. All-day events occupy a separate top lane.
struct CalendarWeekView: View {
    let anchor: Date
    let events: [CalendarEvent]
    let accent: AccentTone
    let onOpen: (CalendarEvent) -> Void

    private let hourHeight: CGFloat = 36

    var body: some View {
        let week = CalendarLayout.week(containing: anchor)

        VStack(spacing: 0) {
            // Day-of-week column headers.
            HStack(spacing: 0) {
                Spacer().frame(width: 44)
                ForEach(week, id: \.self) { day in
                    VStack(spacing: 1) {
                        Text(weekdayLabel(day))
                            .font(.kstText(size: 10, weight: .semibold))
                            .foregroundStyle(KstColor.ink3)
                        Text(dayLabel(day))
                            .font(.kstText(size: 13, weight: Calendar.current.isDateInToday(day) ? .bold : .medium))
                            .foregroundStyle(Calendar.current.isDateInToday(day) ? KstColor.cerulean : KstColor.ink0)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
            }
            .background(KstColor.paper1)
            .overlay(alignment: .bottom) { KstHairline() }

            // All-day lane.
            allDayLane(for: week)

            // Scrollable hour grid.
            ScrollView {
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        hourLabels
                        ForEach(week, id: \.self) { day in
                            VStack(spacing: 0) {
                                ForEach(0..<24, id: \.self) { hour in
                                    Rectangle()
                                        .fill(KstColor.paper0)
                                        .frame(height: hourHeight)
                                        .overlay(alignment: .top) {
                                            Rectangle().fill(KstColor.paper3.opacity(0.5)).frame(height: 0.5)
                                        }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .overlay(alignment: .trailing) {
                                Rectangle().fill(KstColor.paper3).frame(width: 0.5)
                            }
                        }
                    }

                    // Event blocks layered on top of the day columns.
                    GeometryReader { geo in
                        let columnWidth = (geo.size.width - 44) / 7
                        ForEach(timedBlocks(in: week), id: \.id) { block in
                            timedBlockView(block, columnWidth: columnWidth)
                        }
                    }
                }
            }
        }
    }

    // MARK: - All-day

    @ViewBuilder
    private func allDayLane(for week: [Date]) -> some View {
        let weekStart = week.first ?? anchor
        let weekEnd = week.last ?? anchor
        let visible = events.filter { ev in
            ev.isAllDay && ev.start <= weekEnd && (ev.end ?? ev.start) >= weekStart
        }
        if !visible.isEmpty {
            HStack(spacing: 0) {
                Spacer().frame(width: 44)
                ForEach(week, id: \.self) { day in
                    VStack(spacing: 2) {
                        ForEach(visible.filter { CalendarEventBuilder.event($0, intersects: day) }, id: \.id) { ev in
                            Button { onOpen(ev) } label: {
                                Text(ev.title)
                                    .font(.kstText(size: 10))
                                    .foregroundStyle(accent.ink)
                                    .padding(.horizontal, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(1)
                                    .frame(height: 14)
                                    .background(accent.soft)
                                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .top)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
            }
            .background(KstColor.paper1.opacity(0.5))
            .overlay(alignment: .bottom) { KstHairline() }
        }
    }

    // MARK: - Timed blocks

    private struct TimedBlock: Identifiable {
        let id: String
        let event: CalendarEvent
        let columnIndex: Int
        let topOffset: CGFloat
        let height: CGFloat
    }

    private func timedBlocks(in week: [Date]) -> [TimedBlock] {
        var result: [TimedBlock] = []
        let timed = events.filter { !$0.isAllDay }
        for (col, day) in week.enumerated() {
            for ev in timed where CalendarEventBuilder.event(ev, intersects: day) {
                guard let block = block(for: ev, on: day, columnIndex: col) else { continue }
                result.append(block)
            }
        }
        return result
    }

    private func block(for event: CalendarEvent, on day: Date, columnIndex: Int) -> TimedBlock? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = event.timezone
        let dayStart = calendar.startOfDay(for: day)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        // Clip start/end to the day in event-local time.
        let visibleStart = max(event.start, dayStart)
        let visibleEnd = min(event.end ?? event.start, nextDay)
        guard visibleStart < visibleEnd else { return nil }

        let startHour = calendar.dateComponents([.hour, .minute], from: visibleStart)
        let endHour = calendar.dateComponents([.hour, .minute], from: visibleEnd)
        let startFraction = CGFloat(startHour.hour ?? 0) + CGFloat(startHour.minute ?? 0) / 60
        let endFraction = CGFloat(endHour.hour ?? 0) + CGFloat(endHour.minute ?? 0) / 60
        let height = max(14, (endFraction - startFraction) * hourHeight)

        return TimedBlock(
            id: "\(event.id).\(columnIndex)",
            event: event,
            columnIndex: columnIndex,
            topOffset: startFraction * hourHeight,
            height: height
        )
    }

    private func timedBlockView(_ block: TimedBlock, columnWidth: CGFloat) -> some View {
        Button { onOpen(block.event) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(block.event.title)
                    .font(.kstText(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(timeRangeLabel(for: block.event))
                    .font(.kstText(size: 10))
                    .foregroundStyle(accent.ink.opacity(0.8))
                    .lineLimit(1)
            }
            .foregroundStyle(accent.ink)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(width: columnWidth - 4, height: block.height, alignment: .topLeading)
            .background(accent.soft)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(accent.base.opacity(0.4), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .buttonStyle(.plain)
        .offset(x: 44 + columnWidth * CGFloat(block.columnIndex) + 2,
                y: block.topOffset)
    }

    // MARK: - Helpers

    private var hourLabels: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(hour == 0 ? "" : "\(hour):00")
                    .font(.kstText(size: 10))
                    .foregroundStyle(KstColor.ink3)
                    .frame(width: 44, height: hourHeight, alignment: .topTrailing)
                    .padding(.trailing, 4)
            }
        }
    }

    private func weekdayLabel(_ day: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: day).uppercased()
    }

    private func dayLabel(_ day: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f.string(from: day)
    }

    private func timeRangeLabel(for event: CalendarEvent) -> String {
        let f = DateFormatter()
        f.timeZone = event.timezone
        f.dateStyle = .none
        f.timeStyle = .short
        let s = f.string(from: event.start)
        if let end = event.end { return "\(s) – \(f.string(from: end))" }
        return s
    }
}
