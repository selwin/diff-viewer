import Foundation
import FoundationModels

/// Produces a commit message for a staged patch, streamed as it grows. `WindowState`
/// holds one; tests substitute a stub.
protocol CommitMessageGenerator: Sendable {
    /// Nil when generation can run; otherwise a one-line reason for the button's help.
    var unavailableReason: String? { get }
    /// Each element is the whole message so far, not a delta.
    func generate(_ request: CommitMessagePrompt.Request) -> AsyncThrowingStream<String, any Error>
}

/// The real generator: Apple's on-device model, streamed straight into the draft. A
/// fresh session is created for each attempt.
struct FoundationModelsCommitMessageGenerator: CommitMessageGenerator {
    /// Short enough for a button's help tag; each one names what the reader can do next.
    var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case let .unavailable(reason):
            switch reason {
            case .deviceNotEligible: return "This Mac does not support Apple Intelligence"
            case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings"
            case .modelNotReady: return "The Apple Intelligence model is still downloading"
            @unknown default: return "Apple Intelligence is unavailable"
            }
        }
    }

    /// A response cap keeps the message short; a low temperature keeps it close to what
    /// the patch says.
    private static let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: 400)

    func generate(_ request: CommitMessagePrompt.Request) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let model = SystemLanguageModel.default
                let characterBudget = CommitMessagePrompt.characterBudget(contextSize: model.contextSize)
                do {
                    do {
                        try await stream(request, characterBudget: characterBudget, into: continuation)
                    } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                        // Retry with half the stat-and-patch character budget. The
                        // estimate was optimistic: the text cost more tokens than assumed.
                        try await stream(request, characterBudget: characterBudget / 2, into: continuation)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: CommitMessageGenerationError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One attempt: a fresh session, and every snapshot cleaned before it reaches the draft.
    private func stream(
        _ request: CommitMessagePrompt.Request, characterBudget: Int,
        into continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) async throws {
        let session = LanguageModelSession(instructions: CommitMessagePrompt.instructions)
        let prompt = CommitMessagePrompt.prompt(for: request, characterBudget: characterBudget)
        for try await snapshot in session.streamResponse(to: prompt, options: Self.options) {
            try Task.checkCancellation()
            continuation.yield(CommitMessagePrompt.cleaned(snapshot.content))
        }
    }
}

/// What the sheet shows when generation fails: a sentence a reader can act on, rather
/// than the framework's own wording.
struct CommitMessageGenerationError: LocalizedError {
    let underlying: any Error

    init(_ underlying: any Error) {
        self.underlying = underlying
    }

    var errorDescription: String? {
        guard let generation = underlying as? LanguageModelSession.GenerationError else {
            return underlying.localizedDescription
        }
        switch generation {
        case .guardrailViolation, .refusal:
            return "The model declined to describe this change"
        // The retry at half the budget did not fit either.
        case .exceededContextWindowSize:
            return "The staged changes are too large to summarize"
        default:
            return generation.localizedDescription
        }
    }
}
