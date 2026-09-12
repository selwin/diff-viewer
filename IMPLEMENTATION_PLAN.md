# Collapse Unchanged Lines

Show only changed hunks with 5 lines of context by default; hidden runs become one separator
row with GitHub-style expand controls. Full design: see the approved plan.

## Stage 1: Folding model
**Goal**: `DiffViewer/Diff/RowFolding.swift` — `DisplayRow`, `FoldOptions`, `FoldState`, `FoldedRows`, `RowFolding.fold/controls`. Nothing wired into the UI.
**Success Criteria**: Pure projection with O(1) document↔display lookups; invariants hold (changed rows visible, separators cover only equal rows, exact cover).
**Tests**: `DiffViewerTests/RowFoldingTests.swift`
**Status**: Complete

## Stage 2: Renderer + container
**Goal**: `DiffPaneView` draws separators and handles clicks; `SideBySideContainerView` owns fold state, `refold()` with row anchoring, index translations; overview sync fix. Collapse hard-coded on.
**Success Criteria**: Snapshots show aligned separators in both panes; clicks expand stepwise; ⌘↑/⌘↓, overview, highlighting all work.
**Tests**: none new (UI, verified by snapshots)
**Status**: Complete

## Stage 3: Persisted toggle
**Goal**: `AppState.collapseUnchanged` (UserDefaults, default true) + validated `foldOptions`; menu item ⇧⌘U; toolbar toggle; `SideBySideView` three-way `updateNSView`; `COLLAPSE=` in `scripts/snapshot.sh`.
**Success Criteria**: Toggle flips without diff recompute; syntax colors retained; top row anchored.
**Tests**: `contextLinesAreClampedFromDefaults`
**Status**: Complete

## Stage 4: Polish
**Goal**: Pointing-hand cursor over separators, accessibility elements for controls, light/dark check, README note, perf check.
**Success Criteria**: Snapshots in both appearances; VoiceOver reads controls.
**Tests**: none new
**Status**: In Progress
