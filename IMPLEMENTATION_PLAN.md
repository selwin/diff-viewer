# DiffViewer — Implementation Plan

Native macOS 26 app (Swift 6 / SwiftUI + AppKit) for viewing git working-tree diffs
side by side. Syntax-aware diffing via a bundled `difft` (difftastic) binary, full
syntax highlighting via tree-sitter, GitHub-style "hide whitespace" toggle.
Personal, unsandboxed, ad-hoc signed build. UI inspired by Kaleidoscope / JuxtaCode.

Decisions (2026-09-12):
- Inputs: git working tree only (unstaged incl. untracked, and staged), auto-refresh.
- Highlighting: full tree-sitter highlighting of both panes (SwiftTreeSitter + bundled grammars).
- Distribution: personal, run locally, unsandboxed, ad-hoc signed.
- Min macOS: 26.0. Project generated with xcodegen (`project.yml`), built via `make`.
- Diff engine: bundled difft `--display json` for syntax-aware token changes + own
  line-level Myers diff for full side-by-side row alignment. Whitespace toggle is
  applied at the line-alignment layer (difft already ignores whitespace syntactically).

## Stage 1: Project skeleton + git status
**Goal**: App launches, opens a repo (⌘O, recents, restores last), lists changed files
in a sidebar split into Unstaged / Staged.
**Success Criteria**: `make build` succeeds; selecting a file shows its path in the detail area.
**Tests**: GitStatusParser parses porcelain v2 -z output (modified, added, renamed, untracked, both-areas).
**Status**: Complete

## Stage 2: Diff engine
**Goal**: `DiffBuilder` turns (old text, new text, language, whitespace mode) into an
array of aligned `DiffRow`s with per-side line numbers, kind (equal/modified/added/deleted/pad),
and intra-line changed ranges from difft.
**Success Criteria**: Runs off main thread; 20k-line files build in < 500 ms.
**Tests**: Myers line diff (insert/delete/replace/equal), difft JSON decoding, row alignment
with pairing hints, whitespace-only change hidden vs shown.
**Status**: Complete

## Stage 3: Side-by-side renderer
**Goal**: AppKit `DiffPaneView` (custom NSView in NSScrollView, CoreText row drawing,
fixed row height, only visible rows drawn), two panes with synchronized vertical scroll,
line-number gutters, change background colors, intra-line highlight, pad rows hatched.
**Success Criteria**: Smooth 120 Hz scrolling on a 20k-row diff; Light/Dark mode aware.
**Tests**: Row layout math (row ↔ y), visible-range computation.
**Status**: Complete

## Stage 4: Syntax highlighting
**Goal**: Tree-sitter highlighting for both sides using bundled grammars
(Swift, Python, JS, TS/TSX, JSON, Go, Rust, C, C++, HTML, CSS, Bash, Ruby, YAML, TOML, Java, Kotlin, PHP, Markdown).
Capture names mapped to a theme with light/dark variants.
**Success Criteria**: Highlighting is computed in the background and never blocks scrolling.
**Tests**: Language detection from path; capture → style mapping.
**Status**: Complete

## Stage 5: Polish
**Goal**: Next/previous change (⌘↓ / ⌘↑ + toolbar), change overview strip beside the scroller,
FSEvents repo watcher with debounce, whitespace toggle in toolbar, font size setting,
binary/empty/deleted-file states, rename display, drag a folder onto the window to open it.
**Success Criteria**: Editing a file in the repo updates the sidebar and open diff within ~1 s.
**Tests**: Change navigation index math; watcher debounce.
**Status**: Complete
