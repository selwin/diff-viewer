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

### G. Keyboard shortcuts for staging and committing (requested 2026-09-23)

**Goal.** Stage the files just read and commit them without touching the mouse. The
Changes menu (Stage S, Unstage U, Discard Changes…, Move to Trash…, active while the
file list has focus) and the selection popover have landed; what remains is below.

**Design.**
- Stage All / Unstage All, ⌥⌘S / ⌥⇧⌘S, in the Changes menu. Disabled when they don't
  apply and run through `FileActionRunner`, like the other items.
- After staging or unstaging, keep the sidebar selection on the next file in the
  section the file left, so repeated S walks down the Unstaged list and the popover
  walks with it. With All changes selected, S stages the file whose section is at the
  top of the scroll.
- The whole flow is then: read, S (or ⌥⌘S), ⌘Return, ⌘G, ⌘Return.

**Tests.** Which file becomes selected after staging or unstaging (middle, last, and
only file in a section); which file S targets in All changes from a scroll position.

---

### H. Find button in the toolbar (requested 2026-09-23)

**Goal.** Find is reachable today only through ⌘F and Edit ▸ Find, so readers who don't
know the shortcut never see it. Add a visible way in.

**Design.**
- A `magnifyingglass` button in the toolbar next to the other diff controls, with the
  tooltip "Find (⌘F)". It opens the bar or refocuses the field (`showFindBar()`), and
  shows as on while the bar is open.
- Disabled when `isFindAvailable` is false (binary, identical or failed selections),
  like Find… in the menu.

**Tests.** None; UI, checked by screenshot.

---

### I. Copy from the commit and branch pickers (requested 2026-09-24)

**Goal.** Hovering over a commit or branch row offers a way to copy it, so a hash or
branch name can go into a terminal, review, or chat without retyping. Neither picker
has any copy today.

**Design.**
- On hover (and keyboard highlight), a small copy button appears on the row. In the
  commit picker it copies the full hash; in the branch picker it copies the branch name.
  It sits in the row's accessory slot next to the branch sync buttons, and a click never
  activates the row.
- A right-click menu offers the same, plus Copy Short Hash and Copy Subject for commits.
- ⌘C copies the highlighted row's hash or name.
- Brief "Copied" feedback on the button; an accessibility custom action ("Copy hash",
  "Copy branch name").

**Tests.** None beyond what the pasteboard string is for each row kind; UI, checked by
screenshot.

---

### J. Delete branches whose upstream is gone (requested 2026-09-24)

**Goal.** Once a PR merges and its remote branch is deleted, the local branch stays in
the branch picker as "upstream gone" forever; git never removes it. Let the reader clear
it from the picker instead of dropping to a terminal.

**Design.**
- A trash button in the row's accessory slot, in place of the sync buttons, only on
  rows whose upstream is gone and never on the checked-out branch.
- It confirms first ("Delete branch image-preview?"), then runs `git branch -D`. `-D`
  rather than `-d` because PRs are squash-merged, so git doesn't see these branches as
  merged into main.
- Maybe later: a "Delete N gone branches" action in the picker footer.
- Deleting a branch is not in the list of allowed actions under "Whole files, never
  contents" in CLAUDE.md; extend that principle when this lands.

**Tests.** Which rows offer delete: an upstream-gone branch does; the current branch,
branches with no upstream, and branches whose upstream still exists don't.

---

### K. Failed commit alert: copy button and subtitle (requested 2026-09-24)

**Goal.** When a pre-commit hook fails, the reader can copy its whole output in one
click, to paste into a terminal, an issue, or a chat. Today `ErrorAlert` shows a long
message in a selectable scroll view, so copying takes select-all and ⌘C, and a short
message sits in the alert's informative text, which can't be selected at all.

**Design.**
- A small square glass copy button (`doc.on.doc`) pinned to the top-right corner of
  the output scroller, not a button beside OK. It rests at low opacity and sharpens when
  the pointer enters the scroller: the GitHub/Xcode code-block idiom with vibrancy
  (`NSGlassEffectView`) and no extra chrome.
- It stays put while the output scrolls. An exclusion path on the text container keeps
  the first lines wrapping short of it, so no text sits under the button.
- Clicking it puts the whole trimmed message on the pasteboard and leaves the alert
  open, with brief "Copied" feedback. OK stays the default button.
- Open question: a short message has no scroller to pin the button to. Either always
  show the output in the scroller, or keep a plain Copy button for that case.
- It lives in `ErrorAlert`, so every git error (commit, stage, discard, sync) gets it.

**Title and subtitle.** Title the alert "Commit Failed" rather than "Error". Today the
summary is the output's first line, which for a pre-commit run is its harmless
"Unstaged files detected" warning. Git never says in its output that a hook failed, so
guessing from the output text isn't reliable. Take the facts from git's trace2 event log:
- Run `git commit` with `GIT_TRACE2_EVENT` pointing at a temp file (JSON lines, a
  documented and versioned format). Checked against git 2.54 on 2026-09-24.
- A failed hook shows up as a `child_start` event with `"child_class":"hook"` and a
  `hook_name`, then a `child_exit` event with its `code`. This works for any hook manager.
  Git's own failures (gpg signing, identity, index lock) show up as `error` events with a
  `msg`.
- Read only the top-level `git commit`'s events. Git run from inside a hook writes to the
  same file, and a child's `sid` extends its parent's with `/`.
- Subtitle: "The pre-commit hook exited with status 3." when a hook failed; otherwise
  git's first `error` message; otherwise none. When a hook failed and the pre-commit
  framework's result lines (`<name>....Failed` followed by `- hook id:`) are present,
  add the failed hook names ("SwiftLint failed."). Never counts like "1 error": those
  would come from each tool's own output.

**Tests.** `ErrorAlert.layout`; the subtitle from trace2 event logs for a failed hook,
git's own error, a hook whose own git call errors (ignored), and neither (no subtitle);
hook names from pre-commit's `Failed` lines. UI, checked by screenshot.

---

### L. Tab indicator when a repository has changes (requested 2026-09-24)

**Goal.** With several repositories open as tabs, you can see from the tab bar which
ones have diffs to read without switching to each. Sublime Merge does this, and it's
what makes tabs useful while a coding agent works in another repo.

**Design.**
- A small dot in the tab's `NSWindowTab.accessoryView` while the working tree has
  changes (the sidebar's file list is non-empty). It goes away once the repository is
  clean. It could carry the changed-file count if the dot alone proves too vague.
- Background tabs are occluded windows, and a hidden window stops its watcher today
  (`WindowState.isVisible`), so its file list goes stale. The indicator needs hidden
  windows to keep a status-only watch (status, no diff or highlight work) so the dot
  is current.
- Open question: whether the dot also marks changes since the tab was last key, and
  clears when you view them, as Sublime Merge's unread dot does.
- This absorbs the "Tab change indicator" item from the Next list.

**Tests.** None; UI, checked by screenshot. A status-only refresh path for hidden
windows, if one is added, gets tests for when it runs.

---

### M. Redesign how renames and file paths look (requested 2026-09-24)

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

### O. Manual fetch in the branch picker (requested 2026-09-25)

**Goal.** Right after merging a PR on GitHub, the picker sometimes doesn't show that the
remote tracking branch has new commits. Opening the picker fetches automatically, but
within `WindowState.fetchCooldown` (60 s) of the last successful fetch it shows that
fetch's result instead of running another, so the merge isn't seen yet. A Fetch button
lets the reader ask for fresh counts.

**Design.**
- A fetch button (`arrow.clockwise`) in the picker, next to the "fetched …" time. It
  skips the cooldown and fetches the current branch's remote and the other remotes, the
  same way the automatic fetch does.
- While a fetch runs it shows the existing spinner and is disabled; a failure shows the
  way an automatic fetch failure does.

**Tests.** A manual fetch runs within the cooldown, where an automatic one doesn't.

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
- **Sidebar action follow-ups.** Stage All / Unstage All and next-file selection are
  item G under "Requested". Still open: Stage All / Unstage All buttons on the section
  headers; one-step discard of a staged change (`git restore --staged --worktree`); and
  `NSWorkspace.recycle` instead of the `FileManager.trashItem` loop so a batch trash is
  one Finder undo.
- **All changes, remaining pieces.** ⌥⌘↓ / ⌥⌘↑ for next/previous file; file ticks in
  the overview strip; click-to-expand context inside the changeset (separators are
  inert today); tooltips for truncated header paths and notice text; section-aware
  scroll anchoring on a full replace; an aggregate source-byte budget with size
  preflight; an app-wide bound on concurrent git, difft and highlight work.
- **Churn, remaining pieces.** Section headers become `Unstaged (7) +340 −120`, and a
  counts-by-kind line (`5 modified, 2 added, 1 deleted`) somewhere unobtrusive. The
  per-file counts, the All changes total, and the changeset header total have shipped.
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
