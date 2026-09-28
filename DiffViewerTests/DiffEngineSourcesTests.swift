import Foundation
import Testing

@testable import DiffViewer

/// Which revisions a commit's file is read from. The sides that exist are decided from
/// the change kind and whether the commit has a parent — never from a read that came
/// back empty, which is how a missing commit used to masquerade as a wholesale addition.
private let sha = String(repeating: "a", count: 40)
private let parent = String(repeating: "b", count: 40)
private let commit = CommitRef(sha: sha, shortSha: "aaaaaaa", firstParentSHA: parent)
/// A root commit has no `^` to read: its old side is empty by construction, and no
/// revision that cannot resolve is ever asked for.
private let rootCommit = CommitRef(sha: sha, shortSha: "aaaaaaa", firstParentSHA: nil)

struct DiffEngineSourcesTests {
    /// Each side that exists is read at its revision; a side that does not is never read.
    @Test(arguments: [
        (ChangedFile.Kind.modified, commit, [parent, sha]),
        (.added, commit, [sha]),
        (.deleted, commit, [parent]),
        (.modified, rootCommit, [sha]),
    ])
    func aCommitsFileReadsOnlyTheSidesThatExist(kind: ChangedFile.Kind, ref: CommitRef, revisions: [String])
        async throws
    {
        let file = ChangedFile(path: "src/a.swift", originalPath: nil, kind: kind, area: .commit(ref))
        let client = StubRepoClient(files: [])
        let sources = try await DiffEngine.sources(for: file, client: client)
        let reads = await client.contentRevisions
        #expect(reads.map(\.revision) == revisions)
        #expect(reads.allSatisfy { $0.path == "src/a.swift" })
        #expect(sources.oldExists == revisions.contains(parent))
        #expect(sources.newExists == revisions.contains(sha))
        #expect(sources.old == (sources.oldExists ? Data("\(parent):src/a.swift".utf8) : Data()))
        #expect(sources.new == (sources.newExists ? Data("\(sha):src/a.swift".utf8) : Data()))
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

    /// An intent-to-add move: the index still holds the old path, the worktree the new one.
    @Test func anUnstagedRenameReadsTheIndexAtTheOldPath() async throws {
        let client = StubRepoClient(files: [])
        let renamed = ChangedFile(
            path: "src/new.swift", originalPath: "src/old.swift", kind: .renamed, area: .unstaged, fingerprint: nil)
        let sources = try await DiffEngine.sources(for: renamed, client: client)
        #expect(await client.readPaths == ["src/old.swift", "src/new.swift"])
        #expect(sources.old == Data("old src/old.swift".utf8))
        #expect(sources.new == Data("new src/new.swift".utf8))
    }

    @Test func anUntrackedFileHasNoOldSide() async throws {
        let client = StubRepoClient(files: [])
        let sources = try await DiffEngine.sources(for: changedFile("src/a.swift", kind: .untracked), client: client)
        #expect(!sources.oldExists)
        #expect(sources.newExists)
    }
}
