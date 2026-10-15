## Stage 1: Parsing and git resolution
**Goal**: Parse PR links and remote URLs, choose a remote, and resolve a PR with git alone: advertise, fetch, pin and find the comparison base.
**Success Criteria**: The `GitClient+PullRequest` steps work against real repos; `CommitRange.baseLabel` drives the find label.
**Tests**: Parameterized parsing and remote selection; real-repo advertisement, fetch without pruning, pinning and retention through gc, merge-base recovery, shallow clones.
**Status**: Complete

## Stage 2: Extract ComparisonPreview
**Goal**: Move the debounce/single-flight worker out of `CompareWindowModel` into a generic `ComparisonPreview` with a published `resolution`.
**Success Criteria**: Branches mode behaves exactly as before.
**Tests**: Existing `CompareWindowModelTests`; resolution states; stale progress and errors dropped; custom debounce.
**Status**: Complete

## Stage 3: Pull Request mode
**Goal**: The Compare window's Pull Request segment: link input, remote choice, resolution card, wells, opening a `main … PR #n` tab.
**Success Criteria**: The spec's behaviour and wording; snapshots in light and dark; docs updated.
**Tests**: `PullRequestCompareModelTests` scenarios with stubbed reads and `ManualClock`.
**Status**: Not Started
