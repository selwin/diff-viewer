import AppKit
import Testing

@testable import DiffViewer

/// How a branch row shares its line between the name and what follows it. Real rows are
/// measured with the picker's own views at its width; the synthetic cases are stress tests
/// of the stages, not states the picker produces.
@MainActor
struct BranchRowTrailingLayoutTests {
    private let available = BranchPickerRowView.lineWidth(rowWidth: PickerStyle.width)

    private func widths(
        pills buttons: RowSyncButtons? = nil, status: BranchRowLabel? = nil
    ) -> BranchRowTrailingLayout.Widths {
        var widths = BranchRowTrailingLayout.Widths(
            copyButton: PickerCopyButton.side, gap: PickerStyle.trailingGap)
        if let buttons {
            let pills = BranchRowSyncButtons(style: .rowPills)
            pills.configure(
                buttons, isRevealed: true, branch: "b", onPull: { _ in }, onPush: { _ in }, onPublish: { _, _ in },
                onDelete: {})
            widths.syncPills = pills.width(reservingShortcuts: true)
            widths.compactSyncPills = pills.width(reservingShortcuts: false)
        }
        if let status {
            let view = BranchRowStatusView(frame: .zero)
            view.configure(status)
            widths.status = view.naturalSize.width
        }
        return widths
    }

    private func layout(_ widths: BranchRowTrailingLayout.Widths) -> BranchRowTrailingLayout {
        .make(available: available, nameMinimum: BranchPickerRowView.nameMinimum, widths: widths)
    }

    @Test func everyRealRowKeepsTheNameItsMinimum() {
        let counts = BranchRowLabel(text: "12 ahead · 34 behind", style: .secondary)
        let rows: [(String, BranchRowTrailingLayout.Widths)] = [
            // Highlighted in Switch: the status gives way to the pills.
            ("Pull + Push", widths(pills: RowSyncButtons(pull: .enabled, push: .enabled))),
            ("Publish", widths(pills: RowSyncButtons(pull: .hidden, push: .enabled, pushOperation: .publish))),
            ("Delete…", widths(pills: RowSyncButtons(pull: .hidden, push: .hidden, delete: .enabled))),
            ("Merge preview", widths(status: BranchRowLabel(text: "Conflict in 12 files", style: .warning))),
            // A pull still running after the highlight left: the status is back beside it.
            (
                "running Pull + status",
                widths(
                    pills: RowSyncButtons(pull: .running, push: .disabled(reason: "Pulling…")), status: counts)
            ),
        ]
        for (name, widths) in rows {
            #expect(layout(widths).nameWidth >= BranchPickerRowView.nameMinimum, "\(name)")
        }
    }

    /// With no action pill, a highlighted Pull and Push fit at full width.
    @Test func pullAndPushKeepTheirShortcutRoomWhenTheyFit() {
        let result = layout(widths(pills: RowSyncButtons(pull: .enabled, push: .enabled)))
        #expect(result.stage == .full)
        #expect(result.reservesShortcutWidth)
        #expect(result.showsCopyButton)
    }

    /// Stress test: the stages in order as the line narrows.
    @Test func stagesGiveWayInOrder() {
        let widths = BranchRowTrailingLayout.Widths(
            status: 80, syncPills: 100, compactSyncPills: 60, copyButton: 20, gap: 8)
        func make(_ available: CGFloat) -> BranchRowTrailingLayout {
            .make(available: available, nameMinimum: 72, widths: widths)
        }
        #expect(make(332).stage == .full)
        #expect(make(332).nameWidth == 116)
        #expect(make(252).stage == .compactPills)
        #expect(make(232).stage == .noCopyButton)
        #expect(!make(232).showsCopyButton)
        let truncated = make(192)
        #expect(truncated.stage == .truncatedStatus)
        #expect(truncated.nameWidth == 72)
        #expect(truncated.statusWidth == 44)
        // No room for any status: it goes, and the name takes what is left.
        let crowded = make(132)
        #expect(crowded.statusWidth == 0)
        #expect(crowded.nameWidth == 64)
    }
}
