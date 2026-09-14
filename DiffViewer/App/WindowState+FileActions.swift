import AppKit

/// Running one sidebar context-menu action.
///
/// An extension in its own file: the class body is long enough, and these are the only
/// places in the app that write to the repository. Everything they need from the class
/// is `internal`, apart from the pending selection, which `restoreSelectionAfterNextRefresh`
/// hands over.
extension WindowState {
    /// Runs `action` against `file` and, for the writes, republishes the file list.
    ///
    /// Never throws and never retries: a failure becomes `errorMessage`, which the
    /// window already presents as an alert, and the reader decides what to do next.
    func perform(_ action: FileAction, on file: ChangedFile) async {
        // A cheap first pass against the list the reader is looking at: a context menu
        // built before the last refresh can name a file that is no longer there — staged
        // by someone else, or discarded a moment ago — and that one is dropped without
        // starting a process. Kind is part of the match because `ChangedFile.id` is only
        // area and path: a deleted file recreated as a modified one keeps its id while
        // "Restore File" quietly becomes an unconfirmed discard. Writes are checked again
        // against a fresh status read in `runWrite`, which is the decision that counts.
        guard let session, !isClosed,
            files.contains(where: { $0.id == file.id && $0.kind == file.kind })
        else { return }
        if action.isRepositoryWrite {
            await performWrite(action, on: file, session: session)
        } else {
            performHarmless(action, on: file)
        }
    }

    /// Queues a repository write behind whatever the session is already running.
    ///
    /// Two quick clicks would otherwise start two `git` processes at once and one of them
    /// would fail on `index.lock`. The chain serializes the writes: one unstructured task
    /// per write, so a queued write is not cancelled by its caller going away, and each
    /// write re-reads status before it runs. What stops a write whose row changed while it
    /// waited is that read in `runWrite`, not cancellation.
    private func performWrite(_ action: FileAction, on file: ChangedFile, session: RepoSession) async {
        let previousWrite = session.fileActionTask
        let task = Task { [weak self] in
            await previousWrite?.value
            await self?.runWrite(action, on: file, session: session)
        }
        session.fileActionTask = task
        await task.value
    }

    private func runWrite(_ action: FileAction, on file: ChangedFile, session: RepoSession) async {
        // Checked again here: the window may have closed, or its repository been
        // replaced, while the earlier action in the chain was running.
        guard session === self.session, !isClosed else { return }

        // And the row itself may have changed meaning while this write waited its turn.
        // The repository is the authority for that, not `files`: a refresh publishes
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
        // Same id but a different kind is a different file action than the one clicked.
        guard current.contains(where: { $0.id == file.id && $0.kind == file.kind }) else { return }

        // Captured before the write, not after it: while the client call is suspended
        // another refresh — ⌘R, a settings change, the watcher — can publish the list the
        // write produced and clear `selectedFileID`, because the id the reader was on is
        // gone from it. Read afterwards, this row would no longer look selected and the
        // detail pane would stay empty.
        let wasSelected = file.id == selectedFileID
        let row = sidebarRows.firstIndex(where: { $0.id == file.id })

        do {
            // Spelled out rather than "git action, else trash": an action that is neither
            // must do nothing, not fall through to deleting the file.
            if let gitAction = action.gitAction {
                try await session.client.perform(gitAction, on: file.path)
            } else if action == .trash {
                try await session.client.trash(file.path)
            } else {
                return
            }
        } catch {
            guard session === self.session, !isClosed else { return }
            errorMessage = error.localizedDescription
            return
        }
        guard session === self.session, !isClosed else { return }

        // Recorded only after the write returned, and with nothing awaited between here
        // and the refresh below: a watcher refresh that got in first would consume the
        // request and apply it to the list from before the write.
        //
        // A nil selection still restores — a refresh that overtook this write cleared it,
        // the reader did not — but a selection that has moved to another file does not:
        // that one was the reader's own choice and outranks the row being written.
        if wasSelected, selectedFileID == nil || selectedFileID == file.id, let row {
            restoreSelectionAfterNextRefresh(PendingSelection(path: file.path, area: file.area, row: row))
        }
        // Required, not an optimisation: `RepoWatcher` sets `kFSEventStreamCreateFlagIgnoreSelf`,
        // so a change this process makes fires no event and nothing else would republish.
        await refresh(session: session, cause: .fileAction)
    }

    /// Reveal, Open, and Copy Path: they touch Finder, the default editor, and the
    /// pasteboard, never the repository, so they neither queue nor refresh.
    private func performHarmless(_ action: FileAction, on file: ChangedFile) {
        guard let root = repositoryRoot else { return }
        let url = root.url.appendingPathComponent(file.path)
        switch action {
        case .revealInFinder, .openInEditor:
            // Nothing on disk to point at. Saying so beats Finder selecting nothing or
            // the editor offering to create the file.
            guard FileManager.default.fileExists(atPath: url.path) else {
                errorMessage = "\(file.path) is not in the working tree."
                return
            }
            if action == .revealInFinder {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else if !NSWorkspace.shared.open(url) {
                // Nothing is registered for this file type, so nothing happened. Silence
                // would read as the click not having landed.
                errorMessage = "No application could open \(file.path)."
            }
        case .copyPath:
            // The absolute path: a repository-relative one is useless in another app.
            // Works for a deleted file too, which is often why it is being copied.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        case .stage, .unstage, .discard, .trash:
            break
        }
    }
}
