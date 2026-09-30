import Testing
import os

@testable import DiffViewer

/// Stands in for git: records each name asked about and answers when the test says, so
/// the order of answers and edits is the test's to choose.
@MainActor
private final class HeldCheck {
    private(set) var asked: [String] = []
    private var answers: [String: Bool] = [:]
    private var waiting: [String: CheckedContinuation<Bool, Never>] = [:]

    func check(_ name: String) async -> Bool {
        asked.append(name)
        if let answer = answers.removeValue(forKey: name) { return answer }
        return await withCheckedContinuation { waiting[name] = $0 }
    }

    /// Answers a check already waiting, or the next one for `name`.
    func answer(_ name: String, valid: Bool) {
        if let continuation = waiting.removeValue(forKey: name) {
            continuation.resume(returning: valid)
        } else {
            answers[name] = valid
        }
    }
}

/// A debounce the test controls: each wait announces itself on `arrivals`, then stays
/// suspended until `release()` or until its task is cancelled.
private final class HeldDebounce: Sendable {
    private struct Waiter {
        var continuation: CheckedContinuation<Void, any Error>?
        var cancelled = false
    }

    let arrivals: AsyncStream<Void>
    private let arrived: AsyncStream<Void>.Continuation
    private let waiters = OSAllocatedUnfairLock(initialState: (next: 0, byID: [Int: Waiter]()))

    init() {
        (arrivals, arrived) = AsyncStream.makeStream()
    }

    func wait() async throws {
        let id = waiters.withLock { state in
            state.next += 1
            return state.next
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // A cancellation that landed first has already marked this waiter.
                let cancelled = waiters.withLock { state in
                    if state.byID[id]?.cancelled == true { return true }
                    state.byID[id] = Waiter(continuation: continuation)
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) } else { arrived.yield() }
            }
        } onCancel: {
            let continuation = waiters.withLock { state in
                let continuation = state.byID[id]?.continuation
                state.byID[id] = Waiter(continuation: nil, cancelled: true)
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Ends every wait still suspended.
    func release() {
        let waiting = waiters.withLock { state in
            let waiting = state.byID.values.compactMap(\.continuation)
            state.byID = state.byID.mapValues { Waiter(continuation: nil, cancelled: $0.cancelled) }
            return waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}

@MainActor
struct NewBranchNameValidationTests {
    /// No debounce wait, unless a test passes one: the checks run as soon as the main
    /// actor is free.
    private func model(
        _ held: HeldCheck, existing: Set<String> = ["main"],
        debounce: @escaping @Sendable () async throws -> Void = {}
    ) -> NewBranchNameValidation {
        NewBranchNameValidation(
            exists: { existing.contains($0) }, check: { await held.check($0) }, debounce: debounce)
    }

    /// Blank, option-like and taken names are judged locally, so git is never asked.
    @Test(arguments: [
        (text: "   ", status: NewBranchNameValidation.Status.empty, message: String?.none),
        (text: "-x", status: .invalid, message: "Not a valid branch name"),
        (text: " main ", status: .exists, message: "A branch named main already exists"),
    ])
    func aNameJudgedLocallyNeverAsksGit(text: String, status: NewBranchNameValidation.Status, message: String?) {
        let held = HeldCheck()
        let validation = model(held)

        validation.update(text)

        #expect(validation.status == status)
        #expect(!validation.canCreate)
        #expect(validation.message == message)
        #expect(validation.pendingCheck == nil)
        #expect(held.asked.isEmpty)
    }

    /// Quiet while git is asked; the trimmed name is what it is asked about.
    @Test func gitsAnswerEnablesCreate() async throws {
        let held = HeldCheck()
        let validation = model(held)

        validation.update(" feature/x ")
        #expect(validation.status == .pending)
        #expect(validation.message == nil)
        #expect(!validation.canCreate)

        held.answer("feature/x", valid: true)
        try await #require(validation.pendingCheck).value

        #expect(held.asked == ["feature/x"])
        #expect(validation.canCreate)
        #expect(validation.name == "feature/x")
    }

    /// The answer for "foo" arrives after the field says "foo..": it must not enable
    /// Create for the new text, which gets its own answer.
    @Test func anAnswerForEarlierTextIsIgnored() async throws {
        let held = HeldCheck()
        let validation = model(held)
        validation.update("foo")
        let first = try #require(validation.pendingCheck)
        validation.update("foo..")
        let second = try #require(validation.pendingCheck)

        held.answer("foo", valid: true)
        await first.value
        #expect(validation.status == .pending)
        #expect(!validation.canCreate)

        held.answer("foo..", valid: false)
        await second.value
        #expect(validation.status == .invalid)
        #expect(held.asked == ["foo", "foo.."])
    }

    /// A name typed while the first waits out its debounce cancels that wait, so git hears
    /// only the last one.
    @Test func typingDuringTheDebounceChecksOnlyTheLastName() async throws {
        let held = HeldCheck()
        let debounce = HeldDebounce()
        var arrivals = debounce.arrivals.makeAsyncIterator()
        let validation = model(held) { try await debounce.wait() }
        validation.update("f")
        let first = try #require(validation.pendingCheck)
        await arrivals.next()

        validation.update("fe")
        await first.value
        await arrivals.next()
        held.answer("fe", valid: true)
        debounce.release()
        try await #require(validation.pendingCheck).value

        #expect(held.asked == ["fe"])
        #expect(validation.canCreate)
    }

    /// Another git process creates the name while the sheet is up, then deletes it again.
    @Test func aReReadBranchListRejudgesTheName() async throws {
        let held = HeldCheck()
        var existing: Set<String> = ["main"]
        let validation = NewBranchNameValidation(
            exists: { existing.contains($0) }, check: { await held.check($0) }, debounce: {})
        validation.update("topic")
        held.answer("topic", valid: true)
        try await #require(validation.pendingCheck).value
        #expect(validation.canCreate)

        existing.insert("topic")
        validation.branchesChanged()
        #expect(validation.status == .exists)

        existing.remove("topic")
        validation.branchesChanged()
        #expect(validation.status == .pending)
        held.answer("topic", valid: true)
        try await #require(validation.pendingCheck).value
        #expect(validation.canCreate)
    }

    /// Closing the sheet while the check waits out its debounce: git is never asked.
    @Test func cancellingDuringTheDebounceNeverAsksGit() async throws {
        let held = HeldCheck()
        let debounce = HeldDebounce()
        var arrivals = debounce.arrivals.makeAsyncIterator()
        let validation = model(held) { try await debounce.wait() }
        validation.update("topic")
        let queued = try #require(validation.pendingCheck)
        await arrivals.next()

        validation.cancel()
        await queued.value

        #expect(held.asked.isEmpty)
        #expect(validation.pendingCheck == nil)
    }
}
