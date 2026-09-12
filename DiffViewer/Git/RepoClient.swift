import Foundation

/// The repository operations the app needs. `GitClient` is the real one; tests use
/// actor-backed stubs, which is why every method is async.
protocol RepoClient: Sendable {
    func status() async throws -> [ChangedFile]
    /// Contents of `path` in the index, or nil if the path is not in the index.
    func indexContents(of path: String) async throws -> Data?
    /// Contents of `path` at HEAD, or nil if the path does not exist there.
    func headContents(of path: String) async throws -> Data?
    /// Contents of `path` in the working tree, or nil if missing.
    func worktreeContents(of path: String) async -> Data?
}
