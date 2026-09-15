import Foundation

/// Diffs and highlights every changed file for one All-changes load, publishing the
/// changeset as it grows.
///
/// Created per load and discarded with it, so nothing here survives a cancellation and
/// the loader only has to check the generation of what it receives. Three workers pull
/// files in sidebar order; what goes out is always the *contiguous completed prefix*, so
/// every publication is the previous one plus sections appended at the end, whatever
/// order the files actually finish in.
actor ChangesetAssembler {
    /// One update for the loader. A document publication always carries the styles that
    /// match it; styles that finish between two documents go out on their own.
    enum Publication: Sendable {
        case document(ChangesetDocument, DocumentStyles, completed: Int, total: Int)
        case styles(DocumentStyles)
    }

    /// Files diffed and highlighted at once. The worker holds its slot until its file's
    /// highlighting is done, so this bounds highlighting as well as diffing.
    static let workerCount = 3
    /// The shortest gap between two publications. A section that completes inside the gap
    /// waits for its end rather than for the next slow worker.
    static let publishInterval: Duration = .milliseconds(150)

    private let files: [ChangedFile]
    private let client: any RepoClient
    private let hideWhitespace: Bool
    private let cache: DifftCache
    private let clock: any Clock<Duration>
    private let highlight: @Sendable ([String], String) async -> [[StyleRun]]?
    private let loadID: UUID

    /// One slot per file, filled as it finishes. Nil is "not done yet".
    private var results: [ChangesetBuilder.FileResult?]
    /// One slot per file, filled when its highlighting finishes.
    private var sectionStyles: [SectionStyles?]
    /// The next file a worker takes. Files are admitted in sidebar order, never in
    /// completion order.
    private var cursor = 0
    /// How many sections the last publication carried.
    private var publishedCount = 0
    private var revision = 0
    private var published: ChangesetDocument?
    /// Styles arrived for a section that is already published, so the panes are missing
    /// colours the assembler already has.
    private var hasPendingStyles = false
    /// The stop flag and the pending flush, which cancellation has to reach from outside
    /// the actor.
    private let cancellation = Cancellation()
    private var send: (@Sendable (Publication) async -> Void)?
    /// The published sections, for the append-only assertion.
    private var publishedSectionIDs: [ChangedFile.ID] = []

    private struct SectionStyles {
        let old: [[StyleRun]]?
        let new: [[StyleRun]]?
    }

    /// Whether the load was cancelled, and the flush waiting to go out.
    ///
    /// Kept here rather than in the actor because a task's cancellation handler is
    /// synchronous and non-isolated: it has to flip the flag and cancel the timer at the
    /// moment of cancellation, not whenever the actor is next free. A worker sitting
    /// inside a git read keeps the actor's task group open long after that.
    ///
    /// `@unchecked Sendable`: both fields are only ever read or written under `lock`.
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var cooldown: Task<Void, Never>?

        /// Set once the load is cancelled. Nothing may be published afterwards.
        var isStopped: Bool { lock.withLock { stopped } }
        /// True while less than `publishInterval` has passed since the last publication.
        var hasCooldown: Bool { lock.withLock { cooldown != nil } }

        /// Keeps the flush so it can be cancelled from anywhere. One started after the
        /// load stopped is cancelled at once rather than stored.
        func hold(_ task: Task<Void, Never>) {
            lock.lock()
            guard !stopped else {
                lock.unlock()
                task.cancel()
                return
            }
            cooldown = task
            lock.unlock()
        }

        /// The flush fired on its own; there is nothing left to cancel.
        func clearCooldown() { lock.withLock { cooldown = nil } }

        /// Drops a flush that has not fired yet.
        func cancelCooldown() { take()?.cancel() }

        /// Stops the load and drops the pending flush, on whichever thread cancelled it.
        func stop() {
            lock.withLock { stopped = true }
            cancelCooldown()
        }

        private func take() -> Task<Void, Never>? {
            lock.withLock {
                let task = cooldown
                cooldown = nil
                return task
            }
        }
    }

    init(
        files: [ChangedFile],
        client: any RepoClient,
        hideWhitespace: Bool,
        cache: DifftCache,
        clock: any Clock<Duration> = ContinuousClock(),
        highlight: @escaping @Sendable ([String], String) async -> [[StyleRun]]? = { lines, fileName in
            await Task.detached(priority: .userInitiated) {
                Highlighter.highlight(lines: lines, fileName: fileName)
            }.value
        },
        loadID: UUID = UUID()
    ) {
        self.files = files
        self.client = client
        self.hideWhitespace = hideWhitespace
        self.cache = cache
        self.clock = clock
        self.highlight = highlight
        self.loadID = loadID
        results = Array(repeating: nil, count: files.count)
        sectionStyles = Array(repeating: nil, count: files.count)
        // The file cap is decided here, before anything is read, so completion order can
        // never change which files the changeset holds.
        for index in files.indices where index >= ChangesetLimits.maxFiles {
            results[index] = .notShown
        }
    }

    /// Runs the whole load, calling `publish` for every revision and style snapshot.
    ///
    /// Returns when the task group drains, which after a cancellation means when the
    /// workers already inside git, difft, the aligner or tree-sitter come back — those
    /// cannot be interrupted. Cancelling stops the flush timer and the stop flag at once,
    /// though, so nothing is published from the moment the load is cancelled.
    func run(publish: @escaping @Sendable (Publication) async -> Void) async {
        send = publish
        let cancellation = cancellation
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.workerCount {
                    group.addTask { [weak self] in await self?.work() }
                }
            }
        } onCancel: {
            cancellation.stop()
        }
        cancellation.cancelCooldown()
        guard !cancellation.isStopped else { return }
        // The last publication is forced: whatever is left has no later completion to
        // ride out with.
        await publishNow(startingCooldown: false)
        send = nil
    }

    // MARK: - Workers

    private func work() async {
        while let index = nextFile() {
            do {
                try await process(index)
            } catch {
                // Cancelled: the group is winding down and nothing more may be published.
                return
            }
        }
    }

    /// The next file to read, in sidebar order. Files past the cap already have their
    /// outcome and are never handed out.
    private func nextFile() -> Int? {
        let admitted = min(files.count, ChangesetLimits.maxFiles)
        guard cursor < admitted else { return nil }
        defer { cursor += 1 }
        return cursor
    }

    /// Reads, diffs and highlights one file, recording each stage as it lands.
    private func process(_ index: Int) async throws {
        let file = files[index]
        try Task.checkCancellation()
        let result = try await diff(file)
        try Task.checkCancellation()
        await record(result, at: index)
        try Task.checkCancellation()

        // Nothing to colour for a binary, an identical pair, a file that was never read,
        // or one whose changes are all hidden; the section keeps no lines either way.
        guard case let .content(.text(document)) = result, !document.changeBlocks.isEmpty else { return }
        let styles = await highlight(document, fileName: file.fileName)
        try Task.checkCancellation()
        await record(styles: styles, at: index)
    }

    /// One file's outcome. The source buffers are scoped to this call and are never
    /// retained in the section it produces, so a section's `Data` is gone by the time its
    /// lines exist.
    private func diff(_ file: ChangedFile) async throws -> ChangesetBuilder.FileResult {
        let sources: DiffEngine.Sources
        do {
            sources = try await DiffEngine.sources(for: file, client: client)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return .failed(error.localizedDescription)
        }
        try Task.checkCancellation()

        // A computation-admission limit, not a memory one: the read has happened, but a
        // huge file costs no diff and no highlighting.
        guard sources.old.count + sources.new.count <= ChangesetLimits.maxSourceBytesPerFile else {
            return .tooLarge
        }
        return .content(
            await DiffEngine.build(sources, hideWhitespace: hideWhitespace, cache: cache, priority: .foreground))
    }

    /// Both sides of one file, off the actor. Sequential rather than in parallel: the
    /// worker count is the bound on concurrent highlighting.
    private func highlight(_ document: DiffDocument, fileName: String) async -> SectionStyles {
        await SectionStyles(
            old: highlight(document.oldLines, fileName),
            new: highlight(document.newLines, fileName))
    }

    // MARK: - Publishing

    private func record(_ result: ChangesetBuilder.FileResult, at index: Int) async {
        results[index] = result
        await publishIfDue()
    }

    private func record(styles: SectionStyles, at index: Int) async {
        sectionStyles[index] = styles
        // Styles for a section that is not published yet ride out with it; only an
        // already-published section needs a snapshot of its own.
        guard index < publishedCount else { return }
        hasPendingStyles = true
        await publishIfDue()
    }

    /// Publishes at once when the interval has passed, and otherwise leaves it to the
    /// cooldown, which flushes whatever is ready when it expires.
    private func publishIfDue() async {
        guard !cancellation.hasCooldown else { return }
        await publishNow(startingCooldown: true)
    }

    /// Sends whatever is ready: a grown prefix (with the styles it has), or a fresh
    /// snapshot for the sections already out. Nothing ready means nothing sent.
    private func publishNow(startingCooldown: Bool) async {
        guard !cancellation.isStopped, let send else { return }
        let prefix = completedPrefix()

        if prefix > publishedCount {
            revision += 1
            publishedCount = prefix
            let document = ChangesetBuilder.build(
                results: (0..<prefix).map { (files[$0], results[$0]!) }, loadID: loadID, revision: revision)
            checkAppendOnly(document)
            published = document
            hasPendingStyles = false
            let snapshot = snapshot(for: document)
            if startingCooldown { startCooldown() }
            await send(.document(document, snapshot, completed: prefix, total: files.count))
        } else if hasPendingStyles, let document = published {
            hasPendingStyles = false
            let snapshot = snapshot(for: document)
            if startingCooldown { startCooldown() }
            await send(.styles(snapshot))
        }
    }

    /// Sections 0..<k where every file is done. A failed or skipped file is a finished
    /// section, so it never holds the prefix back.
    private func completedPrefix() -> Int {
        var end = publishedCount
        while end < results.count, results[end] != nil { end += 1 }
        return end
    }

    private func startCooldown() {
        cancellation.hold(
            Task { [weak self, clock] in
                do {
                    try await Task.sleep(for: Self.publishInterval, clock: clock)
                } catch {
                    return  // Cancelled with the load; nothing may go out.
                }
                await self?.cooldownExpired()
            })
    }

    private func cooldownExpired() async {
        cancellation.clearCooldown()
        await publishNow(startingCooldown: true)
    }

    /// Styles for every line of `document`, in one array per side. A section that is not
    /// highlighted — unsupported language, or not done yet — contributes empty runs, so a
    /// later file's styles never shift onto the wrong lines.
    private func snapshot(for document: ChangesetDocument) -> DocumentStyles {
        var old: [[StyleRun]] = []
        var new: [[StyleRun]] = []
        old.reserveCapacity(document.document.oldLines.count)
        new.reserveCapacity(document.document.newLines.count)
        for (index, section) in document.sections.enumerated() {
            let styles = sectionStyles[index]
            old.append(contentsOf: runs(styles?.old, count: section.oldLineCount))
            new.append(contentsOf: runs(styles?.new, count: section.newLineCount))
        }
        return DocumentStyles(documentID: document.document.id, revision: document.revision, old: old, new: new)
    }

    private func runs(_ styles: [[StyleRun]]?, count: Int) -> [[StyleRun]] {
        guard let styles, styles.count == count else { return Array(repeating: [], count: count) }
        return styles
    }

    /// Every revision is the previous one plus sections appended at the end. The
    /// container's append path relies on it, so it is checked where it is produced.
    private func checkAppendOnly(_ document: ChangesetDocument) {
        assert(document.sections.count >= publishedSectionIDs.count, "a revision may only grow")
        assert(
            document.sections.prefix(publishedSectionIDs.count).map(\.file.id) == publishedSectionIDs,
            "a revision may only append sections at the end")
        publishedSectionIDs = document.sections.map(\.file.id)
    }
}
