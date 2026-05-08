import SwiftUI

/// Side-by-side mini-month + agenda list. Mini-month shows event-density
/// dots per day; agenda lists upcoming events from `anchor` forward,
/// grouped by day. Tapping a day on the mini-month scrolls the agenda
/// to that day.
struct CalendarCompactView: View {
    @Binding var anchor: Date
    let events: [CalendarEvent]
    let accent: AccentTone
    let onOpen: (CalendarEvent) -> Void

    private let agendaWindow: Int = 21

    var body: some View {
        HStack(spacing: 0) {
            miniMonth
                .frame(width: 280)
                .padding(16)
                .background(KstColor.paper1)

            Divider()

            agenda
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Mini-month

    private var miniMonth: some View {
        let grid = CalendarLayout.monthGrid(for: anchor)
        let weekColumns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        let monthOfAnchor = Calendar.current.component(.month, from: anchor)

        return VStack(alignment: .leading, spacing: 8) {
            Text(CalendarLayout.monthLabel(for: anchor))
                .font(.kstText(size: 13, weight: .semibold))
                .foregroundStyle(KstColor.ink0)

            LazyVGrid(columns: weekColumns, spacing: 4) {
                ForEach(orderedShortWeekdays(), id: \.self) { sym in
                    Text(sym)
                        .font(.kstText(size: 10, weight: .semibold))
                        .foregroundStyle(KstColor.ink3)
                        .frame(maxWidth: .infinity)
                }
                ForEach(grid, id: \.self) { day in
                    Button { anchor = day } label: {
                        VStack(spacing: 1) {
                            Text(dayNumber(day))
                                .font(.kstText(size: 11, weight: isToday(day) ? .bold : .regular))
                                .foregroundStyle(numberColor(day, monthOfAnchor: monthOfAnchor))
                            Circle()
                                .fill(eventDensityColor(for: day))
                                .frame(width: 4, height: 4)
                        }
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(Calendar.current.isDate(day, inSameDayAs: anchor) ? accent.soft : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Agenda

    private var agenda: some View {
        let groups = upcomingGroups()
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if groups.isEmpty {
                    Text("No upcoming events")
                        .font(.kstText(size: 12))
                        .foregroundStyle(KstColor.ink3)
                        .padding(.top, 16)
                }
                ForEach(groups, id: \.day) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(agendaDayLabel(group.day))
                            .font(.kstText(size: 11, weight: .semibold))
                            .foregroundStyle(KstColor.ink3)
                            .textCase(.uppercase)
                            .tracking(0.5)
                        ForEach(group.events) { ev in
                            Button { onOpen(ev) } label: {
                                HStack(alignment: .center, spacing: 8) {
                                    Rectangle()
                                        .fill(accent.base)
                                        .frame(width: 3)
                                        .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ev.title)
                                            .font(.kstText(size: 13, weight: .medium))
                                            .foregroundStyle(KstColor.ink0)
                                            .lineLimit(1)
                                        if let label = timeLabel(for: ev) {
                                            Text(label)
                                                .font(.kstText(size: 11))
                                                .foregroundStyle(KstColor.ink3)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 8)
                                .background(KstColor.paper0)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Helpers

    private struct AgendaGroup {
        let day: Date
        let events: [CalendarEvent]
    }

    private func upcomingGroups() -> [AgendaGroup] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: anchor)
        var groups: [AgendaGroup] = []
        for offset in 0..<agendaWindow {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            let onDay = events.filter { CalendarEventBuilder.event($0, intersects: day) }
                              .sorted { $0.start < $1.start }
            if !onDay.isEmpty { groups.append(AgendaGroup(day: day, events: onDay)) }
        }
        return groups
    }

    private func orderedShortWeekdays() -> [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private func eventDensityColor(for day: Date) -> Color {
        let count = events.filter { CalendarEventBuilder.event($0, intersects: day) }.count
        switch count {
        case 0: return Color.clear
        case 1: return accent.base.opacity(0.5)
        default: return accent.base
        }
    }

    private func dayNumber(_ day: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f.string(from: day)
    }

    private func isToday(_ day: Date) -> Bool {
        Calendar.current.isDateInToday(day)
    }

    private func numberColor(_ day: Date, monthOfAnchor: Int) -> Color {
        if isToday(day) { return KstColor.cerulean }
        return Calendar.current.component(.month, from: day) == monthOfAnchor ? KstColor.ink0 : KstColor.ink3
    }

    private func agendaDayLabel(_ day: Date) -> String {
        let f = DateFormatter()
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInTomorrow(day) { return "Tomorrow" }
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: day)
    }

    private func timeLabel(for event: CalendarEvent) -> String? {
        if event.isAllDay { return nil }
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
