import Foundation
import FoundationModels
import os

/// Writes the Commit Failed alert's one-sentence subtitle from the commit's output. The
/// alert makes one per failure; tests substitute a stub.
protocol CommitFailureSummarizer: Sendable {
    /// False when `summary(of:)` should not be tried, so the alert shows its fallback at once.
    var isAvailable: Bool { get }
    /// A cleaned, non-empty sentence.
    func summary(of output: String) async throws -> String
}

/// The real summarizer: Apple's on-device model (Private Cloud Compute needs a managed
/// entitlement), with a fresh session per summary.
struct FoundationModelsCommitFailureSummarizer: CommitFailureSummarizer {
    /// About 2,000 tokens of output, which leaves the on-device context ample room for the
    /// instructions and the reply.
    static let inputBudget = 6_000

    /// One short sentence, kept close to what the output says.
    private static let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 80)

    /// Whether a generation is still running. The alert's timeout stops waiting but cannot
    /// stop a generation that ignores cancellation, so this keeps repeated failed commits
    /// from piling them up: while one runs, a new alert goes straight to its fallback.
    private static let isGenerating = OSAllocatedUnfairLock(initialState: false)

    private enum Failure: Error {
        case busy
        case emptyReply
    }

    var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available && !Self.isGenerating.withLock { $0 }
    }

    func summary(of output: String) async throws -> String {
        let claimed = Self.isGenerating.withLock { isGenerating in
            defer { isGenerating = true }
            return !isGenerating
        }
        guard claimed else { throw Failure.busy }
        defer { Self.isGenerating.withLock { $0 = false } }

        // Not streamed: the alert reveals the summary all at once.
        let session = LanguageModelSession(instructions: CommitFailurePrompt.instructions)
        let prompt = CommitFailurePrompt.input(from: output, budget: Self.inputBudget)
        let response = try await session.respond(to: prompt, options: Self.options)
        let summary = CommitFailurePrompt.cleaned(response.content)
        guard !summary.isEmpty else { throw Failure.emptyReply }
        return summary
    }
}
