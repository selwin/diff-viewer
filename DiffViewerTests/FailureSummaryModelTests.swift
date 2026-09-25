import Foundation
import Testing
import os

@testable import DiffViewer

/// The alert's summary state: what each summarizer outcome publishes, and that a closed
/// alert publishes nothing.
@MainActor
@Suite struct FailureSummaryModelTests {
    private let output = "git commit exited with status 1: Sources/a.swift:3: error: line too long"
    private var fallback: FailureSummaryModel.State {
        .fallback(CommitFailurePrompt.fallback(for: output))
    }

    @Test func unavailableSummarizerFallsBackWithoutLoading() async {
        let stub = StubSummarizer(.returns("Unused."), isAvailable: false)
        let model = FailureSummaryModel(output: output, summarizer: stub)
        #expect(model.state == fallback)
        await model.run()
        #expect(model.state == fallback)
        #expect(stub.calls == 0)
    }

    @Test func summaryIsPublished() async {
        let model = FailureSummaryModel(output: output, summarizer: StubSummarizer(.returns("SwiftLint failed.")))
        #expect(model.state == .loading)
        await model.run()
        #expect(model.state == .ready("SwiftLint failed."))
    }

    @Test func errorFallsBack() async {
        let model = FailureSummaryModel(output: output, summarizer: StubSummarizer(.fails))
        await model.run()
        #expect(model.state == fallback)
    }

    /// The deadline holds even when generation ignores cancellation, and the late result
    /// is dropped.
    @Test func timeoutFallsBackBeforeAStubbornGenerationEnds() async {
        let stub = StubSummarizer(.ignoresCancellation(for: .milliseconds(300), then: "Too late."))
        let model = FailureSummaryModel(output: output, summarizer: stub, timeout: .milliseconds(10))
        await model.run()
        #expect(model.state == fallback)
        #expect(!stub.hasFinished)
        #expect(await eventually { stub.hasFinished })
        #expect(model.state == fallback)
    }

    /// The alert closing mid-generation.
    @Test func cancelStopsGenerationAndPublishesNothing() async {
        let stub = StubSummarizer(.waitsForCancellation)
        let model = FailureSummaryModel(output: output, summarizer: stub)
        let run = Task { await model.run() }
        #expect(await eventually { stub.calls == 1 })
        model.cancel()
        await run.value
        #expect(model.state == .loading)
        #expect(stub.wasCancelled)
    }

    /// The view's task ending mid-generation.
    @Test func cancellingTheRunCancelsGeneration() async {
        let stub = StubSummarizer(.waitsForCancellation)
        let model = FailureSummaryModel(output: output, summarizer: stub)
        let run = Task { await model.run() }
        #expect(await eventually { stub.calls == 1 })
        run.cancel()
        await run.value
        #expect(model.state == .loading)
        #expect(stub.wasCancelled)
    }

    /// The race ends, then the alert closes before `run` resumes to publish the result.
    @Test func cancelAfterTheRaceEndsPublishesNothing() async {
        let stub = StubSummarizer(.returnsWhenReleased("SwiftLint failed."))
        let model = FailureSummaryModel(output: output, summarizer: stub)
        let run = Task { await model.run() }
        #expect(await eventually { stub.calls == 1 })
        // No suspension from here to `cancel()`, so `run` cannot resume on the main actor
        // while the released generation ends the race.
        stub.release()
        // Only the generation task's `finish` separates the stub's return from the race's
        // end; the margin after it covers that.
        while !stub.hasFinished { usleep(1_000) }
        usleep(50_000)
        model.cancel()
        await run.value
        #expect(model.state == .loading)
    }

    /// Cancelled before the race has started anything: it returns without waiting for the
    /// deadline, and any generation that did start is cancelled.
    @Test func cancellingRightAwayReturnsPromptly() async {
        let stub = StubSummarizer(.waitsForCancellation)
        let model = FailureSummaryModel(output: output, summarizer: stub)
        let run = Task { await model.run() }
        run.cancel()
        await run.value
        #expect(model.state == .loading)
        #expect(stub.calls <= 1)
        #expect(stub.calls == 0 || stub.wasCancelled)
    }
}

/// A summarizer that does what the test says and records what happened to it.
private final class StubSummarizer: CommitFailureSummarizer {
    enum Behavior {
        case returns(String)
        case fails
        /// Holds until cancelled, then throws.
        case waitsForCancellation
        /// Holds until `release()`, then returns `text`.
        case returnsWhenReleased(String)
        /// Runs for `duration` whatever happens, then returns `text`.
        case ignoresCancellation(for: Duration, then: String)
    }

    private struct Record {
        var calls = 0
        var wasCancelled = false
        var hasFinished = false
        var held: CheckedContinuation<Void, Never>?
    }

    private struct StubError: Error {}

    let isAvailable: Bool
    private let behavior: Behavior
    private let record = OSAllocatedUnfairLock(initialState: Record())

    init(_ behavior: Behavior, isAvailable: Bool = true) {
        self.behavior = behavior
        self.isAvailable = isAvailable
    }

    var calls: Int { record.withLock { $0.calls } }
    var wasCancelled: Bool { record.withLock { $0.wasCancelled } }
    var hasFinished: Bool { record.withLock { $0.hasFinished } }

    func summary(of output: String) async throws -> String {
        switch behavior {
        case let .returns(text):
            record.withLock { $0.calls += 1 }
            return text
        case .fails:
            record.withLock { $0.calls += 1 }
            throw StubError()
        case .waitsForCancellation:
            await waitForCancellation()
            throw CancellationError()
        case let .returnsWhenReleased(text):
            await withCheckedContinuation { continuation in
                record.withLock { record in
                    record.calls += 1
                    record.held = continuation
                }
            }
            record.withLock { $0.hasFinished = true }
            return text
        case let .ignoresCancellation(duration, text):
            record.withLock { $0.calls += 1 }
            // A detached sleep does not see this task's cancellation.
            await Task.detached { try? await Task.sleep(for: duration) }.value
            record.withLock { $0.hasFinished = true }
            return text
        }
    }

    func release() {
        record.withLock { record in
            defer { record.held = nil }
            return record.held
        }?.resume()
    }

    /// Counts the call and holds it until cancelled; a call that starts already cancelled
    /// returns at once, so it can only ever be recorded as cancelled.
    private func waitForCancellation() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let cancelled = record.withLock { record in
                    record.calls += 1
                    if !record.wasCancelled { record.held = continuation }
                    return record.wasCancelled
                }
                if cancelled { continuation.resume() }
            }
        } onCancel: {
            let held = record.withLock { record in
                record.wasCancelled = true
                defer { record.held = nil }
                return record.held
            }
            held?.resume()
        }
    }
}
