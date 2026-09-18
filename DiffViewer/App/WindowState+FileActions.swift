import AppKit

/// Running one sidebar context-menu action over the rows it was invoked on.
///
/// An extension in its own file: the class body is long enough, and these, with the
/// commit and branch-switch extensions, are the only places in the app that write to
/// the repository.
/// Everything they need from the class is `internal`, apart from the pending selection,
/// which `restoreSelectionAfterNextRefresh` hands over.
///
/// One row or twenty take the same path: the menu is built from the whole selection, the
/// confirmation is asked once, git runs once, and one refresh publishes the result.
extension WindowState {
    /// Runs `action` against `requestedFiles` and, for the writes, republishes the list.
    ///
    /// Never throws and never retries: a failure becomes `errorMessage`, which the
    /// window already presents as an alert, and the reader decides what to do next.
    func perform(_ action: FileAction, on requestedFiles: [ChangedFile]) async {
        // A cheap first pass against the list the reader is looking at: a context menu
        // built before the last refresh can name a file that is no longer there — staged
        // by someone else, or discarded a moment ago — and those are dropped without
        // starting a process. Kind is part of the match because `ChangedFile.id` is only
        // area and path: a deleted file recreated as a modified one keeps its id while
        // "Restore File" quietly becomes an unconfirmed discard. Writes are checked again
        // against a fresh status read in `runWrite`, which is the decision that counts.
        guard let session, !isClosed else { return }
        let validatedFiles = Self.validatedFiles(requestedFiles, against: files)
        guard !validatedFiles.isEmpty else { return }
        if action.isRepositoryWrite {
            // Reject new repository writes until the branch switch finishes.
            guard !isSwitchingBranch else { return }
            await performWrite(action, on: validatedFiles, session: session)
        } else {
            performHarmless(action, on: validatedFiles)
        }
    }

    /// The requested files that `list` still holds with the same kind, in the order they
    /// were requested. One dictionary rather than a scan of `list` per requested file.
    private static func validatedFiles(_ requested: [ChangedFile], against list: [ChangedFile]) -> [ChangedFile] {
        let kinds = Dictionary(list.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        return requested.filter { kinds[$0.id] == $0.kind }
    }

    /// Serializes repository writes; each operation validates its own inputs.
    ///
    /// Two quick clicks would otherwise start two `git` processes at once and one of them
    /// would fail on `index.lock`. One unstructured task per write, so a queued write is not
    /// cancelled by its caller going away.
    func enqueueWrite(session: RepoSession, _ body: @escaping @MainActor () async -> Void) async {
        let previousWrite = session.repositoryWriteTask
        let task = Task {
            await previousWrite?.value
            await body()
        }
        session.repositoryWriteTask = task
        await task.value
    }

    private func performWrite(_ action: FileAction, on files: [ChangedFile], session: RepoSession) async {
        await enqueueWrite(session: session) { [weak self] in
            await self?.runWrite(action, on: files, session: session)
        }
    }

    private func runWrite(_ action: FileAction, on files: [ChangedFile], session: RepoSession) async {
        // Checked again here: the window may have closed, or its repository been
        // replaced, while the earlier action in the chain was running.
        guard session === self.session, !isClosed else { return }

        // And the rows themselves may have changed meaning while this write waited its
        // turn. The repository is the authority for that, not `files`: a refresh publishes
        // nothing when a newer one supersedes it or when `status()` throws, so the list on
        // screen can still show the world from before the write ahead of this one. Reading
        // status per action costs one `git status` next to the write it protects.
        let current: [ChangedFile]
        do {
            current = try await session.client.status()
        } catch {
            guard session === self.session, !isClosed else { return }
            errorMessage = error.localizedDescription
            return
        }
        guard session === self.session, !isClosed else { return }
        // Revalidate identity and kind before writing; the menu may be stale. A row that
        // came back with another kind is a different action than the one clicked, so it
        // drops out of the batch and the rest of it still runs.
        let validated = Self.validatedFiles(files, against: current)
        guard !validated.isEmpty else { return }

        // Capture selected targets before awaiting the write; a concurrent refresh may
        // remove their original ids.
        let revision = selectionRevision
        let rows = sidebarRows
        let rowIndex = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let reselectionCandidates: [PendingSelection] = validated.compactMap { file in
            guard selection.contains(.file(file.id)) else { return nil }
            return PendingSelection(path: file.path, area: file.area, row: rowIndex[file.id])
        }
        let paths = validated.map(\.path)

        // Held rather than reported at once: the refresh below has to run either way, and
        // it must not be the thing that clears this message.
        var failure: (any Error)?
        do {
            // Spelled out rather than "git action, else trash": an action that is neither
            // must do nothing, not fall through to deleting the files.
            if let gitAction = action.gitAction {
                try await session.client.perform(gitAction, on: paths)
            } else if action == .trash {
                try await session.client.trash(paths)
            } else {
                return
            }
        } catch {
            failure = error
        }
        guard session === self.session, !isClosed else { return }

        // Recorded only after the write returned, and with nothing awaited between here
        // and the refresh below: a watcher refresh that got in first would consume the
        // request and apply it to the list from before the write.
        //
        // Apply pending reselections only if the user has not changed the selection since
        // the write began, including while this refresh was waiting — the setter drops a
        // pending restoration, so a choice made in that gap wins too. A selection the
        // reader moved elsewhere, All changes included, outranks the rows being written.
        if !reselectionCandidates.isEmpty, selectionRevision == revision {
            restoreSelectionAfterNextRefresh(reselectionCandidates)
        }
        // Refresh even after failure because earlier files may already have changed:
        // `git restore` checks out entries one by one and does not roll back the ones it
        // finished, a trash loop can fail midway, and the watcher ignores this process's
        // own events. Required after a success for the same last reason: `RepoWatcher` sets
        // `kFSEventStreamCreateFlagIgnoreSelf`, so nothing else would republish.
        await refresh(session: session, cause: .fileAction)
        guard session === self.session, !isClosed, let failure else { return }
        // After the refresh, so the news survives it: a successful refresh clears only the
        // error a refresh raised.
        errorMessage = failure.localizedDescription
    }

    /// Reveal, Open, and Copy Path: they touch Finder, the default editor, and the
    /// pasteboard, never the repository, so they neither queue nor refresh.
    private func performHarmless(_ action: FileAction, on files: [ChangedFile]) {
        guard let root = repositoryRoot else { return }
        let paths = Self.uniquePaths(of: files)
        let urls = paths.map { root.url.appendingPathComponent($0) }
        switch action {
        case .revealInFinder, .openInEditor:
            let onDisk = zip(paths, urls).filter { FileManager.default.fileExists(atPath: $0.1.path) }
            // Nothing on disk to point at. Saying so beats Finder selecting nothing or
            // the editor offering to create the files. A batch where only some rows are
            // missing goes ahead with the rest, which is what the reader asked for.
            guard !onDisk.isEmpty else {
                errorMessage = "\(paths[0]) is not in the working tree."
                return
            }
            if action == .revealInFinder {
                NSWorkspace.shared.activateFileViewerSelecting(onDisk.map(\.1))
            } else {
                var firstFailure: String?
                for (path, url) in onDisk where !NSWorkspace.shared.open(url) {
                    // Nothing is registered for this file type, so nothing happened.
                    // Silence would read as the click not having landed. The others still
                    // open; only the first failure is named.
                    firstFailure = firstFailure ?? path
                }
                if let firstFailure { errorMessage = "No application could open \(firstFailure)." }
            }
        case .copyPath:
            // Absolute paths: repository-relative ones are useless in another app. Works
            // for a deleted file too, which is often why it is being copied. One line per
            // path, the shape every other app pastes a file list as.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        case .stage, .unstage, .discard, .trash:
            break
        }
    }

    /// The distinct paths of `files`, in the order given. A path with both staged and
    /// unstaged edits is two rows but one file on disk, and Reveal, Open, and Copy Path
    /// all speak about the file rather than the diff.
    static func uniquePaths(of files: [ChangedFile]) -> [String] {
        var seen: Set<String> = []
        return files.map(\.path).filter { seen.insert($0).inserted }
    }
}
