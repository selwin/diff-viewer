# Performance

Written September 2026. Records where the time goes when DiffViewer opens and scrolls
one file, what was measured, and what to change first, so the numbers do not have to be
re-derived. Re-run the benchmark after any change listed here and update the tables.

## Summary

- **Opening a file is dominated by difft, not by tree-sitter.** Everything is published
  together, so difft plus highlighting both sides, one after the other, is the time to
  first content.
- **The pinned difft 0.63.0 cannot parse much of this codebase.** 84 of the repository's
  210 Swift files exceed its parse-error limit, and difft silently falls back to a text
  diff for them: no structural highlights. 0.70.0 falls back on 1 of 210.
- **0.70.0 is faster for ordinary edits** (120–200 ms against 330–440 ms for a one-line
  change in a real file) but a structural diff of many multi-line hunks can take
  seconds. About 115 ms of every Swift run is fixed: difft compiles tree-sitter-swift's
  highlight query in each process.
- **Highlighting is not worth replacing.** Inside `Highlighter`, `LinePainter` (paint,
  runs, sort) is 3% of the time. The avoidable cost is capture-name mapping (24%).
- **Scrolling is fine with "collapse unchanged" on**, the default. Expanded, a
  5,000-line file never gets a warm shaped-line cache: each pane passes the 4,000-entry
  cap and the whole cache is cleared, so every scroll pass reshapes every line.

## How to measure

### Instruments

`PerfProbe` (`DiffViewer/App/PerfProbe.swift`) wraps each stage in an os_signpost
interval, subsystem `com.selwin.DiffViewer`, category Points of Interest. Record a
Time Profiler or os_signpost trace and the stages appear on the timeline:

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

`DiffViewerTests/RenderPerfBenchmarks.swift` builds its input from the app's own Swift
sources, cut to 2,000 and 5,000 lines, with 10 evenly spaced hunks on the new side
(2 lines edited, 4 inserted, 2 deleted each). It then:

1. runs difft alone, then `DiffEngine.build` end to end with fresh caches, recording
   every stage;
2. installs the document into a `SideBySideContainerView` in an offscreen window,
   applies the styles, and scrolls from top to bottom three times: page jumps with a
   cold cache, page jumps again, and 40-point trackpad steps that draw only the exposed
   strip. Each frame draws both panes through `cacheDisplay(in:to:)`.

It is skipped unless `DIFFVIEWER_BENCHMARKS=1`, because timings from a Debug build or
a busy test run mean little. To run it locally in Release:

```sh
TEST_RUNNER_DIFFVIEWER_BENCHMARKS=1 xcodebuild test \
  -project DiffViewer.xcodeproj -scheme DiffViewer -destination 'platform=macOS' \
  -derivedDataPath build -configuration Release ENABLE_TESTABILITY=YES \
  -only-testing:DiffViewerTests/RenderPerfBenchmarks
```

The report is printed and written to `/tmp/diffviewer-benchmark.md`
(`TEST_RUNNER_DIFFVIEWER_BENCHMARK_REPORT` overrides the path). In CI, the Benchmark
workflow (`.github/workflows/benchmark.yml`) runs it on `macos-26` once per difft
version and puts the report in the run summary.

### Caveats

- The CI numbers below come from a GitHub `macos-26` runner: an Apple M1 virtual
  machine with 3 cores and 7 GB. Expect lower absolute times on a real Mac; the
  split between stages is what matters.
- The panes draw into an offscreen bitmap, not an on-screen layer-backed view, so
  frame times include CPU rasterisation but not compositing.
- The input is Swift only. Swift's highlight query is unusually expensive to compile
  (see [difft](#difft)), so other languages will look better.
- The first benchmark run cut files mid-way, which broke the syntax: difft fell back to
  a text diff and its timings in the tables below measure that fallback. The input is
  now whole files with valid edits, and the report names the language difft reported
  (`Text (...)` means it fell back). The highlighting and scrolling numbers do not
  depend on difft.

## Results

### Opening a file

For a single file, the document and its styles are published together
(`DiffLoader.swift`), so nothing is shown until every stage below has finished, one
after another. Medians of 5 runs, difft 0.63.0 (text fallback, see Caveats).

| Stage | 2,000 lines | 5,000 lines |
|---|---:|---:|
| **`DiffEngine.build` total** | **837 ms** | **1,049 ms** |
| difft | 666 ms (80%) | 716 ms (68%) |
| Highlight, old side then new side | 152 ms (18%) | 337 ms (32%) |
| Split lines + align | 7 ms | 14 ms |
| Decode UTF-8 | 0.1 ms | 0.2 ms |

The first file of a session also pays 211 ms to load the Swift grammar and compile its
highlight queries.

### Highlighting

Both sides together, 5,000 lines (the 2,000-line file splits the same way):

| Stage | ms | Share |
|---|---:|---:|
| Query matching (`cursor.nextMatch`, tree-sitter) | 117 | 34% |
| Parse (tree-sitter) | 102 | 30% |
| Capture name → `TokenStyle`, per capture | 83 | 24% |
| Query predicates (`match.allowed(in:)`) | 14 | 4% |
| Paint + runs + sort (`LinePainter`) | 11 | 3% |
| Join lines | 0.5 | 0% |

72,642 matches and 68,633 painted captures. With the probes off, the old side takes
the same time as with them on (185 ms against 167 ms, within run-to-run noise).

### Scrolling

With **collapse unchanged on** (the default), both files show about 175 rows. A cold
page jump takes 8–13 ms (median), a warm trackpad frame 0.4–0.5 ms. Nothing to fix.

With **the whole file expanded**:

| Pass | 2,000 lines | 5,000 lines |
|---|---:|---:|
| Page jumps, cold (median / p95) | 13.5 / 22.4 ms | 11.6 / 20.6 ms |
| Page jumps, second pass (median / p95 / max) | 4.9 / 9.6 / 12.8 ms | 11.7 / 19.3 / 46.1 ms |
| Trackpad 40 pt, second pass (median / p95) | 1.4 / 4.0 ms | 3.7 / 7.4 ms |
| Lines reshaped on the second pass | 0 | 9,928 |
| Whole-cache evictions per pass | 0 | 2 |

Cost per row on the cold pass:

| Stage | µs per row or line |
|---|---:|
| Draw the text (`CTLineDraw`) | 20–27 |
| Shape a line (cache miss) | 19–23 |
| … build the attributed string and apply styles | 7.5–9.4 |
| … `CTLineCreateWithAttributedString` | 10–12 |
| Gutter (fill + cached line-number `CTLine`) | 13–15 |
| Token highlights | 0.8–1.5 |

When styles arrive after the document, `DiffPaneView.styles` clears the whole shaped-line
cache and the visible rows are reshaped: 19 ms for the 2,000-line file expanded, about
one dropped frame.

## difft

Measured locally on Linux x86_64 (4 cores) with the app's flags and environment
(`--display json --context 0`, `DFT_UNSTABLE`, `DFT_BYTE_LIMIT`, `DFT_GRAPH_LIMIT`,
`DFT_PARSE_ERROR_LIMIT`). Medians of 3–5 runs.

### 0.63.0 falls back to text on 40% of this repository

Each Swift file in `DiffViewer` and `DiffViewerTests`, diffed against itself plus one
appended comment line:

| difft | Files | Parsed as Swift | Fell back to `Text (N Swift parse errors …)` |
|---|---:|---:|---:|
| 0.63.0 (pinned in `scripts/fetch-difft.sh`) | 210 | 126 | **84** |
| 0.70.0 (latest release, August 2026) | 210 | 209 | 1 (`WindowStateRemoteTests.swift`) |

`DFT_PARSE_ERROR_LIMIT` is 5. Among the files 0.63.0 gives up on are `WindowState.swift`,
`DiffLoader.swift` and `SyncPolicy.swift`. The app shows no sign of the fallback: the
hints are line-level, so the view still looks like a diff. Newer releases update the
Swift parser (0.68 and 0.69 release notes).

### Time

One-line edit in the middle of a real file:

| File | 0.63.0 | 0.70.0 |
|---|---:|---:|
| `LineDiff.swift` (147 lines) | 360 ms | 120 ms |
| `DiffPaneView.swift` (580 lines) | 400 ms | 150 ms |
| `WindowCoordinator.swift` (582 lines) | 380 ms | 130 ms |
| `WindowState.swift` (1,659 lines) | 390 ms, text fallback | 190 ms |

The benchmark's valid-Swift inputs with 0.70.0, by kind of change:

| Change on the ~5,000-line input | 0.70.0 |
|---|---:|
| 1 one-line edit | 0.35 s |
| 3 one-line edits | 0.35 s |
| 10 one-line edits | 0.57 s |
| 10 hunks (1 line edited, 4 inserted, 2 deleted) | 2.2 s |
| Same, ~2,000-line input | 1.35 s |

0.63.0 takes 0.47 s and 0.57 s on the last two inputs, but only because it falls back to
text on them. Lowering `DFT_GRAPH_LIMIT` from the app's 6,000,000 to the default
3,000,000 or to 1,000,000 saves 15–30% on the slow inputs and still reports Swift, so
it is not a real lever.

### Where the time goes

`difft --version` takes 3 ms, so process start is not the cost. A one-line change takes
6–45 ms in other languages (Python 13, Go 9, Rust 29, TypeScript 27, Kotlin 45, JSON 6)
and 115 ms in Swift with 0.70.0 (345 ms with 0.63.0). Callgrind on the one-line Swift
diff puts 99.9% of the instructions in `tree_sitter::Query::new`, called from
`tree_sitter_parser::from_language`, almost all of it in `ts_query__perform_analysis`:
difft compiles tree-sitter-swift's highlight query on every run. The app pays the same
cost once per session (the 211 ms cold grammar load above).

Callgrind of 0.70.0 on the ~2,000-line benchmark input (instructions, not wall time):

| Stage | Share |
|---|---:|
| Structural search (`mark_syntax`: `compute_neighbours`, graph allocation) | 39% |
| Compile the Swift highlight query | 37% |
| Parse both sides and convert to difft's syntax tree | ~15% |
| Levenshtein between comments (inside the search) | 8% |
| Change positions, slider fixing | ~12% |
| Run the highlight query (`tree_highlights`) | 4% |

The search is allocation- and memory-heavy, so its share of wall time is larger than
its share of instructions. difft uses the highlight query's comment captures to
classify atoms as comments, which changes how comments are diffed, so the query is not
display-only and cannot simply be skipped.

### JSON compatibility of 0.70.0

On the same inputs, 0.70.0 reports the same status and number of chunks, and every
changed line covers exactly the same bytes. Differences:

- a new top-level `aligned_lines` array (pairs of old and new line numbers), which
  `DifftFile` ignores;
- some changed tokens are split finer, for example one range `13..<22` becomes
  `13..<15`, `15..<16`, `16..<22`.

### Ways to make it faster

In order of value for effort:

1. **Upgrade to 0.70.0.** Set the default in `scripts/fetch-difft.sh`. It restores
   structural diffs for 40% of this repository's Swift files and makes ordinary edits
   2–3× faster. Large multi-hunk diffs get slower, because they are now diffed
   structurally instead of as text; items 2 and 3 are what keep that off the critical
   path. Re-run `DifftRunnerTests` and check a few real diffs before merging.
2. **Do not make the first frame wait for difft.** `DiffAligner` already works without
   hints (it falls back to a plain line diff). Publish the document and its syntax
   colours as soon as highlighting finishes, then apply difft's hints when they arrive.
   The catch is that hints can change which changed lines sit side by side, so rows can
   move after the first frame. The existing anchor logic keeps the reader's place, but
   the change has to be tested for visible jumps.
3. **Highlight while difft runs.** Highlighting needs only the split lines, not difft's
   output. Today `DiffEngine.build` runs difft, then highlights old, then new.
4. **Prefetch keeps helping.** `DiffPrefetcher` already warms difft for up to 100
   changed files, 3 at a time, so the cold path is mainly hit for a file that has just
   changed and while browsing commits. The fixed cost per process makes this more
   valuable, not less.
5. **Upstream: cheaper query analysis for tree-sitter-swift's highlight query.** It is
   the fixed cost in both difft and the app's cold start. Out of this repository's
   hands.
6. **Run difft on less text**: only the changed regions, each widened to its enclosing
   declaration using the tree the highlighter already has. It shrinks parsing and the
   search, not the fixed query cost, and needs line mapping and fragments that parse.
   Not worth it before 1–3.

There is no difft library or server mode that keeps grammars warm between files: the
`difft` crate is a binary, so running it in process would mean maintaining a fork.

### Other syntax-aware diff tools

| Tool | What it is | Fit |
|---|---|---|
| difftastic (current) | Rust, tree-sitter, Dijkstra over syntax trees; moves, reindentation, delimiter pairing, word diff in comments | Best open-source structural diff; fixed cost per process for Swift |
| diffsitter | Rust, tree-sitter, Myers diff over leaf tokens; JSON output | Simpler and less precise; its README calls it "nowhere close to production ready". Still a process per file with its own parse |
| GumTree | Java AST differencing with move detection | JVM start-up and memory; a research tool, not built for an interactive viewer |
| SemanticDiff | Closed-source VS Code extension and GitHub app | Not embeddable |
| Mergiraf | Rust, tree-sitter structured merge driver | Merges, not diff output |

No other tool is both faster and as good structurally. The option worth building is
**an in-process token diff** as a first pass: the app already parses both sides with
tree-sitter for colours, so a Myers or histogram diff over the leaf tokens of each
changed block (what diffsitter does) could run in the same pass with no process and no
second parse. It would lose difftastic's structural matching, so it complements difft
rather than replacing it: show the token diff at once, refine with difft's hints when
they arrive (item 2 above). Its cost is unmeasured.

## Recommendations

In order:

1. **Upgrade difft to 0.70.0.** A one-line change that restores structural diffs for
   40% of this repository's Swift files and speeds up ordinary edits 2–3×.
2. **Stop the first frame waiting on difft and on the second side's highlighting.**
   Show the line diff with syntax colours first and apply difft's hints when they
   arrive; highlight concurrently with difft, both sides in parallel for the file in
   front of the reader. Keep the sequential order for All changes, where it limits
   parser concurrency on purpose. This matters more after item 1, since large
   multi-hunk diffs become slower to diff structurally.
3. **Replace the shaped-line cache's clear-everything eviction** (`DiffPaneView`,
   4,000 entries per pane) with an LRU or a limit sized to the document, and invalidate
   only the lines whose runs changed when styles arrive.
4. **Map capture index to `TokenStyle` once per query** instead of splitting the capture
   name for every capture: about a quarter of highlighting time.
5. **Load grammars at launch in the background** to hide the 211 ms first-file cost.
6. Leave `LinePainter`, sorting and joining alone (3% combined). Ranged highlight
   queries for collapsed files are not worth it once highlighting overlaps difft.
