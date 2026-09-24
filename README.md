# DiffViewer

**The git diff viewer a Mac deserves.** Native, fast, and built for one job: reading a
diff.

DiffViewer is a macOS 26 app that shows a repository's changes side by side, with
structural token highlights from [difftastic](https://difftastic.wilfred.me.uk) and full
syntax colouring from tree-sitter. It is a viewer first. It never edits a file's text
or resolves conflicts, and its git actions are only the ones a reader needs right after
reading a diff: stage, discard, commit, switch branch, push. It aims to be the best diff
viewer on the platform.

DiffViewer is fully vibe coded: every line was written by AI coding agents, directed and
reviewed by a human.

## The goal

Build a diff viewer with Apple Design Award–level craft: an app that feels like Apple
could have shipped it, that is instant on a 20,000-line file, and that disappears so the
code is all you see.

The bar is set by Kaleidoscope, JuxtaCode, Sublime Merge and GitHub's pull request reviewing
experience. We want this to be speedy when reviewing large diffs.

## What it does today

**Reading**
- **All changes**, selected by default: every changed file's hunks stacked in one
  side-by-side scroll, each under a header with its kind badge, name, `+12 −4`, and
  language. Files stream in as their diffs finish ("Loading 7 of 12…"). Line numbers
  restart per file, and text selection and ⌘C span the whole changeset.
- **Structural highlights** from a bundled `difft`, and **full tree-sitter colouring** of
  both sides (Swift, Python, JS, TS/TSX, JSON, Go, Rust, C, C++, HTML, CSS, Bash, Ruby,
  YAML, TOML, Java, Kotlin, PHP, Markdown).
- **Collapse unchanged lines** (⇧⌘U, on by default): changed hunks plus 5 lines of
  context. Each hidden run is one separator that expands 20 lines at a time; ⌥-click
  reveals the whole file.
- **Hide whitespace** (⇧⌘W), meaning exactly git's `-w`.
- **Find** (⌘F) with ⌘G / ⇧⌘G to step, and a side scope (⌥⌘← / ⌥⌘→) that shows the
  match count on each side.
- **Change navigation** with ⌘↓ / ⌘↑, across files in All changes, plus a change
  overview strip.
- **Image diffs** side by side, and an SVG preview.
- Font size (⌘+ / ⌘- / ⌘0), light and dark mode.

**Around the diff**
- **Sidebar** of unstaged and staged files, refreshed live as the repository changes,
  with per-file `+12 −4` counts from `git diff --numstat`.
- **Context menu** on one or many files (⌘-click, ⇧-click, ⌘A): stage, unstage, discard,
  restore a delete, or move an untracked file to the Trash, plus Reveal in Finder, Open in
  Default Editor, and Copy Path. A selection runs as one git command with one
  confirmation; destructive actions ask first.
- **Commit picker** (⌘K): see what any commit on the branch changed against its first
  parent. A commit's diffs never change, so nothing reloads until HEAD moves.
- **Branch picker** (⌘B) in the title bar: switch local branches. A row offers Push or
  Pull when the branch is ahead of or behind its upstream, and Publish when it tracks
  nothing.
- **Commit** (⌘Return): records the index with your message, prefilled the way
  `git commit` would. ⌘G drafts a message with Apple's on-device model. Hooks run with
  your login shell's PATH, so a pre-commit hook finds Homebrew tools even from a Finder
  launch.
- **One window per repository**, as native tabs. ⌘T opens a tab that adopts the next
  repository you open; the open set is restored on the next launch.

## Where it stands

| Capability | Kaleidoscope | Sublime Merge | JuxtaCode | DiffViewer |
|---|---|---|---|---|
| Structural (AST-aware) highlights | no | no | no | **yes** |
| All files in one scroll | no | yes | no | **yes** |
| Per-file +/- in sidebar | no | no | no | **yes** |
| Find in diff | yes | no | no | **yes** |
| Collapse unchanged | yes | yes | no | **yes** |
| Stage / unstage from file list | no | yes | no | **yes** (whole file) |
| Image diff | no | yes | no | **yes** (no onion-skin yet) |
| Jump to line | yes | no | no | not yet |
| Wrap long lines | yes | yes | no | not yet |
| Sidebar filter / folder outline | yes | partial | yes | not yet |
| Rename / move detection | yes | yes | yes | not yet |

Comparison as of September 2026 (Kaleidoscope 7.0, Sublime Merge build 2125, JuxtaCode
1.4).

## Roadmap

`TODO.md` holds the full list with designs and competitor research. In short:

**Requested**
- In-progress operation in the branch name (`main (rebasing)`).
- Keyboard staging: Stage ⌘S, Unstage ⇧⌘S, Discard ⌘⌫, with the selection walking to the
  next file, so the whole flow is read, ⌘S, ⌘Return, ⌘G, ⌘Return.
- A Find button in the toolbar.
- Copy a hash or branch name from the pickers; copy a failed hook's output in one click.

**Next**
- A "Change 3 of 41" strip with previous/next controls.
- Jump to line (⌘L), a pane context menu, and the remaining selection conventions.
- Rename and move detection, shown as `old → new`.
- Sidebar filtering and a folder outline.
- Wrap long lines, with per-row heights that keep both panes aligned.
- A change indicator on tabs whose repository changed in the background.
- Commit picker search; amend and other commit follow-ups; timeouts on remote git calls.
- Faster highlighting for very large files.

**Later**
- Onion-skin and swipe image diffs; image previews inside All changes.
- Twin Focus (hover a token to highlight its counterpart) and connector lines between
  panes.
- Themes, a font picker, show invisibles, and a per-file language override.
- Moved-code detection, which none of the competitors offer.
- A CLI and `git difftool` integration.

## Not doing

- **Inline or unified layout.** Side by side only.
- **Ref-range compare, folder compare, blame, file history, merge conflict resolution.**
  These are git-client features, not viewer features. Browsing a branch's commits is in
  scope and has shipped.
- **Hunk-level staging or discarding.** Nothing finer than a file.
- **Editable diffs, regex text filters, a command palette.** A viewer shows what git sees;
  menus with shortcuts are enough.

## Build

Requires Xcode 26 and [xcodegen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
make run      # generate the project, fetch difft, build, launch
make test     # run the unit tests
make open     # open the generated Xcode project
make lint     # SwiftLint, same rules as CI
make format   # rewrite sources with swift-format; `make format-check` only reports
make hooks    # install the git hooks; `make hooks-all` runs them over every file
```

After cloning, install the development tools and the git hooks once:

```bash
brew install pre-commit swiftlint
make hooks
```

- The Xcode project is generated from `project.yml` and is git-ignored; adding a source
  file needs no project edit.
- `make` points `DEVELOPER_DIR` at `/Applications/Xcode.app`, so it works even when
  `xcode-select` is set to the Command Line Tools.
- `difft` is copied from Homebrew if installed, otherwise downloaded from the difftastic
  release, into `DiffViewer/Resources/bin/` (git-ignored) and bundled into
  `Contents/MacOS`.
- Grammar versions in `project.yml` are pinned: newer python, javascript, css, and yaml
  releases break scanner compilation under Xcode.
- CI runs SwiftLint and swift-format on Linux and `xcodebuild test` on a macOS 26 runner.
  The pre-commit hook runs the same checks; when swift-format rewrites a file, re-stage and
  commit again.

## Architecture

| Layer | Directory | Contents |
|-------|-----------|----------|
| App shell | `DiffViewer/App` | `Preferences`, `WindowState` (one repository per window), `WindowCoordinator` (routing, key and visibility tracking, prefetch, session persistence), `DiffLoader`, `ChangesetAssembler`, `FileAction`, commit message generation |
| Git | `DiffViewer/Git` | CLI wrapper over `/usr/bin/git`, status / numstat / log parsers, FSEvents watcher |
| Diff engine | `DiffViewer/Diff` | Myers line diff, difft JSON runner, `DiffAligner` (rows and whitespace mode), `DiffEngine`, changeset builder and projection |
| Highlighting | `DiffViewer/Highlighting` | Grammar registry, tree-sitter highlighter, `TokenStyle` theme |
| Views | `DiffViewer/Views` | SwiftUI chrome, the AppKit `DiffPaneView` renderer, `SideBySideContainerView`, overview strip |
| Tests | `DiffViewerTests` | Swift Testing suites for every non-UI layer |

**Data flow.** Open request → `WindowCoordinator` → `WindowState` → file list. A selection
goes to `DiffLoader` → `DiffEngine` (git sources) → difft and `LineDiff` → `DiffAligner` →
`DiffDocument` rows → two `DiffPaneView`s. Highlighting arrives later as `DocumentStyles`.
With All changes selected, a `ChangesetAssembler` diffs and highlights files in sidebar
order on three workers and publishes a growing `ChangesetDocument` that the panes append
in place. Only visible windows load diffs, and only the key window is prefetched.

**Testing.** Tests cover logic: alignment, diff correctness, parsing, index math. UI is
verified by screenshots: `scripts/screenshot.sh` captures the real window and
`scripts/snapshot.sh` renders from inside the app. Debug builds accept `DIFFVIEWER_*`
environment variables for scripted screenshots, tabs, restoration, and latency checks (see
`DebugLaunchOptions`). Scripted runs use their own defaults suite and never touch a
running DiffViewer.

## Known limitations

- Highlighting a 20k-line Swift file takes about 2.8 s per side in Debug builds. Both
  sides run in parallel and never block scrolling.
- In All changes, separators cannot be expanded in place and file headers do not stick
  while scrolling. The changeset is rebuilt whenever the list changes.
- Highlighting that has started runs to completion even if its window closes, and
  foreground difft runs are not bounded.
- Repository windows always prefer tabs, whatever the system tab preference says.
- Separator controls have no keyboard shortcut yet.

## Credits

Structural diffs by [difftastic](https://difftastic.wilfred.me.uk). The title bar's branch
and commit icons are [Octicons](https://primer.style/octicons) by GitHub, MIT licensed
(`DiffViewer/Assets.xcassets/Octicons-LICENSE`).
