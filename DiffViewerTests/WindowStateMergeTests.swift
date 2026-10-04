import Testing

@testable import DiffViewer

@MainActor
struct WindowStateMergeTests {
    private let remoteSource = remoteBranch("feature", tipSha: objectID("feature"))

    /// A window adopted and waited on past the first reads, so every baseline is stable
    /// before the test acts. HEAD is on `main`, which `side` and `origin/feature` can merge into.
    private func settled() async throws -> Window {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: [changedFile("a.swift")]) {
            await $0.set(commits: [])
            await $0.set(
                localBranches: [
                    localBranch("main", tipSha: objectID("main")), localBranch("side", tipSha: objectID("side")),
                ])
            await $0.set(remoteBranches: [self.remoteSource])
        }
        let historyTask = try #require(state.session?.historyTask)
        await historyTask.value
        #expect(await eventually { await state.localBranches == ["main", "side"] })
        #expect(state.headState == .named("main"))
        return (h, state, repo.client, repo.root)
    }

    private func target(into: String = "main") -> MergeTarget {
        MergeTarget(
            sourceName: "side", sourceRef: "refs/heads/side", sourceTipSha: objectID("side"),
            destinationBranch: into, destinationTipSha: objectID("main"))
    }

    @Test func mergeCallsGitWithTheConfirmedShaAndRefThenRefreshes() async throws {
        let (h, state, client, _) = try await settled()
        let branchReads = await client.localBranchesCalls

        await state.merge(target())

        #expect(await client.mergeCalls == [.init(sourceTipSha: objectID("side"), sourceRef: "refs/heads/side")])
        #expect(h.published.last?.cause == .branchSwitch)
        #expect(await client.localBranchesCalls > branchReads)
        #expect(state.errorMessage == nil)
        #expect(!state.isSwitchingBranch)
    }

    /// git stops on conflicts and exits non-zero; the refresh shows them before the error does.
    @Test func aFailedMergeReportsAfterTheRefresh() async throws {
        let (h, state, client, _) = try await settled()
        await client.fail(merge: true)

        await state.merge(target())

        #expect(h.published.last?.cause == .branchSwitch)
        #expect(state.errorMessage?.contains("merge failed") == true)
        #expect(!state.isSwitchingBranch)
    }

    @Test func mergeIsRefusedWhenHeadLeftTheBranchItWasChosenFor() async throws {
        let (h, state, client, root) = try await settled()

        await state.merge(target(into: "other"))
        #expect(await client.mergeCalls.isEmpty)

        await client.set(headState: .detached(sha: objectID("main")))
        h.tick(root, [.refs])
        #expect(await eventually { await state.headState == .detached(sha: objectID("main")) })
        await state.merge(target())
        #expect(await client.mergeCalls.isEmpty)
    }

    /// The window's cache is stale until the watcher ticks; the merge asks git itself.
    @Test func mergeIsRefusedWhenGitMovedHeadBeforeTheWindowSawIt() async throws {
        let (_, state, client, _) = try await settled()
        await client.set(headState: .named("other"))

        await state.merge(target())

        #expect(await client.mergeCalls.isEmpty)
        #expect(state.errorMessage?.contains("changed before the merge could start") == true)
    }

    @Test func mergeIsRefusedWhenTheDestinationMovedSinceTheSheet() async throws {
        let (_, state, client, _) = try await settled()
        await client.set(localBranches: [
            localBranch("main", tipSha: objectID("main-2")), localBranch("side", tipSha: objectID("side")),
        ])
        let branchReads = await client.localBranchesCalls

        await state.merge(target())

        #expect(await client.mergeCalls.isEmpty)
        #expect(state.errorMessage == "main changed before the merge could start. Open the merge again to review it.")
        #expect(await client.localBranchesCalls > branchReads, "the refresh follows the refusal")
        #expect(!state.isSwitchingBranch)
    }

    /// The merge takes the confirmed sha, so the source moving or going changes nothing.
    @Test func mergeStillRunsWhenTheSourceMovedOrWentSinceTheSheet() async throws {
        let (_, state, client, _) = try await settled()
        await client.set(localBranches: [localBranch("main", tipSha: objectID("main"))])
        await client.set(remoteBranches: [remoteBranch("feature", tipSha: objectID("feature-2"))])

        await state.merge(target())
        await state.merge(.remote(remoteSource, destinationBranch: "main", destinationTipSha: objectID("main")))

        #expect(
            await client.mergeCalls == [
                .init(sourceTipSha: objectID("side"), sourceRef: "refs/heads/side"),
                .init(sourceTipSha: objectID("feature"), sourceRef: remoteSource.ref),
            ])
        #expect(state.errorMessage == nil)
    }

    @Test func mergeIsRefusedWhileASwitchRuns() async throws {
        let (_, state, client, _) = try await settled()
        await client.hold(.switchBranch)
        let switching = Task { await state.switchBranch(to: "side") }
        #expect(await eventually { await client.heldCount(.switchBranch) == 1 })

        await state.merge(target())
        #expect(await client.mergeCalls.isEmpty)
        #expect(!state.canOpenMergeSheet)

        await client.hold(.switchBranch, false)
        await client.release(.switchBranch)
        await switching.value
    }

    @Test func theSheetOpensFromThePickerAndClosesIt() async throws {
        let (_, state, _, _) = try await settled()
        state.isBranchPickerPresented = true
        #expect(state.canOpenMergeSheet == false, "the picker is still up")

        state.openMergeSheetFromPicker(target())

        #expect(!state.isBranchPickerPresented)
        #expect(state.pendingMerge == target())
        #expect(!state.canOpenBranchPicker)
        #expect(!state.canOpenNewBranchSheet)
    }
}
