import Foundation
import Observation
import os

/// The Commit Failed alert's subtitle while the on-device model writes it: loading, the
/// model's summary, or the deterministic fallback when the model is unavailable, fails or
/// runs out of time.
@Observable @MainActor
final class FailureSummaryModel {
    enum State: Equatable {
        case loading
        case ready(String)
        case fallback(String)
    }

    private(set) var state: State

    private let output: String
    private let summarizer: any CommitFailureSummarizer
    /// When the alert gives up and shows the fallback. It does not stop the model: a
    /// generation that ignores cancellation runs, holding its input, until the framework
    /// returns. `FoundationModelsCommitFailureSummarizer` allows one at a time for that reason.
    private let timeout: Duration
    @ObservationIgnored private var race: SummaryRace?
    @ObservationIgnored private var isCancelled = false

    /// Starts at the fallback when the model is unavailable, so no placeholder ever shows.
    init(output: String, summarizer: any CommitFailureSummarizer, timeout: Duration = .seconds(6)) {
        self.output = output
        self.summarizer = summarizer
        self.timeout = timeout
        state = summarizer.isAvailable ? .loading : .fallback(CommitFailurePrompt.fallback(for: output))
    }

    func run() async {
        guard state == .loading, race == nil, !isCancelled else { return }
        let race = SummaryRace()
        self.race = race
        let outcome = await race.run(timeout: timeout) { [summarizer, output] in
            try await summarizer.summary(of: output)
        }
        self.race = nil
        // The race can end just before the alert closes, with this call not yet resumed.
        guard !isCancelled, !Task.isCancelled else { return }
        switch outcome {
        case let .summary(text):
            state = .ready(text)
        case .failed:
            state = .fallback(CommitFailurePrompt.fallback(for: output))
        case .cancelled:
            // The alert is gone; publishing now would only reach a view nobody sees.
            break
        }
    }

    /// Ends the attempt without publishing anything. The alert calls it when it closes,
    /// since the hosting view, whose task would also cancel it, can outlive the alert.
    func cancel() {
        isCancelled = true
        race?.cancel()
    }
}

/// Races a generation against a deadline and reports whichever ends first.
///
/// Not a task group, which waits for every child: a generation that ignores cancellation
/// would hold `run` past its deadline. Instead `run` installs its continuation and starts
/// both tasks inside one critical section, and `finish` sets `finished` and takes the
/// continuation and both handles inside another. So `finish` either runs first, and `run`
/// then starts nothing and returns `.cancelled`, or sees every handle, cancels each one and
/// resumes once. Later calls find `finished` set and do nothing.
private final class SummaryRace: Sendable {
    enum Outcome: Sendable {
        case summary(String)
        /// The generation threw or the deadline passed.
        case failed
        case cancelled
    }

    private struct State {
        var continuation: CheckedContinuation<Outcome, Never>?
        var generation: Task<Void, Never>?
        var timer: Task<Void, Never>?
        var finished = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func run(timeout: Duration, _ operation: @escaping @Sendable () async throws -> String) async -> Outcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.withLock { state in
                    guard !state.finished else {
                        continuation.resume(returning: .cancelled)
                        return
                    }
                    state.continuation = continuation
                    state.generation = Task {
                        do {
                            self.finish(.summary(try await operation()))
                        } catch {
                            self.finish(.failed)
                        }
                    }
                    state.timer = Task {
                        try? await Task.sleep(for: timeout)
                        self.finish(.failed)
                    }
                }
            }
        } onCancel: {
            finish(.cancelled)
        }
    }

    func cancel() {
        finish(.cancelled)
    }

    private func finish(_ outcome: Outcome) {
        let taken: State? = state.withLock { state in
            guard !state.finished else { return nil }
            defer { state = State(finished: true) }
            return state
        }
        guard let taken else { return }
        taken.generation?.cancel()
        taken.timer?.cancel()
        taken.continuation?.resume(returning: outcome)
    }
}
