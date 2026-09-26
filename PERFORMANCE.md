# Performance

Where the time goes when DiffViewer opens and scrolls one file, and what to change
next. Written September 2026 against difftastic 0.70.0. Re-run the benchmark after any
change listed here and update the numbers.

## Summary

- **Opening a file waits on difft.** The document and its styles are published together
  (`DiffLoader.swift`), after difft and then both sides' highlighting, one after the
  other. difft is 81–86% of that time on the benchmark files.
- **About 115 ms of every Swift difft run is fixed**: difft compiles tree-sitter-swift's
  highlight query in each process. The rest grows with the size and shape of the change,
  from about 0.35 s for a few one-line edits in a 5,000-line file to over 2 s for ten
  multi-line hunks.
- **Highlighting is not worth replacing.** Inside `Highlighter`, `LinePainter` (paint,
  runs, sort) is 4% of the time. The avoidable cost is capture-name mapping (25%).
- **Scrolling is fine with "collapse unchanged" on**, the default. Expanded, a
  5,000-line file never gets a warm shaped-line cache: each pane passes the 4,000-entry
  cap, the whole cache is cleared, and every scroll pass reshapes every line.

## How to measure

### Instruments

`PerfProbe` (`DiffViewer/App/PerfProbe.swift`) wraps each stage in an os_signpost
interval, subsystem `com.selwin.DiffViewer`, category Points of Interest:

| Area | Stages |
|---|---|
| Load (`DiffEngine.build`) | `engine.decode`, `engine.difft`, `engine.split`, `engine.align`, `engine.highlightOld`, `engine.highlightNew` |
| Highlighting | `highlight.total`, `highlight.config`, `highlight.join`, `highlight.parse`, `highlight.sort`, `highlight.paint`, `highlight.runs` |
| Pane | `pane.install`, `pane.draw`, `pane.shape` |

The per-match split of the highlight query (`highlight.query.*`) and the per-row split
of drawing (`pane.row.*`, `pane.shape.*`) are recorded only while a recorder runs,
because they are too fine-grained for signposts. With no recorder, a probe costs one
flag read plus a signpost, which is a no-op unless Instruments is recording.

### Benchmark

`DiffViewerTests/RenderPerfBenchmarks.swift` builds its input from whole Swift files of
the app's own sources, about 2,000 and 5,000 lines, so both sides are valid Swift. The
new side has 10 evenly spaced hunks, each at a `let` statement inside a body: that line
gets a trailing comment, 4 statements are inserted after it, and up to 2 nearby blank or
comment lines are deleted. It then:

1. runs difft alone, then `DiffEngine.build` end to end with fresh caches, recording
   every stage;
2. installs the document into a `SideBySideContainerView` in an offscreen window,
   applies the styles, and scrolls from top to bottom three times: page jumps with a
   cold cache, page jumps again, and 40-point trackpad steps that draw only the exposed
   strip. Each frame draws both panes through `cacheDisplay(in:to:)`.

It is skipped unless `DIFFVIEWER_BENCHMARKS=1`, because timings from a Debug build or a
busy test run mean little. To run it locally in Release:

```sh
TEST_RUNNER_DIFFVIEWER_BENCHMARKS=1 xcodebuild test \
  -project DiffViewer.xcodeproj -scheme DiffViewer -destination 'platform=macOS' \
  -derivedDataPath build -configuration Release ENABLE_TESTABILITY=YES \
  -only-testing:DiffViewerTests/RenderPerfBenchmarks
```

The report is printed and written to `/tmp/diffviewer-benchmark.md`
(`TEST_RUNNER_DIFFVIEWER_BENCHMARK_REPORT` overrides the path). In CI, the Benchmark
workflow (`.github/workflows/benchmark.yml`) runs it on `macos-26` on demand and puts
the report in the run summary.

### Caveats

- The CI runner is an Apple M1 virtual machine with 3 cores and 7 GB. Expect lower
  absolute times on a real Mac; compare stages within one run. Two runs on different
  runners differed by up to 2× in per-row drawing cost.
- The panes draw into an offscreen bitmap, not an on-screen layer-backed view, so frame
  times include CPU rasterisation but not compositing.
- The input is Swift only. Swift's highlight query is unusually expensive to compile, so
  other languages will look better on the fixed costs.
- The report names the language difft reported. `Text (N Swift parse errors …)` means
  difft gave up on the syntax and ran a text diff, which is much faster and not
  representative.

## Baseline

From the difft 0.70.0 job of
[run 36227557285](https://github.com/selwin/diff-viewer/actions/runs/36227557285).
Medians of 5 runs.

### Opening a file

| Stage | 2,000 lines | 5,000 lines |
|---|---:|---:|
| **`DiffEngine.build` total** | **979 ms** | **1,396 ms** |
| difft (through `DifftCache`) | 842 ms | 1,136 ms |
| Highlight, old side then new side | 92 ms | 249 ms |
| Split lines + align | 4 ms | 11 ms |
| Decode UTF-8 | 0.1 ms | 0.2 ms |

The first file of a session also pays about 150 ms to load the Swift grammar and
compile its highlight queries.

### Highlighting

Both sides together, 5,000 lines:

| Stage | ms | Share |
|---|---:|---:|
| Query matching (`cursor.nextMatch`, tree-sitter) | 84 | 34% |
| Parse (tree-sitter) | 79 | 32% |
| Capture name → `TokenStyle`, per capture | 62 | 25% |
| Query predicates (`match.allowed(in:)`) | 9 | 3% |
| Paint + runs + sort (`LinePainter`) | 9 | 4% |

72,309 matches and 68,355 painted captures.

### Scrolling

With **collapse unchanged on**, the files show about 250–270 rows. A cold page jump
takes about 8 ms (median), a warm trackpad frame 0.3–0.4 ms.

With **the whole file expanded**:

| Pass | 2,000 lines | 5,000 lines |
|---|---:|---:|
| Page jumps, cold (median / p95 / max) | 7.0 / 10.6 / 16.1 ms | 7.7 / 12.1 / 42.4 ms |
| Page jumps, second pass (median / p95 / max) | 3.6 / 4.2 / 4.3 ms | 6.7 / 11.8 / 22.9 ms |
| Trackpad 40 pt, second pass (median / p95 / max) | 0.8 / 1.9 / 5.2 ms | 2.5 / 4.4 / 13.5 ms |
| Lines reshaped on the second pass | 0 | 9,879 |
| Whole-cache evictions per pass | 0 | 2 |

Cost per row on the cold pass, 5,000 lines:

| Stage | µs per row or line |
|---|---:|
| Draw the text (`CTLineDraw`) | 13.5 |
| Shape a line (cache miss) | 13.3 |
| … build the attributed string and apply styles | 4.9 |
| … `CTLineCreateWithAttributedString` | 7.3 |
| Gutter (fill + cached line-number `CTLine`) | 8.7 |
| Token highlights | 0.5 |

When styles arrive after the document, `DiffPaneView.styles` clears the whole
shaped-line cache and the visible rows are reshaped: 5–10 ms, up to one frame at 120 Hz.

### difft

Measured on Linux x86_64 (4 cores) with the Linux build of 0.70.0 and the app's flags
and environment (`--display json --context 0`, `DFT_UNSTABLE`, `DFT_BYTE_LIMIT`,
`DFT_GRAPH_LIMIT`, `DFT_PARSE_ERROR_LIMIT`):

| Change | Time |
|---|---:|
| One-line edit, real files of 150–1,660 lines | 120–190 ms |
| ~5,000-line input, 1 or 3 one-line edits | 0.35 s |
| ~5,000-line input, 10 one-line edits | 0.57 s |
| ~2,000-line benchmark input (10 hunks) | 1.35 s |
| ~5,000-line benchmark input (10 hunks) | 2.2 s |

`difft --version` takes 3 ms, so process start is not the cost. For a one-line Swift
change, callgrind puts 99.7% of the instructions in `tree_sitter::Query::new`, called
from `tree_sitter_parser::from_language`, almost all of it in the query analysis
(`ts_query__analyze_patterns`): difft compiles tree-sitter-swift's highlight query on
every run. The app pays the same cost once per session.

Callgrind on the ~2,000-line benchmark input (instructions, not wall time):

| Stage | Share |
|---|---:|
| Structural search (`mark_syntax`: `compute_neighbours`, graph allocation) | 39% |
| Compile the Swift highlight query | 37% |
| Parse both sides and convert to difft's syntax tree | ~15% |
| Change positions, slider fixing | ~12% |
| Levenshtein between comments (inside the search) | 8% |
| Run the highlight query (`tree_highlights`) | 4% |

The search is allocation- and memory-heavy, so its share of wall time is larger than its
share of instructions. difft uses the highlight query's comment captures to classify
atoms as comments, which changes how comments are diffed, so the query cannot simply be
skipped.

## Opportunities

In order of value for effort.

1. **Do not make the first frame wait for difft.** `DiffAligner` already works without
   hints (plain line diff, prefix/suffix highlights). Publish the document and its syntax
   colours as soon as highlighting finishes, then apply difft's hints when they arrive.
   Hints can change which changed lines sit side by side, so rows can move after the
   first frame; the existing anchor logic keeps the reader's place, but test for visible
   jumps. At 5,000 lines on the CI runner, first content would go from about 1.4 s to
   about 0.26 s.
2. **Highlight while difft runs, both sides in parallel.** Highlighting needs only the
   split lines. Today `DiffEngine.build` runs difft, then highlights old, then new. Keep
   the sequential order for All changes, where it limits parser concurrency on purpose.
   Together with item 1, first content becomes one side's highlighting time.
3. **Replace the shaped-line cache's clear-everything eviction** (`DiffPaneView`,
   4,000 entries per pane) with an LRU or a limit sized to the document, and invalidate
   only the lines whose runs changed when styles arrive. Trackpad frames on a 5,000-line
   expanded file are 3× slower than at 2,000 lines for this reason alone.
4. **Map capture index to `TokenStyle` once per query** instead of splitting the capture
   name for every capture: about a quarter of highlighting time.
5. **Load grammars at launch in the background** to hide the ~150 ms first-file cost.
6. **In-process token diff as the fast baseline.** For each deleted/added line pair,
   diff the tree-sitter leaf tokens the highlighter already produces (what diffsitter
   does, without a second parse or process). Show it at once, and use it where difft
   gives up, times out or does not know the language; difft's result refines it when it
   arrives. It cannot see changes that span lines (re-wrapped arguments, re-indented
   blocks), which is why difft stays as the refinement. Cost unmeasured.
7. **Cut difft's fixed cost.** The ~115 ms per Swift run is tree-sitter's query analysis
   of tree-sitter-swift's highlight query; a fix upstream (in tree-sitter or the query)
   helps difft and the app's cold start. Embedding difftastic would compile the query
   once per session instead of per file, but difftastic is a binary-only crate (MIT), so
   it means maintaining a fork and adding Rust to the build.
8. **Run difft on less text**: only the changed regions, each widened to its enclosing
   declaration using the tree the highlighter already has. It shrinks parsing and the
   search, not the fixed cost, and needs line mapping and fragments that parse. Not
   worth it before 1–2.

`DiffPrefetcher` already warms difft for up to 100 changed files, 3 at a time, so the
cold path is hit mostly for a file that has just changed and while browsing commits.

### Not worth doing

- Optimising `LinePainter`, sorting or joining: about 4% of highlighting combined.
- Ranged highlight queries for collapsed files: once highlighting overlaps difft, its
  time is hidden.
- Tuning `DFT_GRAPH_LIMIT`: lowering it from 6,000,000 to 3,000,000 or 1,000,000 saves
  15–30% on the slow inputs and still reports Swift.
- Replacing difftastic with another structural differ. diffsitter (Myers over tree-sitter
  leaf tokens) is less precise and calls itself "nowhere close to production ready";
  GumTree is a JVM research tool; SemanticDiff is closed source; Mergiraf merges rather
  than diffs. None is both faster and as good structurally.
