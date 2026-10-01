import Testing

@testable import DiffViewer

/// What the branch picker's help and sync presentation say about the current branch's upstream.
@MainActor
struct WindowStateBranchTrackingTests {
    /// A window adopted with `branches` in the list and HEAD at `headState`, waited on
    /// past the first file list and the branch read, so the picker's values are settled.
    private func settled(
        branches: [LocalBranch], headState: HeadState, configure: (StubRepoClient) async -> Void = { _ in }
    ) async throws -> Window {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: [changedFile("a.swift")]) { client in
            await client.set(localBranches: branches)
            await client.set(headState: headState)
            await configure(client)
        }
        #expect(await eventually { await state.localBranches == branches.map(\.name) })
        #expect(state.headState == headState)
        return (h, state, repo.client, repo.root)
    }

    @Test(
        arguments: [(LocalBranch, HeadState, String)]([
            (
                localBranch("main", upstream: upstream("origin/main", tracking: .counts(ahead: 1, behind: 2))),
                HeadState.named("main"), "Switch branch · origin/main: 1 ahead · 2 behind"
            ),
            (
                localBranch("main", upstream: upstream("origin/main")),
                .named("main"), "Switch branch · origin/main: up to date"
            ),
            (
                localBranch("main", upstream: upstream("origin/main", tracking: .gone)),
                .named("main"), "Switch branch · origin/main: gone"
            ),
            (
                localBranch("main"),
                .named("main"), "Switch branch"
            ),
            // Detached: no branch is current, so its upstream is not the reader's.
            (
                localBranch("main", upstream: upstream("origin/main", tracking: .counts(ahead: 1, behind: 2))),
                .detached(sha: String(repeating: "a", count: 40)), "Switch branch"
            ),
        ]))
    func pickerHelpFollowsTheUpstream(branch: LocalBranch, headState: HeadState, help: String) async throws {
        let (_, state, _, _) = try await settled(branches: [branch], headState: headState)

        #expect(state.branchSwitchHelp == help)
    }

    /// An upstream is set and unset in branch configuration, so a configuration tick
    /// alone must re-read the list and update the title bar.
    @Test func aConfigurationTickRefreshesTheTracking() async throws {
        let untracked = localBranch("main")
        let (h, state, client, root) = try await settled(branches: [untracked], headState: .named("main"))
        #expect(state.currentBranchSync?.pushCount == nil)

        await client.set(localBranches: [
            localBranch("main", upstream: upstream("origin/main", tracking: .counts(ahead: 3, behind: 0)))
        ])
        h.tick(root, [.configuration])
        #expect(await eventually { await state.branchSwitchHelp == "Switch branch · origin/main: 3 ahead" })
        #expect(state.currentBranchSync?.pushCount == 3)

        await client.set(localBranches: [untracked])
        h.tick(root, [.configuration])
        #expect(await eventually { await state.branchSwitchHelp == "Switch branch" })
        #expect(state.currentBranchSync?.pushCount == nil)
    }

    // MARK: Publish without opening the picker

    /// The read Publish depends on that a test makes fail.
    enum FailedRead: CaseIterable {
        case remoteNames, configuredUpstreams
    }

    private func isPublishEnabled(_ state: WindowState) -> Bool {
        state.currentBranchSync?.isPublish == true && state.currentBranchSync?.buttons.push == .enabled
    }

    @Test func aBranchWithoutAnUpstreamOffersPublishBeforeThePickerOpens() async throws {
        let (_, state, client, _) = try await settled(branches: [localBranch("main")], headState: .named("main"))

        #expect(await eventually { await isPublishEnabled(state) })
        #expect(await client.fetchCalls.isEmpty)
    }

    @Test func aNewBranchOffersPublishAfterARefsTick() async throws {
        let tracked = localBranch("main", upstream: upstream("origin/main"))
        let (h, state, client, root) = try await settled(branches: [tracked], headState: .named("main"))
        #expect(state.currentBranchSync?.isPublish == false)

        await client.set(localBranches: [localBranch("feature")])
        await client.set(headState: .named("feature"))
        h.tick(root, [.refs])

        #expect(await eventually { await isPublishEnabled(state) })
        #expect(state.currentBranchSync?.branch == "feature")
    }

    @Test func aHiddenUpstreamKeepsPublishDisabled() async throws {
        let (_, state, _, _) = try await settled(
            branches: [localBranch("main")], headState: .named("main")
        ) { await $0.set(configuredUpstreamRemotes: ["main": "origin"]) }

        #expect(
            await eventually {
                await state.currentBranchSync?.buttons.push
                    == .disabled(reason: "Tracks origin, but fetch settings don't fetch it")
            })
        #expect(state.currentBranchSync?.isPublish == true)
    }

    @Test func noRemotesLeaveNothingToPublishTo() async throws {
        let (_, state, _, _) = try await settled(
            branches: [localBranch("main")], headState: .named("main")
        ) { await $0.set(remoteNames: []) }

        #expect(state.currentBranchSync?.buttons.push == .hidden)
    }

    /// A failed read keeps what was known, which is nothing on the first read. The next
    /// branch read recovers it.
    @Test(arguments: FailedRead.allCases)
    func aFailedReadRecoversOnTheNextBranchRead(failed: FailedRead) async throws {
        let (h, state, client, root) = try await settled(
            branches: [localBranch("main")], headState: .named("main")
        ) { client in
            switch failed {
            case .remoteNames:
                await client.fail(remoteNames: true)
            case .configuredUpstreams:
                await client.set(configuredUpstreamRemotes: ["main": "origin"])
                await client.fail(configuredUpstreamRemotes: true)
            }
        }
        #expect(await eventually { await state.branchReadStatus == .loaded })
        switch failed {
        case .remoteNames: #expect(state.currentBranchSync?.buttons.push == .hidden)
        case .configuredUpstreams: #expect(isPublishEnabled(state), "the hidden upstream is not known yet")
        }

        await client.fail(remoteNames: false)
        await client.fail(configuredUpstreamRemotes: false)
        h.tick(root, [.refs])

        switch failed {
        case .remoteNames:
            #expect(await eventually { await isPublishEnabled(state) })
        case .configuredUpstreams:
            #expect(
                await eventually {
                    await state.currentBranchSync?.buttons.push
                        == .disabled(reason: "Tracks origin, but fetch settings don't fetch it")
                })
        }
    }

    /// Lost remotes would hide Publish and a lost upstream map would enable it, so a
    /// disabled Publish shows both were kept.
    @Test func aFailedReadKeepsTheLastKnownValues() async throws {
        let (_, state, client, _) = try await settled(
            branches: [localBranch("main")], headState: .named("main")
        ) { await $0.set(configuredUpstreamRemotes: ["main": "origin"]) }
        let hiddenUpstream = PickerButtonState.disabled(reason: "Tracks origin, but fetch settings don't fetch it")
        #expect(await eventually { await state.currentBranchSync?.buttons.push == hiddenUpstream })

        await client.set(remoteNames: [])
        await client.set(configuredUpstreamRemotes: [:])
        await client.fail(remoteNames: true)
        await client.fail(configuredUpstreamRemotes: true)
        await state.refresh()

        #expect(state.remotes == ["origin"])
        #expect(state.currentBranchSync?.buttons.push == hiddenUpstream)
    }

    /// The stub answers with what it held when the call began, so a parked older read
    /// returns the remotes from before the newer read's.
    @Test func aSupersededBranchReadDoesNotOverwriteTheRemotes() async throws {
        let (h, state, client, root) = try await settled(branches: [localBranch("main")], headState: .named("main"))
        #expect(state.remotes == ["origin"])

        await client.hold(.remoteNames)
        let olderRefresh = Task { await state.refresh() }
        #expect(await eventually { await client.heldCount(.remoteNames) == 1 })
        await client.set(remoteNames: ["fork"])
        await client.hold(.remoteNames, false)
        h.tick(root, [.refs])
        #expect(await eventually { await state.remotes == ["fork"] })

        await client.release(.remoteNames)
        await olderRefresh.value
        #expect(state.remotes == ["fork"])
    }

    @Test func closingDuringTheRemoteReadPublishesNothing() async throws {
        let (_, state, client, _) = try await settled(branches: [localBranch("main")], headState: .named("main"))
        #expect(state.remotes == ["origin"])

        await client.set(remoteNames: ["fork"])
        await client.hold(.remoteNames)
        let refresh = Task { await state.refresh() }
        #expect(await eventually { await client.heldCount(.remoteNames) == 1 })
        let session = try #require(state.session)
        let readsBefore = session.branchReadGeneration
        state.close()
        await client.hold(.remoteNames, false)
        await client.release(.remoteNames)
        await refresh.value

        #expect(state.remotes == ["origin"])
        #expect(session.branchReadGeneration == readsBefore)
    }
}
