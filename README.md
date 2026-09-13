# DiffViewer

A native macOS 26 app for viewing git working-tree diffs side by side.

- **Syntax-aware diffs** via a bundled [difftastic](https://difftastic.wilfred.me.uk) (`difft`)
  binary: token-level highlights that understand the language's structure.
- **Hide whitespace** toggle (⇧⌘W), like GitHub's diff viewer.
- **Collapse unchanged lines** (⇧⌘U, on by default): only changed hunks plus 5 lines of
  context are shown; each hidden run is one separator with expand-up / expand-down
  controls (20 lines at a time), click the text to reveal the run, ⌥-click to reveal the
  whole file. The hidden `collapseContextLines` default overrides the context size.
- **Full syntax highlighting** of both sides with tree-sitter (Swift, Python, JS, TS/TSX,
  JSON, Go, Rust, C, C++, HTML, CSS, Bash, Ruby, YAML, TOML, Java, Kotlin, PHP, Markdown).
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

Committing then runs, over the staged files only, text hygiene (trailing whitespace, final
newline, line endings, YAML) followed by swift-format and SwiftLint, with the same
configuration as the Format and Lint workflows. swift-format rewrites the file and stops the
commit, so re-stage and commit again. The tests are left to CI. CI pins SwiftLint 0.65.1 and
Swift 6.3 (Xcode 26.6), and the hooks warn when the local versions differ.

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

## Layout

| Directory | Contents |
|-----------|----------|
| `DiffViewer/App` | App entry, `Preferences` (app-wide settings), `WindowState` (one repository per window), `WindowCoordinator` (routing, key and visibility tracking, session persistence), `DiffLoader` |
| `DiffViewer/Git` | `git` CLI wrapper, status parser, FSEvents watcher |
| `DiffViewer/Diff` | Myers line diff, difft JSON runner, row aligner, engine |
| `DiffViewer/Highlighting` | tree-sitter grammar registry, highlighter, token theme |
| `DiffViewer/Views` | SwiftUI shell plus the AppKit pane renderer and overview strip |
| `DiffViewerTests` | Swift Testing suites for the non-UI layers |

Debug builds accept `DIFFVIEWER_SELECT`, `DIFFVIEWER_NEXT`, `DIFFVIEWER_FOLD`,
`DIFFVIEWER_APPEARANCE`, and `DIFFVIEWER_SNAPSHOT` environment variables for scripted
screenshots, and `DIFFVIEWER_OPEN`, `DIFFVIEWER_TAB_STEPS`, and `DIFFVIEWER_DUMP_WINDOWS`
for scripted checks of tabs, restoration, and diff latency (see `scripts/` and
`DebugLaunchOptions`).

## Known limitations / next steps

- Highlighting a 20k-line Swift file takes ~2.8 s per side in Debug builds (tree-sitter
  query predicates are regex-heavy); both sides run in parallel and never block scrolling.
  Possible follow-ups: cache compiled predicates, or highlight visible rows first.
- Separator controls are exposed to VoiceOver as buttons but have no keyboard shortcut yet.
- Tabs are the policy, not the system preference: repository windows always prefer
  tabbing, whatever System Settings > Desktop & Dock > "Prefer tabs when opening
  documents" says. Honouring the system tab preference is a follow-up.
- Highlighting runs in detached tasks the loader cannot stop: a hidden or closed window
  starts no new highlight, but one already computing runs to completion. Bounded
  highlighting concurrency with cooperative cancellation is a follow-up.
- Foreground difft runs are unbounded: several visible windows reloading at once, or
  rapid selection changes, can overlap difft processes (background prefetch runs share
  three slots). A foreground difft scheduler is a follow-up.
- Not yet built: `git difftool` CLI integration, commit/ref-range browsing, folder compare.
