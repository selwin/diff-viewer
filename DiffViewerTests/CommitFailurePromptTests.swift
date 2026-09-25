import Foundation
import Testing

@testable import DiffViewer

/// Picking the line of a failed commit's output that names the failure.
@Suite struct CommitFailurePromptTests {
    /// What a failing pre-commit run looks like once `ProcessError` has prefixed it: the
    /// first stderr line shares a line with the status, colors and dot leaders included.
    private let preCommitOutput = """
        git commit exited with status 1: [WARNING] Unstaged files detected.
        [INFO] Stashing unstaged files to /tmp/patch.
        trim trailing whitespace.................................................\u{1B}[42mPassed\u{1B}[m
        swiftlint................................................................\u{1B}[41mFailed\u{1B}[m
        - hook id: swiftlint
        - exit code: 2

        Linting Swift files (1/1)
        DiffViewer/App/FindSideLabels.swift:24: error: line too long
        Done linting! Found 1 violation, 1 serious in 1 file.
        [INFO] Restored changes from /tmp/patch.
        """

    // MARK: Cleaning

    @Test func stripsColorAndHyperlinkCodes() {
        let colored = "\u{1B}[1;31merror\u{1B}[0m: \u{1B}]8;;file:///a\u{07}a.swift\u{1B}]8;;\u{07}"
        #expect(CommitFailurePrompt.strippingANSI(colored) == "error: a.swift")
    }

    @Test func collapsesDotLeaders() {
        #expect(CommitFailurePrompt.collapsingDotLeader("swiftlint..........Failed") == "swiftlint: Failed")
        #expect(
            CommitFailurePrompt.collapsingDotLeader("check yaml.....(no files to check)Skipped")
                == "check yaml: (no files to check)Skipped")
    }

    /// Dots that do not lead to a status are ordinary text.
    @Test func leavesOtherDotsAlone() {
        #expect(CommitFailurePrompt.collapsingDotLeader("Linting...") == "Linting...")
        #expect(
            CommitFailurePrompt.collapsingDotLeader("see a.swift...b.swift for 3 errors")
                == "see a.swift...b.swift for 3 errors")
    }

    // MARK: Ranking

    @Test func locationsAndErrorTokensAreSpecific() {
        #expect(CommitFailurePrompt.rank("Sources/a.swift:24:5: warning: long line") == .specific)
        #expect(CommitFailurePrompt.rank("ERROR: commit message too short") == .specific)
        #expect(CommitFailurePrompt.rank("fatal: cannot lock ref") == .specific)
    }

    @Test func bareFailuresAreGeneric() {
        #expect(CommitFailurePrompt.rank("swiftlint: Failed") == .generic)
        #expect(CommitFailurePrompt.rank("push rejected by policy") == .generic)
        #expect(CommitFailurePrompt.rank("✗ lint") == .generic)
    }

    /// Zero counts and passed hooks never count as failures.
    @Test func successSummariesAreNotDiagnostics() {
        #expect(CommitFailurePrompt.rank("Found 0 errors") == nil)
        #expect(CommitFailurePrompt.rank("no errors, 0 failures") == nil)
        #expect(CommitFailurePrompt.rank("check for failed merges: Passed") == nil)
        #expect(CommitFailurePrompt.rank("Linting Swift files") == nil)
    }

    /// A zero count beside a real failure does not hide the failure.
    @Test func failureWithAZeroCountStillRanks() {
        #expect(CommitFailurePrompt.rank("Check failed: 0 errors, 1 warning") == .generic)
        #expect(CommitFailurePrompt.rank("12 passed, 0 failed") == nil)
    }

    /// Word-bounded: an error type's name is not an `error:` token.
    @Test func errorTokenIsWordBounded() {
        #expect(CommitFailurePrompt.rank("LintError: see above") == nil)
    }

    // MARK: Fallback

    /// The file line names the problem; the earlier `swiftlint: Failed` only says one exists.
    @Test func specificLineBeatsEarlierGenericOne() {
        #expect(
            CommitFailurePrompt.fallback(for: preCommitOutput)
                == "DiffViewer/App/FindSideLabels.swift:24: error: line too long")
    }

    @Test func genericLineBeatsNoise() {
        let message = """
            git commit exited with status 1: [WARNING] Unstaged files detected.
            [INFO] Stashing unstaged files.
            swiftlint.....Failed
            """
        #expect(CommitFailurePrompt.failureLine(in: message) == "swiftlint: Failed")
        #expect(CommitFailurePrompt.fallback(for: message) == "swiftlint: Failed")
    }

    /// The prefix is not part of the output, so the first line is judged on its own.
    @Test func firstLineIsRankedWithoutThePrefix() {
        let message = "git commit exited with status 128: fatal: unable to write new index file"
        #expect(CommitFailurePrompt.fallback(for: message) == "fatal: unable to write new index file")
    }

    /// No diagnostic: the first line that is neither noise nor a success summary.
    @Test func firstPlainLineWhenNothingRanks() {
        let message = """
            git commit exited with status 1: [WARNING] Unstaged files detected.
            trim trailing whitespace.....Passed
            Aborting commit: the branch is frozen
            """
        #expect(CommitFailurePrompt.fallback(for: message) == "Aborting commit: the branch is frozen")
    }

    @Test func statusLineIsTheLastResort() {
        let message = """
            git commit exited with status 1: [WARNING] Unstaged files detected.
            [INFO] Restored changes.
            """
        #expect(CommitFailurePrompt.fallback(for: message) == "git commit exited with status 1.")
        #expect(
            CommitFailurePrompt.fallback(for: "git commit exited with status 1") == "git commit exited with status 1.")
    }

    @Test func outputPastTheStatusCounts() {
        #expect(!CommitFailurePrompt.hasOutput("git commit exited with status 1"))
        #expect(!CommitFailurePrompt.hasOutput("git commit exited with status 1: \n  \n"))
        #expect(CommitFailurePrompt.hasOutput("git commit exited with status 1: hook failed"))
    }

    @Test func longSubtitleIsClipped() {
        let line = "a.swift:1: error: " + String(repeating: "x", count: 200)
        let subtitle = CommitFailurePrompt.fallback(for: "git commit exited with status 1: \(line)")
        #expect(subtitle == String(line.prefix(159)) + "…")
        #expect(subtitle.count == 160)
    }

    // MARK: Model input

    /// Short output goes to the model whole, cleaned of colors and dot leaders.
    @Test func inputUnderBudgetIsOnlyCleaned() {
        let output = "swiftlint.....\u{1B}[41mFailed\u{1B}[m\n\na.swift:1: error: too long"
        let expected = "swiftlint: Failed\n\na.swift:1: error: too long"
        #expect(CommitFailurePrompt.input(from: output, budget: 1_000) == expected)
    }

    /// A long run of noise between two failures cannot push either one out.
    @Test func earlyAndLateDiagnosticsSurviveNoise() {
        let noise = (1...500).map { "Compiling module \($0) of 500" }
        let lines =
            ["git commit exited with status 1: [WARNING] Unstaged files detected."]
            + ["Sources/Early.swift:3: error: missing return"] + noise
            + ["Sources/Late.swift:9: error: line too long"] + noise
        let input = CommitFailurePrompt.input(from: lines.joined(separator: "\n"), budget: 1_000)
        #expect(input.count <= 1_000)
        #expect(input.contains("Sources/Early.swift:3: error: missing return"))
        #expect(input.contains("Sources/Late.swift:9: error: line too long"))
        #expect(input.contains("[…]"))
        // Kept lines stay in output order.
        let early = input.range(of: "Early.swift")!.lowerBound
        let late = input.range(of: "Late.swift")!.lowerBound
        #expect(early < late)
    }

    /// A final line too long for the budget is clipped, and the lines before it still fit.
    @Test func overlongLastLineIsClipped() {
        let lines = ["Running policy checks", "Commit blocked by policy", String(repeating: "x", count: 500)]
        let input = CommitFailurePrompt.input(from: lines.joined(separator: "\n"), budget: 200)
        #expect(input == "Running policy checks\nCommit blocked by policy\n" + String(repeating: "x", count: 49) + "…")
    }

    /// Output that is one huge line still reaches the model as that line's start.
    @Test func singleHugeLineKeepsItsStart() {
        let line = "Sources/a.swift:3: error: " + String(repeating: "x", count: 7_000)
        let input = CommitFailurePrompt.input(from: line, budget: 6_000)
        #expect(input.hasPrefix("Sources/a.swift:3: error: xxx"))
        #expect(input.count <= 6_000)
    }

    /// Past the half-budget cap, the first and the last specific lines are kept, and the
    /// generic ones lose out to them.
    @Test func specificEndsBeatGenericLinesAtTheCap() {
        let specific = (1...30).map { String(format: "Sources/File%02d.swift:%02d: error: rule broken", $0, $0) }
        // Longer than a specific line, so no generic one fits where a specific one did not.
        let generic = (1...30).map { "hook \($0) failed with a long complaint about formatting" }
        var lines: [String] = []
        for index in specific.indices {
            lines += [specific[index], "noise", "noise", generic[index], "noise", "noise"]
        }
        lines += (1...100).map { "trailing output line \($0) that says nothing useful" }
        let input = CommitFailurePrompt.input(from: lines.joined(separator: "\n"), budget: 600)
        #expect(input.count <= 600)
        #expect(input.contains(specific[0]))
        #expect(input.contains(specific[29]))
        #expect(!input.contains("failed with a long complaint"))
    }

    // MARK: Cleaning the reply

    @Test func cleanedJoinsLinesAndDropsMarkdown() {
        let reply = "\"**SwiftLint** failed:\n- `a.swift:3` breaks   the line length rule.\""
        #expect(CommitFailurePrompt.cleaned(reply) == "SwiftLint failed: a.swift:3 breaks the line length rule.")
    }

    @Test func cleanedClampsAtASentenceEnd() {
        let reply = "The swiftlint hook failed. " + String(repeating: "More detail follows here. ", count: 10)
        let cleaned = CommitFailurePrompt.cleaned(reply)
        #expect(cleaned.count <= 160)
        #expect(cleaned.hasSuffix("More detail follows here."))
    }

    /// The dot inside a file name is not a sentence end.
    @Test func cleanedNeverClipsInsideAFileName() {
        let words = String(repeating: "word ", count: 25)
        let noSentence = words + "in DiffViewer/App/FindSideLabels.swift:24 is too long for the line length rule"
        #expect(CommitFailurePrompt.cleaned(noSentence) == words + "in…")

        let sentence = "SwiftLint failed on FindSideLabels.swift:24. " + words + words
        #expect(CommitFailurePrompt.cleaned(sentence) == "SwiftLint failed on FindSideLabels.swift:24.")
    }
}
