import Foundation

/// Judges a remote's `remote.<name>.fetch` mappings, as the caller read them.
enum FetchRefspecs {
    /// True when `--prune` could delete nothing but remote-tracking refs: every mapping
    /// that stores anything stores it under `refs/remotes/`. `--prune` deletes from every
    /// destination, so a tag or mirror mapping would let it delete local tags or branches.
    /// Negative and destination-less refspecs store nothing and are skipped; no mapping at
    /// all means no prune.
    static func prunesOnlyTrackingRefs(_ refspecs: [String]) -> Bool {
        var destinations: [Substring] = []
        for refspec in refspecs {
            let spec = refspec.hasPrefix("+") ? refspec.dropFirst() : Substring(refspec)
            guard !spec.hasPrefix("^"), let colon = spec.firstIndex(of: ":") else { continue }
            let destination = spec[spec.index(after: colon)...]
            if !destination.isEmpty { destinations.append(destination) }
        }
        return !destinations.isEmpty && destinations.allSatisfy { $0.hasPrefix("refs/remotes/") }
    }
}
