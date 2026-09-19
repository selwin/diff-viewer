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
            guard case let .counted(a, d)? = stats(for: section, currentFile: current[section.file.id]) else {
                continue
            }
            added += a
            deleted += d
        }
        return (added, deleted)
    }

    /// Text sections use their rendered counts; other outcomes use the current file's stats
    /// while its inputs still match, else nil.
    static func stats(for section: ChangesetSection, currentFile: ChangedFile?) -> LineStats? {
        if case .text = section.outcome {
            return .counted(added: section.added, deleted: section.deleted)
        }
        guard let currentFile, sameInputs(section.file, currentFile) else { return nil }
        return currentFile.lineStats
    }

    /// A commit's content cannot change, so its files match without a fingerprint. A
    /// working-tree file matches only on known, equal fingerprints: equal unknown ones
    /// prove nothing, as `DiffInputFingerprint.mayHaveChanged` says.
    private static func sameInputs(_ built: ChangedFile, _ current: ChangedFile) -> Bool {
        if built.area.isCommit { return true }
        return !DiffInputFingerprint.mayHaveChanged(built.fingerprint, current.fingerprint)
    }
}
