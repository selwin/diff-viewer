# Branch picker: Switch and Merge… tabs

Full plan: design 16b, Switch and Merge only. Delete this file when all stages are done.

## Stage 1: Merge git layer
**Goal**: `GitClient` can preview, list and run a merge; remote branches carry their tip sha.
**Success Criteria**: `mergePreview`, `commitsToMerge`, `merge(sourceRef:)` on `RepoClient`; tests pass.
**Tests**: `MergeTreeParserTests`, `RemoteBranchParserTests`, merge cases in a scratch-repo suite.
**Status**: Complete

## Stage 2: Tabs, sentence and restyled popover
**Goal**: Switch / Merge… tabs, instruction sentence with token, idle highlight, dimmed current row, footer bar.
**Success Criteria**: Switch behaves as before; Merge tab lists rows (not yet actionable); screenshots match the design.
**Tests**: `BranchPickerStateTests` for idle highlight, navigation around the current row, per-tab activation and instruction.
**Status**: Complete

## Stage 3: Merge previews
**Goal**: Merge rows show `N commits` / `Already merged` / `Conflict in N files`, loaded lazily and cached.
**Success Criteria**: Previews fade in for visible rows; at most 2 preview processes; stale results never shown.
**Tests**: `MergePreviewLoaderTests`, `MergePreviewText`, state key lookups.
**Status**: Not Started

## Stage 4: Merge sheet and merge
**Goal**: Clicking a Merge row opens a confirmation sheet; Merge runs `git merge` and refreshes.
**Success Criteria**: Clean, already-merged and conflicting merges behave as planned; Cancel never merges.
**Tests**: `WindowStateMergeTests`, `MergeSheetModelTests`.
**Status**: Not Started
