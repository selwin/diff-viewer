import Foundation
import Testing

@testable import DiffViewer

@MainActor
struct PreferencesTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "DiffViewerTests.Preferences.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func readsStoredValuesUnderTheOriginalKeys() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "hideWhitespace")
        defaults.set(false, forKey: "collapseUnchanged")
        defaults.set(15.0, forKey: "fontSize")
        defaults.set(["/tmp/one", "/tmp/two"], forKey: "recentRepos")

        let preferences = Preferences(defaults: defaults)
        #expect(!preferences.hideWhitespace)
        #expect(!preferences.collapseUnchanged)
        #expect(preferences.fontSize == 15)
        #expect(
            preferences.recentRepositoryRoots == [RepositoryRoot(path: "/tmp/one"), RepositoryRoot(path: "/tmp/two")])
    }

    @Test func defaultsWhenNothingIsStored() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.hideWhitespace)
        #expect(preferences.collapseUnchanged)
        #expect(preferences.fontSize == 12)
        #expect(preferences.recentRepositoryRoots.isEmpty)
    }

    @Test func clampsStoredFontSize() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(40.0, forKey: "fontSize")
        #expect(Preferences(defaults: defaults).fontSize == Preferences.fontSizeRange.upperBound)
        defaults.set(3.0, forKey: "fontSize")
        #expect(Preferences(defaults: defaults).fontSize == Preferences.fontSizeRange.lowerBound)
    }

    @Test func writesChangesBack() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.hideWhitespace = false
        preferences.collapseUnchanged = false
        preferences.adjustFontSize(by: 2)
        #expect(defaults.bool(forKey: "hideWhitespace") == false)
        #expect(defaults.bool(forKey: "collapseUnchanged") == false)
        #expect(defaults.double(forKey: "fontSize") == 14)
        preferences.adjustFontSize(by: 100)
        #expect(preferences.fontSize == Preferences.fontSizeRange.upperBound)
        preferences.resetFontSize()
        #expect(defaults.double(forKey: "fontSize") == 12)
    }

    @Test func noteOpenedMovesToFrontDedupesAndCaps() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let roots = (0..<12).map { RepositoryRoot(path: "/tmp/repo\($0)") }
        for root in roots { preferences.noteOpened(root) }
        #expect(preferences.recentRepositoryRoots.count == Preferences.maxRecentRepositories)
        #expect(preferences.recentRepositoryRoots.first == roots[11])
        #expect(!preferences.recentRepositoryRoots.contains(roots[0]))

        preferences.noteOpened(roots[5])
        #expect(preferences.recentRepositoryRoots.first == roots[5])
        #expect(preferences.recentRepositoryRoots.filter { $0 == roots[5] }.count == 1)
        #expect(preferences.recentRepositoryRoots.count == Preferences.maxRecentRepositories)
        #expect(defaults.stringArray(forKey: "recentRepos")?.first == roots[5].path)
    }

    @Test func diffSettingsCallbackFiresAfterRealChangesOnly() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        var observed: [Bool] = []
        preferences.onDiffSettingsChange = { observed.append(preferences.hideWhitespace) }

        preferences.hideWhitespace = true
        #expect(observed.isEmpty, "assigning the current value is not a change")
        preferences.hideWhitespace = false
        preferences.hideWhitespace = true
        preferences.hideWhitespace = false
        #expect(observed == [false, true, false], "the new value is readable inside the callback")

        preferences.collapseUnchanged.toggle()
        preferences.adjustFontSize(by: 1)
        #expect(observed.count == 3, "presentation settings do not change diff content")
    }
}
