import Foundation

/// Recency sections, newest first.
enum RecencyGroup: CaseIterable, Sendable {
    case today
    case yesterday
    /// Two to six days ago.
    case thisWeek
    case older

    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .thisWeek: "This week"
        case .older: "Older"
        }
    }
}

/// How the pickers date commits and group them by recency: relative for today and
/// yesterday, by weekday within the week, with the year only when it is not this one.
///
/// Every input is injected so tests can pin the calendar, the zone and "now".
struct CommitDayGrouping {
    private let calendar: Calendar
    /// The presentation time every grouping decision is made against.
    let now: Date
    private let dayMonth: DateFormatter
    private let dayMonthYear: DateFormatter
    private let time: DateFormatter
    private let shortWeekday: DateFormatter
    private let weekdayDayMonth: DateFormatter
    private let weekdayDayMonthYear: DateFormatter

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
        dayMonth = formatter("d MMM")
        dayMonthYear = formatter("d MMM yyyy")
        time = formatter("HH:mm")
        shortWeekday = formatter("EEE")
        weekdayDayMonth = formatter("EEE d MMM")
        weekdayDayMonthYear = formatter("EEE d MMM yyyy")
    }

    /// A tip dated after now counts as today.
    func recencyGroup(for date: Date) -> RecencyGroup {
        switch daysAgo(date) {
        case ...0: .today
        case 1: .yesterday
        case 2...6: .thisWeek
        default: .older
        }
    }

    /// Short enough for a row's subtitle; the section header says which day.
    func rowTimeText(for date: Date) -> String {
        switch recencyGroup(for: date) {
        case .today, .yesterday: return time.string(from: date)
        case .thisWeek: return shortWeekday.string(from: date)
        case .older: return (isInCurrentYear(date) ? dayMonth : dayMonthYear).string(from: date)
        }
    }

    /// A commit's date where no section header names the day, as in the picker's header:
    /// the day and time for today and yesterday, the weekday and date for two to six days
    /// ago, the date after that. The year only outside this one.
    func commitDateText(for date: Date) -> String {
        let sameYear = isInCurrentYear(date)
        switch recencyGroup(for: date) {
        case .today: return "Today \(time.string(from: date))"
        case .yesterday: return "Yesterday \(time.string(from: date))"
        case .thisWeek: return (sameYear ? weekdayDayMonth : weekdayDayMonthYear).string(from: date)
        case .older: return (sameYear ? dayMonth : dayMonthYear).string(from: date)
        }
    }

    private func isInCurrentYear(_ date: Date) -> Bool {
        calendar.component(.year, from: date) == calendar.component(.year, from: now)
    }

    /// Whole local days between `date` and `now`; negative for a date after `now`.
    private func daysAgo(_ date: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day
            ?? 0
    }
}
