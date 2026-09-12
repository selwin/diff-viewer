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
```

`make` points `DEVELOPER_DIR` at `/Applications/Xcode.app` so it works even when
`xcode-select` is set to the Command Line Tools.

The `difft` binary is copied from Homebrew if installed, otherwise downloaded from the
difftastic GitHub release, into `DiffViewer/Resources/bin/` (git-ignored).

## Use

Open a repository with ⌘O, drag a folder onto the window, or `open -a DiffViewer <repo>`.
The last repository reopens on launch.

## Layout

| Directory | Contents |
|-----------|----------|
| `DiffViewer/App` | App entry, `AppState`, `DiffLoader` |
| `DiffViewer/Git` | `git` CLI wrapper, status parser, FSEvents watcher |
| `DiffViewer/Diff` | Myers line diff, difft JSON runner, row aligner, engine |
| `DiffViewer/Highlighting` | tree-sitter grammar registry, highlighter, token theme |
| `DiffViewer/Views` | SwiftUI shell plus the AppKit pane renderer and overview strip |
| `DiffViewerTests` | Swift Testing suites for the non-UI layers |

Debug builds accept `DIFFVIEWER_SELECT`, `DIFFVIEWER_NEXT`, `DIFFVIEWER_FOLD`,
`DIFFVIEWER_APPEARANCE`, and `DIFFVIEWER_SNAPSHOT` environment variables for scripted
screenshots (see `scripts/`).

## Known limitations / next steps

- Highlighting a 20k-line Swift file takes ~2.8 s per side in Debug builds (tree-sitter
  query predicates are regex-heavy); both sides run in parallel and never block scrolling.
  Possible follow-ups: cache compiled predicates, or highlight visible rows first.
- Separator controls are exposed to VoiceOver as buttons but have no keyboard shortcut yet.
- Not yet built: `git difftool` CLI integration, commit/ref-range browsing, folder compare.
