import Foundation
import Testing

@testable import DiffViewer

/// Everything one assembler run published, in order.
private actor PublicationLog {
    private(set) var documents: [ChangesetAssembler.Publication] = []

    func append(_ publication: ChangesetAssembler.Publication) { documents.append(publication) }

    var count: Int { documents.count }

    var isEmpty: Bool { documents.isEmpty }

    var lastDocument: ChangesetDocument? { documents.last?.document }
}

/// A highlighter that colours one language, records what it was asked for, and can be
/// held open on a file the way the stub client holds a worktree read.
actor HighlighterProbe {
    private(set) var fileNames: [String] = []
    /// Files whose highlighting suspends until the test releases them.
    private var heldNames: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Suspends highlighting of each file, so a worker can be pinned inside its build.
    func hold(_ names: Set<String>) { heldNames.formUnion(names) }

    func release(_ name: String) {
        heldNames.remove(name)
        for continuation in waiters.removeValue(forKey: name) ?? [] { continuation.resume() }
    }

    /// Every line gets one run, so a coloured section is obvious in the snapshot.
    nonisolated func callback() -> @Sendable ([String], String) async -> [[StyleRun]]? {
        { [self] lines, fileName in
            await record(fileName)
            guard fileName.hasSuffix(".swift") else { return nil }
            return lines.map { _ in [StyleRun(range: 0..<1, style: .keyword)] }
        }
    }

    private func record(_ fileName: String) async {
        fileNames.append(fileName)
        guard heldNames.contains(fileName) else { return }
        await withCheckedContinuation { waiters[fileName, default: []].append($0) }
    }
}

/// A cache whose difft always fails, so every file falls back to the plain line diff.
/// The assembler's job is ordering and publication, not difft.
private func plainCache() -> DifftCache {
    DifftCache(runner: { _, _, _, _ in throw ProcessError.failed(command: "difft", status: 1, stderr: "no difft") })
}

private func files(_ names: [String]) -> [ChangedFile] {
    names.map { changedFile($0) }
}

struct ChangesetAssemblerTests {
    private func assemble(
        _ names: [String],
        client: StubRepoClient,
        clock: ManualClock = ManualClock(),
        highlighter: HighlighterProbe = HighlighterProbe(),
        cache: DifftCache = plainCache(),
        resultCache: DiffResultCache = DiffResultCache()
    ) -> (assembler: ChangesetAssembler, log: PublicationLog, run: () -> Task<Void, Never>) {
        let log = PublicationLog()
        let assembler = ChangesetAssembler(
            files: files(names), client: client, hideWhitespace: true, cache: cache, resultCache: resultCache,
            clock: clock, highlight: highlighter.callback())
        return (assembler, log, { Task { await assembler.run { await log.append($0) } } })
    }

    /// The append-only invariant in full: `later` must be `earlier` with sections added
    /// at the end, so the container can keep the rows, lines and caches it already has.
    private func expectPrefix(_ earlier: ChangesetDocument, of later: ChangesetDocument) {
        #expect(later.sections.count >= earlier.sections.count)
        #expect(Array(later.document.rows.prefix(earlier.document.rows.count)) == earlier.document.rows)
        #expect(later.document.rows.count >= earlier.document.rows.count)
        #expect(Array(later.document.oldLines.prefix(earlier.document.oldLines.count)) == earlier.document.oldLines)
        #expect(later.document.oldLines.count >= earlier.document.oldLines.count)
        #expect(Array(later.document.newLines.prefix(earlier.document.newLines.count)) == earlier.document.newLines)
        #expect(later.document.newLines.count >= earlier.document.newLines.count)
        for (before, after) in zip(earlier.sections, later.sections) {
            #expect(before.file.id == after.file.id)
            #expect(before.rowRange == after.rowRange)
            #expect(before.oldLineOffset == after.oldLineOffset)
            #expect(before.newLineOffset == after.newLineOffset)
            #expect(before.oldLineCount == after.oldLineCount)
            #expect(before.newLineCount == after.newLineCount)
        }
    }

    /// Every document publication must be able to colour the document it ships with.
    private func expectMatchingStyles(_ document: ChangesetDocument, _ styles: DocumentStyles) {
        #expect(styles.documentID == document.document.id)
        #expect(styles.revision == document.revision)
        #expect(styles.old?.count == document.document.oldLines.count)
        #expect(styles.new?.count == document.document.newLines.count)
    }

    // MARK: Ordering

    /// Files finish in whatever order git and difft take, but only the contiguous
    /// completed prefix is ever published.
    @Test func nothingIsPublishedUntilThePrefixGrows() async {
        let client = StubRepoClient(files: [])
        await client.hold(worktree: ["a.swift"])
        let (assembler, log, run) = assemble(["a.swift", "b.swift", "c.swift"], client: client)
        let task = run()

        #expect(await eventually { await assembler.completedCount == 2 }, "b and c are recorded")
        #expect(await log.isEmpty, "a completed section behind an unfinished one publishes nothing")

        await client.release(worktree: "a.swift")
        await task.value
        let documents = await log.documents
        #expect(documents.count == 1)
        #expect(documents[0].document.revision == 1)
        #expect(documents[0].document.sections.map(\.file.path) == ["a.swift", "b.swift", "c.swift"])
        #expect(documents[0].completed == 3)
        #expect(documents[0].total == 3)
    }

    /// Every revision is the previous one plus sections appended at the end, down to the
    /// rows, the lines and each section's offsets.
    @Test func revisionsOnlyAppend() async {
        let client = StubRepoClient(files: [])
        await client.hold(worktree: ["b.swift", "d.swift"])
        let clock = ManualClock()
        let (assembler, log, run) = assemble(
            ["a.swift", "b.swift", "c.swift", "d.swift"], client: client, clock: clock)
        let task = run()

        #expect(await eventually { await log.documents.count == 1 })
        let first = await log.documents[0].document
        #expect(first.sections.map(\.file.path) == ["a.swift"], "the held file stops the prefix")

        // The second revision is flushed at the deadline, the third when the group drains.
        #expect(await eventually { clock.sleeperCount == 1 })
        await client.release(worktree: "b.swift")
        #expect(await eventually { await assembler.completedCount == 3 })
        clock.advance(by: .milliseconds(150))
        #expect(await eventually { await log.documents.count == 2 })

        await client.release(worktree: "d.swift")
        await task.value
        let documents = await log.documents
        #expect(documents.count == 3)
        let last = documents[2].document
        #expect(last.loadID == first.loadID)
        #expect(documents.map(\.document.revision) == [1, 2, 3])
        #expect(documents[1].document.sections.map(\.file.path) == ["a.swift", "b.swift", "c.swift"])
        #expect(last.sections.map(\.file.path) == ["a.swift", "b.swift", "c.swift", "d.swift"])
        for (earlier, later) in zip(documents, documents.dropFirst()) {
            expectPrefix(earlier.document, of: later.document)
        }
        for document in documents { expectMatchingStyles(document.document, document.styles) }
    }

    // MARK: Failures and limits

    @Test func aFirstFileThatCannotBeReadBecomesANoticeAndTheRestStillArrive() async {
        let client = StubRepoClient(files: [])
        await client.fail(worktree: ["a.swift"])
        let (_, log, run) = assemble(["a.swift", "b.swift"], client: client)
        await run().value

        let document = await log.lastDocument
        #expect(document?.sections.count == 2)
        guard case let .failed(message)? = document?.sections.first?.outcome else {
            Issue.record("the unreadable file must be a failed section")
            return
        }
        #expect(message.contains("permission denied"))
        #expect(document?.sections.first?.rowRange.isEmpty == true)
        if case .text = document?.sections.last?.outcome {
        } else {
            Issue.record("the file after the failure is diffed as usual")
        }
    }

    /// The byte cap is a computation limit: the read has happened, but nothing after it.
    @Test func anOversizedFileIsNeitherDiffedNorHighlighted() async {
        let client = StubRepoClient(files: [])
        await client.set(
            worktree: Data(repeating: 65, count: ChangesetLimits.maxSourceBytesPerFile + 1), for: "big.swift")
        let highlighter = HighlighterProbe()
        let (_, log, run) = assemble(["big.swift", "small.swift"], client: client, highlighter: highlighter)
        await run().value

        let document = await log.lastDocument
        #expect(document?.sections.first?.outcome == .tooLarge)
        #expect(document?.sections.first?.rowRange.isEmpty == true)
        // Two calls per file, one per side, so the set is what matters.
        #expect(await eventually { await Set(highlighter.fileNames) == ["small.swift"] }, "the big file is skipped")
    }

    /// The file cap is applied in sidebar order before anything is read, so completion
    /// order cannot change which files a changeset holds.
    @Test func filesPastTheCapAreNeverRead() async {
        let names = (0..<(ChangesetLimits.maxFiles + 5)).map { "f\($0).txt" }
        let client = StubRepoClient(files: [])
        let (_, log, run) = assemble(names, client: client)
        await run().value

        let document = await log.lastDocument
        #expect(document?.sections.count == names.count)
        let past = document?.sections.suffix(5) ?? []
        #expect(past.allSatisfy { $0.outcome == .notShown })
        #expect(past.map(\.file.path) == Array(names.suffix(5)))
        let read = Set(await client.readPaths)
        #expect(read.isDisjoint(with: Set(names.suffix(5))), "a file past the cap is never read")
        #expect(read.contains(names[0]))
    }

    // MARK: Cadence

    /// A section that completes inside the throttle window goes out when the window ends,
    /// without waiting for the worker that is still busy.
    @Test func aSectionCompletingInsideTheWindowIsPublishedAtTheDeadline() async {
        let client = StubRepoClient(files: [])
        await client.hold(worktree: ["b.swift", "d.swift"])
        let clock = ManualClock()
        let (assembler, log, run) = assemble(
            ["a.swift", "b.swift", "c.swift", "d.swift"], client: client, clock: clock)
        let task = run()

        #expect(await eventually { await log.documents.count == 1 }, "the first section publishes at once")
        #expect(await eventually { clock.sleeperCount == 1 }, "and starts the throttle window")

        // The second file finishes inside the window: it is recorded, but the
        // publication is deferred.
        await client.release(worktree: "b.swift")
        #expect(await eventually { await assembler.completedCount == 3 })
        #expect(await log.documents.count == 1, "still inside the window")

        clock.advance(by: .milliseconds(150))
        #expect(await eventually { await log.documents.count == 2 })
        #expect(await log.documents[1].document.sections.map(\.file.path) == ["a.swift", "b.swift", "c.swift"])
        #expect(await client.waitingWorktreePaths.contains("d.swift"), "and a worker is still busy")

        await client.release(worktree: "d.swift")
        await task.value
        #expect(await log.lastDocument?.sections.count == 4)
    }

    /// Cancelling must stop the pending flush at the moment of cancellation, not when the
    /// workers come back: one of them is still inside a git read here, so the task group
    /// stays open and the flush would otherwise have time to expire and publish.
    @Test func cancellationWithAPendingFlushPublishesNothingFurther() async {
        let client = StubRepoClient(files: [])
        await client.hold(worktree: ["b.swift", "c.swift"])
        let clock = ManualClock()
        let (assembler, log, run) = assemble(["a.swift", "b.swift", "c.swift"], client: client, clock: clock)
        let task = run()

        #expect(await eventually { await log.documents.count == 1 })
        #expect(await eventually { clock.sleeperCount == 1 })
        // A second section completes inside the window, so a flush is waiting to go out.
        await client.release(worktree: "b.swift")
        #expect(await eventually { await assembler.completedCount == 2 })
        let published = await log.count
        #expect(published == 1)

        task.cancel()
        // The window ends while the third file's read is still held, so the run task has
        // not returned and the assembler is very much alive.
        clock.advance(by: .seconds(1))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await client.waitingWorktreePaths.contains("c.swift"), "a worker is still inside git")
        #expect(await log.count == published, "the flush must not fire after the cancellation")

        await client.releaseAllWorktreeHolds()
        await task.value
        #expect(await log.count == published, "and nothing goes out when the workers return either")
    }

    /// A worker is occupied until its file's highlighting is done, so the bound on files
    /// being read covers the whole pipeline rather than just the diff.
    @Test func aWorkerKeepsItsSlotThroughHighlighting() async {
        let names = (0..<6).map { "f\($0).swift" }
        let held = Set(names.prefix(3))
        let client = StubRepoClient(files: [])
        let highlighter = HighlighterProbe()
        await highlighter.hold(held)
        let (_, log, run) = assemble(names, client: client, highlighter: highlighter)
        let task = run()

        #expect(await eventually { await Set(client.readPaths) == held })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await Set(client.readPaths) == held, "a worker inside highlighting takes no new file")

        await highlighter.release(names[0])
        #expect(await eventually { await client.readPaths.contains(names[3]) }, "and frees it when released")

        for name in held { await highlighter.release(name) }
        await task.value
        #expect(await log.lastDocument?.sections.count == 6)
    }

    /// Three files are read at once, never more: the worker holds its slot through
    /// highlighting, so that bound covers the whole pipeline.
    @Test func neverMoreThanThreeFilesAreReadAtOnce() async {
        let names = (0..<6).map { "f\($0).swift" }
        let client = StubRepoClient(files: [])
        await client.hold(worktree: Set(names))
        let (_, log, run) = assemble(names, client: client)
        let task = run()

        #expect(await eventually { await client.waitingWorktreePaths.count == 3 })
        #expect(await client.peakInFlightReads == 3)

        await client.releaseAllWorktreeHolds()
        await task.value
        #expect(await client.peakInFlightReads == 3, "and the remaining files wait their turn")
        #expect(await log.lastDocument?.sections.count == 6)
    }

    // MARK: Styles

    /// A file with no highlighting still needs its lines counted, or every later file's
    /// colours would land on the wrong rows.
    @Test func everyLineHasAStyleEntryEvenWithoutAHighlighter() async {
        let client = StubRepoClient(files: [])
        let (_, log, run) = assemble(["plain.txt", "code.swift"], client: client)
        await run().value

        guard let document = await log.lastDocument, let styles = await log.documents.last?.styles else {
            Issue.record("nothing was published")
            return
        }
        expectMatchingStyles(document, styles)
        let plain = document.sections[0]
        let code = document.sections[1]
        #expect(plain.newLineCount > 0 && code.newLineCount > 0)
        let plainRuns = (0..<plain.newLineCount).map { styles.new![plain.newLineOffset + $0] }
        #expect(plainRuns.allSatisfy { $0.isEmpty }, "an unsupported language contributes empty runs")
        let codeRuns = (0..<code.newLineCount).map { styles.new![code.newLineOffset + $0] }
        #expect(codeRuns.allSatisfy { !$0.isEmpty }, "and a supported one keeps its colours")
    }

    /// Styles that finish before their section joins the prefix must ride out with it.
    @Test func stylesFinishedEarlyAppearWithTheirSection() async {
        let client = StubRepoClient(files: [])
        await client.hold(worktree: ["a.swift"])
        let (assembler, log, run) = assemble(["a.swift", "b.swift"], client: client)
        let task = run()

        #expect(await eventually { await assembler.completedCount == 1 })
        #expect(await log.isEmpty)

        await client.release(worktree: "a.swift")
        await task.value
        guard let first = await log.documents.first else {
            Issue.record("nothing was published")
            return
        }
        expectMatchingStyles(first.document, first.styles)
        let b = first.document.sections[1]
        let runs = (0..<b.newLineCount).map { first.styles.new![b.newLineOffset + $0] }
        #expect(runs.allSatisfy { !$0.isEmpty }, "the early styles are in the first revision that holds the section")
    }

    /// A section appended after the first publication ships a snapshot that fits the new
    /// document, whether or not it brought colours of its own.
    @Test func anAppendedSectionStillGetsAMatchingSnapshot() async {
        let client = StubRepoClient(files: [])
        await client.hold(worktree: ["b.txt"])
        let (_, log, run) = assemble(["a.swift", "b.txt"], client: client)
        let task = run()

        #expect(await eventually { await log.documents.count == 1 })
        await client.release(worktree: "b.txt")
        await task.value

        let documents = await log.documents
        #expect(documents.count == 2)
        for document in documents { expectMatchingStyles(document.document, document.styles) }
        #expect(documents[1].document.sections.count == 2)
    }

    // MARK: Result cache

    /// A second load of the same files against one result store neither diffs nor
    /// highlights again, and still publishes a fully styled document.
    @Test func aSecondLoadOfTheSameFilesIsServedFromTheResultCache() async {
        let names = ["a.swift", "b.swift", "c.swift"]
        let probe = RunnerProbe()
        let cache = DifftCache(runner: { old, new, fileName, qos in
            try await probe.run(old: old, new: new, fileName: fileName, qualityOfService: qos)
        })
        let resultCache = DiffResultCache()
        let highlighter = HighlighterProbe()

        let first = assemble(
            names, client: StubRepoClient(files: []), highlighter: highlighter, cache: cache, resultCache: resultCache)
        await first.run().value
        let launches = await probe.launches.count
        let highlights = await highlighter.fileNames.count
        #expect(launches == 3)
        #expect(highlights == 6, "two sides per file")

        let second = assemble(
            names, client: StubRepoClient(files: []), highlighter: highlighter, cache: cache, resultCache: resultCache)
        await second.run().value
        #expect(await probe.launches.count == launches, "difft did not run again")
        #expect(await highlighter.fileNames.count == highlights, "nor did the highlighter")

        guard let last = await second.log.documents.last else {
            Issue.record("nothing was published")
            return
        }
        expectMatchingStyles(last.document, last.styles)
        #expect(last.document.sections.count == 3)
        #expect(last.styles.new?.allSatisfy { !$0.isEmpty } == true, "every line keeps its colours")
    }
}
