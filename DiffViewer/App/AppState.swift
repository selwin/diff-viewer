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
        didSet { if selectedFileID != oldValue { reloadDiff() } }
    }
    let diffLoader = DiffLoader()

    var recentRepos: [URL] {
        didSet { UserDefaults.standard.set(recentRepos.map(\.path), forKey: Keys.recentRepos) }
    }

    var hideWhitespace: Bool {
        didSet {
            UserDefaults.standard.set(hideWhitespace, forKey: Keys.hideWhitespace)
            if hideWhitespace != oldValue { reloadDiff() }
        }
    }

    private var client: GitClient?

    private enum Keys {
        static let recentRepos = "recentRepos"
        static let hideWhitespace = "hideWhitespace"
    }

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: Keys.recentRepos) ?? []
        recentRepos = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        hideWhitespace = UserDefaults.standard.object(forKey: Keys.hideWhitespace) as? Bool ?? true
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
}
