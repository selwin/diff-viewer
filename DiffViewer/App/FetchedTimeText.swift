import Foundation

/// How long ago a fetch was, as the branch picker's header says it.
enum FetchedTimeText {
    /// Under a minute is "just now" (a clock that moved backwards too), under an hour is
    /// minutes, under a day is hours, and anything older is the date.
    static func make(at date: Date, now: Date, timeZone: TimeZone = .current) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) min ago" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3600)) h ago" }
        let formatter = DateFormatter()
        // Fixed, like the English words around it.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }
}
