import Foundation

/// Thin wrapper over the `git` CLI for one repository.
struct GitClient: RepoClient {
    let repoRoot: URL

    static let executable = URL(fileURLWithPath: "/usr/bin/git")

    /// Environment that avoids git taking the index lock or paging.
    private static let environment = [
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_PAGER": "cat",
        "LC_ALL": "C",
    ]

    /// Resolves the repository root containing `url`, or throws if it isn't inside a repo.
    static func discoverRoot(from url: URL) async throws -> URL {
        let result = try await ProcessRunner.check(
            executable,
            arguments: ["rev-parse", "--show-toplevel"],
            currentDirectory: url,
            environment: environment
        )
        let path = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func status() async throws -> [ChangedFile] {
        let result = try await ProcessRunner.check(
            Self.executable,
            arguments: ["status", "--porcelain=v2", "-z", "--untracked-files=all", "--no-renames"],
            currentDirectory: repoRoot,
            environment: Self.environment
        )
        return GitStatusParser.parse(result.stdout)
            .sorted { ($0.area.rawValue, $0.path) < ($1.area.rawValue, $1.path) }
    }

    /// Contents of `path` in the index, or nil if the path is not in the index.
    func indexContents(of path: String) async throws -> Data? {
        try await show(":\(path)")
    }

    /// Contents of `path` at HEAD, or nil if the path does not exist there.
    func headContents(of path: String) async throws -> Data? {
        try await show("HEAD:\(path)")
    }

    /// Contents of `path` in the working tree, or nil if missing.
    func worktreeContents(of path: String) async -> Data? {
        try? Data(contentsOf: repoRoot.appendingPathComponent(path))
    }

    private func show(_ spec: String) async throws -> Data? {
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["show", spec],
            currentDirectory: repoRoot,
            environment: Self.environment
        )
        if result.status == 0 { return result.stdout }
        let stderr = result.stderrString
        if stderr.contains("does not exist") || stderr.contains("exists on disk, but not in") || stderr.contains("is in the index, but not at stage") || stderr.contains("Invalid object name") {
            return nil
        }
        throw ProcessError.failed(command: "git show \(spec)", status: result.status, stderr: stderr)
    }
}
