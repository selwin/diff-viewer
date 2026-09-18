import Foundation

/// Carries a viewport position from one changeset to the one that replaces it.
///
/// Approximate on purpose: it keeps the reader in the same file at the same source line,
/// where "same line" is the new-side line number of the row at the top of the viewport
/// (the old-side number for a deleted row), matched to the first row of that file in the
/// new changeset whose line number on that side is at least as large. Files are matched
/// by `ChangedFile.id`; a file that lost its rows, or vanished, falls back to a header.
enum ChangesetAnchor {
    /// The display index in `to` that shows roughly what `displayIndex` showed in `from`,
    /// or nil when `from` has no such row or `to` has nothing to show.
    static func translate(displayIndex: Int, from: ChangesetDocument, to: ChangesetDocument) -> Int? {
        guard from.folded.displayRows.indices.contains(displayIndex) else { return nil }
        guard !to.sections.isEmpty else { return nil }
        let headers = headerIndices(in: to)

        switch from.folded.displayRows[displayIndex] {
        case let .fileHeader(section), let .spacer(section), let .notice(section):
            return header(forSection: section, in: from, to: to, headers: headers)
        case let .documentRow(row):
            return translate(documentRow: row, from: from, to: to, headers: headers)
        case let .separator(hidden):
            return translate(documentRow: hidden.lowerBound, from: from, to: to, headers: headers)
        }
    }

    private static func translate(
        documentRow: Int, from: ChangesetDocument, to: ChangesetDocument, headers: [ChangedFile.ID: Int]
    ) -> Int? {
        guard let sectionIndex = from.sections.firstIndex(where: { $0.rowRange.contains(documentRow) }) else {
            return nil
        }
        let section = from.sections[sectionIndex]
        let row = from.document.rows[documentRow]

        // Gone, or no rows any more (binary, identical, failed, …): show a header.
        let targetSection = to.sections.first { $0.file.id == section.file.id }
        guard let targetSection, !targetSection.rowRange.isEmpty else {
            return header(forSection: sectionIndex, in: from, to: to, headers: headers)
        }

        let matchingDocumentRow: Int?
        if let new = row.new {
            let localLineIndex = new.lineIndex - section.newLineOffset
            matchingDocumentRow = targetSection.rowRange.first {
                localLine(to.document.rows[$0].new, targetSection.newLineOffset) >= localLineIndex
            }
        } else if let old = row.old {
            let localLineIndex = old.lineIndex - section.oldLineOffset
            matchingDocumentRow = targetSection.rowRange.first {
                localLine(to.document.rows[$0].old, targetSection.oldLineOffset) >= localLineIndex
            }
        } else {
            return nil
        }
        // Past the end of the file now: the last row it has.
        return to.folded.displayIndex(forDocumentRow: matchingDocumentRow ?? targetSection.rowRange.upperBound - 1)
    }

    /// The header of `section`'s file in `to`; if that file is gone, the header of the
    /// next `from` section that survives, else `to`'s last header.
    private static func header(
        forSection section: Int, in from: ChangesetDocument, to: ChangesetDocument, headers: [ChangedFile.ID: Int]
    ) -> Int? {
        for sectionIndex in section..<from.sections.count {
            if let index = headers[from.sections[sectionIndex].file.id] { return index }
        }
        return to.sections.last.flatMap { headers[$0.file.id] }
    }

    /// A side's line number within its file, or -1 when the row has no such side, so a
    /// row missing the side never matches.
    private static func localLine(_ side: DiffSide?, _ offset: Int) -> Int {
        side.map { $0.lineIndex - offset } ?? -1
    }

    /// Display index of every `.fileHeader`, by file id; the first wins if an id repeats.
    private static func headerIndices(in changeset: ChangesetDocument) -> [ChangedFile.ID: Int] {
        var headers: [ChangedFile.ID: Int] = [:]
        for (index, row) in changeset.folded.displayRows.enumerated() {
            guard case let .fileHeader(section) = row else { continue }
            let id = changeset.sections[section].file.id
            if headers[id] == nil { headers[id] = index }
        }
        return headers
    }
}
