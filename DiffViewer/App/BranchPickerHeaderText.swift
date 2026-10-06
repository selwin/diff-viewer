import Foundation

/// The header's face: where HEAD is, how far it is from its upstream, and the current
/// branch's Pull and Push.
struct BranchPickerHeaderText: Equatable {
    let title: String
    /// What the detail line says about HEAD's upstream; the fetch news follows.
    var detailParts: [String] = []
    /// True while a fetch round runs, whether or not its remotes are known yet.
    var showsSpinner = false
    /// Fetch is offered unless a round is running or a pull or push is about to move the
    /// same counts, which a round would not start beside.
    var canFetch = true
    /// HEAD's branch, which `buttons` act on; nil when HEAD is on no listed branch.
    var branch: String?
    var buttons = RowSyncButtons.hidden
    /// What the title's copy button copies: HEAD's branch name, listed or not yet. Nil
    /// when HEAD is detached or unread.
    var copyableName: String?

    /// A header button Tab can reach.
    enum Control: Equatable {
        case copy
        case fetch
        case pull
        case push
    }

    /// The header buttons Tab visits after the search field, in order: only those shown
    /// and enabled, so focus never lands on a button that can't act.
    var focusOrder: [Control] {
        var order: [Control] = copyableName == nil ? [] : [.copy]
        if canFetch { order.append(.fetch) }
        guard branch != nil else { return order }
        if buttons.pull == .enabled { order.append(.pull) }
        if buttons.push == .enabled { order.append(.push) }
        return order
    }

    /// The detail line, with the fetch news last.
    func detail(fetch: BranchPickerFetchText?) -> String {
        (detailParts + [fetch?.text ?? ""]).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func make(snapshot: BranchPickerSnapshot) -> BranchPickerHeaderText {
        let spinner = snapshot.fetchStatus != .idle
        let canFetch = !spinner && snapshot.activeSync == nil
        guard let headState = snapshot.headState else {
            let title = snapshot.readStatus == .failed ? "Couldn't read branches" : "Loading…"
            return BranchPickerHeaderText(title: title, showsSpinner: spinner, canFetch: canFetch)
        }
        switch headState {
        case .detached:
            return BranchPickerHeaderText(title: headState.displayTitle, showsSpinner: spinner, canFetch: canFetch)
        case let .named(name):
            // A branch missing from the list says nothing: the counts are what the list holds.
            guard let branch = snapshot.branches.first(where: { $0.name == name }) else {
                return BranchPickerHeaderText(
                    title: name, showsSpinner: spinner, canFetch: canFetch, copyableName: name)
            }
            // Worded as the row is, so a hidden upstream reads the same in both places, but
            // capitalised: it starts the detail line.
            let status = BranchRowStatus.local(branch, configuredRemote: snapshot.configuredUpstreamRemotes[name])
            let words = status == .none ? "up to date" : status.text
            return BranchPickerHeaderText(
                title: name, detailParts: [words.prefix(1).uppercased() + words.dropFirst()], showsSpinner: spinner,
                canFetch: canFetch, branch: name,
                buttons: BranchPickerState.syncButtons(for: branch, isCurrent: true, snapshot: snapshot),
                copyableName: name)
        }
    }
}
