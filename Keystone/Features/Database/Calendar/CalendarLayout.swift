import Foundation

enum CalendarMode: Sendable, CaseIterable {
    case month, week, day, compact
}

/// Pure date-math helpers for the calendar views. No SwiftUI dependency,
/// so layout rules are easy to unit-test.
enum CalendarLayout {
    /// 42 contiguous days (6 weeks × 7) starting at the locale's first
    /// week-day on or before the 1st of the month containing `month`.
    /// Honors `Calendar.current.firstWeekday` (Sunday in en_US, Monday in
    /// most of Europe).
    static func monthGrid(for month: Date, calendar: Calendar = .current) -> [Date] {
        let cal = calendar
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: month)) ?? month
        let weekday = cal.component(.weekday, from: monthStart)
        let firstWeekday = cal.firstWeekday
        let leadingOffset = ((weekday - firstWeekday) + 7) % 7
        guard let gridStart = cal.date(byAdding: .day, value: -leadingOffset, to: monthStart) else {
            return [monthStart]
        }
        return (0..<42).compactMap { offset in
            cal.date(byAdding: .day, value: offset, to: gridStart)
        }
    }

    /// 7 days starting at the first week-day on or before `anchor`.
    static func week(containing anchor: Date, calendar: Calendar = .current) -> [Date] {
        let cal = calendar
        let weekday = cal.component(.weekday, from: anchor)
        let firstWeekday = cal.firstWeekday
        let leadingOffset = ((weekday - firstWeekday) + 7) % 7
        guard let weekStart = cal.date(byAdding: .day, value: -leadingOffset, to: cal.startOfDay(for: anchor)) else {
            return [anchor]
        }
        return (0..<7).compactMap { offset in
            cal.date(byAdding: .day, value: offset, to: weekStart)
        }
    }

    /// Step the anchor forward (`direction = +1`) or backward (`-1`) by
    /// one unit appropriate to the mode. Compact pages by month, matching
    /// the typical mini-calendar UX.
    static func step(_ anchor: Date, by direction: Int, mode: CalendarMode, calendar: Calendar = .current) -> Date {
        switch mode {
        case .month, .compact:
            return calendar.date(byAdding: .month, value: direction, to: anchor) ?? anchor
        case .week:
            return calendar.date(byAdding: .weekOfYear, value: direction, to: anchor) ?? anchor
        case .day:
            return calendar.date(byAdding: .day, value: direction, to: anchor) ?? anchor
        }
    }

    /// "May 2026" — the header label most modes show.
    static func monthLabel(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "LLLL yyyy"
        return f.string(from: date)
    }

    /// "May 8 – May 14, 2026" — the header label Week mode shows.
    static func weekLabel(for week: [Date]) -> String {
        guard let first = week.first, let last = week.last else { return "" }
        let f = DateFormatter()
        f.dateFormat = "LLL d"
        let yearF = DateFormatter()
        yearF.dateFormat = "yyyy"
        return "\(f.string(from: first)) – \(f.string(from: last)), \(yearF.string(from: last))"
    }

    /// "Friday, May 8, 2026" — the header label Day mode shows.
    static func dayLabel(for day: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        return f.string(from: day)
    }
}
