import Foundation

extension GitClient {
    /// The stash list, newest first. `stash list` is `log -g --first-parent -m`, so
    /// `--shortstat` counts each stash's tracked changes against its first parent.
    func stashes() async throws -> [StashEntry] {
        let result = try await ProcessRunner.check(
            Self.executable,
            arguments: [
                "stash", "list", "--format=%x00%H%x00%h%x00%P%x00%cI%x00%an%x00%gs%x00", "--shortstat",
            ],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        return try StashListParser.parse(result.stdout)
    }
}
