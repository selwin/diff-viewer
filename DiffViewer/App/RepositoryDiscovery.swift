import AppKit
import Foundation

/// Resolves a URL to the git repository containing it and a client for that root.
enum RepositoryDiscovery {
    typealias Result = (root: RepositoryRoot, client: any RepoClient)

    static func discover(_ url: URL, cache: RepositoryShellEnvironmentCache) async throws -> Result {
        let toplevel = try await GitClient.discoverRoot(from: url)
        // The cache key must be the canonical URL the coordinator refreshes and forgets by.
        let root = RepositoryRoot(toplevel)
        let client = GitClient(
            repoRoot: toplevel, resolveCommandEnvironment: { try await cache.environment(for: root.url) })
        return (root, client)
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
