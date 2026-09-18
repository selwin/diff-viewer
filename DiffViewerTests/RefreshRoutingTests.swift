import Testing

@testable import DiffViewer

/// Which reads a batch of watcher changes drives, by scope and by whether a commit
/// template is configured.
struct RefreshRoutingTests {
    private let commit = DiffScope.commit(CommitRef(sha: objectID("c"), shortSha: "c", firstParentSHA: nil))

    private func work(
        _ changes: Set<RepoChange>, scope: DiffScope = .workingTree,
        template: CommitDefaults.TemplateDependency = .none
    ) -> RefreshWork {
        RefreshRouting.work(for: changes, scope: scope, template: template)
    }

    /// Every category alone in working-tree scope. Status is always on: even a refs-only
    /// event (a soft reset) changes the staged list.
    @Test(arguments: [
        (RepoChange.worktree, RefreshWork(status: true, repositoryMetadata: false, commitDefaults: false)),
        (.index, RefreshWork(status: true, repositoryMetadata: false, commitDefaults: false)),
        (.refs, RefreshWork(status: true, repositoryMetadata: true, commitDefaults: true)),
        (.commitState, RefreshWork(status: true, repositoryMetadata: false, commitDefaults: true)),
        (.configuration, RefreshWork(status: true, repositoryMetadata: false, commitDefaults: true)),
        (.rescan, RefreshWork(status: true, repositoryMetadata: true, commitDefaults: true)),
    ])
    func eachChangeAloneInWorkingTreeScope(change: RepoChange, expected: RefreshWork) {
        #expect(work([change]) == expected)
    }

    @Test func combinedChangesUnionTheirWork() {
        #expect(
            work([.worktree, .index]) == RefreshWork(status: true, repositoryMetadata: false, commitDefaults: false))
        #expect(
            work([.index, .commitState]) == RefreshWork(status: true, repositoryMetadata: false, commitDefaults: true))
        #expect(
            work([.worktree, .refs, .index])
                == RefreshWork(status: true, repositoryMetadata: true, commitDefaults: true))
    }

    /// A commit's file list and the commit box do not depend on the working tree, but the
    /// title bar's branch and history still follow HEAD.
    @Test func commitScopeKeepsOnlyMetadata() {
        #expect(work([.worktree, .index, .commitState, .configuration], scope: commit) == .none)
        #expect(
            work([.refs], scope: commit) == RefreshWork(status: false, repositoryMetadata: true, commitDefaults: false))
        #expect(
            work([.rescan, .worktree], scope: commit)
                == RefreshWork(status: false, repositoryMetadata: true, commitDefaults: false))
    }

    /// A worktree write refreshes the defaults only when a template may live there.
    @Test func worktreeWritesFollowTheTemplateDependency() {
        #expect(work([.worktree], template: .none).commitDefaults == false)
        #expect(work([.worktree], template: .configured(path: "/r/.gitmessage")).commitDefaults == true)
        #expect(work([.worktree], template: .unknown).commitDefaults == true)
        // Staging alone never touches the defaults, whatever the template.
        #expect(work([.index], template: .configured(path: "/r/.gitmessage")).commitDefaults == false)
    }

    @Test func nothingChangedNeedsNothing() {
        #expect(work([]) == .none)
        #expect(work([], template: .configured(path: "/r/.gitmessage")) == .none)
        #expect(work([], scope: commit) == .none)
    }
}
