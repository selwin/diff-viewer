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

    /// Every line gets one run, so a coloured section is obvious in the snapshot, and one
    /// scope named after the file spans every line.
    nonisolated func callback() -> DiffEngine.Highlight {
        { [self] lines, fileName in
            await record(fileName)
            guard fileName.hasSuffix(".swift") else { return nil }
            // An empty side has no line to span, so it gets no scope.
            let scopes =
                lines.isEmpty
                ? []
                : [
                    ScopeOutline.Scope(
                        lineRange: 0...(lines.count - 1), name: fileName, parent: nil,
                        claimsFirstLine: true, claimsLastLine: true)
                ]
            return Highlighter.Result(
                runs: lines.map { _ in [StyleRun(range: 0..<1, style: .keyword)] },
                outline: ScopeOutline(scopes: scopes))
        }
    }

    private func record(_ fileName: String) async {
        fileNames.append(fileName)
        guard heldNames.contains(fileName) else { return }
        await withCheckedContinuation { waiters[fileName, default: []].append($0) }
    }
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
        cache: DifftCache = plainDifftCache(),
        resultCache: DiffResultCache = DiffResultCache(),
        publication: ChangesetAssembler.PublicationMode = .progressive
    ) -> (assembler: ChangesetAssembler, log: PublicationLog, run: () -> Task<Void, Never>) {
        let log = PublicationLog()
        let assembler = ChangesetAssembler(
            files: files(names), repository: testRepository, client: client, hideWhitespace: true,
            publication: publication, cache: cache,
            resultCache: resultCache, clock: clock, highlight: highlighter.callback())
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
        // Styles that finished before their section joined the prefix ride out with it.
        expectMatchingStyles(documents[0].document, documents[0].styles)
        let b = documents[0].document.sections[1]
        let runs = (0..<b.newLineCount).map { documents[0].styles.new![b.newLineOffset + $0] }
        #expect(runs.allSatisfy { !$0.isEmpty }, "the early styles are in the first revision that holds the section")
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

    /// A reused result skips the read, so the byte cap applies to the size it recorded.
    @Test func aReusedResultOverTheByteCapIsTooLarge() async {
        let client = StubRepoClient(files: [])
        let resultCache = DiffResultCache()
        let file = changedFile("big.swift")
        guard case let .text(document) = textContent(rows: 1, modified: [0..<1]) else { return }
        let key = DiffResultCache.Key(
            difftKey: DifftCache.key(old: Data(), new: Data("x".utf8), fileName: file.fileName), hideWhitespace: true)
        await resultCache.store(
            DiffResultCache.Entry(
                document: document, styles: SyntaxStyles(old: nil, new: nil, oldOutline: nil, newOutline: nil),
                sourceByteCount: ChangesetLimits.maxSourceBytesPerFile + 1),
            for: key)
        await resultCache.register(
            key,
            forInputs: DiffResultCache.InputKey(
                repository: testRepository, fileID: file.id, fingerprint: file.fingerprint, hideWhitespace: true))
        if let worktree = file.fingerprint?.worktree {
            await client.set(worktreeState: worktree, for: file.path)
        }

        let (_, log, run) = assemble(["big.swift"], client: client, resultCache: resultCache)
        await run().value
        #expect(await log.lastDocument?.sections.first?.outcome == .tooLarge)
        #expect(await client.contentReads == 0, "nothing is read")
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
    /// without waiting for the worker that is still busy. Every revision is the previous
    /// one plus sections appended at the end, down to the rows, the lines and each
    /// section's offsets.
    @Test func aSectionCompletingInsideTheWindowIsPublishedAtTheDeadline() async {
        let client = StubRepoClient(files: [])
        await client.hold(worktree: ["b.swift", "d.swift"])
        let clock = ManualClock()
        let (assembler, log, run) = assemble(
            ["a.swift", "b.swift", "c.swift", "d.swift"], client: client, clock: clock)
        let task = run()

        #expect(await eventually { await log.documents.count == 1 }, "the first section publishes at once")
        let first = await log.documents[0].document
        #expect(first.sections.map(\.file.path) == ["a.swift"], "the held file stops the prefix")
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

        // The last revision is flushed when the task group drains.
        await client.release(worktree: "d.swift")
        await task.value
        let documents = await log.documents
        #expect(documents.count == 3)
        #expect(documents.map(\.document.revision) == [1, 2, 3])
        #expect(documents.allSatisfy { $0.document.loadID == documents[0].document.loadID })
        #expect(documents[2].document.sections.map(\.file.path) == ["a.swift", "b.swift", "c.swift", "d.swift"])
        for (earlier, later) in zip(documents, documents.dropFirst()) {
            expectPrefix(earlier.document, of: later.document)
        }
        for document in documents { expectMatchingStyles(document.document, document.styles) }
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

    // MARK: Final-only publication

    /// A final-only load never publishes a prefix, however long an early prefix sits
    /// ready: the one revision carries every section, with no cooldown ever started.
    @Test func finalOnlyPublishesOnceWhenEveryFileIsDone() async {
        let client = StubRepoClient(files: [])
        await client.hold(worktree: ["c.swift"])
        let clock = ManualClock()
        let (assembler, log, run) = assemble(
            ["a.swift", "b.swift", "c.swift"], client: client, clock: clock, publication: .finalOnly)
        let task = run()

        #expect(await eventually { await assembler.completedCount == 2 })
        #expect(await log.isEmpty, "the ready [a, b] prefix is not published")
        #expect(clock.sleeperCount == 0, "and no cooldown was started")

        await client.release(worktree: "c.swift")
        await task.value
        let documents = await log.documents
        #expect(documents.count == 1)
        #expect(documents[0].document.revision == 1)
        #expect(documents[0].document.sections.map(\.file.path) == ["a.swift", "b.swift", "c.swift"])
        #expect(documents[0].completed == 3)
        #expect(documents[0].total == 3)
        if let first = documents.first { expectMatchingStyles(first.document, first.styles) }
    }

    @Test func finalOnlyCancelledPublishesNothing() async {
        let client = StubRepoClient(files: [])
        await client.hold(worktree: ["a.swift"])
        let (_, log, run) = assemble(["a.swift"], client: client, publication: .finalOnly)
        let task = run()

        #expect(await eventually { await client.waitingWorktreePaths.contains("a.swift") })
        task.cancel()
        await client.release(worktree: "a.swift")
        await task.value
        #expect(await log.isEmpty)
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

    /// Each file's outline is shifted to where its lines start in the joined document.
    @Test func outlinesAreJoinedAtEachSectionsLineOffset() async {
        let client = StubRepoClient(files: [])
        let (_, log, run) = assemble(["a.swift", "b.swift"], client: client)
        await run().value

        guard let document = await log.lastDocument, let styles = await log.documents.last?.styles else {
            Issue.record("nothing was published")
            return
        }
        let b = document.sections[1]
        #expect(b.newLineOffset > 0 && b.oldLineOffset > 0)
        #expect(styles.newOutline?.name(atLine: b.newLineOffset) == "b.swift")
        #expect(styles.oldOutline?.name(atLine: b.oldLineOffset) == "b.swift")
        #expect(styles.newOutline?.name(atLine: b.newLineOffset - 1) == "a.swift")
    }

    // MARK: Result cache

    /// A second load of the same files against one result store neither diffs nor
    /// highlights again, and still publishes a fully styled document.
    @Test func aSecondLoadOfTheSameFilesIsServedFromTheResultCache() async {
        let names = ["a.swift", "b.swift", "c.swift"]
        let probe = RunnerProbe()
        let cache = probeCache(probe)
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
