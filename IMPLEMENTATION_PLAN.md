# GitHub indicator on the repository name

Full plan: ~/.claude/plans/pasted-content-id-b00d-diffviewer-adaptive-widget.md

## Stage 1: Check inputs and derivation
**Goal**: GitHubConnection, GitHubRepositoryCheck, GitHubCheckOutcome.make, client `gitHubRepositoryCheck`
**Success Criteria**: pure derivation + client mapping covered by tests
**Tests**: GitHubConnectionTests, GitHubClientTests (/repos), PullRequestParsingTests additions
**Status**: Complete

## Stage 2: GitHubConnectionModel and WindowState wiring
**Goal**: per-window freshness (revisions, cancellation, progress, stop)
**Success Criteria**: stale/foreign results never publish; branch picker status unchanged
**Tests**: GitHubConnectionModelTests, WindowState wiring tests
**Status**: Complete

## Stage 3: Split capsule and GitHub popover
**Goal**: RepositoryCapsuleView, GitHubPopover, GitHubMark asset
**Success Criteria**: screenshots for every state, light and dark
**Tests**: screenshots only
**Status**: Not Started

## Stage 4: Repository picker and connection directory
**Goal**: GitHubConnectionDirectory, beginRefresh ordering, RepositoryPickerItems, picker popover
**Success Criteria**: bounded, revision-guarded background checks
**Tests**: RepositoryPickerItemsTests, GitHubConnectionDirectoryTests, lifecycle tests
**Status**: In Progress (non-view parts complete; picker popover not started)
