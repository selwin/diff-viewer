import Foundation

/// The values the sidebar and the title bar derive from a window's state.
///
/// An extension in its own file: none of this writes anything — each member only reads
/// what the class already holds — so it does not need to sit next to the mutating code,
/// and SwiftLint caps a file at 600 lines.
extension WindowState {
    /// A path to find again in a new scope, and the area it came from.
    struct PendingSelection: Equatable, Sendable {
        let path: String
        let area: ChangedFile.Area
        /// Where the file sat in sidebar order, used only when the path is gone from the
        /// new list: discarding or trashing the selected row leaves nothing to match, and
        /// the reader expects the row that took its place. Nil for a scope change, where
        /// the two lists describe different commits and an index means nothing.
        var row: Int?
    }

    /// What the next refresh that publishes a list should select.
    enum PendingReselection: Equatable, Sendable {
        /// Find these rows again by path: a discard, a trash, or a branch switch.
        case paths([PendingSelection])
        /// Select the row now at `sourceIndex` among `sourceArea`'s rows. Stage moves rows
        /// to the tray, and the reader works down Changes rather than following them.
        case neighbour(sourceArea: ChangedFile.Area, sourceIndex: Int)
        /// Nothing: an unstage backs out of the tray rather than working down it.
        case clear
    }

    static let scopeSelectionHelp = "Choose what to compare: the working tree, or a commit against its parent"

    /// The branch picker's face: the current branch, or where a detached HEAD sits.
    var branchDisplayTitle: String {
        headState?.displayTitle ?? ""
    }

    /// What the title bar pill's Pull and Push show. Nil when HEAD's branch isn't known.
    var currentBranchSync: CurrentBranchSyncPresentation? {
        CurrentBranchSyncPresentation.make(snapshot: branchPickerSnapshot)
    }

    /// The branch picker's help: the upstream, named whenever there is one, and where the
    /// branch stands against it.
    var branchSwitchHelp: String {
        let base = "Switch branch"
        guard let upstream = currentBranch?.upstream else { return base }
        let detail = upstream.tracking == .gone ? "gone" : (upstream.tracking.summary ?? "up to date")
        return "\(base) · \(upstream.shortName): \(detail)"
    }

    /// The branch HEAD is on: nil while HEAD is detached or unread.
    var currentBranchName: String? {
        if case let .named(name)? = headState { return name }
        return nil
    }

    /// The scope picker's face: the working tree, or the selected commit's subject. Never
    /// the hash; a commit scope always holds its summary.
    var scopeDisplayTitle: String {
        switch scope {
        case .workingTree: "Working Tree"
        case .commit: selectedCommit?.subject ?? ""
        }
    }

    /// The sheets and popovers that open one at a time.
    enum Overlay {
        case commitSheet, commitPicker, branchPicker, newBranchSheet, mergeSheet
    }

    /// Whether an overlay other than `overlay` is up. Only one opens at a time.
    func isOtherOverlayPresented(besides overlay: Overlay) -> Bool {
        (overlay != .commitSheet && isCommitSheetPresented)
            || (overlay != .commitPicker && isCommitPickerPresented)
            || (overlay != .branchPicker && isBranchPickerPresented)
            || (overlay != .newBranchSheet && isNewBranchSheetPresented)
            || (overlay != .mergeSheet && pendingMerge != nil)
    }
}

/// The title bar pill's Pull and Push for the current branch. Its button states come from
/// the same rules as the picker header's.
struct CurrentBranchSyncPresentation: Equatable {
    let branch: String
    let buttons: RowSyncButtons
    /// Nil unless the branch tracks a remote upstream with counts, so no count reads as 0.
    let target: SyncTarget?

    /// Nil unless the read landed and HEAD's branch is listed: a failed read keeps a stale
    /// HEAD and list.
    static func make(snapshot: BranchPickerSnapshot) -> CurrentBranchSyncPresentation? {
        guard snapshot.readStatus == .loaded, case let .named(name)? = snapshot.headState,
            let branch = snapshot.branches.first(where: { $0.name == name })
        else { return nil }
        return CurrentBranchSyncPresentation(
            branch: name,
            buttons: BranchPickerState.syncButtons(for: branch, isCurrent: true, snapshot: snapshot),
            target: SyncPolicy.target(for: branch, readStatus: snapshot.readStatus))
    }

    var isPublish: Bool { buttons.pushOperation == .publish }

    /// What the Push slot does when pressed. A publish with several remotes has no one
    /// action, so the reader picks the remote.
    enum PushAction: Equatable {
        case push
        case publish(remote: String)
        case chooseRemote(remotes: [PublishMenuItem])
    }

    /// Nil unless Push is enabled.
    var pushAction: PushAction? {
        guard buttons.push == .enabled else { return nil }
        switch buttons.publish {
        case nil: return isPublish ? nil : .push
        case let .remote(remote): return .publish(remote: remote)
        case let .menu(items): return .chooseRemote(remotes: items)
        }
    }

    var showsSegments: Bool { buttons.pull != .hidden || buttons.push != .hidden }

    /// Commits a pull would take, or nil when there are none to show. Nil while running
    /// too: the refresh behind the spinner may zero the counts.
    var pullCount: Int? { Self.count(target?.behind, state: buttons.pull) }

    /// Commits a push would send, nil as for `pullCount`. Always nil for a publish, which
    /// has no upstream to count against.
    var pushCount: Int? { isPublish ? nil : Self.count(target?.ahead, state: buttons.push) }

    var pullAccessibilityLabel: String {
        if buttons.pull == .running { return "Pulling \(branch), in progress" }
        guard let count = pullCount else { return "Pull into \(branch)" }
        return "Pull \(Self.commits(count)) into \(branch)"
    }

    var pushAccessibilityLabel: String {
        let running = buttons.push == .running
        if isPublish { return running ? "Publishing \(branch), in progress" : "Publish \(branch)" }
        if running { return "Pushing \(branch), in progress" }
        guard let count = pushCount else { return "Push \(branch)" }
        return "Push \(Self.commits(count)) from \(branch)"
    }

    private static func count(_ count: Int?, state: PickerButtonState) -> Int? {
        guard state != .hidden, state != .running, let count, count > 0 else { return nil }
        return count
    }

    private static func commits(_ count: Int) -> String {
        count == 1 ? "1 commit" : "\(count) commits"
    }
}

extension HeadState {
    /// The branch name, or "Detached" and a short sha; the picker's face and header share it.
    var displayTitle: String {
        switch self {
        case let .named(name): name
        case let .detached(sha): "Detached " + sha.prefix(7)
        }
    }
}

extension RemoteBranch {
    /// Explains why a remote branch cannot be checked out when its local name exists.
    var localNameCollisionMessage: String {
        "A local branch named \(name) already exists"
    }
}

/// Segments the title bar pill keeps drawing while they collapse: hidden in the live
/// presentation, drawn as they last were.
struct SegmentDeparture: Equatable {
    /// The presentation the departing segments last had.
    let previous: CurrentBranchSyncPresentation
    let pull: Bool
    let push: Bool

    /// The segments that went hidden between `old` and `new`. Nil when none did, or when
    /// the branch changed: another branch's pill starts fresh.
    static func between(
        _ old: CurrentBranchSyncPresentation?, _ new: CurrentBranchSyncPresentation?
    ) -> SegmentDeparture? {
        guard let old, let new, old.branch == new.branch else { return nil }
        let pull = old.buttons.pull != .hidden && new.buttons.pull == .hidden
        let push = old.buttons.push != .hidden && new.buttons.push == .hidden
        guard pull || push else { return nil }
        return SegmentDeparture(previous: old, pull: pull, push: push)
    }

    /// Whether Pull is still departing: a segment back in `live` is drawn live again.
    func departsPull(in live: CurrentBranchSyncPresentation) -> Bool {
        pull && live.branch == previous.branch && live.buttons.pull == .hidden
    }

    func departsPush(in live: CurrentBranchSyncPresentation) -> Bool {
        push && live.branch == previous.branch && live.buttons.push == .hidden
    }

    /// `live` with the departing segments put back as they last were.
    func applied(to live: CurrentBranchSyncPresentation) -> CurrentBranchSyncPresentation {
        var buttons = live.buttons
        if departsPull(in: live) { buttons.pull = previous.buttons.pull }
        if departsPush(in: live) {
            buttons.push = previous.buttons.push
            buttons.pushOperation = previous.buttons.pushOperation
            buttons.publish = previous.buttons.publish
        }
        return CurrentBranchSyncPresentation(branch: live.branch, buttons: buttons, target: live.target)
    }
}
