import CoreGraphics

/// How a branch row splits its text line between the name and what follows it on the
/// right: the status or Merge preview and the sync pills. The name keeps
/// at least `nameMinimum` by giving things up in stages.
/// Worked out from natural widths alone, never from a previous pass, so it can't oscillate.
struct BranchRowTrailingLayout: Equatable {
    /// What the row gave up, in order.
    enum Stage: Equatable {
        /// Everything at its natural width.
        case full
        /// The pills drop their shortcut glyphs' room.
        case compactPills
        /// The copy button's room goes too.
        case noCopyButton
        /// The status truncates to what is left.
        case truncatedStatus
    }

    /// Natural widths of what follows the name; 0 for anything not shown.
    struct Widths: Equatable {
        var status: CGFloat = 0
        var syncPills: CGFloat = 0
        var compactSyncPills: CGFloat = 0
        /// The copy button's room after the name.
        var copyButton: CGFloat = 0
        /// Before each item that shows.
        var gap: CGFloat = 0
    }

    let stage: Stage
    /// The name label's room, short of the copy button's.
    let nameWidth: CGFloat
    /// 0 when the status doesn't show, or had no room left at all.
    let statusWidth: CGFloat
    let reservesShortcutWidth: Bool
    let showsCopyButton: Bool

    /// `available` runs from the name's start to the row's trailing content edge.
    static func make(available: CGFloat, nameMinimum: CGFloat, widths: Widths) -> BranchRowTrailingLayout {
        let pills = widths.syncPills > 0
        func room(_ width: CGFloat) -> CGFloat { width > 0 ? width + widths.gap : 0 }
        for stage in [Stage.full, .compactPills, .noCopyButton] {
            let reserves = stage == .full
            let copy = stage != .noCopyButton
            let pillWidth = reserves ? widths.syncPills : widths.compactSyncPills
            let name = available - room(pillWidth) - room(widths.status) - (copy ? widths.copyButton : 0)
            if name >= nameMinimum {
                return BranchRowTrailingLayout(
                    stage: stage, nameWidth: name, statusWidth: widths.status,
                    reservesShortcutWidth: reserves || !pills, showsCopyButton: copy)
            }
        }
        // The status takes what the name leaves; with no room left it doesn't show.
        let rest = available - room(widths.compactSyncPills)
        var status = min(widths.status, rest - widths.gap - nameMinimum)
        if status <= 0 { status = 0 }
        return BranchRowTrailingLayout(
            stage: .truncatedStatus, nameWidth: max(rest - room(status), 0), statusWidth: status,
            reservesShortcutWidth: !pills, showsCopyButton: false)
    }
}
