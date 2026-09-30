import Foundation
import Testing

@testable import DiffViewer

struct FetchedTimeTextTests {
    private let now = Date(timeIntervalSince1970: 1_789_300_000)  // 2026-09-13 11:46:40 UTC
    private let utc = TimeZone(identifier: "UTC")!

    private func text(secondsAgo: TimeInterval) -> String {
        FetchedTimeText.make(at: now - secondsAgo, now: now, timeZone: utc)
    }

    @Test(arguments: [
        (secondsAgo: 0, expected: "just now"),
        (secondsAgo: 59, expected: "just now"),
        (secondsAgo: -30, expected: "just now"),  // A clock that moved backwards.
        (secondsAgo: 60, expected: "1 min ago"),
        (secondsAgo: 119, expected: "1 min ago"),
        (secondsAgo: 3_599, expected: "59 min ago"),
        (secondsAgo: 3_600, expected: "1 h ago"),
        (secondsAgo: 86_399, expected: "23 h ago"),
        (secondsAgo: 86_400, expected: "12 Sep"),
        (secondsAgo: 40 * 86_400, expected: "4 Aug"),
    ])
    func theTextGrowsFromJustNowToTheDate(secondsAgo: Int, expected: String) {
        #expect(text(secondsAgo: TimeInterval(secondsAgo)) == expected)
    }
}
