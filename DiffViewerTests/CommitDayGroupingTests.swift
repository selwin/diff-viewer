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

    /// A local London time; `offset` picks the earlier or later reading of an ambiguous one.
    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, offset: Int? = nil)
        -> Date
    {
        var calendar = calendar
        calendar.timeZone = timeZone
        var components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        if let offset { components.timeZone = TimeZone(secondsFromGMT: offset) }
        return calendar.date(from: components)!
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, offset: Int? = nil) -> Date {
        Self.date(year, month, day, hour, minute, offset: offset)
    }

    // MARK: Day labels

    @Test func todayYesterdayAndWeekdayTitles() {
        #expect(grouping.dayLabel(for: date(2026, 9, 19, 9, 0)).title == "Today")
        #expect(grouping.dayLabel(for: date(2026, 9, 18, 23, 59)).title == "Yesterday")
        #expect(grouping.dayLabel(for: date(2026, 9, 17, 12, 0)).title == "Thursday")
    }

    @Test func subtitleIsDayAndMonthWithTheYearOnlyWhenItDiffers() {
        #expect(grouping.dayLabel(for: date(2026, 9, 19, 9, 0)).subtitle == "19 Sep")
        #expect(grouping.dayLabel(for: date(2025, 9, 18, 9, 0)).subtitle == "18 Sep 2025")
    }

    /// Days are cut at local midnight, not by 24-hour distance from now.
    @Test func midnightSeparatesYesterdayFromToday() {
        let lateYesterday = date(2026, 9, 18, 23, 59)
        let earlyToday = date(2026, 9, 19, 0, 0)
        #expect(grouping.dayLabel(for: lateYesterday).title == "Yesterday")
        #expect(grouping.dayLabel(for: earlyToday).title == "Today")
        #expect(grouping.gutterLabels(for: [earlyToday, lateYesterday]).compactMap { $0 }.count == 2)
    }

    // MARK: Gutter labels

    @Test func oneLabelPerRunOfSameDayDates() {
        let labels = grouping.gutterLabels(for: [
            date(2026, 9, 19, 13, 0), date(2026, 9, 19, 12, 0), date(2026, 9, 19, 11, 0),
            date(2026, 9, 18, 10, 0),
        ])
        #expect(labels.map { $0?.title } == ["Today", nil, nil, "Yesterday"])
    }

    /// Git's order is kept: a day that reappears gets a label again rather than being
    /// merged into its earlier run.
    @Test func outOfOrderDatesKeepTheirOwnLabels() {
        let labels = grouping.gutterLabels(for: [
            date(2026, 9, 19, 13, 0), date(2026, 9, 18, 12, 0), date(2026, 9, 19, 11, 0),
        ])
        #expect(labels.map { $0?.title } == ["Today", "Yesterday", "Today"])
    }

    /// 25 October 2026 is when London leaves BST: 01:30 happens twice, and both readings
    /// belong to the same day. The run boundary stays at midnight.
    @Test func runBoundaryAcrossTheAutumnClockChange() {
        let bst = date(2026, 10, 25, 1, 30, offset: 3600)
        let gmt = date(2026, 10, 25, 1, 30, offset: 0)
        #expect(gmt.timeIntervalSince(bst) == 3600)
        #expect(grouping.gutterLabels(for: [gmt, bst]).compactMap { $0 }.count == 1)

        let beforeMidnight = date(2026, 10, 24, 23, 30)
        let afterMidnight = date(2026, 10, 25, 0, 30)
        #expect(grouping.gutterLabels(for: [afterMidnight, beforeMidnight]).compactMap { $0 }.count == 2)
    }

    @Test func emptyInputYieldsNoLabels() {
        #expect(grouping.gutterLabels(for: []).isEmpty)
    }

    // MARK: Date and time text

    @Test func dateTimeTextForms() {
        #expect(grouping.dateTimeText(for: date(2026, 9, 19, 14, 2)) == "Today at 14:02")
        #expect(grouping.dateTimeText(for: date(2026, 9, 18, 9, 10)) == "Yesterday at 09:10")
        #expect(grouping.dateTimeText(for: date(2025, 9, 18, 14, 2)) == "18 Sep 2025 at 14:02")
        #expect(grouping.dateTimeText(for: date(2026, 9, 17, 14, 2)) == "17 Sep 2026 at 14:02")
    }
}
