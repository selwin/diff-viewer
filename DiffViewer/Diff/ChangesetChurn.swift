import Foundation

/// The header total for the displayed changeset. `.text` sections carry their own
/// row-derived counts. Every other section (binary, too large, not shown, …) borrows
/// the current file's line stats, but only while that file's inputs are known to be the
/// ones the section was built from, so the header never mixes two content versions.
enum ChangesetChurn {
    /// Sums `sections`, taking non-text counts from `files`. Both sides may be zero; the
    /// view decides how to show that.
    static func total(sections: [ChangesetSection], files: [ChangedFile]) -> (added: Int, deleted: Int) {
        let current = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var added = 0
        var deleted = 0
        for section in sections {
            if case .text = section.outcome {
                added += section.added
                deleted += section.deleted
                continue
            }
            guard let file = current[section.file.id], sameInputs(section.file, file),
                case let .counted(a, d)? = file.lineStats
            else { continue }
            added += a
            deleted += d
        }
        return (added, deleted)
    }

    /// A commit's content cannot change, so its files match without a fingerprint. A
    /// working-tree file matches only on known, equal fingerprints: equal unknown ones
    /// prove nothing, as `DiffInputFingerprint.mayHaveChanged` says.
    private static func sameInputs(_ built: ChangedFile, _ current: ChangedFile) -> Bool {
        if built.area.isCommit { return true }
        return !DiffInputFingerprint.mayHaveChanged(built.fingerprint, current.fingerprint)
    }
}
