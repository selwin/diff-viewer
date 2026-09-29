import Testing

@testable import DiffViewer

/// A repository's churn, summed from its working-tree list for the tab.
struct RepositoryChurnTests {
    @Test func stagedUnstagedAndUntrackedAllCount() {
        let churn = RepositoryChurn([
            changedFile("a.swift", area: .staged).with(lineStats: .counted(added: 5, deleted: 2)),
            changedFile("b.swift").with(lineStats: .counted(added: 1, deleted: 3)),
            changedFile("new.txt", kind: .untracked).with(lineStats: .counted(added: 10, deleted: 0)),
        ])
        #expect(churn == RepositoryChurn(changedFileCount: 3, added: 16, deleted: 5))
    }

    @Test func aPathBothStagedAndUnstagedIsOneFileWithBothDiffsLines() {
        let churn = RepositoryChurn([
            changedFile("a.swift", area: .staged).with(lineStats: .counted(added: 2, deleted: 1)),
            changedFile("a.swift").with(lineStats: .counted(added: 3, deleted: 0)),
        ])
        #expect(churn == RepositoryChurn(changedFileCount: 1, added: 5, deleted: 1))
    }

    @Test func binariesAndUncountedFilesAddNoLines() {
        let churn = RepositoryChurn([
            changedFile("a.png").with(lineStats: .binary(nil)),
            changedFile("b.swift"),
        ])
        #expect(churn == RepositoryChurn(changedFileCount: 2, added: 0, deleted: 0))
    }

    @Test(
        arguments: [
            (RepositoryChurn(changedFileCount: 0, added: 0, deleted: 0), []),
            (RepositoryChurn(changedFileCount: 7, added: 120, deleted: 45), ["+120", "−45"]),
            (RepositoryChurn(changedFileCount: 1, added: 12, deleted: 0), ["+12"]),
            (RepositoryChurn(changedFileCount: 1, added: 0, deleted: 3), ["−3"]),
            (RepositoryChurn(changedFileCount: 2, added: 0, deleted: 0), ["2 files"]),
        ] as [(RepositoryChurn, [String])])
    func tabParts(churn: RepositoryChurn, parts: [String]) {
        #expect(churn.tabParts == parts)
    }

    @Test func summaryNamesFilesAndLines() {
        #expect(RepositoryChurn(changedFileCount: 7, added: 120, deleted: 45).summary == "7 files changed · +120 −45")
        #expect(RepositoryChurn(changedFileCount: 1, added: 0, deleted: 0).summary == "1 file changed")
    }
}
