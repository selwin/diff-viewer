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
| Character-level highlights inside a changed line | no (word-level) | yes | no (word-level) | **yes** |
| Full syntax colouring both panes | yes | yes | yes | yes |
| Ignore whitespace | yes (3 kinds + regex filters) | yes | not documented | yes (one toggle) |
| Live working-copy refresh | yes (7.0 headline) | yes | yes | yes |
| Multiple repos at once | tabs | repo tabs | tabs + windows | **yes** (native tabs with +/− churn) |
| Aggregate +/- churn | counts by kind only | per-commit only | none | **yes** (All changes row and header) |
| Per-file +/- churn in sidebar | no | no | no | **yes** |
| Stage / unstage / discard from file list | no (viewer) | yes | no | **yes** (whole file) |
| All files in one scroll | no (per file) | yes (default view) | no | **yes** (All changes) |
| Collapse unchanged / context expansion | yes | yes (default) | no | **yes** (fixed context in All changes) |
| Find in diff | yes | no | no | **yes** |
| Jump to line | yes | no | no | **no** |
| Wrap long lines | yes | yes | no | **no** |
| Browse a previous commit's diffs | yes (changesets) | yes (graph) | yes (tabs) | **yes** (picker) |
| Sidebar filter (name / ext / kind) | yes | partial | yes | **no** |
| Folder outline in sidebar | yes | no (long-requested) | no | **no** |
| Rename / move detection | yes | yes | yes | **yes** (exact) |
| Image diff | no | yes | no (top request) | **yes** (side by side, no onion-skin) |
| Text selection / copy from panes | yes | yes | yes | **yes** |

---

## Requested

Items Selwin asked for. They take priority over the "Next" list below. Earlier requests
(per-file churn, the sidebar context menu, multi-selection with bulk actions, the copy
button on git error alerts, copying from the branch picker, moved-code detection, churn on repository tabs) have shipped and are gone from here.

### A. Branch state in the title bar (remainder)

The branch picker landed on 2026-09-18. Still open from the original request:

- **In-progress operations.** If `.git/rebase-merge`, `.git/rebase-apply`,
  `.git/MERGE_HEAD`, or `.git/CHERRY_PICK_HEAD` exists, append the state to the branch
  name, e.g. `main (rebasing)`, the way the git prompt scripts do. Cheap file-exists
  checks, no extra git calls; `RepoWatcher` already fires on `.git` changes.
- **Ahead/behind counts** from `git rev-list --left-right --count @{u}...HEAD`, if
  they stay cheap.

**Tests.** The in-progress state suffix from a set of existing marker files.

---

### B. Keyboard shortcuts for staging and committing (requested 2026-09-23)

**Goal.** Stage the files just read and commit them without touching the mouse. The
Changes menu (Stage S, Unstage U, Discard Changes…, Move to Trash…, active while the
file list has focus), the selection popover, and moving the selection on to the next
file after staging or unstaging have landed; what remains is below.

**Design.**
- Unstage All, ⌥⇧⌘S, in the Changes menu (Stage All ⌥⌘S has landed). Disabled when it
  doesn't apply and runs through `FileActionRunner`, like the other items.
- With All changes selected, S stages the file whose section is at the top of the
  scroll.
- The whole flow is then: read, S (or ⌥⌘S), ⌘Return, ⌘G, ⌘Return.

**Tests.** Which file S targets in All changes from a scroll position.

---

### E. Redesign how renames and file paths look (requested 2026-09-24)

**Goal.** Make moved and renamed files, and file paths in general, read clearly in the
sidebar, the single-file view and the All changes view, and make the three consistent.

**Today.**
- A rename has an `R` badge, which is git's status letter (`Kind.rawValue`). A different
  glyph needs a display property on `Kind`, because the parser matches on the raw value.
- Sidebar: the new file name, with `← old/dir/OldName.swift` as the caption. The caption
  truncates at the head, so the old name stays visible.
- Single-file header: `NewName.swift ← old/dir/OldName.swift`, a copy button, and the new
  directory at the right edge.
- All changes section header: the same layout in monospace, but the old path truncates at
  the tail, so a long old path loses its file name (`← src/Deep/Nested/Directo…`).
- The sidebar never shows a rename's new directory, because the old path replaces it.
  Both headers put the new directory at the far right, away from the name, so a move
  between folders reads as two separate facts rather than one change of path.

**To decide.**
- How a move between folders differs from a rename in place: show only the part that
  changed, or old and new paths in full.
- One truncation rule for every path.
- Whether the badge stays `R` or says "moved" when only the directory changed.

**Tests.** None; UI, checked by screenshot.

---

### F. Rework the All changes file header (requested 2026-09-26)

**Goal.** The per-file section header in All changes needs a redesign. The
"Renamed without changes" sections look especially bad. Goes with item E, which
covers rename and path display.

**Today** (screenshot of an Android repo, 2026-09-26).
- The header is split across the two panes. The name and old path sit on the left, the
  directory and churn sit at the far right of the right pane, and the pane divider runs
  through the middle. Most of the right half is empty.
- A rename with no content changes takes a header row, a notice row and a spacer, and
  the notice ("Renamed without changes") appears in both panes. A run of pure renames
  (five resource moves in the screenshot) fills the screen with repeated notices and
  nothing to read.
- A binary rename says "Binary file" and doesn't mention the rename; only the `R` badge
  shows it (`DiffPaneView+Changeset.swift` `notice`).
- The old path truncates at the tail, so it loses the file name (see E).

**To decide.**
- Whether the header spans both panes as one bar instead of being split at the divider.
- Whether pure renames (and other sections with nothing to show) collapse to just the
  header, with no notice row, or group into one compact "N files renamed" block.
- Where the directory and churn go so they read with the name.

**Tests.** None; UI, checked by screenshot.

---

### G. Compare any two commits or branches (requested 2026-09-27)

**Goal.** Pick two refs (commit, branch, tag, or the working tree) and read the diff
between them, e.g. a feature branch against `main` before opening a PR, or two commits
of the same branch. Today the commit picker shows one commit against its parent, and
the working tree against HEAD. This reverses the "Ref-range compare" entry under Not
doing; README's Not doing list changes with it.

**Design.**
- A Compare… item (⇧⌘K or similar) opens a sheet with two fields, Base and Compare,
  each a searchable list of branches (local and remote), recent commits and tags, plus
  "Working tree" for Compare. Swap button between them.
- A merge-base toggle: `base...compare` (what the branch adds, the PR view) by default,
  `base..compare` (the two trees as they are) when off.
- The title bar and the pinned row show the comparison (`main … feature/x`), with a
  way back to the working tree. Staging and discarding are disabled while comparing,
  as they are for a picked commit.
- Reuses the commit picker's rows and the All changes loader; only the git arguments
  and the diff's two sides differ.

**Tests.** The git arguments for each pair (commit/commit, branch/branch with and
without the merge base, branch/working tree), and name-status parsing of a comparison
that includes renames.

---

### H. Hunk-level staging (requested 2026-09-27)

**Goal.** Stage, unstage or discard one change block instead of the whole file, so a
file with an unrelated edit can be committed in pieces. Sublime Merge has it on every
hunk header. This reverses the "Hunk-level staging" entry under Not doing; README's Not
doing list changes with it.

**Design.**
- Each change block gets a small action strip at its top edge on hover: Stage Hunk,
  or Unstage Hunk for a staged change, and Discard Hunk (with the same confirmation as
  a file discard). Keyboard: the change ⌘↓ / ⌘↑ lands on can be staged with ⇧S.
- The patch comes from git, not from the display rows: read `git diff -U0` (or
  `--cached` to unstage) for the file, pick the hunk overlapping the block's line
  range, and pipe it to `git apply --cached --unidiff-zero` (with `-R` to unstage,
  and without `--cached` plus `-R` to discard). Refuse and say why when the display
  and git's hunks disagree (e.g. under Hide whitespace, where the display isn't what
  git would apply).
- Runs through `FileActionRunner` like the file actions, and the live refresh redraws
  the file as partly staged.
- Later: stage a selection of lines, as Sublime Merge's line staging does.

**Tests.** Hunk selection from a block's line range, the patch text for a hunk in the
middle of a file, and staging, unstaging and discarding one hunk in a temporary repo.

---

### I. Show the function or method a change is in (requested 2026-09-27)

**Goal.** When reading a change, see which function, method or type it belongs to
without scrolling up to find the signature. Today a change deep inside a long method,
or just below a collapsed-lines separator, gives no hint of where it is.

**Design.**
- Take the enclosing scope from the tree-sitter parse the highlighter already runs,
  not from git's regex-based hunk header: walk up from the change's first row to the
  nearest function, method, class or similar node, and show its signature line
  (`func adopt(_ repository:)`, `class WindowState`). Nested scopes read as a path
  (`WindowState › adopt(_:)`). Which node kinds count is set per grammar in
  `LanguageRegistry`.
- Where it shows, to decide:
  - on each collapsed-lines separator, after the hidden-line count, for the scope of
    the change below it (the way GitHub puts it in the hunk header);
  - a sticky line at the top of each pane naming the scope of the top visible row,
    so it stays current while scrolling (VS Code's sticky scroll). Old and new sides
    can differ when the change renames or moves the function.
- Works in single-file mode and in All changes. Files without a grammar show nothing
  rather than a guess.

**Tests.** The enclosing scope for a row inside a method, inside a nested type, between
two functions (none), and on a line where the old and new sides name different
functions.

---

### J. Don't highlight unchanged lines for difft's re-nested delimiters (requested 2026-09-27)

**Goal.** A line whose text didn't change shouldn't light up as a change just because
difftastic re-paired its brackets. Found in a scratch repo where a top-level
`func total` moved into `final class Cart { … }`: `final class Cart {` and its closing
`}` are identical on both sides, yet both show as modified with the brace in the strong
tint.

**Cause.**
- difftastic picks the path with the fewest changed tokens. It matched the old top-level
  `func receipt(...) -> [String] {` skeleton (`func`, `(`, `:`, `)`, `->`, `{`) with the
  new `func total(...) -> Int {` inside the class. Crossing that nesting level is only
  possible if the class's `{` and `}` count as novel on both sides, and six matched tokens
  outweigh two novel ones. Confirmed from `difft --display json` output.
- `DiffAligner.align` promotes an equal-op row to `.modified` whenever difft reports
  ranges on it, so the identical line is drawn as changed.

**Why not drop difft ranges on every identical line.** The promotion is useful: when code
gets wrapped in a new block, the line diff often pairs an identical `}` with the wrong
one, and difft's highlight is what points at the new brace.

**Design.**
- On an equal-op row, ignore difft's ranges (and keep the row `.equal`) only when every
  range on both sides is a single delimiter character, and the delimiter's partner on the
  same side also sits on an equal-op row. A wrapped block fails the second test (its new
  brace's partner is on an inserted line), so it keeps today's highlight.
- Finding the partner needs difft's delimiter pairing or a bracket match over the line
  text. Character-level refinement narrows difft ranges only on modified rows, so an
  equal-op row still carries difft's ranges as reported.

**Tests.** The re-nested class case (both braces unhighlighted, rows equal); a block
wrapped in a new `if` (the new `}` still highlighted); an equal-op row where difft marks
a non-delimiter token (unchanged behaviour).

---

### K. Title bar pickers and commit picker design (requested 2026-09-28)

**Goal.** Refine how the branch and commit pickers look in the title bar, and redesign
the commit picker popover to match the branch picker.

**Title bar faces.** On 2026-09-28 both became 36pt capsules (`TitleBarPickerLabel`):
white with a thin outline at rest, tinted on hover, filled grey while open. Still to
refine:
- Dark mode: the capsule is darker than the title bar and its outline barely shows.
- Hover has not been checked on screen.

**Commit picker popover.** Make it resemble the branch picker: header with the current
scope and a status line, a search field, rows grouped by day (Today, Yesterday, This
week, Older) with two-line rows and a right-aligned accessory. The search field's
behaviour is spelled out under "Commit picker search" in the Next list.

**Tests.** Grouping commits by day, if that logic is new. The rest is UI, checked by
screenshot.

---

### L. Explain a resolved conflict that matches HEAD (requested 2026-09-28)

**Goal.** A conflicted file whose resolution equals HEAD shouldn't read as a
contradiction. Found while merging `main` into `consolidate-quick-wins` (PR #41): the
conflict was resolved by keeping the branch's side, and selecting the file showed
"No differences / Both versions have identical content." next to a popover offering
"Stage". Both are correct, but together they look like the app wants you to stage
nothing.

**Cause.**
- For an unmerged file, `DiffEngine.sources` diffs HEAD against the working tree. A
  resolution that keeps HEAD's side is therefore identical, and `DiffDetailView` (single
  file) and `DiffPaneView+Changeset` (All changes) show the generic "No differences".
- Staging is how git marks a conflict resolved, and Commit Merge stays disabled until it
  is. The context menu says so ("Mark Resolved", `FileAction.title(for:)`), but the
  selection popover uses `FileAction.compactTitle(for:)`, which says "Stage", and its
  accessibility label says "Stage 1 file".

**Reproduce.**
```bash
rm -rf /tmp/conflict-demo && mkdir /tmp/conflict-demo && cd /tmp/conflict-demo
git init -q -b main
printf 'base\n' > f.txt && git add f.txt && git commit -qm base
git checkout -qb other && printf 'other\n' > f.txt && git commit -qam other
git checkout -q main && printf 'main\n' > f.txt && git commit -qam main
git merge other           # CONFLICT in f.txt
git checkout --ours f.txt # resolve by keeping main's side, still unmerged
```
Then `scripts/snapshot.sh /tmp/out.png /tmp/conflict-demo` (or `make run` and open the
repo) and select `f.txt`: purple **U**, "No differences", popover "Stage", tray button
"Commit Merge" disabled. Resolving with `git checkout --theirs f.txt` instead shows a
real diff, so only the matches-HEAD case needs new wording.

**Design.**
- Popover: "Mark Resolved" when every selected file is unmerged ("Mark N Resolved" for a
  batch, or whatever matches the popover's short style); accessibility label to match.
- Empty diff for an unmerged file: say what it was compared with, e.g. "Resolution
  matches HEAD", in both the single-file view and the All changes section line.

**Tests.** `compactTitle` for an unmerged file, a batch of unmerged files, and a mix
with a modified file (falls back to "Stage N files"). The empty-state text is UI,
checked by screenshot with the repro above.

---

## Next: high-value features the competitors have and we lack

Roughly in priority order.

- **Change counter strip.** "Change 3 of 41" left the file header when it took the
  name-first layout (2026-09-19). Bring it back in its own thin strip below the header,
  together with previous/next controls, in both single-file and All changes mode.
- **Jump to line (⌘L).** Pick old or new line number; scroll and flash the row.
- **Pane context menu and selection conventions.** Selection and ⌘C / ⌘A have landed.
  Remaining: the context menu (Copy, Copy Path, Copy Line Number, Reveal in Finder, Open
  in Default Editor) and the deferred conventions (shift-click extend, Escape to clear,
  dimming when the window is not key, autoscroll while the mouse is held still).
- **Sidebar action follow-ups.** Unstage All and next-file selection are
  item B under "Requested". Still open: an Unstage All button on the staging tray
  header; Stage All passes every path as a git argument, so very large change sets may
  need batching or `--pathspec-from-file`; one-step discard of a staged change
  (`git restore --staged --worktree`); and `NSWorkspace.recycle` instead of the
  `FileManager.trashItem` loop so a batch trash is one Finder undo.
- **All changes, remaining pieces.** ⌥⌘↓ / ⌥⌘↑ for next/previous file; file ticks in
  the overview strip; click-to-expand context inside the changeset (separators are
  inert today); tooltips for truncated header paths and notice text; section-aware
  scroll anchoring on a full replace; an aggregate source-byte budget with size
  preflight; an app-wide bound on concurrent git, difft and highlight work.
- **Churn, remaining pieces.** The Changes header and the staging tray header show
  churn (`Changes 7 +340 −120`), and a counts-by-kind line (`5 modified, 2 added,
  1 deleted`) somewhere unobtrusive. The per-file counts, the All changes total, and
  the changeset header total have shipped.
- **Commit picker search.** A search field between the pinned row and the list,
  matching subject, hash prefix and body (needs `%b` in the log format), highlighted
  subject ranges, Escape clears before it dismisses, "No matches in loaded commits" when
  the filter empties the list, and eventually searching beyond the loaded pages. Its
  shortcut must not fight the diff's ⌘F: the picker is a popover, so ⌘F while
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
- **Timeout on remote git calls.** Fetch, pull, push, publish and fast-forward wait on
  git for as long as it runs. An SSH connection or a credential helper that hangs keeps
  the picker's spinner going; only `GIT_TERMINAL_PROMPT=0` guards against a prompt
  today. Give them a timeout that stops git and reports it.
- **Undo Move.** For an unstaged move: restore the old path and move the new file to the
  Trash.
- **Highlight a rename's old side by its own name.** `DiffEngine.Sources` carries only
  the new file name, so a rename that shows edits colours its old side with the new
  extension's grammar. That happens today for an intent-to-add move (`.R`) under a clean
  filter, where the raw old and new text can differ.
- **Similarity-based rename detection.** Deliberately not done: git runs with
  `--find-renames=100%`, so only content-identical renames are paired. Git compares
  content after clean filters; the app's own pairing of an unstaged `mv` compares raw
  bytes. A renamed and edited file still shows as a delete plus an add.
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
- **Delete N gone branches** from the branch picker footer, in one action.
- **CLI and `git difftool` integration.** All three ship a CLI (`ksdiff`, `smerge`,
  `juxta`) and a difftool config. Deferred per the v1 decision; when it comes, a
  `diffviewer <repo>` opener plus a `kaleidoscope://changeset?path=` style URL scheme
  is the minimum. Listed in README as a non-goal for now.

## Not doing (and why)

- **Inline / unified text layout.** Side by side only (CLAUDE.md). Sublime Merge's
  `diff_style` auto-switching and Kaleidoscope's Unified layout are not goals.
- **Folder compare, blame, file history.** Non-goals in CLAUDE.md. Sublime Merge's blame
  is a git-client feature, not a viewer feature. Comparing two refs is now requested
  (item G), and commit browsing shipped as the commit picker.
- **Hunk cherry-picking** (Sublime Merge). Hunk-level staging and discarding are now
  requested (item H); moving hunks between commits is not.
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
