import Testing
@testable import DiffViewer

struct WindowTitlesTests {
    private func root(_ path: String) -> RepositoryRoot { RepositoryRoot(path: path) }

    @Test func uniqueNamesStayBare() {
        let titles = WindowTitles.assign([root("/work/app"), root("/work/site"), root("/personal/blog")])
        #expect(titles == [root("/work/app"): "app", root("/work/site"): "site", root("/personal/blog"): "blog"])
    }

    @Test func sameNameGainsTheParentFolder() {
        let titles = WindowTitles.assign([root("/work/app"), root("/personal/app"), root("/work/site")])
        #expect(titles[root("/work/app")] == "app — work")
        #expect(titles[root("/personal/app")] == "app — personal")
        #expect(titles[root("/work/site")] == "site", "a unique name is untouched by others colliding")
    }

    @Test func rootsDifferingTwoLevelsUpGetTwoParents() {
        let titles = WindowTitles.assign([root("/work/team/app"), root("/personal/team/app")])
        #expect(titles[root("/work/team/app")] == "app — work/team")
        #expect(titles[root("/personal/team/app")] == "app — personal/team")
    }

    @Test func onlyTheCollidingTitlesGrow() {
        let titles = WindowTitles.assign([root("/a/x/app"), root("/b/x/app"), root("/c/app")])
        #expect(titles[root("/a/x/app")] == "app — a/x")
        #expect(titles[root("/b/x/app")] == "app — b/x")
        #expect(titles[root("/c/app")] == "app — c", "distinct after one parent; it stops there")
    }

    @Test func removingARootRestoresTheBareName() {
        let both = WindowTitles.assign([root("/work/app"), root("/personal/app")])
        #expect(both[root("/work/app")] == "app — work")
        let one = WindowTitles.assign([root("/work/app")])
        #expect(one[root("/work/app")] == "app")
    }

    @Test func aRootWithNoParentsLeftKeepsItsFullestTitle() {
        let titles = WindowTitles.assign([root("/app"), root("/x/app")])
        #expect(titles[root("/app")] == "app")
        #expect(titles[root("/x/app")] == "app — x")
    }

    @Test func emptyInputGivesNoTitles() {
        #expect(WindowTitles.assign([]).isEmpty)
    }
}
