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

    @Test func longSubtitleIsClipped() {
        let line = "a.swift:1: error: " + String(repeating: "x", count: 200)
        let subtitle = CommitFailurePrompt.fallback(for: "git commit exited with status 1: \(line)")
        #expect(subtitle == String(line.prefix(159)) + "…")
        #expect(subtitle.count == 160)
    }
}
