# TODO

Open work for DiffViewer. Every item is judged by the question in CLAUDE.md: does it
make reading a diff faster, clearer, or more pleasant? Items are grouped by priority;
within a group, order is a suggestion. Shipped features are not listed here; their
design notes live in git history and their behaviour in CLAUDE.md and README. Competitor
references come from the research notes at the bottom (Kaleidoscope 7.0, Sublime Merge
build 2125, JuxtaCode 1.4, all as of September 2026).

Where DiffViewer stands versus the bar:

| Capability | Kaleidoscope | Sublime Merge | JuxtaCode | DiffViewer |
|---|---|---|---|---|
| Side-by-side, aligned rows | yes | yes (or inline) | yes | yes |
| Structural (AST-aware) token highlights | no (word-level) | no (character-level) | no (word-level) | **yes (difftastic)** |
| Full syntax colouring both panes | yes | yes | yes | yes |
| Ignore whitespace | yes (3 kinds + regex filters) | yes | not documented | yes (one toggle) |
| Live working-copy refresh | yes (7.0 headline) | yes | yes | yes |
| Multiple repos at once | tabs | repo tabs | tabs + windows | **yes** (native tabs, no change indicator) |
| Aggregate +/- churn | counts by kind only | per-commit only | none | **yes** (All changes row and header) |
| Per-file +/- churn in sidebar | no | no | no | **yes** |
| Stage / unstage / discard from file list | no (viewer) | yes | no | **yes** (whole file) |
| All files in one scroll | no (per file) | yes (default view) | no | **yes** (All changes) |
| Collapse unchanged / context expansion | yes | yes (default) | no | **yes** (fixed context in All changes) |
| Find in diff | yes | no | no | **no** |
| Jump to line | yes | no | no | **no** |
| Wrap long lines | yes | yes | no | **no** |
| Browse a previous commit's diffs | yes (changesets) | yes (graph) | yes (tabs) | **yes** (picker) |
| Sidebar filter (name / ext / kind) | yes | partial | yes | **no** |
| Folder outline in sidebar | yes | no (long-requested) | no | **no** |
| Rename / move detection | yes | yes | yes | **no** (`--no-renames`) |
| Image diff | no | yes | no (top request) | **yes** (side by side, no onion-skin) |
| Text selection / copy from panes | yes | yes | yes | **yes** |

---

## Requested

Items Selwin asked for. They take priority over the "Next" list below. Earlier requests
(per-file churn, the sidebar context menu, multi-selection with bulk actions) have
shipped and are gone from here.

### C. Branch state in the title bar (remainder)

The branch picker landed on 2026-09-18. Still open from the original request:

- **In-progress operations.** If `.git/rebase-merge`, `.git/rebase-apply`,
  `.git/MERGE_HEAD`, or `.git/CHERRY_PICK_HEAD` exists, append the state to the branch
  name, e.g. `main (rebasing)`, the way the git prompt scripts do. Cheap file-exists
  checks, no extra git calls; `RepoWatcher` already fires on `.git` changes.
- **Ahead/behind counts** from `git rev-list --left-right --count @{u}...HEAD`, if
  they stay cheap.

**Tests.** The in-progress state suffix from a set of existing marker files.

---

### E. Find in the diff (requested 2026-09-22)

**Goal.** ⌘F opens a find bar; typing highlights every match in both panes and the
overview strip, ⌘G / ⌘⇧G step through them, and the bar reads "3 of 41". It works the
same in a single file and in All changes, so a reader can find a symbol across every
changed file without leaving the scroll. Kaleidoscope has this; Sublime Merge and
JuxtaCode do not.

**Design.**
- Model: a `FindQuery` (text, case-sensitive flag, side: old / new / both, changed
  lines only) and a `FindMatch` (row index, side, UTF-16 range in that line). A `Finder`
  in `Diff/` walks `DiffDocument.rows` rather than the raw line arrays, so a match is
  born knowing its row; an equal row can match on both sides and reports each once.
  Plain substring search with `String.range(of:options:)`; no regex in the first cut.
- Changed lines only: rows whose `DiffRow.Kind` is not `.equal`. Off by default. The
  three options persist in `Preferences`.
- Where it runs: on a background task owned by `WindowState`, debounced as the user
  types and cancelled by the next keystroke. A 20k-line file is a few milliseconds of
  substring search, but All changes can be ten times that, and the main thread never
  waits on it. In All changes the query is re-run over the rows the
  `ChangesetAssembler` appends, and the current match index is clamped rather than
  reset, so the counter does not jump while files are still arriving.
- Drawing: `DiffPaneView` gains a `matches` property next to `styles`, keyed by document
  row, applied without re-layout the way `DocumentStyles` is. Matches are filled behind
  the text in a translucent find colour; the current match uses the accent colour. The
  current match also becomes the pane's `PaneSelection`, so ⌘C copies it and the eye
  lands on it. `ChangeOverviewView` gets a `matchRows` list and draws a thin tick per
  row, a different shape from the change marks so the two read apart.
- Navigation: ⌘G / ⌘⇧G and the bar's ‹ › buttons step with the `ChangeNavigator` index
  math, wrapping at the ends, and scroll through a `ScrollTarget`. Return in the field
  is next, ⇧Return previous. A match inside a folded `DisplayRow.separator` is revealed
  first, reusing the expand path, so no match is unreachable in All changes.
- Find bar: a thin strip under the file header (Safari-style: field, options menu in the
  field, counter, ‹ ›, Done), not a sheet. Escape closes it and clears the highlights;
  the query text survives so ⌘F reopens with it. ⌘E puts the pane selection into the
  field. Menu items live in `RepositoryCommands` under Edit ▸ Find. ⌘G already generates
  a message inside the commit sheet; the sheet is modal, so the two never compete.
- Sidebar: files with at least one match could show a count badge later; not in the
  first cut.

**Tests.** Match enumeration across sides and rows, including a line that matches on
both sides of an equal row and adjacent or overlapping occurrences; case folding; the
changed-lines-only filter; next/previous wrapping; index stability when rows are
appended mid-search; and mapping a match in a hidden range to the rows that must be
revealed. The bar and highlights are verified by screenshots.

---

### F. Push and pull branches from the branch picker (requested 2026-09-23)

**Goal.** Every local branch in the branch picker gets Push and Pull buttons. A branch
with no upstream is published with `git push --set-upstream <remote> <branch>`, so a
branch made for a change can go up for review without leaving the app.

**Design.**
- Each branch row shows push / pull buttons, visible on hover or selection so the list
  stays quiet. None of them switches the working tree to that branch.
- Push: `git push <remote> <branch>` works on any local branch, checked out or not.
  With no upstream (`git rev-parse --abbrev-ref <branch>@{u}` fails), push with
  `--set-upstream`, and relabel the button "Publish". Never force-push.
- Pull, current branch: `git pull --ff-only`, so it never creates a merge or starts a
  rebase. If it can't fast-forward, show git's message.
- Pull, other branches: `git fetch <remote> <branch>:<branch>` fast-forwards a branch
  that isn't checked out without touching the working tree. git refuses a
  non-fast-forward, and we surface that. Disabled when the branch has no upstream.
- Remote: the branch's upstream remote when set. Otherwise `origin` when it exists,
  otherwise the only remote. With several remotes and no `origin`, ask. No remote means
  no buttons.
- Ahead/behind counts from item C, per row, tell the reader which button matters.
- Run off the main thread with a timeout (credential helpers and SSH prompts can hang),
  show progress on the row, and surface git's stderr on failure. A pull on the current
  branch refreshes the diff through the existing watcher.
- Scope: push and pull are not in CLAUDE.md's list of allowed actions; add them there
  ("push a local branch to its remote; fast-forward a local branch from it") when this
  lands.

**Tests.** Remote choice from a branch's upstream and a list of remotes; detecting "no
upstream" from git's output; choosing the pull command for the current branch versus
any other branch.

---

## Next: high-value features the competitors have and we lack

Roughly in priority order.

- **Change counter strip.** "Change 3 of 41" left the file header when it took the
  name-first layout (2026-09-19). Bring it back in its own thin strip below the header,
  together with previous/next controls, in both single-file and All changes mode.
- **Find in diff (⌘F).** Requested on 2026-09-22 and written up as item E under
  "Requested" above.
- **Jump to line (⌘L).** Pick old or new line number; scroll and flash the row.
- **Pane context menu and selection conventions.** Selection and ⌘C / ⌘A have landed.
  Remaining: the context menu (Copy, Copy Path, Copy Line Number, Reveal in Finder, Open
  in Default Editor) and the deferred conventions (shift-click extend, Escape to clear,
  dimming when the window is not key, autoscroll while the mouse is held still).
- **File menu mirror for the sidebar actions.** Stage / Unstage / Discard / Delete on
  the File menu with ⌘S / ⌘⇧S / ⌘⌫, acting on the sidebar selection, so the actions are
  discoverable and reachable from the keyboard. With it: Stage All / Unstage All on the
  section headers; one-step discard of a staged change (`git restore --staged
  --worktree`); a split menu for a mixed selection ("Stage 2 Files" + "Unstage 1 File")
  if the intersection rule proves too strict; and `NSWorkspace.recycle` instead of the
  `FileManager.trashItem` loop so a batch trash is one Finder undo.
- **All changes, remaining pieces.** ⌥⌘↓ / ⌥⌘↑ for next/previous file; file ticks in
  the overview strip; click-to-expand context inside the changeset (separators are
  inert today); tooltips for truncated header paths and notice text; section-aware
  scroll anchoring on a full replace; an aggregate source-byte budget with size
  preflight; an app-wide bound on concurrent git, difft and highlight work.
- **Churn, remaining pieces.** Section headers become `Unstaged (7) +340 −120`, and a
  counts-by-kind line (`5 modified, 2 added, 1 deleted`) somewhere unobtrusive. The
  per-file counts, the All changes total, and the changeset header total have shipped.
- **Tab change indicator.** When a watcher fires in a non-key window, mark its tab (a
  dot in the title, or an `NSWindowTab.accessoryView` badge with the changed-file
  count) and clear it when the tab becomes key. This is the Sublime Merge behaviour
  that makes tabs useful while a coding agent works in another repo.
- **Commit picker search.** A search field between the pinned row and the list,
  matching subject, hash prefix and body (needs `%b` in the log format), highlighted
  subject ranges, Escape clears before it dismisses, "No matches in loaded commits" when
  the filter empties the list, and eventually searching beyond the loaded pages. Its
  shortcut must not fight the diff's ⌘F (item E): the picker is a popover, so ⌘F while
  it is open goes to the picker.
- **Commit picker paging and refresh.** Load More re-reads from page 1 with a larger
  limit, so reaching 2,000 commits in pages of 50 reads about 41,000 records in total;
  `startingAt: last.firstParentSHA` with append would fix it. Measure before optimising
  the table diff further. Also: the ⌘R-only path for re-reading a commit's files.
- **Commit follow-ups.** Amend; a `--no-verify` toggle; sign-off; commit-and-push;
  honouring `commit.cleanup`; a 50/72 column guide; a summary/description split; an
  identity check via `git var GIT_AUTHOR_IDENT` before enabling the button; timeouts on
  git calls (a hanging gpg pinentry); undo last commit; and watching a linked
  worktree's git dir (HEAD, the index and merge metadata there are missed today).
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
  table so both panes stay aligned (the taller side wins per row).
- **Next/previous change crossing files in single-file mode.** Kaleidoscope 7.0's ⌘↓ at
  the last change advances to the next file. Small change to `ChangeNavigator`.
- **Larger-file highlighting.** README follow-up: highlight visible rows first, or cache
  compiled query predicates. Kaleidoscope auto-disables syntax colouring on very large
  files; do the same above a line threshold with a "Highlight anyway" button.
- **Finer whitespace control.** Kaleidoscope splits ignore into leading / trailing /
  line-ending. Offer "Ignore all whitespace" vs "Ignore leading and trailing" if the
  single toggle proves too coarse; keep the persisted-toggle design.

## Later: worth having, not urgent

- **Image diff, second pass.** The side-by-side preview landed (2026-09-20); still
  open: a swipe or onion-skin slider, zoom, and images inside All changes.
- **SVG (and image) previews inside All changes.** Today a binary section shows the
  "Binary file" notice and an SVG section shows its source rows. Medium effort, and the
  cost is all in the pane: `PaneLayout` assumes one row height for every display row, so
  an image band needs either variable-height rows (touches `y(forRow:)`, hit testing,
  the overview strip, and scroll anchoring) or a fixed-height "preview" display row
  (say 160 pt, thumbnails scaled to fit, no zoom) drawn by `DiffPaneView+Changeset`
  from a per-section `ImagePreview`. The fixed-height row is the boring choice and
  keeps the layout math intact. The rest is small: `ChangesetAssembler` decodes the
  preview alongside the diff (the loader already knows how, per side and format), the
  section carries it, and `ChangesetProjection` emits the preview row after the file
  header, before the source rows for an SVG. Open question for SVG: preview and source
  both, or a per-section Preview / Source toggle like the single-file header.
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

## Not doing (and why)

- **Inline / unified text layout.** Side by side only (CLAUDE.md). Sublime Merge's
  `diff_style` auto-switching and Kaleidoscope's Unified layout are not goals.
- **Ref-range compare, folder compare, blame, file history.** Non-goals in CLAUDE.md.
  Sublime Merge's blame and Kaleidoscope's two-commit Compare are git-client features, not
  viewer features. Commit *browsing* is in scope and shipped as the commit picker.
- **Hunk-level staging, discarding, or cherry-picking** from the changeset headers
  (Sublime Merge). Whole-file stage / unstage / discard / delete is in scope via the
  sidebar context menu; anything finer than a file is not.
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
