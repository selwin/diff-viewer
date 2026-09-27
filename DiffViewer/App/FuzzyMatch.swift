import Foundation

/// A fuzzy match of a search query against one name, with the characters to emphasize.
struct FuzzyMatch: Equatable {
    let score: Int
    /// Ranges in the original candidate string to emphasize.
    let ranges: [Range<String.Index>]

    // Runs and word starts beat scattered mid-word hits.
    private static let matchScore = 16
    private static let runBonus = 8
    private static let boundaryBonus = 12
    private static let gapPenalty = 1

    /// The one form of the field text every search decision uses: whitespace removed.
    static func normalized(_ query: String) -> String {
        query.filter { !$0.isWhitespace }
    }

    /// Nil when `query` (already normalized, non-empty) is not a case-insensitive
    /// subsequence of `candidate`.
    static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        let needle = Array(query)
        let name = Array(candidate)
        guard !needle.isEmpty, needle.count <= name.count else { return nil }
        let scores = suffixScores(needle, name)
        guard let best = scores[0].compactMap({ $0 }).max() else { return nil }
        let positions = earliestAlignment(scores, best: best, name: name)
        return FuzzyMatch(score: best, ranges: runs(of: positions, in: candidate))
    }

    /// `scores[i][j]` is the best score for matching `needle[i...]` with `needle[i]` at
    /// `name[j]`, or nil when that is impossible.
    private static func suffixScores(_ needle: [Character], _ name: [Character]) -> [[Int?]] {
        var scores = [[Int?]](repeating: [Int?](repeating: nil, count: name.count), count: needle.count)
        for i in stride(from: needle.count - 1, through: 0, by: -1) {
            let isLast = i == needle.count - 1
            // Best of scores[i + 1][j'] for j' >= j + 2, already charged for the gap to j.
            var bestLater: Int?
            for j in stride(from: name.count - 1, through: 0, by: -1) {
                let next: Int? = isLast || j + 1 == name.count ? nil : scores[i + 1][j + 1]
                if matches(needle[i], name[j]) {
                    if isLast {
                        scores[i][j] = charScore(at: j, in: name)
                    } else if let tail = larger(next.map { $0 + runBonus }, bestLater) {
                        scores[i][j] = charScore(at: j, in: name) + tail
                    }
                }
                if !isLast, let widened = larger(bestLater, next) {
                    bestLater = widened - gapPenalty
                }
            }
        }
        return scores
    }

    /// Walks forward taking the smallest position that still reaches `best`, so ties go to
    /// the lexicographically earliest alignment.
    private static func earliestAlignment(_ scores: [[Int?]], best: Int, name: [Character]) -> [Int] {
        var position = scores[0].firstIndex { $0 == best }!
        var positions = [position]
        var remaining = best
        for i in 1..<scores.count {
            remaining -= charScore(at: position, in: name)
            let from = position
            position = (from + 1..<name.count).first { j in
                guard let tail = scores[i][j] else { return false }
                return transition(from: from, to: j) + tail == remaining
            }!
            remaining -= transition(from: from, to: position)
            positions.append(position)
        }
        return positions
    }

    private static func transition(from j: Int, to next: Int) -> Int {
        next == j + 1 ? runBonus : -(next - j - 1) * gapPenalty
    }

    private static func charScore(at j: Int, in name: [Character]) -> Int {
        matchScore + (isWordStart(j, in: name) ? boundaryBonus : 0)
    }

    private static func isWordStart(_ j: Int, in name: [Character]) -> Bool {
        guard j > 0 else { return true }
        let previous = name[j - 1]
        if "/-_.".contains(previous) { return true }
        return previous.isLowercase && name[j].isUppercase
    }

    private static func matches(_ a: Character, _ b: Character) -> Bool {
        String(a).caseInsensitiveCompare(String(b)) == .orderedSame
    }

    private static func larger(_ a: Int?, _ b: Int?) -> Int? {
        guard let a else { return b }
        guard let b else { return a }
        return max(a, b)
    }

    /// One range per contiguous run of matched positions, on `candidate`'s own indices.
    private static func runs(of positions: [Int], in candidate: String) -> [Range<String.Index>] {
        let indices = Array(candidate.indices)
        var ranges: [Range<String.Index>] = []
        var start = positions[0]
        var end = start
        for position in positions.dropFirst() {
            if position == end + 1 {
                end = position
            } else {
                ranges.append(indices[start]..<candidate.index(after: indices[end]))
                start = position
                end = position
            }
        }
        ranges.append(indices[start]..<candidate.index(after: indices[end]))
        return ranges
    }
}
