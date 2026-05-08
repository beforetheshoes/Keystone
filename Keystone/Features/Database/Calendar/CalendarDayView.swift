import SwiftUI

/// Single-day vertical timeline. Events for the anchor day render as
/// rectangles positioned by event-local hour. All-day events appear in a
/// top lane, same as the Week view.
struct CalendarDayView: View {
    let anchor: Date
    let events: [CalendarEvent]
    let accent: AccentTone
    let onOpen: (CalendarEvent) -> Void

    private let hourHeight: CGFloat = 44
    private let labelWidth: CGFloat = 64

    private var dayEvents: [CalendarEvent] {
        events.filter { CalendarEventBuilder.event($0, intersects: anchor) }
    }

    private var allDayEvents: [CalendarEvent] {
        dayEvents.filter(\.isAllDay)
    }

    private var timedEvents: [CalendarEvent] {
        dayEvents.filter { !$0.isAllDay }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !allDayEvents.isEmpty {
                VStack(spacing: 4) {
                    HStack {
                        Text("All day")
                            .font(.kstText(size: 11, weight: .semibold))
                            .foregroundStyle(KstColor.ink3)
                        Spacer()
                    }
                    ForEach(allDayEvents) { ev in
                        Button { onOpen(ev) } label: {
                            Text(ev.title)
                                .font(.kstText(size: 12, weight: .semibold))
                                .foregroundStyle(accent.ink)
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: 22)
                                .background(accent.soft)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(KstColor.paper1.opacity(0.5))
                .overlay(alignment: .bottom) { KstHairline() }
            }

            ScrollView {
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text(hour == 0 ? "" : "\(hour):00")
                                    .font(.kstText(size: 11))
                                    .foregroundStyle(KstColor.ink3)
                                    .frame(width: labelWidth, height: hourHeight, alignment: .topTrailing)
                                    .padding(.trailing, 6)
                            }
                        }

                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { _ in
                                Rectangle()
                                    .fill(KstColor.paper0)
                                    .frame(height: hourHeight)
                                    .overlay(alignment: .top) {
                                        Rectangle().fill(KstColor.paper3.opacity(0.5)).frame(height: 0.5)
                                    }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }

                    GeometryReader { geo in
                        let columnWidth = geo.size.width - labelWidth
                        ForEach(timedBlocks, id: \.id) { block in
                            timedBlockView(block, columnWidth: columnWidth)
                        }
                    }
                }
            }
        }
    }

    private struct TimedBlock: Identifiable {
        let id: String
        let event: CalendarEvent
        let topOffset: CGFloat
        let height: CGFloat
    }

    private var timedBlocks: [TimedBlock] {
        timedEvents.compactMap { ev in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = ev.timezone
            let dayStart = calendar.startOfDay(for: anchor)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

            let visibleStart = max(ev.start, dayStart)
            let visibleEnd = min(ev.end ?? ev.start, nextDay)
            guard visibleStart < visibleEnd else { return nil }

            let startHour = calendar.dateComponents([.hour, .minute], from: visibleStart)
            let endHour = calendar.dateComponents([.hour, .minute], from: visibleEnd)
            let startFraction = CGFloat(startHour.hour ?? 0) + CGFloat(startHour.minute ?? 0) / 60
            let endFraction = CGFloat(endHour.hour ?? 0) + CGFloat(endHour.minute ?? 0) / 60
            let height = max(20, (endFraction - startFraction) * hourHeight)

            return TimedBlock(
                id: ev.id,
                event: ev,
                topOffset: startFraction * hourHeight,
                height: height
            )
        }
    }

    private func timedBlockView(_ block: TimedBlock, columnWidth: CGFloat) -> some View {
        Button { onOpen(block.event) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(block.event.title)
                    .font(.kstText(size: 13, weight: .semibold))
                Text(timeRangeLabel(for: block.event))
                    .font(.kstText(size: 11))
                    .foregroundStyle(accent.ink.opacity(0.85))
            }
            .foregroundStyle(accent.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: columnWidth - 8, height: block.height, alignment: .topLeading)
            .background(accent.soft)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(accent.base.opacity(0.4), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .offset(x: labelWidth + 4, y: block.topOffset)
    }

    private func timeRangeLabel(for event: CalendarEvent) -> String {
        let f = DateFormatter()
        f.timeZone = event.timezone
        f.dateStyle = .none
        f.timeStyle = .short
        let s = f.string(from: event.start)
        let tzAbbr = event.timezone.abbreviation(for: event.start) ?? ""
        if let end = event.end {
            return "\(s) – \(f.string(from: end)) \(tzAbbr)"
        }
        return "\(s) \(tzAbbr)"
    }
}
