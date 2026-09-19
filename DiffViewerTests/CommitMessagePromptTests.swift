import Foundation
import Testing

@testable import DiffViewer

/// The prompt sent to the model and the cleanup of its answer, checked without a model.
@Suite struct CommitMessagePromptTests {
    /// A stat, then two files' worth of patch: what `--patch-with-stat` prints.
    private let patchWithStat = """
         a.swift | 2 +-
         b.swift | 1 +
         2 files changed, 2 insertions(+), 1 deletion(-)

        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1 +1 @@
        -old
        +new
        diff --git a/b.swift b/b.swift
        --- a/b.swift
        +++ b/b.swift
        @@ -0,0 +1 @@
        +added
        """

    // MARK: Splitting

    @Test func splitSeparatesTheStatFromThePatch() {
        let (stat, patch) = CommitMessagePrompt.split(patchWithStat)
        #expect(stat.hasPrefix(" a.swift | 2 +-"))
        #expect(stat.hasSuffix("\n\n"))
        #expect(patch.hasPrefix("diff --git a/a.swift"))
        #expect(patch.hasSuffix("+added"))
    }

    /// Input without a diff header is treated entirely as stat text.
    @Test func splitWithoutADiffHeaderIsAllStat() {
        let (stat, patch) = CommitMessagePrompt.split(" a.swift | 0\n")
        #expect(stat == " a.swift | 0\n")
        #expect(patch.isEmpty)
    }

    /// A stat with no diff header describes nothing to summarize.
    @Test func hasPatchNeedsADiffHeader() {
        #expect(!CommitMessagePrompt.hasPatch(" a.swift | 0\n\n"))
        #expect(CommitMessagePrompt.hasPatch(patchWithStat))
    }

    // MARK: Truncating

    /// A last line without a newline costs only its characters: it fits a budget of exactly
    /// its length, and a budget one short keeps nothing.
    @Test func truncationKeepsALineThatFillsTheBudget() {
        let line = String(repeating: "x", count: 80)
        #expect(CommitMessagePrompt.truncated(line, budget: 80, marker: "[cut]") == line)
        #expect(CommitMessagePrompt.truncated(line, budget: 79, marker: "[cut]") == "[cut]")
    }

    /// A line far longer than the budget is dropped; the search for its end stops at the
    /// allowance rather than walking the rest.
    @Test func truncationDropsAVeryLongLine() {
        let line = String(repeating: "x", count: 100_000)
        #expect(CommitMessagePrompt.truncated(line, budget: 200, marker: "[cut]") == "[cut]")
    }

    // MARK: Building the prompt

    @Test func promptKeepsTheStatAndThePatchWhenTheyFit() {
        let prompt = CommitMessagePrompt.prompt(
            for: .init(patchWithStat: patchWithStat, recentSubjects: []), characterBudget: 10_000)
        #expect(prompt.contains("2 files changed, 2 insertions(+), 1 deletion(-)"))
        #expect(prompt.contains("+added"))
        #expect(!prompt.contains("[patch truncated]"))
        #expect(!prompt.contains("for style:"))
    }

    /// The stat is the summary of what the cut hides, so it survives whole while it fits
    /// its quarter of the budget; the patch is cut between lines and says so.
    @Test func promptTruncatesOnlyThePatchAndOnALineBoundary() {
        let long = patchWithStat + "\n" + (1...200).map { "+line \($0)" }.joined(separator: "\n")
        let prompt = CommitMessagePrompt.prompt(
            for: .init(patchWithStat: long, recentSubjects: []), characterBudget: 400)
        #expect(prompt.contains("2 files changed, 2 insertions(+), 1 deletion(-)"))
        #expect(!prompt.contains("[stat truncated]"))
        #expect(prompt.hasSuffix("Write the commit message for these changes."))
        #expect(prompt.contains("[patch truncated]"))
        #expect(!prompt.contains("+line 200"), "the tail was dropped")
        // Every kept patch line is whole.
        for line in ["diff --git a/a.swift b/a.swift", "--- a/a.swift"] where prompt.contains(line) {
            #expect(prompt.contains("\(line)\n"))
        }
    }

    /// A stat longer than its quarter is cut on a line boundary too, and the patch still
    /// gets the rest of the budget.
    @Test func promptTruncatesAnOversizedStat() {
        let stat = (1...200).map { " file\($0).swift | 2 +-" }.joined(separator: "\n") + "\n\n"
        let prompt = CommitMessagePrompt.prompt(
            for: .init(patchWithStat: stat + CommitMessagePrompt.split(patchWithStat).patch, recentSubjects: []),
            characterBudget: 400)
        // Five 20-character lines are the whole quarter; the sixth does not fit.
        #expect(prompt.contains(" file5.swift | 2 +-\n[stat truncated]"))
        #expect(!prompt.contains("file6.swift"))
        #expect(prompt.contains("+added"), "the patch still got the rest")
    }

    @Test func promptShowsAtMostEightRecentSubjects() {
        let subjects = (1...12).map { "Subject \($0)" }
        let prompt = CommitMessagePrompt.prompt(
            for: .init(patchWithStat: patchWithStat, recentSubjects: subjects), characterBudget: 10_000)
        #expect(prompt.contains("Recent commit subjects in this repository, for style:"))
        #expect(prompt.contains("Subject 8"))
        #expect(!prompt.contains("Subject 9"))
    }

    /// A subject is there for its style, so only its first 80 characters are worth the room.
    @Test func promptClipsALongRecentSubject() {
        let prompt = CommitMessagePrompt.prompt(
            for: .init(patchWithStat: patchWithStat, recentSubjects: [String(repeating: "x", count: 200)]),
            characterBudget: 10_000)
        #expect(prompt.contains(String(repeating: "x", count: 80)))
        #expect(!prompt.contains(String(repeating: "x", count: 81)))
    }

    // MARK: Cleaning the answer

    @Test func cleanedStripsAFenceALabelAndBlankEdges() {
        let output = """

            ```text
            Commit Message: Add the picker
            \u{20}
            Lets the reader choose a commit.\u{20}\u{20}
            ```

            """
        #expect(CommitMessagePrompt.cleaned(output) == "Add the picker\n\nLets the reader choose a commit.")
    }

    /// A fence opened but not yet closed: the message is still arriving.
    @Test func cleanedStripsAnUnclosedFence() {
        #expect(CommitMessagePrompt.cleaned("```\nAdd the pic") == "Add the pic")
    }

    /// A colon inside a summary is not a label, and a message with neither is untouched.
    @Test func cleanedLeavesAPlainMessageAlone() {
        #expect(CommitMessagePrompt.cleaned("Sidebar: show staged files") == "Sidebar: show staged files")
    }

    // MARK: Budget

    @Test func budgetLeavesRoomForTheRestOfTheContext() {
        #expect(CommitMessagePrompt.characterBudget(contextSize: 8_192) == (8_192 - 1_000) * 3)
        #expect(CommitMessagePrompt.characterBudget(contextSize: 500) == 2_000, "never smaller than the floor")
    }
}
