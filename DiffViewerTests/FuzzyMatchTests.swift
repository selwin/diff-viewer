import Foundation
import Testing

@testable import DiffViewer

struct FuzzyMatchTests {
    /// Matched ranges as integer character offsets, so expectations read as positions.
    private func offsets(_ match: FuzzyMatch?, in name: String) -> [Range<Int>] {
        let offset = { name.distance(from: name.startIndex, to: $0) }
        return (match?.ranges ?? []).map { offset($0.lowerBound)..<offset($0.upperBound) }
    }

    @Test func nonSubsequenceIsNil() {
        #expect(FuzzyMatch.match("xyz", in: "feature/fix-deps") == nil)
        #expect(FuzzyMatch.match("spedfix", in: "feature/fix-deps") == nil)
    }

    @Test func matchingIgnoresCase() {
        #expect(FuzzyMatch.match("FIX", in: "feature/fix-deps") != nil)
        #expect(FuzzyMatch.match("fix", in: "Feature/FIX-deps") != nil)
    }

    @Test func normalizedRemovesWhitespace() {
        #expect(FuzzyMatch.normalized(" fix deps\t") == "fixdeps")
        #expect(FuzzyMatch.normalized("   ") == "")
    }

    @Test func contiguousOutranksScattered() throws {
        let contiguous = try #require(FuzzyMatch.match("abc", in: "xabcx"))
        let scattered = try #require(FuzzyMatch.match("abc", in: "xaxbxcx"))
        #expect(contiguous.score > scattered.score)
    }

    @Test func wordStartsOutrankMidWordHits() throws {
        let boundaries = try #require(FuzzyMatch.match("fdr", in: "feature/discount-rules"))
        let midWord = try #require(FuzzyMatch.match("fdr", in: "fooddrawer"))
        #expect(boundaries.score > midWord.score)
    }

    @Test func rangesFollowTheBestAlignmentAsOneRun() throws {
        let name = "feature/fix-deps"
        let match = try #require(FuzzyMatch.match("fix", in: name))
        #expect(match.ranges.count == 1)
        #expect(String(name[match.ranges[0]]) == "fix")
    }

    @Test func rangesStayOnTheOriginalUnicodeName() throws {
        let name = "fix/Été-banner"
        let match = try #require(FuzzyMatch.match("é", in: name))
        #expect(match.ranges.count == 1)
        #expect(String(name[match.ranges[0]]) == "É")
    }

    @Test func equalScoresPickTheEarliestRun() {
        let name = "ab-ab"
        #expect(offsets(FuzzyMatch.match("ab", in: name), in: name) == [0..<2])
    }

    @Test func equalScoresPickTheEarliestFirstPosition() {
        // [0, 17]: 2×16 + 12 (start) + 12 (after "-") − 16 (gap) = 40
        // [11, 12]: 2×16 + 8 (run) = 40
        // The crossings lose: [0, 12] = 32 + 12 − 11 = 33, [11, 17] = 32 + 12 − 5 = 39.
        let name = "a" + String(repeating: "x", count: 10) + "ab" + "xxx" + "-b"
        let match = FuzzyMatch.match("ab", in: name)
        #expect(match?.score == 40)
        #expect(offsets(match, in: name) == [0..<1, 17..<18])
    }
}
