import Foundation
import Testing

@testable import DiffViewer

/// What the picker may offer, and what it may do, for a given branch read.
struct SyncPolicyTests {
    private func tracked(ahead: Int, behind: Int, name: String = "main", remote: String = "origin") -> LocalBranch {
        localBranch(
            name,
            upstream: upstream("\(remote)/\(name)", remote: remote, tracking: .counts(ahead: ahead, behind: behind)))
    }

    private func target(
        _ readStatus: BranchReadStatus = .loaded, branch: String = "main", branches: [LocalBranch]
    ) -> SyncTarget? {
        SyncPolicy.target(branch: branch, readStatus: readStatus, branches: branches)
    }

    // MARK: Target

    @Test func aLoadedReadOnATrackedBranchNamesTheDestination() {
        let resolved = target(branches: [tracked(ahead: 1, behind: 2)])
        #expect(
            resolved
                == SyncTarget(
                    destination: SyncDestination(
                        branch: "main", remote: "origin", remoteRef: "refs/heads/main",
                        localRef: "refs/remotes/origin/main"),
                    ahead: 1, behind: 2))
    }

    @Test func anyBranchInTheListHasATargetNotJustHead() {
        let branches = [tracked(ahead: 0, behind: 0), tracked(ahead: 0, behind: 3, name: "feature", remote: "fork")]
        #expect(target(branch: "feature", branches: branches)?.destination.remote == "fork")
        #expect(target(branch: "feature", branches: branches)?.behind == 3)
    }

    @Test func anythingLessThanALoadedRemoteUpstreamHasNoTarget() {
        let branches = [tracked(ahead: 1, behind: 1)]
        #expect(target(.unread, branches: branches) == nil)
        #expect(target(.failed, branches: branches) == nil)
        #expect(target(branch: "other", branches: branches) == nil, "not in the list")
        #expect(target(branches: [localBranch("main")]) == nil, "no upstream")
        #expect(
            target(branches: [localBranch("main", upstream: upstream("origin/main", tracking: .gone))]) == nil,
            "a gone upstream says nothing about where a push would go")
        let local = upstream("base", remote: ".", localRef: "refs/heads/base", tracking: .counts(ahead: 0, behind: 1))
        #expect(target(branches: [localBranch("main", upstream: local)]) == nil, "a local branch upstream")
        let outside = upstream("origin/main", localRef: "refs/heads/main", tracking: .counts(ahead: 0, behind: 1))
        #expect(target(branches: [localBranch("main", upstream: outside)]) == nil, "a ref outside refs/remotes/")
    }

    // MARK: Permission

    @Test func pullNeedsCommitsToTakeAndPushAFastForward() {
        func target(ahead: Int, behind: Int) -> SyncTarget {
            SyncTarget(
                destination: SyncDestination(
                    branch: "main", remote: "origin", remoteRef: "refs/heads/main",
                    localRef: "refs/remotes/origin/main"),
                ahead: ahead, behind: behind)
        }
        for isCurrent in [true, false] {
            #expect(SyncPolicy.allows(.pull, on: target(ahead: 0, behind: 1), isCurrent: isCurrent))
            #expect(!SyncPolicy.allows(.pull, on: target(ahead: 3, behind: 0), isCurrent: isCurrent))
            #expect(SyncPolicy.allows(.push, on: target(ahead: 1, behind: 0), isCurrent: isCurrent))
            #expect(!SyncPolicy.allows(.push, on: target(ahead: 0, behind: 0), isCurrent: isCurrent))
            #expect(!SyncPolicy.allows(.push, on: target(ahead: 1, behind: 1), isCurrent: isCurrent), "pull first")
        }
        #expect(SyncPolicy.allows(.pull, on: target(ahead: 1, behind: 1), isCurrent: true), "git pull merges")
        #expect(!SyncPolicy.allows(.pull, on: target(ahead: 1, behind: 1), isCurrent: false), "only a fast-forward")
    }

    // MARK: Row buttons

    private func buttons(
        _ branch: LocalBranch, isCurrent: Bool = true, readStatus: BranchReadStatus = .loaded,
        active: ActiveSync? = nil, isSwitching: Bool = false, isDiscovering: Bool = false,
        fetchingRemotes: Set<String> = [], remotes: [String] = [], configuredRemote: String? = nil
    ) -> RowSyncButtons {
        SyncPolicy.rowButtons(
            branch: branch, isCurrent: isCurrent, readStatus: readStatus, active: active, isSwitching: isSwitching,
            isDiscovering: isDiscovering, fetchingRemotes: fetchingRemotes, remotes: remotes,
            configuredRemote: configuredRemote)
    }

    private func buttons(ahead: Int, behind: Int, isCurrent: Bool = true) -> RowSyncButtons {
        buttons(tracked(ahead: ahead, behind: behind), isCurrent: isCurrent)
    }

    @Test func theCountsDecideWhichButtonsShow() {
        for isCurrent in [true, false] {
            #expect(buttons(ahead: 0, behind: 0, isCurrent: isCurrent) == .hidden, "in sync")
            #expect(buttons(ahead: 0, behind: 2, isCurrent: isCurrent) == RowSyncButtons(pull: .enabled, push: .hidden))
            #expect(buttons(ahead: 2, behind: 0, isCurrent: isCurrent) == RowSyncButtons(pull: .hidden, push: .enabled))
        }
        #expect(
            buttons(ahead: 1, behind: 2, isCurrent: true)
                == RowSyncButtons(pull: .enabled, push: .disabled(reason: "Pull first")))
        #expect(
            buttons(ahead: 1, behind: 2, isCurrent: false)
                == RowSyncButtons(
                    pull: .disabled(reason: "Has local commits; switch to it to pull"),
                    push: .disabled(reason: "Pull first")))
    }

    @Test func noRemoteUpstreamOrNoReadShowsNothing() {
        #expect(buttons(localBranch("main")) == .hidden, "no upstream")
        #expect(buttons(localBranch("main", upstream: upstream("origin/main", tracking: .gone))) == .hidden)
        let local = upstream("base", remote: ".", localRef: "refs/heads/base", tracking: .counts(ahead: 0, behind: 1))
        #expect(buttons(localBranch("main", upstream: local)) == .hidden)
        let outside = upstream("origin/main", localRef: "refs/heads/main", tracking: .counts(ahead: 2, behind: 0))
        #expect(buttons(localBranch("main", upstream: outside)) == .hidden)
        #expect(buttons(tracked(ahead: 0, behind: 2), readStatus: .failed) == .hidden, "stale counts")
    }

    @Test func aSwitchDisablesWhateverWouldShow() {
        let diverged = tracked(ahead: 1, behind: 2)
        let switching = PickerButtonState.disabled(reason: "Switching branch…")
        #expect(buttons(diverged, isSwitching: true) == RowSyncButtons(pull: switching, push: switching))
    }

    /// A fetch may still move a pull's counts; it can only take a push away, and the push
    /// waits for it after the click.
    @Test func discoveryOrThisRowsFetchDisablesPullOnly() {
        let fetching = PickerButtonState.disabled(reason: "Fetching…")
        let diverged = tracked(ahead: 1, behind: 2)
        let pullFirst = PickerButtonState.disabled(reason: "Pull first")
        #expect(buttons(diverged, isDiscovering: true) == RowSyncButtons(pull: fetching, push: pullFirst))
        #expect(buttons(diverged, fetchingRemotes: ["origin"]) == RowSyncButtons(pull: fetching, push: pullFirst))
        let behind = tracked(ahead: 0, behind: 2)
        #expect(buttons(behind, isDiscovering: true) == RowSyncButtons(pull: fetching, push: .hidden))
        #expect(buttons(behind, fetchingRemotes: ["origin"]) == RowSyncButtons(pull: fetching, push: .hidden))
        let ahead = tracked(ahead: 1, behind: 0)
        #expect(buttons(ahead, isDiscovering: true) == RowSyncButtons(pull: .hidden, push: .enabled))
        #expect(buttons(ahead, fetchingRemotes: ["origin"]) == RowSyncButtons(pull: .hidden, push: .enabled))
        #expect(
            buttons(behind, fetchingRemotes: ["fork"]) == RowSyncButtons(pull: .enabled, push: .hidden),
            "another remote's fetch")
        #expect(buttons(tracked(ahead: 0, behind: 0), isDiscovering: true) == .hidden, "nothing to disable")
    }

    /// The button the reader clicked keeps its spinner while the operation's own refresh
    /// moves the counts under it, or takes the target away entirely. The other button
    /// shows, disabled, only where the counts would show it anyway.
    @Test func theOperationOnThisRowOutranksTheCounts() {
        let pull = ActiveSync(branch: "main", operation: .pull)
        let push = ActiveSync(branch: "main", operation: .push)
        #expect(buttons(tracked(ahead: 0, behind: 2), active: pull) == RowSyncButtons(pull: .running, push: .hidden))
        #expect(buttons(tracked(ahead: 2, behind: 0), active: push) == RowSyncButtons(pull: .hidden, push: .running))
        // Diverged: Push was already up as "Pull first", so it stays up while the pull runs.
        #expect(
            buttons(tracked(ahead: 1, behind: 2), active: pull)
                == RowSyncButtons(pull: .running, push: .disabled(reason: "Pulling…")))
        #expect(
            buttons(tracked(ahead: 2, behind: 1), active: push)
                == RowSyncButtons(pull: .disabled(reason: "Pushing…"), push: .running))
        // The pull finished the counts it was started for, and the upstream is gone.
        #expect(buttons(localBranch("main"), active: pull) == RowSyncButtons(pull: .running, push: .hidden))
        #expect(
            buttons(tracked(ahead: 0, behind: 0), active: push, isSwitching: true)
                == RowSyncButtons(pull: .hidden, push: .running))
    }

    @Test func anOperationOnAnotherRowDisablesThisOne() {
        let elsewhere = ActiveSync(branch: "feature", operation: .push)
        #expect(
            buttons(tracked(ahead: 1, behind: 0), active: elsewhere)
                == RowSyncButtons(pull: .hidden, push: .disabled(reason: "Pushing feature…")))
        let pulling = ActiveSync(branch: "feature", operation: .pull)
        #expect(
            buttons(tracked(ahead: 0, behind: 1), isCurrent: false, active: pulling)
                == RowSyncButtons(pull: .disabled(reason: "Pulling feature…"), push: .hidden))
        #expect(buttons(tracked(ahead: 0, behind: 0), active: elsewhere) == .hidden, "nothing to disable")
    }

    // MARK: Publish

    @Test func publishGoesToOriginThenTheOnlyRemoteElseAsks() {
        #expect(SyncPolicy.publishRemote(remotes: []) == PublishRemote.none)
        #expect(SyncPolicy.publishRemote(remotes: ["origin"]) == .remote("origin"))
        #expect(SyncPolicy.publishRemote(remotes: ["fork", "origin"]) == .remote("origin"))
        #expect(SyncPolicy.publishRemote(remotes: ["fork"]) == .remote("fork"))
        #expect(SyncPolicy.publishRemote(remotes: ["fork", "upstream"]) == .ask(["fork", "upstream"]))
    }

    private let untracked = localBranch("feature")

    private func publish(_ push: PickerButtonState, _ action: PublishAction? = nil) -> RowSyncButtons {
        RowSyncButtons(pull: .hidden, push: push, pushTitle: "Publish", publish: action)
    }

    @Test func aBranchThatTracksNothingOffersPublish() {
        for isCurrent in [true, false] {
            #expect(
                buttons(untracked, isCurrent: isCurrent, remotes: ["fork", "origin"])
                    == publish(.enabled, .remote("origin")))
        }
        #expect(
            buttons(untracked, remotes: ["fork", "upstream"])
                == publish(
                    .enabled,
                    .menu([
                        PublishMenuItem(remote: "fork", isEnabled: true),
                        PublishMenuItem(remote: "upstream", isEnabled: true),
                    ])))
    }

    @Test func publishIsHiddenWithNoRemoteOrNoRead() {
        #expect(buttons(untracked) == .hidden, "no remotes")
        #expect(buttons(untracked, readStatus: .failed, remotes: ["origin"]) == .hidden)
        #expect(buttons(untracked, readStatus: .unread, remotes: ["origin"]) == .hidden)
        let gone = localBranch("feature", upstream: upstream("origin/feature", tracking: .gone))
        #expect(buttons(gone, remotes: ["origin"]) == .hidden, "a gone upstream is still an upstream")
    }

    @Test func publishIsDisabledWhenFetchSettingsHideTheUpstream() {
        #expect(
            buttons(untracked, remotes: ["origin", "fork"], configuredRemote: "fork")
                == publish(.disabled(reason: "Tracks fork, but fetch settings don't fetch it")))
        // A branch whose upstream reads normally ignores its config.
        #expect(buttons(tracked(ahead: 0, behind: 0), remotes: ["origin"], configuredRemote: "origin") == .hidden)
    }

    @Test func publishWaitsOnDiscoveryAndOnItsRemotesFetch() {
        let fetching = PickerButtonState.disabled(reason: "Fetching…")
        #expect(buttons(untracked, isDiscovering: true, remotes: ["origin"]) == publish(fetching))
        #expect(buttons(untracked, fetchingRemotes: ["origin"], remotes: ["origin"]) == publish(fetching))
        #expect(
            buttons(untracked, fetchingRemotes: ["fork"], remotes: ["origin", "fork"])
                == publish(.enabled, .remote("origin")), "another remote's fetch")
        #expect(
            buttons(untracked, isDiscovering: true, remotes: ["fork", "upstream"]) == publish(fetching),
            "discovery may change the list")
        // A menu stays up, and only the remote being fetched waits.
        #expect(
            buttons(untracked, fetchingRemotes: ["fork"], remotes: ["fork", "upstream"])
                == publish(
                    .enabled,
                    .menu([
                        PublishMenuItem(remote: "fork", isEnabled: false),
                        PublishMenuItem(remote: "upstream", isEnabled: true),
                    ])))
    }

    @Test func aPublishRunsOnItsRowAndHoldsTheOthers() {
        let publishing = ActiveSync(branch: "feature", operation: .publish)
        #expect(buttons(untracked, active: publishing, remotes: ["origin"]) == publish(.running))
        // The publish landed and the branch now tracks origin/feature.
        let published = tracked(ahead: 0, behind: 0, name: "feature")
        #expect(buttons(published, active: publishing, remotes: ["origin"]) == publish(.running))
        #expect(
            buttons(tracked(ahead: 1, behind: 0), active: publishing)
                == RowSyncButtons(pull: .hidden, push: .disabled(reason: "Publishing feature…")))
        let pushing = ActiveSync(branch: "main", operation: .push)
        #expect(
            buttons(untracked, active: pushing, remotes: ["origin"]) == publish(.disabled(reason: "Pushing main…")))
        #expect(
            buttons(untracked, isSwitching: true, remotes: ["origin"])
                == publish(.disabled(reason: "Switching branch…")))
    }

    @Test func aPublishRequestNeedsAnUntrackedBranchAndItsRemote() {
        let request = PublishRequest(branch: "feature", remote: "origin")
        func can(_ branches: [LocalBranch], remotes: [String] = ["origin"], configured: String? = nil) -> Bool {
            SyncPolicy.canPublish(request, branches: branches, remotes: remotes, configuredRemote: configured)
        }
        #expect(can([untracked]))
        #expect(!can([tracked(ahead: 0, behind: 0, name: "feature")]), "gained an upstream")
        #expect(!can([localBranch("main")]), "deleted")
        #expect(!can([untracked], configured: "origin"), "hidden config")
        #expect(!can([untracked], remotes: ["fork"]), "lost its remote")
    }
}
