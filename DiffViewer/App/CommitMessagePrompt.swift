import Foundation

/// The text handed to the on-device model, and the cleanup of what comes back. Pure and
/// free of any model API so the wording and the truncation can be tested on their own.
enum CommitMessagePrompt {
    /// System instructions: the model's job and the shape of its answer.
    static let instructions = """
        You write git commit messages. Reply with the commit message only: no preamble, \
        no explanation, no markdown headings, no code fences, no surrounding quotes.

        The first line is a summary in the imperative mood ("Add", "Fix", "Rename"), \
        at most 72 characters, capitalized, with no trailing period. When more is worth \
        saying, follow it with a blank line and a short body of plain sentences or "-" \
        bullets that says what changed and why, wrapped at 72 columns. Leave the body out \
        when the summary already says everything.

        Describe the change as a whole rather than file by file, unless the files are \
        unrelated to each other.
        """

    /// One generation's input: the staged changes, recent subjects as style examples, the
    /// reader's own note (why), and the branch name (what the work is for). Nil leaves a
    /// section out.
    struct Request: Sendable, Equatable {
        var patchWithStat: String
        var recentSubjects: [String]
        var draftNote: String?
        var branch: String?
    }

    /// At most this many recent subjects, each clipped to this many characters. They are
    /// style examples, so a long tail is not worth its tokens.
    private static let subjectLimit = 8
    private static let subjectCharacterLimit = 80
    /// A note is a hint about intent; past this it starts crowding out the patch.
    private static let draftNoteCharacterLimit = 500
    /// Branch names that say nothing about the work and invite "Update main".
    private static let uninformativeBranches: Set<String> = ["main", "master", "trunk", "develop"]

    /// Splits `git diff --patch-with-stat` output at the first `diff --git` line: the stat
    /// is everything before it, the patch everything from it on. No such line → all stat.
    static func split(_ patchWithStat: String) -> (stat: String, patch: String) {
        guard let start = firstDiffHeader(in: patchWithStat) else { return (patchWithStat, "") }
        return (String(patchWithStat[..<start]), String(patchWithStat[start...]))
    }

    /// Whether there is a patch to describe: a `diff --git` line with non-whitespace text
    /// after it. Cheaper than `split`, which copies both halves.
    static func hasPatch(_ patchWithStat: String) -> Bool {
        guard let start = firstDiffHeader(in: patchWithStat) else { return false }
        return patchWithStat[start...].contains { !$0.isWhitespace }
    }

    /// Where the first line beginning with `diff --git` starts.
    private static func firstDiffHeader(in text: String) -> String.Index? {
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(where: \.isNewline) ?? text.endIndex
            if text[lineStart..<lineEnd].hasPrefix("diff --git") { return lineStart }
            guard lineEnd < text.endIndex else { break }
            lineStart = text.index(after: lineEnd)
        }
        return nil
    }

    /// The user prompt: style examples, the branch, the reader's note, then the stat and
    /// the patch, which share `characterBudget` characters. The stat gets up to a quarter
    /// and the patch the rest; each ends with a marker line when cut. An absent note or
    /// branch is not mentioned at all: the model fills any slot it is told about.
    static func prompt(for request: Request, characterBudget: Int) -> String {
        let (stat, patch) = split(request.patchWithStat)
        var sections: [String] = []
        let subjects = request.recentSubjects.prefix(subjectLimit).map { String($0.prefix(subjectCharacterLimit)) }
        if !subjects.isEmpty {
            // Spelled out as style only: given a bare list, the model reads the subjects
            // as part of the change and writes about them.
            let heading = """
                Recent commit subjects in this repository, for style:
                (they describe earlier work, not the change below)
                """
            sections.append(([heading] + subjects).joined(separator: "\n"))
        }
        if let branch = request.branch, !uninformativeBranches.contains(branch) {
            sections.append(
                """
                The branch this commit goes on, for context about the work:
                \(branch)
                (it names the ongoing work, not the change below)
                """)
        }
        let note = request.draftNote.map { String($0.prefix(draftNoteCharacterLimit)) }
        if let note {
            sections.append("The author's note about this change, in their own words:\n\(note)")
        }
        let statText = truncated(stat, budget: characterBudget / 4, marker: "[stat truncated]")
        sections.append("The staged changes to describe:\n\n\(statText)")
        sections.append(truncated(patch, budget: characterBudget - statText.count, marker: "[patch truncated]"))
        if note == nil {
            sections.append("Write the commit message for these changes.")
        } else {
            sections.append(
                """
                Write the commit message for these changes. Take the intent from the author's \
                note and the facts from the patch; say nothing the patch does not show.
                """)
        }
        return sections.joined(separator: "\n\n")
    }

    /// `text` cut to `budget` characters on a line boundary, plus a `marker` line when
    /// anything was dropped. The marker is not counted, so a cut result can exceed the
    /// budget slightly. Whole lines only: half a hunk line reads as a change that isn't
    /// there. Stops at the budget, so a huge patch is never scanned in full.
    static func truncated(_ text: String, budget: Int, marker: String) -> String {
        var lineStart = text.startIndex
        var used = 0
        while lineStart < text.endIndex {
            // Look one character past the remaining budget: a newline in reach means the
            // line fits; none means it does not, and the rest of it is never scanned.
            let limit = text.index(lineStart, offsetBy: budget - used + 1, limitedBy: text.endIndex) ?? text.endIndex
            guard let lineEnd = text[lineStart..<limit].firstIndex(where: \.isNewline) else {
                // No newline in reach: the last line, which costs only its characters, or
                // a line too long to keep.
                guard limit == text.endIndex, used + text.distance(from: lineStart, to: limit) <= budget else {
                    return String(text[..<lineStart]) + marker
                }
                break
            }
            let cost = text.distance(from: lineStart, to: lineEnd) + 1  // the newline that rejoins it
            guard used + cost <= budget else { return String(text[..<lineStart]) + marker }
            used += cost
            lineStart = text.index(after: lineEnd)
        }
        return text
    }

    /// Strips what a model wraps around a message it was asked for bare: a code fence, a
    /// "Commit message:" label on the first line, trailing spaces, and blank edges.
    static func cleaned(_ output: String) -> String {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0).replacingOccurrences(of: "[ \t]+$", with: "", options: .regularExpression)
        }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        // An opening fence may carry a language tag; the closing one is absent while the
        // answer is still streaming.
        if lines.first?.hasPrefix("```") == true {
            lines.removeFirst()
            if lines.last?.hasPrefix("```") == true { lines.removeLast() }
        }
        if let first = lines.first, let stripped = withoutLabel(first) {
            lines[0] = stripped
        }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Labels a model prefixes the message with. Matched case-insensitively at the start
    /// of the first line only, so a colon inside a real summary survives.
    private static let labels = ["commit message:", "commit msg:", "message:", "subject:"]

    /// `line` without its leading label, or nil when it has none.
    private static func withoutLabel(_ line: String) -> String? {
        let lowered = line.lowercased()
        guard let label = labels.first(where: { lowered.hasPrefix($0) }) else { return nil }
        return String(line.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
    }

    /// How many characters the stat and the patch have between them for a model with
    /// `contextSize` tokens: roughly three characters per token, less about 1000 tokens
    /// for the instructions, the subjects, and the reply.
    static func characterBudget(contextSize: Int) -> Int {
        max(2_000, (contextSize - 1_000) * 3)
    }
}
