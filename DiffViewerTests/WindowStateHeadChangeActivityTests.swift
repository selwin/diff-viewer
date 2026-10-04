import Testing

@testable import DiffViewer

private let conflicts = [changedFile("a.swift", kind: .unmerged), changedFile("b.swift", kind: .unmerged)]

@MainActor
struct WindowStateHeadChangeActivityTests {
    private let remoteSource = remoteBranch("feature", tipSha: objectID("feature"))

    /// A window adopted and waited on past the first reads. HEAD is on `main`, which `side`
    /// can merge into.
    private func settled(commits: [CommitSummary] = []) async throws -> Window {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: [changedFile("a.swift")]) {
            await $0.set(commits: commits)
            await $0.set(
                localBranches: [
                    localBranch("main", tipSha: objectID("main")), localBranch("side", tipSha: objectID("side")),
                ])
            await $0.set(remoteBranches: [self.remoteSource])
        }
        let historyTask = try #require(state.session?.historyTask)
        await historyTask.value
        #expect(await eventually { await state.localBranches == ["main", "side"] })
        return (h, state, repo.client, repo.root)
    }

    private func target(source: String = "side") -> MergeTarget {
        MergeTarget(
            sourceName: source, sourceRef: "refs/heads/\(source)", sourceTipSha: objectID(source),
            destinationBranch: "main", destinationTipSha: objectID("main"))
    }

    /// Lets the display duration pass once the clear timer is sleeping.
    private func expire(_ h: Harness, by duration: Duration = WindowState.headChangeFeedbackDuration) async {
        let clock = h.sleepClock
        #expect(await eventually { clock.sleeperCount == 1 })
        clock.advance(by: duration)
    }

    /// Holds the switch, starts one and waits until git has it.
    private func startHeldSwitch(_ state: WindowState, _ client: StubRepoClient) async -> Task<Void, Never> {
        await client.hold(.switchBranch)
        let task = Task { await state.switchBranch(to: "side") }
        #expect(await eventually { await client.heldCount(.switchBranch) == 1 })
        return task
    }

    private func release(_ task: Task<Void, Never>, _ client: StubRepoClient) async {
        await client.hold(.switchBranch, false)
        await client.release(.switchBranch)
        await task.value
    }

    // MARK: Switching

    @Test func aSwitchRunsThenReportsThenClearsAfterTheDisplayDuration() async throws {
        let (h, state, client, _) = try await settled()
        let task = await startHeldSwitch(state, client)
        #expect(state.headChangeActivity?.state == .running(.switchTo("side")))

        await release(task, client)
        #expect(state.headChangeActivity?.state == .finished(.switched(to: "side")))

        await expire(h)
        #expect(await eventually { await state.headChangeActivity == nil })
    }

    @Test func aFailedSwitchSetsNoActivityAndAlerts() async throws {
        let (_, state, client, _) = try await settled()
        await client.fail(switchBranch: true)

        await state.switchBranch(to: "side")

        #expect(state.headChangeActivity == nil)
        #expect(state.errorMessage?.contains("post-checkout hook failed") == true)
    }

    /// The text names the requested branch, so a switch that left HEAD where it was, or a
    /// failed branch read afterwards, still reports success.
    @Test func successNamesTheRequestedBranchWhateverTheFollowUpReadSaw() async throws {
        let (_, state, client, _) = try await settled()

        await state.switchBranch(to: "side")
        #expect(state.headChangeActivity?.state == .finished(.switched(to: "side")))

        await state.createBranch(named: "new")
        #expect(state.headChangeActivity?.state == .finished(.created("new")))

        await state.checkoutRemoteBranch(remoteSource)
        #expect(state.headChangeActivity?.state == .finished(.switched(to: "feature")))

        await client.fail(localBranches: true)
        await state.switchBranch(to: "other")
        #expect(state.headChangeActivity?.state == .finished(.switched(to: "other")))
    }

    // MARK: Merge kind

    @Test func mergeKindFollowsTheBranchTipTheMergeLeft() async throws {
        let cases: [(tipAfter: String?, source: String, kind: MergeKind)] = [
            (objectID("merged"), "side", .mergeCommit),
            (objectID("side"), "side", .fastForward),
            (nil, "side", .alreadyUpToDate),
            (nil, "main", .alreadyUpToDate),
        ]
        for (tipAfter, source, kind) in cases {
            let (_, state, client, _) = try await settled()
            if let tipAfter { await client.set(branchTipAfterMerge: tipAfter, for: "main") }

            await state.merge(target(source: source))

            #expect(
                state.headChangeActivity?.state == .finished(.merged(source: source, kind: kind, commitCount: nil)))
        }
    }

    /// Validation reads the branch first and succeeds; the read after the merge then fails.
    @Test func mergeKindIsUnknownWhenTheTipCannotBeRead() async throws {
        for response in [CommitShaResponse.none, .failure] {
            let (_, state, client, _) = try await settled()
            await client.queue(commitShas: [.sha(objectID("main")), response], for: "refs/heads/main")

            await state.merge(target())

            #expect(
                state.headChangeActivity?.state == .finished(.merged(source: "side", kind: .unknown, commitCount: nil)))
        }
    }

    @Test func mergeCountComesFromTheCachedPreview() async throws {
        let cases: [(MergePreview?, Int?)] = [
            (nil, nil), (.clean(commits: 4), 4), (.conflicts(commits: 3, paths: ["a"]), 3), (.alreadyMerged, nil),
        ]
        for (preview, count) in cases {
            let (_, state, client, _) = try await settled()
            await client.set(branchTipAfterMerge: objectID("merged"), for: "main")
            if let preview {
                await client.set(mergePreview: preview, for: target().previewKey)
                let loader = try #require(state.session?.mergePreviews)
                let token = loader.registerConsumer { _ in }
                loader.setRequestedKeys([target().previewKey], for: token)
                #expect(await eventually { await loader.cachedPreview(for: target().previewKey) != nil })
            }

            await state.merge(target())

            #expect(
                state.headChangeActivity?.state
                    == .finished(.merged(source: "side", kind: .mergeCommit, commitCount: count)))
        }
    }

    // MARK: Merge stopped

    @Test func aMergeStoppedOnConflictsShowsTheCountAndNoAlert() async throws {
        let (_, state, client, _) = try await settled()
        await client.fail(merge: true)
        await client.set(failedMergeSetsMergeHead: true, files: conflicts)

        await state.merge(target())

        #expect(state.headChangeActivity?.state == .finished(.mergeStopped(source: "side", conflictFileCount: 2)))
        #expect(state.errorMessage == nil)
    }

    /// The displayed count is the refreshed list's, not the diagnosis's.
    @Test func theConflictCountFollowsTheRefreshedRows() async throws {
        let (_, state, client, _) = try await settled()
        await client.fail(merge: true)
        await client.set(failedMergeSetsMergeHead: true)
        await client.queue(statuses: [.files(conflicts), .files([conflicts[0]])])

        await state.merge(target())

        #expect(state.headChangeActivity?.state == .finished(.mergeStopped(source: "side", conflictFileCount: 1)))
    }

    /// Anything short of a conflict stop this merge made, or a list that can show it, keeps
    /// today's alert with git's own error.
    @Test func otherMergeFailuresAlertWithGitsError() async throws {
        let setups: [(StubRepoClient) async -> Void] = [
            // A hook failure: MERGE_HEAD set, nothing unmerged.
            { await $0.set(failedMergeSetsMergeHead: true) },
            // A merge already in progress before this one started.
            {
                await $0.set(failedMergeSetsMergeHead: false, files: conflicts)
                await $0.set(commitSha: objectID("side"), for: "MERGE_HEAD")
            },
            // MERGE_HEAD names another commit than the one merged.
            {
                await $0.set(failedMergeSetsMergeHead: false, files: conflicts)
                await $0.queue(commitShas: [.none, .sha(objectID("other"))], for: "MERGE_HEAD")
            },
            // A diagnostic read throws.
            {
                await $0.set(failedMergeSetsMergeHead: true, files: conflicts)
                await $0.queue(commitShas: [.none, .failure], for: "MERGE_HEAD")
            },
            {
                await $0.set(failedMergeSetsMergeHead: true, files: conflicts)
                await $0.queue(statuses: [.failure])
            },
            // The refresh that should list the conflicts fails.
            {
                await $0.set(failedMergeSetsMergeHead: true)
                await $0.queue(statuses: [.files(conflicts), .failure])
            },
        ]
        for setup in setups {
            let (_, state, client, _) = try await settled()
            await client.fail(merge: true)
            await setup(client)

            await state.merge(target())

            #expect(state.headChangeActivity == nil)
            #expect(state.errorMessage?.contains("merge failed") == true)
        }
    }

    /// A window showing `commit`, whose merge stops on conflicts.
    private func settledInCommitScope() async throws -> (Window, CommitSummary) {
        let commit = commitSummary("c1")
        let window = try await settled(commits: [commit])
        await window.client.fail(merge: true)
        await window.client.set(failedMergeSetsMergeHead: true, files: conflicts)
        await window.client.set(
            files: [changedFile("one.swift", area: .commit(commit.ref))], forCommit: commit.ref.sha)
        window.state.select(commit: commit)
        #expect(await eventually { await window.h.published.last?.cause == .scope })
        return (window, commit)
    }

    @Test func aMergeInCommitScopeAlerts() async throws {
        let ((_, state, _, _), _) = try await settledInCommitScope()

        await state.merge(target())

        #expect(state.headChangeActivity == nil)
        #expect(state.errorMessage?.contains("merge failed") == true)
    }

    /// The reader opens a commit while the merge's re-reads run, so the conflicts are no
    /// longer what the sidebar shows.
    @Test func aScopeChangedDuringTheRefreshAlerts() async throws {
        let ((_, state, client, _), commit) = try await settledInCommitScope()
        state.selectWorkingTree()
        #expect(await eventually { await state.scope == .workingTree })
        await client.hold(.localBranches)
        let merging = Task { await state.merge(target()) }
        #expect(await eventually { await client.heldCount(.localBranches) == 1 })

        state.select(commit: commit)
        await client.hold(.localBranches, false)
        await client.release(.localBranches)
        await merging.value

        #expect(state.headChangeActivity == nil)
        #expect(state.errorMessage?.contains("merge failed") == true)
    }

    // MARK: Lifecycle

    @Test func openingThePickerClearsFinishedFeedback() async throws {
        let (_, state, _, _) = try await settled()
        await state.switchBranch(to: "side")
        #expect(state.headChangeActivity != nil)

        state.isBranchPickerPresented = true

        #expect(state.headChangeActivity == nil)
    }

    @Test func aRunningStateSurvivesTheOpenPickerAndEndsWithItsOperation() async throws {
        let (_, state, client, _) = try await settled()
        let task = await startHeldSwitch(state, client)

        state.isBranchPickerPresented = true
        #expect(state.headChangeActivity?.state == .running(.switchTo("side")))

        await release(task, client)
        #expect(state.headChangeActivity == nil)
        state.isBranchPickerPresented = false
        #expect(state.headChangeActivity == nil)
    }

    /// The first timer's deadline passes while the second activity is up.
    @Test func aFirstTimerNeverClearsASecondActivity() async throws {
        let (h, state, _, _) = try await settled()
        await state.switchBranch(to: "side")
        let first = try #require(state.headChangeActivity)
        await expire(h, by: .seconds(3))

        await state.createBranch(named: "new")
        let second = try #require(state.headChangeActivity)
        #expect(second.activityID > first.activityID)
        await expire(h, by: .seconds(2))
        // Let a stale wake-up, if there were one, run.
        await Task.yield()

        #expect(state.headChangeActivity == second)
        await expire(h, by: .seconds(2))
        #expect(await eventually { await state.headChangeActivity == nil })
    }

    @Test func closingDuringAnOperationLeavesNoActivity() async throws {
        let (_, state, client, _) = try await settled()
        let task = await startHeldSwitch(state, client)

        state.close()
        await release(task, client)

        #expect(state.headChangeActivity == nil)
    }
}
