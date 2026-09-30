import Foundation
import Testing

@testable import DiffViewer

/// A difft that always succeeds, so finished results are stored and can be reused.
private func succeedingCache() -> DifftCache {
    probeCache(RunnerProbe())
}

/// Makes every side of `file` verifiable: its blobs exist and its worktree stat still
/// matches the fingerprint.
private func vouch(for file: ChangedFile, in client: StubRepoClient) async {
    guard let fingerprint = file.fingerprint else { return }
    for case let .object(oid) in [fingerprint.old, fingerprint.new] {
        await client.set(blob: Data("blob \(oid)\n".utf8), for: oid)
    }
    await client.set(worktreeState: fingerprint.worktree, for: file.path)
}

/// Path reads and blob reads together.
private func reads(_ client: StubRepoClient) async -> Int {
    await client.contentReads + client.blobReads.count
}

private func document(_ output: DiffEngine.Output) -> DiffDocument? {
    guard case let .text(document) = output.content else { return nil }
    return document
}

private let commitFile = changedFile(
    "a.swift", area: .commit(CommitRef(sha: objectID("c1"), shortSha: "c1", firstParentSHA: objectID("c0"))))

struct DiffEngineLoadTests {
    let client = StubRepoClient(files: [])
    let cache = succeedingCache()
    let resultCache = DiffResultCache()

    private func load(
        _ file: ChangedFile, repository: RepositoryRoot = testRepository, hideWhitespace: Bool = false
    ) async throws -> DiffEngine.Output {
        try await DiffEngine.load(
            file, repository: repository, client: client, hideWhitespace: hideWhitespace, cache: cache,
            resultCache: resultCache, priority: .foreground, highlight: { _, _ in nil })
    }

    /// Loads `file` twice and says whether the second load read anything.
    private func secondLoadReads(_ file: ChangedFile) async throws -> Bool {
        _ = try await load(file)
        let before = await reads(client)
        _ = try await load(file)
        return await reads(client) > before
    }

    // MARK: Reuse

    /// A working-tree file by its fingerprint, a commit's file by its SHA.
    @Test(arguments: [changedFile("a.swift"), commitFile])
    func anUnchangedFileIsReusedWithoutReading(_ file: ChangedFile) async throws {
        await vouch(for: file, in: client)

        let first = try await load(file)
        let before = await reads(client)
        let second = try await load(file)

        #expect(await reads(client) == before, "nothing is read")
        #expect(document(second)?.id == document(first)?.id, "the same document comes back")
    }

    enum Change: CaseIterable {
        case fingerprint, whitespace, repository
    }

    @Test(arguments: Change.allCases)
    func aChangedInputReadsAgain(_ change: Change) async throws {
        let file = changedFile("a.swift")
        await vouch(for: file, in: client)
        _ = try await load(file)
        let before = await reads(client)

        switch change {
        case .fingerprint: _ = try await load(file.edited())
        case .whitespace: _ = try await load(file, hideWhitespace: true)
        case .repository: _ = try await load(file, repository: RepositoryRoot(path: "/other"))
        }
        #expect(await reads(client) > before)
    }

    /// Status cannot vouch for these files' content.
    @Test(arguments: [changedFile("a.swift", kind: .unmerged), changedFile("a.swift").with(fingerprint: nil)])
    func aFileWithoutKnownInputsIsNeverReused(_ file: ChangedFile) async throws {
        await vouch(for: file, in: client)
        #expect(try await secondLoadReads(file))
    }

    // MARK: Reads that match the fingerprint

    /// The file changed between status and the read, so the bytes may not be the ones the
    /// fingerprint describes.
    @Test func aWorktreeThatMovedDuringTheReadIsNotRegistered() async throws {
        let file = changedFile("a.swift")
        await vouch(for: file, in: client)
        await client.set(worktreeState: .file(mtimeNs: 2, ctimeNs: 2, size: 11, inode: 1), for: "a.swift")
        _ = try await load(file)
        // Stats as status saw it again, so only a missing registration makes the next load read.
        await vouch(for: file, in: client)
        let before = await reads(client)
        _ = try await load(file)
        #expect(await reads(client) > before)
    }

    /// An edit the watcher has not reported yet: status's fingerprint still matches the
    /// registered result, but the file on disk no longer does.
    @Test func aWorktreeEditedSinceStatusIsReadInsteadOfReused() async throws {
        let file = changedFile("a.swift")
        await vouch(for: file, in: client)
        _ = try await load(file)
        await client.set(worktreeState: .file(mtimeNs: 2, ctimeNs: 2, size: 11, inode: 1), for: "a.swift")
        let before = await reads(client)
        _ = try await load(file)
        #expect(await reads(client) > before)
    }

    /// The index has moved on since status; the blob status named is what is shown.
    @Test func aGitSideIsReadByItsBlobID() async throws {
        let file = changedFile("a.swift", area: .staged)
        await vouch(for: file, in: client)
        await client.set(blob: Data("from blob\n".utf8), for: objectID("index-a.swift"))
        await client.set(index: Data("from index\n".utf8), for: "a.swift")

        let output = try await load(file)
        #expect(document(output)?.newLines == ["from blob"])
        #expect(await client.contentReads == 0, "no side is read by path")
    }

    /// A gitlink's id is a commit, so `blobContents` returns nil. The path read shows what
    /// it always did, but does not match the fingerprint, so nothing is registered.
    @Test func aBlobGitCannotProduceFallsBackToThePathAndIsNotRegistered() async throws {
        let file = changedFile("a.swift", area: .staged)
        await vouch(for: file, in: client)
        await client.set(blob: nil, for: objectID("index-a.swift"))
        await client.set(index: Data("from index\n".utf8), for: "a.swift")

        let output = try await load(file)
        #expect(document(output)?.newLines == ["from index"])
        #expect(try await secondLoadReads(file))
    }
}

// MARK: - Overlap

/// Opens once. A waiter resumes when it opens, or after a timeout so a regression fails
/// the test instead of hanging it.
private actor Gate {
    private var isOpen = false
    private(set) var timedOut = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        resumeWaiters()
    }

    func wait(timeout: Duration) async {
        guard !isOpen else { return }
        let timer = Task.detached { [self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            await expire()
        }
        await withCheckedContinuation { waiters.append($0) }
        timer.cancel()
    }

    private func expire() {
        guard !isOpen else { return }
        timedOut = true
        resumeWaiters()
    }

    private func resumeWaiters() {
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

struct DiffEngineOverlapTests {
    /// Highlighting needs only the lines, so it starts while difft is still running.
    @Test func highlightingStartsBeforeDifftReturns() async throws {
        let highlightStarted = Gate()
        let cache = DifftCache(runner: { _, _, fileName, _ in
            await highlightStarted.wait(timeout: .seconds(5))
            return DifftFile(language: "Swift", path: fileName, status: "changed", chunks: [])
        })
        let probe = HighlighterProbe().callback()
        let sources = DiffEngine.Sources(old: Data("a\nb\n".utf8), new: Data("a\nc\nd\n".utf8), fileName: "a.swift")

        let output = try await DiffEngine.build(
            sources, hideWhitespace: false, cache: cache, resultCache: DiffResultCache(), priority: .foreground,
            highlight: { lines, fileName in
                await highlightStarted.open()
                return await probe(lines, fileName)
            })

        #expect(await !highlightStarted.timedOut, "difft returned before highlighting started")
        let built = try #require(document(output))
        #expect(built.language == "Swift", "difft's result was used")
        #expect(output.styles?.old?.count == built.oldLines.count)
        #expect(output.styles?.new?.count == built.newLines.count)
    }
}
