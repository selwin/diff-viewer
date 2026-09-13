import Foundation

/// Window titles for the open repositories. A title is the repository's folder name;
/// when two repositories share a name, each colliding title gains as many parent
/// folders as it takes to tell them apart (`app — team`, then `app — work/team`).
enum WindowTitles {
    static let separator = " — "

    /// Pure: the same set of roots always yields the same titles, and a root whose
    /// name is unique is titled with its bare name regardless of the others.
    static func assign(_ roots: [RepositoryRoot]) -> [RepositoryRoot: String] {
        let roots = Array(Set(roots))
        // The number of parent folders each title currently shows.
        var depths = [RepositoryRoot: Int](uniqueKeysWithValues: roots.map { ($0, 0) })
        while true {
            let titles = [RepositoryRoot: String](
                uniqueKeysWithValues: roots.map { ($0, title(for: $0, parents: depths[$0]!)) })
            var grew = false
            for group in Dictionary(grouping: roots, by: { titles[$0]! }).values where group.count > 1 {
                for root in group where depths[root]! < parentCount(of: root) {
                    depths[root]! += 1
                    grew = true
                }
            }
            if !grew { return titles }
        }
    }

    private static func parentCount(of root: RepositoryRoot) -> Int {
        max(components(of: root).count - 1, 0)
    }

    /// Path components without the leading "/".
    private static func components(of root: RepositoryRoot) -> [String] {
        root.url.pathComponents.filter { $0 != "/" }
    }

    private static func title(for root: RepositoryRoot, parents: Int) -> String {
        let components = components(of: root)
        guard let name = components.last else { return root.path }
        guard parents > 0 else { return name }
        let suffix = components.dropLast().suffix(parents).joined(separator: "/")
        return name + separator + suffix
    }
}
