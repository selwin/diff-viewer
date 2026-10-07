# Commit picker restyle (match the branch picker)

## Context
The branch picker (⌘B) now has the new look; the commit picker (⌘K, the title bar's scope button) still has the old one:
- an opaque popover, an 18pt title over a hairline, and a grey list sheet;
- a 28pt search field and text-only rows with a trailing checkmark;
- a light-grey highlight.

This restyle gives it the same visual language so the two title bar popovers read as one family. Its behaviour stays as it is: hover highlighting, pagination, searching older commits, Retry, and copying the SHA.

Defaults chosen:
- **Width:** 368pt, matching the branch picker. Subjects truncate sooner; the full subject is in the header's tooltip when that commit is shown, and in VoiceOver.
- **Row tiles:** 32pt round tiles like branch rows. The scope being shown gets the blue checkmark tile, replacing today's trailing checkmark.
- **Header title:** the shown commit's subject in the 18pt bold title (shared with the branch picker, reduced from 22pt at Selwin's request), wrapping to at most 2 lines and ending in an ellipsis, with the full subject in the tooltip.
- **Meta line:** `Author · time` like branch rows. A long author name truncates and the time stays visible.
- **Message rows:** Loading, Retry and Search older commits stay 36pt tall (no tile).

Not carried over: the Switch/Merge control, the Fetch button, the New Branch… footer, row Pull/Push pills, and resting selection.

## Stage 1: Share the style
**Goal**: `BranchPickerStyle` → `PickerStyle` (`Views/PickerStyle.swift`), used everywhere; header comment says the tokens belong to both title bar pickers.
**Success Criteria**: builds; branch picker unchanged.
**Tests**: none (mechanical).
**Status**: Complete

## Stage 2: Chrome
**Goal**: Files `Views/CommitPickerView.swift`, `CommitPickerContainerView.swift`, `CommitPickerHeaderView.swift`.
- **Popover.** `.frame(width: PickerStyle.width)`; `sizeThatFits` / `intrinsicContentSize` at the same width. Drop `.presentationBackground`, so the system Liquid Glass shows.
- **No sheet.** Delete the container's `draw(_:)` that fills under the header with `PickerMetrics.listBackground`.
- **Header.** `PickerHeaderView`'s fixed layout, shared by both pickers: 20pt top, 12pt bottom, `edgeInset` on both sides; `titleFont` and `headerStatusFont`; no hairline.
- **Title wrapping.** At most 2 lines. `PickerHeaderView.init(wrapsTitle:maximumTitleLines:)`; the commit header passes 2. With a limit, the wrapping title field keeps `.byWordWrapping` and also sets `maximumNumberOfLines = limit` and `cell?.truncatesLastVisibleLine = true`. `titleHeight(width:)` keeps measuring the configured field with `cellSize(forBounds:)` at its real text width; `fittingHeight` and `layout` both use that one measurement. The header sets the title's tooltip to the full subject.
- **Hash and copy button.** Subtitle's dot, monospaced short hash and copy button stay, restyled to `headerStatusFont` and the meta colour.
- **Search field.** 34pt capsule with `controlFill`, from `edgeInset − 4` on each side; move the branch picker's `searchOutset` into `PickerStyle`. The header's 12pt bottom padding is the whole gap above (the branch picker's tabs sit there instead); 8pt below. Placeholder `Search commits`.
- **Height.** `rowHeight(forItem:)` is the one source of row heights (table + `updatePreferredHeight`): `.commit`/`.workingTree` → `PickerStyle.rowHeight`; `.header` → `PickerStyle.sectionHeaderHeight`; `.message` → `CommitPickerMessageRowView.height` (36). Table default `rowHeight` = `PickerStyle.rowHeight` as fallback. `updatePreferredHeight` = chrome + `max(min(list, maximumListHeight), minimumListHeight)` + 8pt bottom gap; still only grows.
- **Accessibility settings.** Observe `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` as `BranchPickerContainerView+Chrome.swift` does; on change call `refreshRendering()` on the search fill, visible rows and their `PickerTableRowView`s, no table reload. Remove the observer in `tearDown`.
**Success Criteria**: snapshot matches the branch picker's chrome.
**Status**: Complete

## Stage 3: Rows
**Goal**: Files `Views/CommitPickerRowView.swift`, `CommitPickerMessageRowView.swift`, `CommitPickerContainerView+Input.swift`, `App/CommitPickerItems.swift`, `App/CommitPickerState.swift`.
- **Highlight and section headers.** `PickerTableRowView` / `PickerGroupHeaderView`, whose only look is the branch picker's (raised highlight, radius 20, inset 8, contrast border; section titles at `edgeInset` in `sectionFont`).
- **Tile.** Move `BranchRowIconTile` from `BranchRowParts.swift` into `Views/PickerRowIconTile.swift` as `PickerRowIconTile`, taking an explicit `Glyph` (image, sizing, tint, fill). Sizing: asset image at a given side, or SF Symbol point size + weight — kept separate. Branch rows: branch asset, cloud, or bold checkmark, as today. Commit: `gitCommit` asset on grey tile. Working Tree: `square.and.pencil` on grey tile. Scope shown: accent-tint tile with bold checkmark; trailing checkmark goes.
- **Row data.** `CommitPickerRow` keeps `authorName`, gains `timeText`. `CommitPickerState`: recency-group rows use `CommitDayGrouping.rowTimeText(for:)`; the "Selected" row outside the loaded page uses `commitDateText(for:)`. Rename `branchTimeText(for:)` → `rowTimeText(for:)`.
- **Text.** Subject in `nameFont`; no separate bold weight for the shown scope.
- **Subject line**, right to left: short hash (11.5pt monospaced, meta colour); the copy button's 18pt room (kept even while hidden); subject takes the rest, tail-truncates.
- **Meta line**, right to left: `Not pushed` in `rowStatusFont` when unpushed; `· time` at natural width; author takes the rest, tail-truncates.
- **Working Tree row.** Single line centred on the tile, 46pt; change count at right in `rowStatusFont` (the `detail` label, which shows `Not pushed` on commit rows); title truncates first.
- **Message row.** Spinner and text at `edgeInset`, `metaFont`, meta colour. Retry / Search older commits links: accent colour, semibold.
- **Accessibility.** Label keeps "current" and includes the time; "Show" / "Copy SHA" actions unchanged.
**Tests**: `CommitPickerStateTests` — recency row `timeText` (Today + older) on the fixed clock; "Selected" row outside the page uses the full date. `CommitDayGroupingTests` rename.
**Status**: Complete

## Stage 4: Remove the old look
**Goal**: Every caller passed the same values, so `PickerHeaderView`, `PickerGroupHeaderView`, `PickerTableRowView` and `RoundedFillView` lost their `Style`s and read `PickerStyle` directly. Only `wrapsTitle` and `maximumTitleLines` remain as init arguments. `PickerMetrics.swift` is deleted; nothing read it, `popoverBackground` included. Stale comments updated.
**Success Criteria**: no dead tokens; branch picker snapshot unchanged.
**Status**: Complete

## Verification
`make build`, `make lint`, `make format-check`, `make test` once; snapshots (`DIFFVIEWER_COMMIT_PICKER=1`, `DIFFVIEWER_SCOPE=<sha>`, light/dark) and branch picker snapshots; interactive check handed to Selwin.
