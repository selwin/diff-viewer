# DiffViewer

A native macOS 26 app for viewing git diffs side by side.

- **Commit picker** at the top of the sidebar: show the working tree, as always, or pick a
  commit from the branch's history and see what it changed against its first parent.
- **All changes**, selected by default: every changed file's hunks stacked in one
  side-by-side scroll, each under a header with its kind badge, name, `+12 −4` and
  language. Line numbers restart per file and ⌘↓ / ⌘↑ walk changes across files.
- **Syntax-aware diffs** via a bundled [difftastic](https://difftastic.wilfred.me.uk) (`difft`)
  binary: token-level highlights that understand the language's structure.
- **Hide whitespace** toggle (⇧⌘W), like GitHub's diff viewer.
- **Per-file line counts** in the sidebar (`+12 −4`, or "binary"), from `git diff --numstat`
  (with `-w` when Hide whitespace is on — it means exactly git's `-w`: ASCII whitespace only).
- **Collapse unchanged lines** (⇧⌘U, on by default): only changed hunks plus 5 lines of
  context are shown; each hidden run is one separator with expand-up / expand-down
  controls (20 lines at a time), click the text to reveal the run, ⌥-click to reveal the
  whole file. The hidden `collapseContextLines` default overrides the context size.
- **Full syntax highlighting** of both sides with tree-sitter (Swift, Python, JS, TS/TSX,
  JSON, Go, Rust, C, C++, HTML, CSS, Bash, Ruby, YAML, TOML, Java, Kotlin, PHP, Markdown).
- **Sidebar context menu**: right-click a file to stage it, unstage it, discard its changes,
  restore it after a delete, or move an untracked file to the Trash, plus Reveal in Finder,
  Open in Default Editor, and Copy Path. Discard and Delete ask first; "Don't ask again"
  turns the question off and View › Confirm Destructive File Actions turns it back on.
  Whole files only: the app never edits file contents and never commits.
- **Fast**: custom AppKit renderer draws only visible rows; a 20k-line file scrolls smoothly.
- Unstaged / staged file list, live refresh when the repo changes, next/previous change
  (⌘↓ / ⌘↑), change overview strip, font size (⌘+ / ⌘- / ⌘0), light and dark mode.

## Build

Requires Xcode 26 and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
make run      # generate the project, fetch difft, build, launch
make test     # run the unit tests
make open     # open the generated Xcode project
make lint     # SwiftLint (brew install swiftlint), same rules as CI
make format   # rewrite sources with swift-format; `make format-check` only reports
make hooks    # install the git hooks; `make hooks-all` runs them over every file
```

CI runs the same three checks as separate workflows under `.github/workflows/`: SwiftLint and
swift-format on Linux, and `xcodebuild test` on a macOS 26 runner.

After cloning, install the development tools and the git hooks once:

```bash
brew install pre-commit swiftlint
make hooks
```

Committing then runs text hygiene, swift-format and SwiftLint over the staged files, with the
same configuration as the Format and Lint workflows; `make hooks-all` checks the whole
repository. swift-format rewrites the file and stops the commit, so re-stage and commit again.

`make` points `DEVELOPER_DIR` at `/Applications/Xcode.app` so it works even when
`xcode-select` is set to the Command Line Tools.

The `difft` binary is copied from Homebrew if installed, otherwise downloaded from the
difftastic GitHub release, into `DiffViewer/Resources/bin/` (git-ignored).

## Use

Open a repository with ⌘O, drag a folder onto the window, or `open -a DiffViewer <repo>`.
Each repository gets its own window, and windows are tabs of one window by default:
⌘T opens an empty tab that adopts the next repository you open, ⇧⌘] / ⇧⌘[ cycle tabs,
and the Window menu's Move Tab to New Window and Merge All Windows detach and regroup
them. Opening a repository that is already open focuses its tab. On quit the set of open
repositories and the active one are saved and restored on the next launch; launching by
opening a folder from Finder shows that repository instead of the saved set.

The picker above the file list chooses what the sidebar and the diffs are comparing.
**Working Tree** is the default and behaves exactly as before: unstaged and staged
sections, refreshed live as the repository changes. Picking a commit instead shows the
files that commit changed, compared against its first parent — the root commit against the
empty tree, and a merge against the branch it was merged onto, which is the same thing
`git log --first-parent` shows. Commits merged in from side branches are therefore not
listed individually. The list holds 50 commits at a time, with Load More below it, and
follows the branch you check out. A commit's diffs cannot change, so nothing about that
view reloads until HEAD moves.

The window subtitle, under the repository name, names the branch HEAD is on, or reads
`detached at <sha>` on a detached HEAD, and follows a checkout made in the terminal.

**All changes**, the first row of the sidebar, is selected whenever a list arrives. It
shows every file in the list in sidebar order, streaming in as each diff finishes
("Loading 7 of 12…" in the header). Hunks are shown with fixed context and their
separators cannot be expanded there; click a file in the sidebar to read it in full.
A file over 1 MB of source, or past the 200th, shows a one-line notice instead and is
still readable from the sidebar. Text selection and ⌘C span the whole changeset.

## Layout

| Directory | Contents |
|-----------|----------|
| `DiffViewer/App` | App entry, `Preferences` (app-wide settings), `WindowState` (one repository per window), `WindowCoordinator` (routing, key and visibility tracking, session persistence), `DiffLoader`, `ChangesetAssembler` (streams All changes) |
| `DiffViewer/Git` | `git` CLI wrapper, status / numstat / name-status / log parsers, commit refs, FSEvents watcher |
| `DiffViewer/Diff` | Myers line diff, difft JSON runner, row aligner, engine, changeset builder and projection |
| `DiffViewer/Highlighting` | tree-sitter grammar registry, highlighter, token theme |
| `DiffViewer/Views` | SwiftUI shell plus the AppKit pane renderer and overview strip |
| `DiffViewerTests` | Swift Testing suites for the non-UI layers |

Debug builds accept `DIFFVIEWER_SELECT`, `DIFFVIEWER_SCOPE`, `DIFFVIEWER_NEXT`,
`DIFFVIEWER_FOLD`, `DIFFVIEWER_APPEARANCE`, and `DIFFVIEWER_SNAPSHOT` environment
variables for scripted screenshots, and `DIFFVIEWER_OPEN`, `DIFFVIEWER_TAB_STEPS`, and
`DIFFVIEWER_DUMP_WINDOWS` for scripted checks of tabs, restoration, and diff latency (see
`scripts/` and `DebugLaunchOptions`).

## Known limitations / next steps

- Highlighting a 20k-line Swift file takes ~2.8 s per side in Debug builds (tree-sitter
  query predicates are regex-heavy); both sides run in parallel and never block scrolling.
  Possible follow-ups: cache compiled predicates, or highlight visible rows first.
- Separator controls are exposed to VoiceOver as buttons but have no keyboard shortcut yet.
- All changes is rebuilt from scratch every time it is selected or the list changes;
  its file headers do not stick to the top while scrolling, and its hunks cannot be
  expanded in place. See `TODO.md` item 3 for the follow-ups.
- Tabs are the policy, not the system preference: repository windows always prefer
  tabbing, whatever System Settings > Desktop & Dock > "Prefer tabs when opening
  documents" says. Honouring the system tab preference is a follow-up.
- Highlighting runs in detached tasks the loader cannot stop: a hidden or closed window
  starts no new highlight, but one already computing runs to completion. Bounded
  highlighting concurrency with cooperative cancellation is a follow-up.
- Foreground difft runs are unbounded: several visible windows reloading at once, or
  rapid selection changes, can overlap difft processes (background prefetch runs share
  three slots). A foreground difft scheduler is a follow-up.
- Not yet built: `git difftool` CLI integration, ref-range compare, folder compare. The
  commit picker browses one branch's first-parent history; comparing two arbitrary commits
  is not in scope.
