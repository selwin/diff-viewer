import AppKit
import Foundation

/// Resolves a URL to the git repository containing it and a client for that root.
enum RepositoryDiscovery {
    typealias Result = (root: RepositoryRoot, client: any RepoClient)

    static func discover(_ url: URL) async throws -> Result {
        let toplevel = try await GitClient.discoverRoot(from: url)
        return (RepositoryRoot(toplevel), GitClient(repoRoot: toplevel))
    }

    /// Runs the standard folder chooser; nil when cancelled.
    @MainActor
    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a git repository"
        panel.prompt = "Open"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
