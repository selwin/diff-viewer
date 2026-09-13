# TODO

Roadmap for DiffViewer after Stage 5. Every item is judged by the question in CLAUDE.md:
does it make reading a diff faster, clearer, or more pleasant? Items are grouped by
priority; within a group, order is a suggestion. Competitor references come from the
research notes at the bottom (Kaleidoscope 7.0, Sublime Merge build 2125, JuxtaCode 1.4,
all as of September 2026).

Where DiffViewer already stands versus the bar:

| Capability | Kaleidoscope | Sublime Merge | JuxtaCode | DiffViewer |
|---|---|---|---|---|
| Side-by-side, aligned rows | yes | yes (or inline) | yes | yes |
| Structural (AST-aware) token highlights | no (word-level) | no (character-level) | no (word-level) | **yes (difftastic)** |
| Full syntax colouring both panes | yes | yes | yes | yes |
| Ignore whitespace | yes (3 kinds + regex filters) | yes | not documented | yes (one toggle) |
| Live working-copy refresh | yes (7.0 headline) | yes | yes | yes |
| Multiple repos at once | tabs | repo tabs | tabs + windows | **no** |
| Aggregate +/- churn | counts by kind only | per-commit only | none | **no** |
| Per-file +/- churn in sidebar | no | no | no | **yes** |
| Stage / unstage / discard from file list | no (viewer) | yes | no | **no** (Requested B) |
| All files in one scroll | no (per file) | yes (default view) | no | **no** |
| Collapse unchanged / context expansion | yes | yes (default) | no | **no** |
| Find in diff | yes | no | no | **no** |
| Jump to line | yes | no | no | **no** |
| Wrap long lines | yes | yes | no | **no** |
| Browse a previous commit's diffs | yes (changesets) | yes (graph) | yes (tabs) | **yes** (picker) |
| Sidebar filter (name / ext / kind) | yes | partial | yes | **no** |
| Folder outline in sidebar | yes | no (long-requested) | no | **no** |
| Rename / move detection | yes | yes | yes | **no** (`--no-renames`) |
| Image diff | no | yes | no (top request) | **no** |
| Text selection / copy from panes | yes | yes | yes | **no** |

---

## Requested: sidebar churn and sidebar actions

Three items Selwin asked for on 2026-09-12. They take priority over the "Now" list below.

### A. Per-file churn in the sidebar (done 2026-09-13)

Shipped as designed below, with two changes: `LineStats` is an enum (`.counted` /
`.binary`) so that `nil` can mean "unknown" (numstat failed, unmerged, unreadable), and
only untracked files need a worktree line count because git's numstat already covers
tracked added and deleted files. Section-header sums, the grand total, and the
detail-header counts remain under feature 2.

**Goal.** Every changed, added, or deleted file in the sidebar shows how much churn it
has: a trailing `+12 −4` in monospaced caption, green/red, on each `FileRow`.

**Design.** This is the sidebar half of feature 2 below; do it first and leave the
aggregate totals, section-header sums, and detail-header counts for a follow-up.
- `git diff --numstat -z` (unstaged) and `git diff --cached --numstat -z` (staged),
  run alongside `status()` on every refresh, joined to `ChangedFile` by path and area.
- Added / untracked files have no numstat entry: count the worktree file's lines and
  show them as all additions. Deleted files: count HEAD (or index) lines as all
  deletions. Binary files report `-`: show "binary" instead of numbers.
- Pass `-w` when Hide Whitespace is on so the counts match the panes.
- Add `LineStats { added: Int, deleted: Int }?` to `ChangedFile`, a `GitNumstatParser`
  shaped like `GitStatusParser`, and a `numstat(area:)` method on `RepoClient`.
- Optional: a five-block GitHub-style bar per row, only if it stays subtle.

**Tests.** `GitNumstatParser` (rename lines, binary `-`, `-z` framing), join of numstat
rows to status rows, untracked/deleted line counting.

#### A.1 Follow-up: sizes for binary files (requested 2026-09-13)

**Goal.** A binary row currently says only `binary`. Show its size instead, in KB, so an
image or asset change is as informative as a `+12 −4` text change: `48 KB` for an added
or deleted file, `48 KB → 51 KB` for a modified one.

**Design.**
- Sizes come from git objects, not the worktree, so staged and unstaged rows agree with
  what the diff shows. Old side: `HEAD:path` (unstaged and staged rows); new side:
  `:path` (the index) for staged rows, the worktree file for unstaged rows, `FileManager`
  for untracked. Deleted files have only an old side, added files only a new side.
- One `git cat-file --batch-check` call per refresh, fed every needed object spec on
  stdin, returns `<oid> <type> <size>` lines; parse with a `GitCatFileSizeParser` in the
  style of the numstat parser. Worktree sizes come from `FileManager.attributesOfItem`.
- Model: `LineStats.binary` gains `(oldBytes: Int?, newBytes: Int?)`. Format with
  `ByteCountFormatter` in decimal KB, one decimal below 100 KB, switching to MB above
  1 MB (`1.2 MB`). Keep the `binary` word only when both sizes are unknown.
- `ChurnLabel` renders the size in the same tertiary monospaced caption. Modified rows
  colour the arrow's right side green or red depending on whether the file grew or
  shrank; equal sizes show one value.
- Only run cat-file when the status contains at least one binary row.

**Tests.** `GitCatFileSizeParser` (missing objects, `-z` framing), size formatting
thresholds, old/new pairing per `Kind` and `Area`.

### B. Right-click actions on sidebar files

**Goal.** Right-clicking a file in the sidebar shows the actions that make sense for its
state: stage, unstage, discard (reset) changes, delete file, plus the harmless ones
(Reveal in Finder, Open in Default Editor, Copy Path).

**Scope note.** This is the first feature that writes to the repository, so it revises
the "Read-only" principle in CLAUDE.md and the "Staging, discarding, cherry-picking hunks"
entry under Not doing. The rule becomes: the app never edits file *contents* and never
commits, but it may move whole files between the working tree, index, and HEAD, because
those are the actions a reader takes right after reading a diff. Update CLAUDE.md and
README when this lands. Hunk-level staging stays out.

**Design.**
- `.contextMenu` on `FileRow`, with the menu built from the file's `Area` and `Kind`:

  | State | Actions |
  |---|---|
  | Unstaged, modified / typeChanged | Stage, Discard Changes… |
  | Unstaged, deleted | Stage Deletion, Restore File |
  | Untracked | Stage (add), Delete File… |
  | Staged, any kind | Unstage |
  | Staged, added | Unstage (then the file becomes untracked) |
  | Unmerged | Stage (mark resolved) only |
  | Every row | Reveal in Finder, Open in Default Editor, Copy Path |

- Git commands, all whole-file and all added to `RepoClient` so tests can stub them:
  `git add -- <path>` (stage), `git restore --staged -- <path>` (unstage, also covers a
  staged add), `git restore -- <path>` (discard unstaged changes, also restores a deleted
  file), `git restore --staged --worktree -- <path>` (discard a staged change). Deleting
  an untracked file uses `FileManager.trashItem` so it is recoverable from the Trash.
- Destructive actions (Discard Changes, Delete File) get a confirmation alert with the
  file name and a Don't Ask Again toggle, persisted in `Preferences`. Stage / unstage
  need no confirmation because they are reversible from the same menu.
- Multi-selection: the sidebar is single-select today; keep it that way for the first
  cut and act on the clicked row (macOS convention when the right-clicked row is not the
  selected one).
- After an action, run `status()` immediately rather than waiting for `RepoWatcher`, and
  keep the selection on the same path if it still exists in either section; otherwise
  select the next row. The detail pane reloads via `DiffLoader` as usual.
- Keyboard: ⌘⌫ deletes / discards the selected file (with the same confirmation), ⌘S
  stages, ⌘⇧S unstages. Mirror the menu in a File › menu so the shortcuts are
  discoverable.
- Errors (index lock, permission) surface as an alert with git's stderr; never retry
  silently.

**Tests.** Menu-model derivation from `(Area, Kind)` to action list, post-action
selection rule, and the git argument builder per action. The UI is verified by
screenshots.

### C. Show the current branch

**Goal.** The window always shows which branch the open repository is on, and updates
when the branch changes underneath the app (checkout in a terminal, a coding agent
switching branches, a rebase in progress).

**Design.**
- Source: `git symbolic-ref --short -q HEAD`. When it fails the head is detached; fall
  back to `git rev-parse --short HEAD` and show it as `detached at 1a2b3c4`. Add a
  `currentBranch()` method to `RepoClient` next to `status()` and run it in the same
  refresh so the two never disagree.
- Placement: window subtitle under the repo name, via `.navigationSubtitle`, so it
  reads "diff-viewer — main" in the title bar without taking sidebar space. In the tabs
  model the tab title stays the repo name; the branch is per window and per session.
- In-progress operations: if `.git/rebase-merge`, `.git/rebase-apply`, `.git/MERGE_HEAD`,
  or `.git/CHERRY_PICK_HEAD` exists, append the state, e.g. `main (rebasing)`, the way
  the git prompt scripts do. Cheap file-exists checks, no extra git calls.
- Refresh: `RepoWatcher` already fires on `.git` changes; `.git/HEAD` rewrites cover
  checkouts, so no new watcher is needed. Read-only, so it fits the current scope
  regardless of item B.
- Optional later: clicking the subtitle copies the branch name; upstream ahead/behind
  counts (`git rev-list --left-right --count @{u}...HEAD`) if they stay cheap.

**Tests.** Parsing of the symbolic-ref and detached fallbacks, and the in-progress
state suffix from a set of existing marker files.

---

## Now: the three planned features

### 1. Tabs: several repositories open at once (Safari-style)

**Goal.** ⌘T opens a new tab, each tab is one repository with its own file list, selection,
diff, and watcher. Tabs reorder by drag, close with ⌘W, restore on relaunch.

**Competitor notes.** Sublime Merge uses one tab per repository with a change indicator dot
when a background repo changed. Kaleidoscope uses one tab per comparison and lets `ksdiff
--label` re-target an existing tab. JuxtaCode uses tabs for commits and separate windows
for repos, disambiguating same-named repos by path in the title.

**Design.**
- Use native macOS window tabbing rather than a custom tab bar. Set
  `NSWindow.tabbingMode = .preferred` and `tabbingIdentifier` on the main window; AppKit
  then gives Safari-style tabs, ⌘T / ⌘W / ⌘⇧] / ⌘⇧[ / "Merge All Windows", drag to
  reorder, and tear-off, for free. Each tab is a window with its own scene state.
- Split `AppState` into two types:
  - `Preferences` (one per app): font size, hide whitespace, recent repos, tab restore
    list. Backed by `UserDefaults` as today.
  - `RepoSession` (one per tab/window): `repoRoot`, `GitClient`, `RepoWatcher`, `files`,
    `selectedFileID`, `DiffLoader`, change-navigation state. This is essentially today's
    `AppState` minus the persisted prefs.
- A preference change (font size, whitespace) applies to every session; each session
  reloads its diff on whitespace changes.
- Tab title = repo name; if two open tabs share a name, append the parent directory
  (JuxtaCode's rule). Window subtitle shows the selected file path.
- Change indicator: when a watcher fires in a non-key window, mark its tab (e.g. a dot
  in the title, or `NSWindowTab.accessoryView` badge with the changed-file count) and clear
  it when the tab becomes key. This is the Sublime Merge behaviour that makes tabs useful
  while a coding agent works in another repo.
- Opening a repo that is already open in another tab focuses that tab instead of opening
  a duplicate (Kaleidoscope's `--label` semantic).
- Persist the list of open repo roots and the selected tab; restore all on launch instead
  of only `recentRepos.first`. Files opened via `open -a DiffViewer` or drag-and-drop go
  into a new tab unless the drop lands on an empty tab.
- Watcher cost: one FSEvents stream per open repo is fine; pause a session's watcher when
  its window is miniaturised or its tab has been inactive for a long time (Kaleidoscope
  offers pause/resume; we can automate it).

**Tests.** Tab-title disambiguation, "focus existing tab instead of duplicate" lookup,
restore list round-trip. No UI tests; verify with `scripts/screenshot.sh`.

### 2. Churn indicators: how much changed, in aggregate and per file

**Goal.** At a glance: total lines added / deleted across the working tree, split by
staged and unstaged, plus per-file counts in the sidebar.

**Competitor notes.** None of the three does this well. Kaleidoscope's changeset header
shows only counts of modified / added / deleted / moved files. Sublime Merge has a
lines-changed indicator on commits, not on the working tree. JuxtaCode has no stats at
all. This is a cheap differentiator.

**Design.**
- Source of truth: `git diff --numstat -z` (unstaged) and `git diff --cached --numstat -z`
  (staged), run alongside `status` on every refresh. Pass `-w` when Hide Whitespace is on
  so the numbers agree with what the panes show. Untracked files have no numstat entry:
  count their lines in the worktree file (they are all additions). Binary files report
  `-` in numstat; show them as "binary" rather than 0.
- Add `LineStats { added: Int, deleted: Int }` to `ChangedFile` (optional, nil for
  binary), populated by a `GitNumstatParser` with the same shape as `GitStatusParser`.
- Sidebar: per-file trailing `+12 −4` in monospaced caption, green/red. Section headers
  become `Unstaged (7) +340 −120`. A footer or toolbar item shows the grand total, with
  the counts-by-kind Kaleidoscope shows (`5 modified, 2 added, 1 deleted`).
- Detail header: per-file `+12 −4` next to the existing "N changes" text. For the open
  file, prefer the exact counts derived from `DiffDocument.rows` (added/deleted/modified
  row counts) since those already respect the whitespace mode and difft's alignment.
- Optional visual: the GitHub-style five-block bar per file row (proportional green/red
  squares). Only if it stays subtle; the numbers matter more.
- Keep the numbers in sync with `RepoWatcher` refreshes; numstat on a 500-file working
  tree is well under 100 ms and runs off the main thread with `status`.

**Tests.** `GitNumstatParser` (rename lines, binary `-`, `-z` framing), `DiffDocument`
row-count stats, aggregate summation across areas.

### 3. All-changes view: every file's hunks in one continuous scroll

**Goal.** Like Sublime Merge's changes pane: scroll through every changed file's hunks
top to bottom without clicking through the sidebar. The sidebar becomes a jump list.

**Scope clarification.** "Unified" here means *unified across files*, not the inline
unified-diff text format. The view stays side by side, as CLAUDE.md requires; Sublime
Merge itself renders its changes pane side by side when the window is wide enough.

**Competitor notes.** Sublime Merge stacks every file's hunks with a per-file header
(hover buttons, context menu), shows condensed hunks by default, and lets you expand
context by dragging a hunk edge or double-clicking it. Kaleidoscope 7.0 instead keeps one
file per view but makes ⌘↓ / ⌘↑ cross file boundaries, and offers Collapse Unchanged
(6.0) with ⌥-click to expand all. Neither has structural token highlights in this mode,
which we keep.

**Design.**
- New document type `ChangesetDocument`: an ordered list of `FileSection`s, each holding
  a `ChangedFile`, its `DiffDocument` (or binary/identical/loading state), and the row
  offset at which it starts. Total row count is the sum of section heights.
- Extend `DiffRow.Kind` with `.fileHeader` and `.collapsed(hiddenCount)` so `DiffPaneView`
  can draw a sticky-looking header row (path, kind badge, `+12 −4`) and a "⋯ 48 unchanged
  lines" row without a second renderer. Keep `PaneLayout` as fixed-height rows; header
  rows can be the same height as text rows, or an integer multiple.
- Context by default: show N (3) lines of context around each change block and collapse
  the rest. Clicking a collapsed row expands it in place; ⌥-click expands all in that
  file; a global toggle (View › Show Full Files) turns collapsing off. This is also the
  single-file view's "collapse unchanged" feature (see Next), so build it in
  `DiffAligner` output space: a `RowFilter` that maps document rows to visible rows and
  back, so navigation and the overview strip keep working with the full row indices.
- Loading: diff files lazily in sidebar order with a small concurrency limit (git + difft
  per file). Sections that have not loaded yet reserve an estimated height (from numstat
  lines) so the scroll bar does not jump; when the real document arrives, adjust offsets
  and keep the visible row anchored. Highlighting is requested only for sections that
  intersect the visible range plus one screen of lookahead.
- Sidebar becomes scroll-spy: selecting a file scrolls the changeset to its header;
  scrolling updates the sidebar selection to the file under the top of the viewport.
- Navigation: ⌘↓ / ⌘↑ walk change blocks across file boundaries; add ⌘⌥↓ / ⌘⌥↑ for
  next/previous file. The change overview strip spans the whole changeset with thin file
  separators.
- Mode switch: View › Single File (⌘1) / All Changes (⌘2), persisted. Both modes share
  the sidebar and prefs. Per-window in the tabs model.
- Performance guard: for changesets above a threshold (e.g. 200 files or 100k total
  lines) show a banner and load sections only as they scroll into view; never run difft
  on every file up front.

**Tests.** `RowFilter` round-trips (visible index ↔ document row), section offset
arithmetic when a section resizes, change-block navigation across sections, scroll-spy
mapping from row to file.

---

## Next: high-value features the competitors have and we lack

Roughly in priority order.

- **Collapse unchanged text in the single-file view.** Same `RowFilter` and collapsed
  rows as the all-changes view; toggle in View menu, ⌥-click to expand all. Off by
  default to match Kaleidoscope, and because full context is what a viewer is for. Most of
  the work lands with feature 3 above.
- **Find in diff (⌘F).** Search old side, new side, or both; highlight matches in the
  panes and the overview strip; ⌘G / ⌘⇧G step through matches. Kaleidoscope has it, and
  Sublime Merge users complain it is missing, so it is a visible win. Add an option to
  search only changed lines.
- **Jump to line (⌘L).** Pick old or new line number; scroll and flash the row.
- **Text selection and copy.** The custom `NSView` renderer has no selection today. Add
  per-pane click-drag selection over the visible CTLines, ⌘C copying plain text (one side
  only), and ⌘A selecting the current pane. Context menu: Copy, Copy Path, Copy Line
  Number, Reveal in Finder, Open in Default Editor. All three competitors support
  selecting text.
- **Rename and move detection.** Status currently runs with `--no-renames`. Switch to
  `--find-renames` and show `old → new` in the sidebar and header (already supported by
  `ChangedFile.originalPath`); diff the renamed pair instead of showing a delete plus an
  add. Sublime Merge and Kaleidoscope both show moves.
- **Sidebar filtering.** Live filename filter field, filter by extension, filter by
  change kind (toggle the badge icons, as Kaleidoscope does). Sublime Merge users have
  asked for this since 2018.
- **Sidebar folder outline.** Toggle between flat list (default) and a collapsible tree
  grouped by directory (Kaleidoscope 6.7). Cheap with `OutlineGroup`.
- **Wrap long lines toggle.** Kaleidoscope and Sublime Merge have it. This breaks the
  fixed-row-height assumption in `PaneLayout`; needs per-row heights with a prefix-sum
  table so both panes stay aligned (the taller side wins per row). Do this after the
  changeset view so the row model only changes once.
- **Next/previous change crossing files in single-file mode.** Kaleidoscope 7.0's ⌘↓ at
  the last change advances to the next file. Small change to `ChangeNavigator`.
- **Larger-file highlighting.** README follow-up: highlight visible rows first, or cache
  compiled query predicates. Kaleidoscope auto-disables syntax colouring on very large
  files; do the same above a line threshold with a "Highlight anyway" button.
- **Finer whitespace control.** Kaleidoscope splits ignore into leading / trailing /
  line-ending. Offer "Ignore all whitespace" vs "Ignore leading and trailing" if the
  single toggle proves too coarse; keep the persisted-toggle design.

## Later: worth having, not urgent

- **Image diff.** Show old and new images side by side with dimensions and size; optional
  swipe or onion-skin slider. Sublime Merge has it; it is JuxtaCode's most requested
  feature. Also covers the "Binary file" dead end for the most common binary case.
- **Quick Look for other binaries** (Kaleidoscope, JuxtaCode): press Space on a binary
  file to preview the worktree version.
- **Connector lines between panes** for modified rows, as in Kaleidoscope's Fluid layout
  and JuxtaCode's scattered-word connectors. Purely visual; try it behind a toggle and keep
  only if it reads better than the current padding rows.
- **Twin Focus** (JuxtaCode): hovering a highlighted token highlights its counterpart on
  the other side. difft gives us the pairing for free.
- **Syntax colour themes and font choice.** Kaleidoscope ships several themes; we have
  one light/dark theme. Add a font family picker (monospaced only) and a couple of
  `TokenStyle` themes.
- **Per-file language override** (Kaleidoscope's View › Syntax Coloring) for files difft
  or the registry misdetect.
- **Show invisibles / line endings** toggle. CRLF differences are already visible; this
  adds visible tabs and spaces on demand.
- **Sidebar options**: show ignored files (Sublime Merge lacks it), hide untracked.
- **Pause live refresh** button when a build churns the tree (Kaleidoscope 7.0).
- **Moved-code detection** (git `--color-moved`-style): dim blocks that were cut from one
  place and pasted elsewhere. None of the three does this; a real differentiator but
  substantial alignment work.
- **CLI and `git difftool` integration.** All three ship a CLI (`ksdiff`, `smerge`,
  `juxta`) and a difftool config. Deferred per the v1 decision; when it comes, a
  `diffviewer <repo>` opener plus a `kaleidoscope://changeset?path=` style URL scheme
  is the minimum. Listed in README as a non-goal for now.

## Landed since this list was written

### Commit picker (2026-09-13)

A popup at the top of the sidebar scopes the file list and the diffs to the working tree
(the default, unchanged) or to one commit from the branch's first-parent history, shown
against its first parent.

**Scope change.** This reverses the commit-browsing half of the "Commit browsing,
ref-range compare, folder compare, blame, file history" entry under *Not doing*, the way
Requested item B revises the read-only principle. What stays out: comparing two arbitrary
commits, folder compare, blame, and per-file history. `CLAUDE.md` carries the same
non-goal list and needs the same edit — it is not in the repository, so it could not be
updated here.

**Notes for whatever builds on this.** A commit is named by a `CommitRef` carrying its
first parent, so every read states both sides explicitly: `git diff-tree` prints nothing
at all for a merge given only the commit, and git reports an unreadable revision as though
the *path* were missing, which would otherwise render an unreachable commit as a file
added wholesale. History loading has its own generation counter, separate from the file
list's, and a watcher tick in commit scope does nothing unless HEAD has moved.

Follow-ups it leaves open: a keyboard shortcut for the picker, a filter over the commit
list once it is long, and the ⌘R-only path for re-reading a commit's files.

## Not doing (and why)

- **Inline / unified text layout.** Side by side only (CLAUDE.md). Sublime Merge's
  `diff_style` auto-switching and Kaleidoscope's Unified layout are not goals.
- **Ref-range compare, folder compare, blame, file history.** Non-goals in CLAUDE.md.
  Sublime Merge's blame and Kaleidoscope's two-commit Compare are git-client features, not
  viewer features. Commit *browsing* has moved into scope — see below.
- **Hunk-level staging, discarding, or cherry-picking** from the changeset headers
  (Sublime Merge). Whole-file stage / unstage / discard / delete is now in scope via the
  sidebar context menu (Requested B); anything finer than a file is not.
- **Regex text filters and JSON normalisation** (Kaleidoscope). Interesting, but it
  changes what the diff *is*; a viewer should show what git sees. Revisit only if
  whitespace handling proves insufficient.
- **Editable diffs and merge** (JuxtaCode 1.4). Not a viewer.
- **Command palette.** Menu items with shortcuts are enough at this size.

---

## Research notes

Kaleidoscope 7.0.1 (July 2026):
Blocks / Fluid / Unified layouts; Collapse Unchanged (6.0) with ⌥-click expand all;
Ignore Whitespace (leading/trailing/line-ending) plus regex Text Filters; ⌘F search with
side targeting and negative search; Jump to Line; Wrap Long Lines; ⌘↓/⌘↑ crossing files
(7.0); changeset sidebar with counts by kind, filter by name/extension/kind, flat or
outline view (6.7); Live Working Copy Changes with pause/resume (7.0); one tab per
comparison; `ksdiff` CLI, URL scheme, Finder services, Xcode lldb integration.
Sources: kaleidoscope.app/help/docs/{text-comparison-views, text-compare-settings,
text-diffs-and-colors, text-filters, changeset-window, git-changesets, command-line-tool,
kaleidoscope-url-scheme, integration}, blog.kaleidoscope.app (2025-05-27 Collapse
Unchanged, 2026-04-24 6.7, 2026-07-28 7.0), cloud.kaleidoscope.app/support/release-notes.

Sublime Merge build 2125 (September 2026):
`diff_style` auto / inline / side-by-side; character-level diffs; changes pane stacks all
files' hunks with per-file headers; condensed hunks by default with drag / double-click
context expansion and a whole-file toggle; Ignore Whitespace; word wrap auto; image
diffs; repository tabs with change indicators; lines-changed indicator on commits only;
no find-in-diff, no per-file +/- counts, no folder tree, no changed-file filter (all
open requests).
Sources: sublimemerge.com/{dev, download, docs/diff_context, docs/getting_started,
docs/key_bindings, docs/themes}, sublimetext.com/blog/articles/sublime-merge-2-announcement,
forum.sublimetext.com threads 53597, 41291, 69206, 70001, 39899, 39122, 55433.

JuxtaCode 1.4.1 (August 2026):
Side by side only; word-level highlights; Twin Focus hover pairing (1.3); connector lines
for scattered word diffs; ↓/↑ change navigation continuing into the next file; scrollbar
section markers; selectable text; file filter by name/type/change kind; no whitespace
toggle, no stats, no collapse, no search documented; tabs for commits, windows per repo
with path disambiguation; `juxta` CLI and difftool integration; image diff is the top
App Store request.
Sources: juxtacode.app/{releases, docs/cli, integrations}, apps.apple.com JuxtaCode
listing, news.ycombinator.com/item?id=36159270.
