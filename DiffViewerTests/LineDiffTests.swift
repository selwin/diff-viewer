import Testing
@testable import DiffViewer

struct LineDiffTests {
    /// Applies ops to `a` and checks they reproduce `b`, and that every op references
    /// its lines in order.
    private func verify(_ a: [String], _ b: [String], expectedEdits: Int? = nil) {
        let ops = LineDiff.diff(a, b)
        var rebuilt: [String] = []
        var edits = 0
        var lastOld = -1, lastNew = -1
        for op in ops {
            switch op {
            case let .equal(o, n):
                #expect(a[o] == b[n])
                #expect(o > lastOld && n > lastNew)
                lastOld = o; lastNew = n
                rebuilt.append(b[n])
            case let .delete(o):
                #expect(o > lastOld)
                lastOld = o
                edits += 1
            case let .insert(n):
                #expect(n > lastNew)
                lastNew = n
                rebuilt.append(b[n])
                edits += 1
            }
        }
        #expect(rebuilt == b)
        if let expectedEdits { #expect(edits == expectedEdits) }
    }

    @Test func identical() { verify(["a", "b", "c"], ["a", "b", "c"], expectedEdits: 0) }
    @Test func empty() { verify([], [], expectedEdits: 0) }
    @Test func allInserted() { verify([], ["a", "b"], expectedEdits: 2) }
    @Test func allDeleted() { verify(["a", "b"], [], expectedEdits: 2) }
    @Test func replaceMiddle() { verify(["a", "b", "c"], ["a", "x", "c"], expectedEdits: 2) }
    @Test func insertMiddle() { verify(["a", "c"], ["a", "b", "c"], expectedEdits: 1) }
    @Test func classicMyersExample() {
        verify(["a", "b", "c", "a", "b", "b", "a"], ["c", "b", "a", "b", "a", "c"], expectedEdits: 5)
    }
    @Test func completelyDifferent() { verify(["a", "b"], ["c", "d"], expectedEdits: 4) }

    @Test func randomizedAgainstLCS() {
        var generator = SplitMix64(seed: 42)
        for _ in 0..<300 {
            let alphabet = ["a", "b", "c", "d"]
            let a = (0..<Int.random(in: 0..<12, using: &generator)).map { _ in
                alphabet.randomElement(using: &generator)!
            }
            let b = (0..<Int.random(in: 0..<12, using: &generator)).map { _ in
                alphabet.randomElement(using: &generator)!
            }
            let expected = a.count + b.count - 2 * lcsLength(a, b)
            verify(a, b, expectedEdits: expected)
        }
    }

    @Test func largeInputIsFast() {
        let a = (0..<20000).map { "line \($0)" }
        var b = a
        for i in stride(from: 0, to: b.count, by: 200) { b[i] += " changed" }
        b.insert(contentsOf: ["x", "y"], at: 5000)
        let start = ContinuousClock.now
        verify(a, b, expectedEdits: 202)
        #expect(ContinuousClock.now - start < .milliseconds(500))
    }

    private func lcsLength(_ a: [String], _ b: [String]) -> Int {
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...max(a.count, 1) where i <= a.count {
            for j in 1...max(b.count, 1) where j <= b.count {
                dp[i][j] = a[i - 1] == b[j - 1] ? dp[i - 1][j - 1] + 1 : max(dp[i - 1][j], dp[i][j - 1])
            }
        }
        return dp[a.count][b.count]
    }
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
