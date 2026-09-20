import Foundation
import Testing

@testable import DiffViewer

/// Which revisions a commit's file is read from. The sides that exist are decided from
/// the change kind and whether the commit has a parent — never from a read that came
/// back empty, which is how a missing commit used to masquerade as a wholesale addition.
struct DiffEngineSourcesTests {
    private let sha = String(repeating: "a", count: 40)
    private let parent = String(repeating: "b", count: 40)

    private func ref(root: Bool = false) -> CommitRef {
        CommitRef(sha: sha, shortSha: "aaaaaaa", firstParentSHA: root ? nil : parent)
    }

    private func file(_ kind: ChangedFile.Kind, root: Bool = false) -> ChangedFile {
        ChangedFile(path: "src/a.swift", originalPath: nil, kind: kind, area: .commit(ref(root: root)))
    }

    @Test func modifiedReadsBothSides() async throws {
        let client = StubRepoClient(files: [])
        let sources = try await DiffEngine.sources(for: file(.modified), client: client)
        let reads = await client.contentRevisions
        #expect(reads.map(\.revision) == [parent, sha])
        #expect(reads.allSatisfy { $0.path == "src/a.swift" })
        #expect(sources.old == Data("\(parent):src/a.swift".utf8))
        #expect(sources.new == Data("\(sha):src/a.swift".utf8))
        #expect(sources.oldExists && sources.newExists)
    }

    @Test func addedReadsOnlyTheCommit() async throws {
        let client = StubRepoClient(files: [])
        let sources = try await DiffEngine.sources(for: file(.added), client: client)
        let reads = await client.contentRevisions
        #expect(reads.map(\.revision) == [sha])
        #expect(sources.old.isEmpty)
        #expect(!sources.oldExists)
        #expect(sources.newExists)
    }

    @Test func deletedReadsOnlyTheParent() async throws {
        let client = StubRepoClient(files: [])
        let sources = try await DiffEngine.sources(for: file(.deleted), client: client)
        let reads = await client.contentRevisions
        #expect(reads.map(\.revision) == [parent])
        #expect(sources.new.isEmpty)
        #expect(sources.oldExists)
        #expect(!sources.newExists)
    }

    /// A root commit has no `^` to read: its old side is empty by construction, and no
    /// revision that cannot resolve is ever asked for.
    @Test func rootCommitReadsNoParentRevision() async throws {
        let client = StubRepoClient(files: [])
        let sources = try await DiffEngine.sources(for: file(.added, root: true), client: client)
        let reads = await client.contentRevisions
        #expect(reads.map(\.revision) == [sha])
        #expect(sources.old.isEmpty)
        #expect(!sources.oldExists)
        #expect(!sources.new.isEmpty)
    }

    @Test func workingTreeFilesStillReadTheIndexAndWorktree() async throws {
        let client = StubRepoClient(files: [])
        let sources = try await DiffEngine.sources(for: changedFile("src/a.swift"), client: client)
        #expect(await client.contentRevisions.isEmpty)
        #expect(sources.old == Data("old src/a.swift".utf8))
        #expect(sources.new == Data("new src/a.swift".utf8))
    }

    @Test func anEmptyWorktreeFileStillExists() async throws {
        let client = StubRepoClient(files: [])
        await client.set(worktree: Data(), for: "src/a.swift")
        let sources = try await DiffEngine.sources(for: changedFile("src/a.swift"), client: client)
        #expect(sources.new.isEmpty)
        #expect(sources.newExists)
    }

    @Test func anUntrackedFileHasNoOldSide() async throws {
        let client = StubRepoClient(files: [])
        let sources = try await DiffEngine.sources(for: changedFile("src/a.swift", kind: .untracked), client: client)
        #expect(!sources.oldExists)
        #expect(sources.newExists)
    }
}
