## Stage 1: Row layout and short author names
**Goal**: Branch rows without the leading tile; check before the current branch, cloud after a remote-only one, current-row tint; subtitle uses the author's first token.
**Success Criteria**: Picker matches the reference renders minus the capsule; `make test` passes.
**Tests**: `AuthorNameTests` (token extraction); subtitle test in `BranchPickerStateTests`.
**Status**: Complete

## Stage 2: Listing, parsing and matching
**Goal**: `listPullRequests(head:base:)`, `ListedPullRequest`, `BranchPullRequests` index.
**Success Criteria**: Parsing, listing-failure and matching tests pass; nothing wired into the UI.
**Tests**: Parsing, listing failures, matching (see plan).
**Status**: Complete

## Stage 3: Refresh in the window; rows carry their PR
**Goal**: Background, identity-keyed, single-flight refresh; rows get `pullRequest`; `Remote gone` hidden for merged/closed.
**Success Criteria**: Lifecycle and presentation tests pass.
**Tests**: `WindowStateBranchPullRequestTests`, `BranchPickerStateTests`.
**Status**: Not Started

## Stage 4: The capsule
**Goal**: `PullRequestCapsuleButton`, colours, click to open, context menu, screenshot fixture.
**Success Criteria**: Screenshots match the renders in light and dark; capsule click opens the PR without switching branch.
**Tests**: `WindowState.openPullRequest(url:)`.
**Status**: Not Started
