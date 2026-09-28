import Foundation
import Testing

@testable import DiffViewer

struct FetchedTimeTextTests {
    private let now = Date(timeIntervalSince1970: 1_789_300_000)  // 2026-09-13 11:46:40 UTC
    private let utc = TimeZone(identifier: "UTC")!

    private func text(secondsAgo: TimeInterval) -> String {
        FetchedTimeText.make(at: now - secondsAgo, now: now, timeZone: utc)
    }

    @Test func underAMinuteIsJustNow() {
        #expect(text(secondsAgo: 0) == "just now")
        #expect(text(secondsAgo: 59) == "just now")
        #expect(text(secondsAgo: -30) == "just now", "a clock that moved backwards")
    }

    @Test func underAnHourIsWholeMinutes() {
        #expect(text(secondsAgo: 60) == "1 min ago")
        #expect(text(secondsAgo: 119) == "1 min ago")
        #expect(text(secondsAgo: 3599) == "59 min ago")
    }

    @Test func underADayIsWholeHours() {
        #expect(text(secondsAgo: 3600) == "1 h ago")
        #expect(text(secondsAgo: 86_399) == "23 h ago")
    }

    @Test func aDayOrMoreIsTheDate() {
        #expect(text(secondsAgo: 86_400) == "12 Sep")
        #expect(text(secondsAgo: 40 * 86_400) == "4 Aug")
    }
}
