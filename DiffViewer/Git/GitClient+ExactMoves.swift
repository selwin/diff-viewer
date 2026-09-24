import Foundation

/// Exact move pairing for `status()`: sizing and hashing the candidates `ExactMovePairing` picks.
extension GitClient {
    /// `files` with each plain `mv` of unchanged content shown as one unstaged rename.
    /// Decoration: any failure leaves the list as status reported it.
    func pairingExactMoves(in files: [ChangedFile]) async -> [ChangedFile] {
        guard let candidates = ExactMovePairing.candidates(in: files),
            let sizes = try? await objectSizes(of: candidates.deletedBlobIDs)
        else { return files }
        // Only same-size files can match, so most untracked files are never hashed.
        let deletedSizes = Set(sizes.compactMap { $0 })
        let paths = candidates.untrackedSizes
            .filter { path, size in
                deletedSizes.contains(size) && Self.isRegularFile(at: repoRoot.appendingPathComponent(path))
            }
            .keys.sorted()
        guard !paths.isEmpty, let ids = try? await rawBlobIDs(ofWorktreePaths: paths) else { return files }
        return ExactMovePairing.apply(to: files, rawBlobIDs: ids)
    }

    /// `hash-object` follows a symlink and would hash its target, while git stores a link
    /// as its target's path, so only regular files can be compared.
    private static func isRegularFile(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    /// The blob id each worktree file would get, by path, without writing any object.
    /// `--no-filters` hashes the raw bytes, which are what the diff reads, so equal ids
    /// mean an empty diff; it also keeps filter processes such as LFS from running. Each
    /// path is sent as `./path` because git unquotes a line that starts with `"`. Paths
    /// one stdin line cannot carry are left out: an LF splits the line and git strips a
    /// trailing CR.
    func rawBlobIDs(ofWorktreePaths paths: [String]) async throws -> [String: String] {
        let lineEncodablePaths = paths.filter { !Self.breaksLineFraming($0) }
        if lineEncodablePaths.isEmpty { return [:] }
        let lines = try await batch(
            ["hash-object", "--no-filters", "--stdin-paths"], lines: lineEncodablePaths.map { "./" + $0 })
        return Dictionary(zip(lineEncodablePaths, lines.map(String.init)), uniquingKeysWith: { first, _ in first })
    }
}
