import AppKit
import Observation
import SwiftUI

/// An opened repository: its root, client, and watcher. Refreshes are bound to the
/// session they started in, so a result for a repository that has since been replaced
/// is discarded.
@MainActor
final class RepoSession {
    let root: URL
    let client: any RepoClient
    var watcher: (any RepoWatching)?
    /// Incremented per refresh; only the latest may publish.
    var refreshSerial = 0

    init(root: URL, client: any RepoClient) {
        self.root = root
        self.client = client
    }
}

@MainActor
@Observable
final class AppState {
    /// Discovers the repository root containing a URL and returns a client for it.
    typealias RepositoryOpener = @Sendable (URL) async throws -> (root: URL, client: any RepoClient)
    typealias WatcherFactory = @MainActor (URL, @escaping @MainActor () -> Void) -> (any RepoWatching)?

    private(set) var session: RepoSession?
    var repoRoot: URL? { session?.root }
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
    /// One cache for every difft run, shared by the loader and the prefetcher.
    let difftCache: DifftCache
    let diffLoader: DiffLoader
    let prefetcher: DiffPrefetcher

    /// Index into the current document's change blocks, for next/previous navigation.
    private(set) var currentChangeIndex: Int?
    private(set) var scrollTarget: ScrollTarget?

    var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Keys.fontSize) }
    }

    var recentRepos: [URL] {
        didSet { defaults.set(recentRepos.map(\.path), forKey: Keys.recentRepos) }
    }

    var hideWhitespace: Bool {
        didSet {
            defaults.set(hideWhitespace, forKey: Keys.hideWhitespace)
            if hideWhitespace != oldValue { reloadDiff() }
        }
    }

    /// Show only change blocks plus context; hidden runs become expandable separators.
    /// Applied in the view layer, so toggling never recomputes the diff.
    var collapseUnchanged: Bool {
        didSet { defaults.set(collapseUnchanged, forKey: Keys.collapseUnchanged) }
    }

    /// Context lines come from the hidden `collapseContextLines` default, validated once.
    let foldOptions: FoldOptions

    private let defaults: UserDefaults
    private let openRepository: RepositoryOpener
    private let watchRepository: WatcherFactory
    /// Incremented per `openRepo`; an open that is no longer the latest installs nothing.
    private var openGeneration = 0

    private enum Keys {
        static let recentRepos = "recentRepos"
        static let hideWhitespace = "hideWhitespace"
        static let fontSize = "fontSize"
        static let collapseUnchanged = "collapseUnchanged"
        static let collapseContextLines = "collapseContextLines"
    }

    static let fontSizeRange: ClosedRange<Double> = 9...24

    convenience init() {
        self.init(
            defaults: .standard,
            openRepository: { url in
                let root = try await GitClient.discoverRoot(from: url)
                return (root, GitClient(repoRoot: root))
            },
            watchRepository: { root, onChange in RepoWatcher(root: root, onChange: onChange) },
            cache: .bundled()
        )
    }

    init(defaults: UserDefaults, openRepository: @escaping RepositoryOpener, watchRepository: @escaping WatcherFactory, cache: DifftCache) {
        self.defaults = defaults
        self.openRepository = openRepository
        self.watchRepository = watchRepository
        difftCache = cache
        diffLoader = DiffLoader(cache: cache)
        prefetcher = DiffPrefetcher(cache: cache)
        let paths = defaults.stringArray(forKey: Keys.recentRepos) ?? []
        recentRepos = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        hideWhitespace = defaults.object(forKey: Keys.hideWhitespace) as? Bool ?? true
        let storedSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 12
        fontSize = min(max(storedSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        collapseUnchanged = defaults.object(forKey: Keys.collapseUnchanged) as? Bool ?? true
        foldOptions = FoldOptions.validated(contextLines: defaults.object(forKey: Keys.collapseContextLines) as? Int)
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
        openGeneration += 1
        let generation = openGeneration
        isLoading = true
        let opened: (root: URL, client: any RepoClient)
        do {
            opened = try await openRepository(url)
        } catch {
            guard generation == openGeneration else { return }
            isLoading = false
            errorMessage = "Not a git repository: \(url.path)\n\(error.localizedDescription)"
            return
        }
        guard generation == openGeneration else { return }

        prefetcher.cancel()
        session?.watcher?.stop()
        let session = RepoSession(root: opened.root, client: opened.client)
        session.watcher = watchRepository(opened.root) { [weak self, weak session] in
            guard let self, let session else { return }
            Task { await self.refresh(session: session) }
        }
        self.session = session
        selectedFileID = nil
        errorMessage = nil
        recentRepos.removeAll { $0.standardizedFileURL == opened.root.standardizedFileURL }
        recentRepos.insert(opened.root, at: 0)
        recentRepos = Array(recentRepos.prefix(10))
        await refresh(session: session)
        if generation == openGeneration { isLoading = false }
    }

    func refresh() async {
        guard let session else { return }
        await refresh(session: session)
    }

    /// Reloads the file list for `session`. The result is published only if the
    /// session is still current and no newer refresh of it has started since.
    func refresh(session: RepoSession) async {
        // A watcher callback queued before its repository was replaced: skip the read.
        guard session === self.session else { return }
        session.refreshSerial += 1
        let serial = session.refreshSerial
        let outcome: Result<[ChangedFile], Error>
        do {
            outcome = .success(try await session.client.status())
        } catch {
            outcome = .failure(error)
        }
        guard session === self.session, serial == session.refreshSerial else { return }

        switch outcome {
        case let .success(newFiles):
            files = newFiles
            if let selectedFileID, !newFiles.contains(where: { $0.id == selectedFileID }) {
                self.selectedFileID = nil
            }
            errorMessage = nil
            reloadDiff()
            // The selected file is the loader's job at foreground priority; a background
            // start for it could not be promoted once its process is running.
            let toWarm = (unstagedFiles + stagedFiles).filter { $0.id != selectedFileID }
            prefetcher.prefetch(files: toWarm, client: session.client)
        case let .failure(error):
            errorMessage = error.localizedDescription
        }
    }

    private func reloadDiff() {
        diffLoader.load(file: selectedFile, client: session?.client, hideWhitespace: hideWhitespace)
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
