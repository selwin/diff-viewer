import CoreServices
import Testing

@testable import DiffViewer

/// Which FSEvents paths reach the app and as what. The dropped set is what git touches on
/// nearly every operation, so getting it wrong means refreshing on every object write.
struct RepoEventFilterTests {
    private let root = "/private/tmp/repo"

    private func classify(_ relative: String, flags: FSEventStreamEventFlags = 0) -> RepoChange? {
        RepoEventFilter.classify(path: root + "/" + relative, flags: flags, root: root)
    }

    @Test(arguments: [
        (".git/index", RepoChange.index),
        (".git/HEAD", .refs),
        (".git/packed-refs", .refs),
        (".git/refs/heads/main", .refs),
        (".git/refs/tags/v1", .refs),
        (".git/MERGE_HEAD", .commitState),
        (".git/MERGE_MSG", .commitState),
        (".git/SQUASH_MSG", .commitState),
        (".git/CHERRY_PICK_HEAD", .commitState),
        (".git/REVERT_HEAD", .commitState),
        (".git/rebase-merge", .commitState),
        (".git/rebase-merge/done", .commitState),
        (".git/rebase-apply/patch", .commitState),
        (".git/config", .configuration),
        (".git/config.worktree", .configuration),
        (".git/info/exclude", .configuration),
        (".git/info/attributes", .configuration),
    ])
    func metadataPathsAreClassified(relative: String, expected: RepoChange) {
        #expect(classify(relative) == expected)
    }

    @Test(arguments: [
        ".git/index.lock", ".git/logs/HEAD", ".git/logs/refs/heads/main", ".git/objects/ab/cdef",
        ".git/objects/pack/pack-1.idx", ".git/FETCH_HEAD", ".git/ORIG_HEAD", ".git/hooks/pre-commit",
        ".git/info/refs", ".git/objects", ".git/logs", ".git/refs", ".git/COMMIT_EDITMSG", ".git/description",
    ])
    func noiseInsideGitIsDropped(relative: String) {
        #expect(classify(relative) == nil)
    }

    @Test(arguments: [
        kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagRootChanged,
        kFSEventStreamEventFlagEventIdsWrapped,
    ])
    func scanFlagsMeanRescanWhateverThePath(flag: Int) {
        let flags = FSEventStreamEventFlags(flag)
        #expect(classify(".git/objects/ab/cdef", flags: flags) == .rescan)
        #expect(RepoEventFilter.classify(path: "/elsewhere", flags: flags, root: root) == .rescan)
    }

    /// A configured template is read from wherever it lives, `.git` included, so its
    /// path outranks the drop rules.
    @Test func aDependencyPathIsCommitStateWhereverItLives() {
        let inGit = root + "/.git/commit-template"
        let inTree = root + "/.gitmessage"
        func classify(_ path: String, dependencies: Set<String> = [inGit, inTree]) -> RepoChange? {
            RepoEventFilter.classify(path: path, flags: 0, root: root, dependencies: dependencies)
        }
        #expect(classify(inGit) == .commitState)
        #expect(classify(inGit + "/") == .commitState)
        #expect(classify(inTree) == .commitState)
        #expect(classify(inGit, dependencies: []) == nil, "without the dependency it is noise")
    }

    @Test func theGitDirectoryItselfMeansRescan() {
        #expect(classify(".git") == .rescan)
        #expect(classify(".git/") == .rescan)
    }

    @Test func ignoreAndAttributesFilesAreConfigurationAtAnyDepth() {
        #expect(classify(".gitignore") == .configuration)
        #expect(classify("src/.gitignore") == .configuration)
        #expect(classify(".gitattributes") == .configuration)
        #expect(classify("docs/.gitattributes") == .configuration)
    }

    /// The `.git` prefix check includes the slash, so sibling names that merely start with
    /// `.git` are ordinary worktree paths.
    @Test func gitPrefixedNamesOutsideGitAreWorktree() {
        #expect(classify(".github/workflows/ci.yml") == .worktree)
        #expect(classify(".gitmodules") == .worktree)
        #expect(classify("src/main.swift") == .worktree)
    }

    @Test func theRootItselfIsWorktree() {
        #expect(RepoEventFilter.classify(path: root, flags: 0, root: root) == .worktree)
        #expect(RepoEventFilter.classify(path: root + "/", flags: 0, root: root) == .worktree)
    }

    @Test func pathsOutsideTheRootAreDropped() {
        #expect(RepoEventFilter.classify(path: "/private/tmp/other/file", flags: 0, root: root) == nil)
        // A sibling whose name extends the root's is not inside it.
        #expect(RepoEventFilter.classify(path: root + "2/file", flags: 0, root: root) == nil)
    }

    @Test func trailingSlashesAreTolerated() {
        #expect(classify(".git/refs/heads/") == .refs)
        #expect(classify(".git/rebase-merge/") == .commitState)
        #expect(classify("src/") == .worktree)
        #expect(classify(".git/objects/ab/") == nil)
    }
}
