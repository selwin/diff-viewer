import Foundation

/// Judges a remote's `remote.<name>.fetch` mappings, as the caller read them.
enum FetchRefspecs {
    /// True when `--prune` could delete nothing but remote-tracking refs: every mapping
    /// that stores anything stores it under `refs/remotes/`. `--prune` deletes from every
    /// destination, so a tag or mirror mapping would let it delete local tags or branches.
    /// Negative and destination-less refspecs store nothing and are skipped; no mapping at
    /// all means no prune.
    static func prunesOnlyTrackingRefs(_ refspecs: [String]) -> Bool {
        let destinations = refspecs.compactMap { parse($0).destination }
        return !destinations.isEmpty && destinations.allSatisfy { $0.hasPrefix("refs/remotes/") }
    }

    /// One refspec with its force `+` dropped.
    private struct Refspec {
        let isNegative: Bool
        let source: String
        /// Nil when the refspec stores nothing: a negative one, or no destination after `:`.
        let destination: String?
    }

    private static func parse(_ refspec: String) -> Refspec {
        let spec = refspec.hasPrefix("+") ? String(refspec.dropFirst()) : refspec
        if spec.hasPrefix("^") {
            return Refspec(isNegative: true, source: String(spec.dropFirst()), destination: nil)
        }
        guard let colon = spec.firstIndex(of: ":") else {
            return Refspec(isNegative: false, source: spec, destination: nil)
        }
        let destination = String(spec[spec.index(after: colon)...])
        return Refspec(
            isNegative: false, source: String(spec[..<colon]), destination: destination.isEmpty ? nil : destination)
    }
}

extension FetchRefspecs {
    /// Where one remote's mapping says a tracking ref came from.
    struct Source: Sendable, Hashable {
        let remote: String
        /// The ref on the remote: `refs/heads/main`.
        let ref: String
    }

    /// Every remote and source ref whose fetch mapping stores into `trackingRef`, from the
    /// `remote.<name>.fetch` values keyed by remote. A source matching one of its remote's
    /// negative refspecs is not mapped by that remote.
    static func sources(of trackingRef: String, refspecsByRemote: [String: [String]]) -> Set<Source> {
        var sources: Set<Source> = []
        for (remote, refspecs) in refspecsByRemote {
            var negatives: [String] = []
            var candidates: [String] = []
            for text in refspecs {
                let refspec = parse(text)
                if refspec.isNegative {
                    negatives.append(refspec.source)
                    continue
                }
                guard let destination = refspec.destination,
                    let mapped = invert(source: refspec.source, destination: destination, trackingRef)
                else { continue }
                candidates.append(mapped)
            }
            for ref in candidates where !negatives.contains(where: { match($0, ref) != nil }) {
                sources.insert(Source(remote: remote, ref: ref))
            }
        }
        return sources
    }

    /// The source a refspec fetched into `trackingRef`, or nil when its destination does
    /// not match. A glob's `*` must appear once on each side, as git requires.
    private static func invert(source: String, destination: String, _ trackingRef: String) -> String? {
        let sourceStars = source.filter { $0 == "*" }.count
        let destinationStars = destination.filter { $0 == "*" }.count
        switch (sourceStars, destinationStars) {
        case (0, 0):
            return destination == trackingRef ? source : nil
        case (1, 1):
            guard let captured = match(destination, trackingRef) else { return nil }
            return source.replacingOccurrences(of: "*", with: captured)
        default:
            return nil
        }
    }

    /// What `pattern`'s `*` captures in `name`, "" for an exact match, or nil for none.
    private static func match(_ pattern: String, _ name: String) -> String? {
        guard let star = pattern.firstIndex(of: "*") else { return pattern == name ? "" : nil }
        let prefix = pattern[..<star]
        let suffix = pattern[pattern.index(after: star)...]
        guard name.count >= prefix.count + suffix.count, name.hasPrefix(prefix), name.hasSuffix(suffix) else {
            return nil
        }
        return String(name.dropFirst(prefix.count).dropLast(suffix.count))
    }
}
