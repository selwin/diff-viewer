import Foundation

/// The canonical identity of a repository: its git toplevel, standardized with
/// symlinks resolved. One key for window routing, the scene value, and persistence.
/// Separate worktrees stay distinct because their toplevels differ.
struct RepositoryRoot: Hashable, Codable, Sendable {
    let url: URL

    init(_ url: URL) {
        self.url = URL(fileURLWithPath: url.standardizedFileURL.resolvingSymlinksInPath().path, isDirectory: true)
    }

    init(path: String) {
        self.init(URL(fileURLWithPath: path, isDirectory: true))
    }

    var path: String { url.path }
    var name: String { url.lastPathComponent }

    init(from decoder: any Decoder) throws {
        self.init(path: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(path)
    }
}
