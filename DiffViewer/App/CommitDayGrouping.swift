import Foundation

/// How the commit picker names days: relative for today and yesterday, by weekday
/// after that, with the year only when it is not this one.
///
/// Every input is injected so tests can pin the calendar, the zone and "now".
struct CommitDayGrouping {
    struct DayLabel: Equatable, Sendable {
        let title: String
        let subtitle: String
    }

    private let calendar: Calendar
    private let now: Date
    private let weekday: DateFormatter
    private let dayMonth: DateFormatter
    private let dayMonthYear: DateFormatter
    private let time: DateFormatter

    init(
        calendar: Calendar = .current, locale: Locale = .current, timeZone: TimeZone = .current, now: Date = .now
    ) {
        var calendar = calendar
        calendar.locale = locale
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.now = now
        // Fixed patterns rather than `Date.FormatStyle`, which puts en_US in month-day
        // order and 12-hour time; the names stay localized, the order and clock do not.
        func formatter(_ pattern: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateFormat = pattern
            return formatter
        }
        weekday = formatter("EEEE")
        dayMonth = formatter("d MMM")
        dayMonthYear = formatter("d MMM yyyy")
        time = formatter("HH:mm")
    }

    func dayLabel(for date: Date) -> DayLabel {
        let title =
            switch daysAgo(date) {
            case 0: "Today"
            case 1: "Yesterday"
            default: weekday.string(from: date)
            }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return DayLabel(title: title, subtitle: (sameYear ? dayMonth : dayMonthYear).string(from: date))
    }

    // Group adjacent commits by local day without reordering git's traversal.
    func gutterLabels(for dates: [Date]) -> [DayLabel?] {
        var labels: [DayLabel?] = []
        labels.reserveCapacity(dates.count)
        var previousDay: Date?
        for date in dates {
            let day = calendar.startOfDay(for: date)
            labels.append(day == previousDay ? nil : dayLabel(for: date))
            previousDay = day
        }
        return labels
    }

    func dateTimeText(for date: Date) -> String {
        let day =
            switch daysAgo(date) {
            case 0: "Today"
            case 1: "Yesterday"
            default: dayMonthYear.string(from: date)
            }
        return "\(day) at \(time.string(from: date))"
    }

    /// Whole local days between `date` and `now`; negative for a date after `now`.
    private func daysAgo(_ date: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day
            ?? 0
    }
}
