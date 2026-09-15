import Foundation

/// What one file contributed to a changeset. Narrow on purpose: a section can never
/// hold a changeset.
enum FileOutcome: Sendable, Equatable {
    /// Rows were produced; the language difftastic reported, if it ran.
    case text(language: String?)
    /// Text, but no change blocks (e.g. whitespace-only changes while they are hidden).
    case noVisibleChanges
    case binary
    case identical
    /// Over `ChangesetLimits.maxSourceBytesPerFile`, never diffed.
    case tooLarge
    /// Past `ChangesetLimits.maxFiles`, never read.
    case notShown
    /// A git or read error; the changeset carries on past it.
    case failed(String)
}

/// One file's slice of a changeset. `rowRange` indexes the flat document and is empty
/// for every outcome but `.text`; the line offsets turn a global `DiffSide.lineIndex`
/// into a file-local number (`lineIndex - offset + 1`).
struct ChangesetSection: Sendable {
    let file: ChangedFile
    let rowRange: Range<Int>
    let oldLineOffset: Int
    let newLineOffset: Int
    let oldLineCount: Int
    let newLineCount: Int
    /// Counted from this section's own rows for `.text`, from `file.lineStats` otherwise.
    let added: Int
    let deleted: Int
    let outcome: FileOutcome
}

/// What a changeset is allowed to diff. Applied by the caller of `ChangesetBuilder`,
/// which only records the outcome a rejected file was given.
enum ChangesetLimits {
    /// Files admitted per changeset, decided in sidebar order before anything is read.
    static let maxFiles = 200
    /// Old + new source bytes admitted per file, checked after the read and before the diff.
    static let maxSourceBytesPerFile = 1_000_000
}

/// Every changed file concatenated into one flat `DiffDocument`, plus the section each
/// file occupies. `loadID` is shared by every revision published from one load and
/// `revision` increases within it, so a consumer can tell an appended revision of the
/// same load from a different one.
struct ChangesetDocument: Sendable {
    let document: DiffDocument
    let sections: [ChangesetSection]
    let loadID: UUID
    let revision: Int
    /// The fixed projection for this revision, built with the load's fold options, so the
    /// view installs it and never folds a changeset itself.
    let folded: FoldedRows

    init(
        document: DiffDocument, sections: [ChangesetSection], loadID: UUID, revision: Int,
        foldOptions: FoldOptions = FoldOptions()
    ) {
        self.document = document
        self.sections = sections
        self.loadID = loadID
        self.revision = revision
        folded = ChangesetProjection.build(document: document, sections: sections, options: foldOptions)
    }

    var identity: ChangesetIdentity { ChangesetIdentity(loadID: loadID, revision: revision) }
}
