import Foundation

/// The stash list's read, and what the stash picker reads from a window.
extension WindowState {
    /// An open window with a repository and no other overlay up.
    var canOpenStashPicker: Bool {
        session != nil && !isClosed && !isOtherOverlayPresented(besides: .stashPicker)
    }

    var stashPickerSnapshot: StashPickerSnapshot {
        let displayedRef: CommitRef? = if case let .commit(ref) = scope { ref } else { nil }
        return StashPickerSnapshot(
            stashes: stashList.entries, readStatus: stashList.readStatus, displayedRef: displayedRef)
    }

    /// Shows the stash as a commit scope: its tracked changes and any untracked files it saved.
    func selectStash(_ entry: StashEntry) {
        isStashPickerPresented = false
        select(commit: entry.commitSummary)
    }

    /// Reads the stash list on its own task, so the capsule doesn't wait behind status,
    /// history or branch reads. The ticket is taken before the task starts, so the newest
    /// request wins whatever order the reads finish in.
    func scheduleStashRefresh(session: RepoSession) {
        guard isLive(session) else { return }
        session.stashSerial += 1
        let ticket = session.stashSerial
        session.stashTask = Task { [weak self, weak session] in
            guard let self, let session, isCurrentStashRead(session: session, ticket: ticket) else { return }
            let list = try? await session.client.stashes()
            guard isCurrentStashRead(session: session, ticket: ticket) else { return }
            stashList.publish(list)
        }
    }

    private func isCurrentStashRead(session: RepoSession, ticket: Int) -> Bool {
        isLive(session) && ticket == session.stashSerial
    }
}
