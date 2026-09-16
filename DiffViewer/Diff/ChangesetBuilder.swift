import Foundation

/// Turns one result per changed file into a flat `ChangesetDocument`. Admission (the
/// file cap and the byte cap) is the caller's decision, so the input is already ordered
/// and already carries the outcome of anything that was rejected.
enum ChangesetBuilder {
    /// What happened to one file. `.content` is a finished diff; the rest never ran.
    enum FileResult: Sendable {
        case content(DiffContent)
        case tooLarge
        case notShown
        case failed(String)
    }

    static func build(
        results: [(file: ChangedFile, result: FileResult)], loadID: UUID, revision: Int,
        foldOptions: FoldOptions = FoldOptions()
    ) -> ChangesetDocument {
        var oldLines: [String] = []
        var newLines: [String] = []
        var rows: [DiffRow] = []
        var boundaries: [Int] = []
        var sections: [ChangesetSection] = []

        for (file, result) in results {
            let rowStart = rows.count
            let oldStart = oldLines.count
            let newStart = newLines.count
            // A change block may not span two files, so every section after the first
            // starts on a boundary.
            if !sections.isEmpty { boundaries.append(rowStart) }

            guard case let .content(.text(document)) = result, !document.changeBlocks.isEmpty else {
                sections.append(
                    emptySection(
                        file: file, outcome: outcome(for: result), rowStart: rowStart, oldStart: oldStart,
                        newStart: newStart))
                continue
            }

            var added = 0
            var deleted = 0
            for row in document.rows {
                switch row.kind {
                case .added: added += 1
                case .deleted: deleted += 1
                case .modified:
                    added += 1
                    deleted += 1
                case .equal: break
                }
                rows.append(
                    DiffRow(
                        kind: row.kind,
                        old: shifted(row.old, by: oldStart),
                        new: shifted(row.new, by: newStart)))
            }
            oldLines.append(contentsOf: document.oldLines)
            newLines.append(contentsOf: document.newLines)

            sections.append(
                ChangesetSection(
                    file: file,
                    rowRange: rowStart..<rows.count,
                    oldLineOffset: oldStart,
                    newLineOffset: newStart,
                    oldLineCount: document.oldLines.count,
                    newLineCount: document.newLines.count,
                    added: added,
                    deleted: deleted,
                    outcome: .text(language: document.language)))
        }

        let flat = DiffDocument(
            oldLines: oldLines, newLines: newLines, rows: rows, language: nil, blockBoundaries: boundaries)
        return ChangesetDocument(
            document: flat, sections: sections, loadID: loadID, revision: revision, foldOptions: foldOptions)
    }

    /// A section that contributed no rows and no lines. Its counts fall back to numstat,
    /// which is all we know about a file that was never diffed.
    private static func emptySection(
        file: ChangedFile, outcome: FileOutcome, rowStart: Int, oldStart: Int, newStart: Int
    ) -> ChangesetSection {
        var added = 0
        var deleted = 0
        if case let .counted(a, d)? = file.lineStats {
            added = a
            deleted = d
        }
        return ChangesetSection(
            file: file,
            rowRange: rowStart..<rowStart,
            oldLineOffset: oldStart,
            newLineOffset: newStart,
            oldLineCount: 0,
            newLineCount: 0,
            added: added,
            deleted: deleted,
            outcome: outcome)
    }

    /// The outcome of everything that contributes no rows. A text document with no
    /// change blocks is the one case decided here rather than by the caller.
    private static func outcome(for result: FileResult) -> FileOutcome {
        switch result {
        case .content(.text): .noVisibleChanges
        case .content(.binary): .binary
        case .content(.identical): .identical
        case .content(.changeset): preconditionFailure("a section is one file, never a changeset")
        case .tooLarge: .tooLarge
        case .notShown: .notShown
        case let .failed(message): .failed(message)
        }
    }

    private static func shifted(_ side: DiffSide?, by offset: Int) -> DiffSide? {
        guard let side else { return nil }
        return DiffSide(lineIndex: side.lineIndex + offset, highlights: side.highlights)
    }
}
