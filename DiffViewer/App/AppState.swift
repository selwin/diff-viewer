import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AppState {
    private(set) var repoRoot: URL?
    private(set) var files: [ChangedFile] = []
    private(set) var isLoading = false
    var errorMessage: String?
    var selectedFileID: ChangedFile.ID? {
        didSet {
            if selectedFileID != oldValue {
                currentChangeIndex = nil
                scrollTarget = nil
                reloadDiff()
            }
        }
    }
    /// One cache for every difft run, shared by the loader and (later) the prefetcher.
    let difftCache: DifftCache
    let diffLoader: DiffLoader

    /// Index into the current document's change blocks, for next/previous navigation.
    private(set) var currentChangeIndex: Int?
    private(set) var scrollTarget: ScrollTarget?

    var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Keys.fontSize) }
    }

    private var watcher: RepoWatcher?

    var recentRepos: [URL] {
        didSet { UserDefaults.standard.set(recentRepos.map(\.path), forKey: Keys.recentRepos) }
    }

    var hideWhitespace: Bool {
        didSet {
            UserDefaults.standard.set(hideWhitespace, forKey: Keys.hideWhitespace)
            if hideWhitespace != oldValue { reloadDiff() }
        }
    }

    /// Show only change blocks plus context; hidden runs become expandable separators.
    /// Applied in the view layer, so toggling never recomputes the diff.
    var collapseUnchanged: Bool {
        didSet { UserDefaults.standard.set(collapseUnchanged, forKey: Keys.collapseUnchanged) }
    }

    /// Context lines come from the hidden `collapseContextLines` default, validated once.
    let foldOptions: FoldOptions

    private var client: GitClient?

    private enum Keys {
        static let recentRepos = "recentRepos"
        static let hideWhitespace = "hideWhitespace"
        static let fontSize = "fontSize"
        static let collapseUnchanged = "collapseUnchanged"
        static let collapseContextLines = "collapseContextLines"
    }

    static let fontSizeRange: ClosedRange<Double> = 9...24

    init() {
        difftCache = DifftCache.bundled()
        diffLoader = DiffLoader(cache: difftCache)
        let paths = UserDefaults.standard.stringArray(forKey: Keys.recentRepos) ?? []
        recentRepos = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        hideWhitespace = UserDefaults.standard.object(forKey: Keys.hideWhitespace) as? Bool ?? true
        let storedSize = UserDefaults.standard.object(forKey: Keys.fontSize) as? Double ?? 12
        fontSize = min(max(storedSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        collapseUnchanged = UserDefaults.standard.object(forKey: Keys.collapseUnchanged) as? Bool ?? true
        foldOptions = FoldOptions.validated(contextLines: UserDefaults.standard.object(forKey: Keys.collapseContextLines) as? Int)
    }

    var selectedFile: ChangedFile? {
        files.first { $0.id == selectedFileID }
    }

    var unstagedFiles: [ChangedFile] { files.filter { $0.area == .unstaged } }
    var stagedFiles: [ChangedFile] { files.filter { $0.area == .staged } }

    var repoName: String { repoRoot?.lastPathComponent ?? "DiffViewer" }

    // MARK: - Opening repositories

    func restoreLastRepo() async {
        guard repoRoot == nil, let last = recentRepos.first else { return }
        await openRepo(at: last)
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a git repository"
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openRepo(at: url) }
    }

    func openRepo(at url: URL) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let root = try await GitClient.discoverRoot(from: url)
            repoRoot = root
            client = GitClient(repoRoot: root)
            watcher?.stop()
            watcher = RepoWatcher(root: root) { [weak self] in
                Task { await self?.refresh() }
            }
            selectedFileID = nil
            errorMessage = nil
            recentRepos.removeAll { $0.standardizedFileURL == root.standardizedFileURL }
            recentRepos.insert(root, at: 0)
            recentRepos = Array(recentRepos.prefix(10))
            await refresh()
        } catch {
            errorMessage = "Not a git repository: \(url.path)\n\(error.localizedDescription)"
        }
    }

    func refresh() async {
        guard let client else { return }
        do {
            let newFiles = try await client.status()
            files = newFiles
            if let selectedFileID, !newFiles.contains(where: { $0.id == selectedFileID }) {
                self.selectedFileID = nil
            }
            errorMessage = nil
            reloadDiff()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadDiff() {
        diffLoader.load(file: selectedFile, client: client, hideWhitespace: hideWhitespace)
    }

    // MARK: - Change navigation

    var changeBlockCount: Int {
        if case let .text(document)? = diffLoader.content { return document.changeBlocks.count }
        return 0
    }

    func nextChange() {
        jump(to: ChangeNavigator.next(after: ChangeNavigator.clamp(currentChangeIndex, count: changeBlockCount), count: changeBlockCount))
    }

    func previousChange() {
        jump(to: ChangeNavigator.previous(before: ChangeNavigator.clamp(currentChangeIndex, count: changeBlockCount), count: changeBlockCount))
    }

    private func jump(to index: Int?) {
        guard let index, case let .text(document)? = diffLoader.content else { return }
        currentChangeIndex = index
        scrollTarget = ScrollTarget(row: document.changeBlocks[index].lowerBound)
    }

    // MARK: - Font size

    func adjustFontSize(by delta: Double) {
        fontSize = min(max(fontSize + delta, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
    }

    func resetFontSize() {
        fontSize = 12
    }
}
