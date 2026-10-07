import Foundation
import Testing

@testable import DiffViewer

/// London, Gregorian, en_US, with "now" pinned to Saturday 19 September 2026 at 14:02.
struct CommitDayGroupingTests {
    private static let calendar = Calendar(identifier: .gregorian)
    private static let timeZone = TimeZone(identifier: "Europe/London")!
    private static let locale = Locale(identifier: "en_US")

    private let grouping: CommitDayGrouping

    init() {
        grouping = CommitDayGrouping(
            calendar: Self.calendar, locale: Self.locale, timeZone: Self.timeZone,
            now: Self.date(2026, 9, 19, 14, 2))
    }

    /// A local London time.
    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = calendar
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Self.date(year, month, day, hour, minute)
    }

    // MARK: Commit row dates

    @Test func commitDateTextForms() {
        #expect(grouping.commitDateText(for: date(2026, 9, 19, 14, 2)) == "Today 14:02")
        #expect(grouping.commitDateText(for: date(2026, 9, 20, 9, 0)) == "Today 09:00", "a date after now")
        #expect(grouping.commitDateText(for: date(2026, 9, 18, 17, 40)) == "Yesterday 17:40")
        #expect(grouping.commitDateText(for: date(2026, 9, 17, 9, 0)) == "Thu 17 Sep")
        #expect(grouping.commitDateText(for: date(2026, 9, 13, 9, 0)) == "Sun 13 Sep")
        #expect(grouping.commitDateText(for: date(2026, 9, 12, 23, 59)) == "12 Sep")
        #expect(grouping.commitDateText(for: date(2025, 9, 18, 9, 0)) == "18 Sep 2025")
    }

    /// Only a date outside the current year carries it, even within the last week.
    @Test func commitDateTextAcrossNewYear() {
        let newYear = CommitDayGrouping(
            calendar: Self.calendar, locale: Self.locale, timeZone: Self.timeZone, now: date(2027, 1, 2, 10, 0))
        #expect(newYear.commitDateText(for: date(2027, 1, 1, 8, 30)) == "Yesterday 08:30")
        #expect(newYear.commitDateText(for: date(2026, 12, 31, 17, 40)) == "Thu 31 Dec 2026")
        #expect(newYear.commitDateText(for: date(2026, 12, 20, 9, 0)) == "20 Dec 2026")
    }

    // MARK: Branch groups

    /// Sections are cut at local midnight: 2 to 6 days ago is this week.
    @Test func recencyGroupBoundaries() {
        #expect(grouping.recencyGroup(for: date(2026, 9, 19, 0, 0)) == .today)
        #expect(grouping.recencyGroup(for: date(2026, 9, 20, 9, 0)) == .today, "a tip dated after now")
        #expect(grouping.recencyGroup(for: date(2026, 9, 18, 23, 59)) == .yesterday)
        #expect(grouping.recencyGroup(for: date(2026, 9, 18, 0, 0)) == .yesterday)
        #expect(grouping.recencyGroup(for: date(2026, 9, 17, 23, 59)) == .thisWeek)
        #expect(grouping.recencyGroup(for: date(2026, 9, 13, 0, 0)) == .thisWeek)
        #expect(grouping.recencyGroup(for: date(2026, 9, 12, 23, 59)) == .older)
    }

    @Test func rowTimeTextForms() {
        #expect(grouping.rowTimeText(for: date(2026, 9, 19, 9, 5)) == "09:05")
        #expect(grouping.rowTimeText(for: date(2026, 9, 18, 21, 40)) == "21:40")
        #expect(grouping.rowTimeText(for: date(2026, 9, 15, 9, 0)) == "Tue")
        #expect(grouping.rowTimeText(for: date(2026, 9, 12, 9, 0)) == "12 Sep")
        #expect(grouping.rowTimeText(for: date(2025, 12, 30, 9, 0)) == "30 Dec 2025")
    }
}
