import Foundation
import Testing

@testable import DiffViewer

struct LineStatsStateTests {
    private let unknownFingerprint = DiffInputFingerprint(
        old: .unknown, new: .notApplicable, worktree: .unknown, kind: .modified, originalPath: nil)

    private func request(
        _ files: [ChangedFile] = [changedFile("a.swift")],
        scope: DiffScope = .workingTree,
        hideWhitespace: Bool = false,
        configurationRevision: Int = 0
    ) -> LineStatsRequest {
        LineStatsRequest(
            scope: scope,
            hideWhitespace: hideWhitespace,
            configurationRevision: configurationRevision,
            inputs: Dictionary(uniqueKeysWithValues: files.map { ($0.id, FileInputIdentity($0.fingerprint)) }))
    }

    private func outcome(_ request: LineStatsRequest, failed: Bool = false) -> LineStatsOutcome {
        LineStatsOutcome(
            request: request,
            results: request.inputs.keys.reduce(into: [:]) { results, id in
                results[id] = failed ? .failed : .available(.counted(added: 1, deleted: 0))
            })
    }

    /// A state whose last outcome answers `request`.
    private func completed(_ request: LineStatsRequest, failed: Bool = false) -> LineStatsState {
        var state = LineStatsState()
        guard case let .start(token, _) = state.decide(desired: request, cause: .initial) else {
            Issue.record("expected a start")
            return state
        }
        let recorded = state.record(outcome(request, failed: failed), token: token)
        #expect(recorded)
        return state
    }

    // MARK: FileInputIdentity

    @Test func identityIsKnownOnlyForKnownFingerprints() {
        #expect(FileInputIdentity(changedFile("a.swift").fingerprint) != .unknown)
        #expect(FileInputIdentity(unknownFingerprint) == .unknown)
        #expect(FileInputIdentity(nil) == .unknown)
    }

    // MARK: decide

    @Test func firstRequestStarts() {
        var state = LineStatsState()
        #expect(state.decide(desired: request(), cause: .initial) == .start(token: 1, cancelActive: false))
        #expect(state.activeRequest?.request == request())
    }

    @Test func equalKnownRequestReusesLastOutcome() {
        var state = completed(request())
        #expect(state.decide(desired: request(), cause: .watcher) == .reuseLastOutcome(cancelActive: false))
        #expect(state.activeRequest == nil)
    }

    @Test func equalActiveRequestIsKept() {
        var state = LineStatsState()
        _ = state.decide(desired: request(), cause: .initial)
        #expect(state.decide(desired: request(), cause: .watcher) == .keepActive)
    }

    @Test func differentRequestWhileActiveStartsAndCancels() {
        var state = LineStatsState()
        _ = state.decide(desired: request(), cause: .initial)
        let edited = request([changedFile("a.swift").edited()])
        #expect(state.decide(desired: edited, cause: .watcher) == .start(token: 2, cancelActive: true))
        #expect(state.activeRequest?.token == 2)
    }

    @Test func returningToCompletedRequestReusesAndInvalidatesActive() {
        // A completed, B running, desired returns to A.
        let a = request()
        let b = request([changedFile("a.swift").edited()])
        var state = completed(a)
        guard case let .start(bToken, _) = state.decide(desired: b, cause: .watcher) else {
            Issue.record("expected B to start")
            return
        }
        #expect(state.decide(desired: a, cause: .watcher) == .reuseLastOutcome(cancelActive: true))
        #expect(state.activeRequest == nil)
        // B's result arrives anyway and must not overwrite A's.
        let recorded = state.record(outcome(b), token: bToken)
        #expect(!recorded)
        #expect(state.lastOutcome == outcome(a))
    }

    /// An unchanged tick must not cancel a ⌘R already running for the same inputs, or
    /// a retry after a failure: an equal active request beats the cached outcome.
    @Test func equalActiveRequestBeatsReusableOutcome() {
        var state = completed(request())
        guard case let .start(manual, _) = state.decide(desired: request(), cause: .manual) else {
            Issue.record("expected the manual refresh to start")
            return
        }
        #expect(state.decide(desired: request(), cause: .watcher) == .keepActive)
        let recorded = state.record(outcome(request()), token: manual)
        #expect(recorded, "the manual read still owns its token")

        var failed = completed(request(), failed: true)
        guard case let .start(retry, _) = failed.decide(desired: request(), cause: .fileAction) else {
            Issue.record("expected the retry to start")
            return
        }
        #expect(failed.decide(desired: request(), cause: .watcher) == .keepActive)
        let retried = failed.record(outcome(request()), token: retry)
        #expect(retried)
        #expect(failed.lastOutcome?.hasFailures == false)
    }

    @Test func unknownInputsNeverReuseButKeepEqualActive() {
        let unknown = request([changedFile("a.swift").with(fingerprint: unknownFingerprint)])
        var state = completed(unknown)
        #expect(!unknown.isKnown)
        #expect(state.decide(desired: unknown, cause: .watcher) == .start(token: 2, cancelActive: false))
        #expect(state.decide(desired: unknown, cause: .watcher) == .keepActive)
    }

    @Test func replacingOneUnknownFileWithAnotherStarts() {
        let first = request([changedFile("a.swift").with(fingerprint: unknownFingerprint)])
        let second = request([changedFile("b.swift").with(fingerprint: unknownFingerprint)])
        var state = LineStatsState()
        _ = state.decide(desired: first, cause: .initial)
        #expect(state.decide(desired: second, cause: .watcher) == .start(token: 2, cancelActive: true))
    }

    @Test func outcomeWithFailuresIsReusedOnlyForWatcherTicks() {
        var state = completed(request(), failed: true)
        #expect(state.decide(desired: request(), cause: .watcher) == .reuseLastOutcome(cancelActive: false))
        #expect(state.decide(desired: request(), cause: .fileAction) == .start(token: 2, cancelActive: false))
    }

    @Test func manualAlwaysStarts() {
        var state = completed(request())
        #expect(state.decide(desired: request(), cause: .manual) == .start(token: 2, cancelActive: false))
        // Even with an equal request already running.
        #expect(state.decide(desired: request(), cause: .manual) == .start(token: 3, cancelActive: true))
    }

    @Test func changedSettingsStart() {
        var state = completed(request())
        #expect(
            state.decide(desired: request(hideWhitespace: true), cause: .settings)
                == .start(token: 2, cancelActive: false))
        #expect(
            state.decide(desired: request(configurationRevision: 1), cause: .settings)
                == .start(token: 3, cancelActive: true))
        let commit = CommitRef(sha: objectID("c1"), shortSha: "c1", firstParentSHA: objectID("c0"))
        let commitFile = changedFile("a.swift", area: .commit(commit))
        #expect(
            state.decide(desired: request([commitFile], scope: .commit(commit)), cause: .scope)
                == .start(token: 4, cancelActive: true))
    }

    // MARK: record

    @Test func recordRejectsStaleTokenAndAcceptsCurrent() {
        var state = LineStatsState()
        guard case let .start(first, _) = state.decide(desired: request(), cause: .initial),
            case let .start(second, _) = state.decide(desired: request(hideWhitespace: true), cause: .settings)
        else {
            Issue.record("expected two starts")
            return
        }
        let stale = state.record(outcome(request()), token: first)
        #expect(!stale)
        #expect(state.lastOutcome == nil)
        #expect(state.activeRequest?.token == second)
        let current = state.record(outcome(request(hideWhitespace: true)), token: second)
        #expect(current)
        #expect(state.lastOutcome?.request == request(hideWhitespace: true))
        #expect(state.activeRequest == nil)
    }

    @Test func invalidateActiveReturnsTokenAndClears() {
        var state = LineStatsState()
        #expect(state.invalidateActive() == nil)
        guard case let .start(token, _) = state.decide(desired: request(), cause: .initial) else {
            Issue.record("expected a start")
            return
        }
        #expect(state.invalidateActive() == token)
        #expect(state.activeRequest == nil)
        let recorded = state.record(outcome(request()), token: token)
        #expect(!recorded)
    }
}
