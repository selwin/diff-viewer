# Alternative diff renderers: NSTextView / TextKit 2 vs the custom pane

Written September 2026. Records the evaluation of replacing or supplementing the
custom `DiffPaneView` renderer with an `NSTextView` built on TextKit 2, so the
question does not have to be re-derived later. Current deployment target is
macOS 26; macOS 27 has shipped and is an acceptable minimum if it buys something.

## Question

Would an alternative side-by-side renderer built on `NSTextView` be a good idea,
and would it simplify the code?

## What the current renderer is

- `Views/DiffPaneView.swift` (~450 lines) plus `DiffPaneView+Selection.swift`
  (~150), `PaneLayout.swift` (~50) and `PaneSelection.swift` (~135). About 800
  lines in total for both panes.
- Fixed row height. Layout is arithmetic: `PaneLayout` maps row ↔ y, and
  `draw(_:)` only touches rows intersecting the dirty rect.
- One `CTLine` per source line, shaped once and cached (`CachedLine`), with a
  tab-expansion map so highlight ranges and hit tests translate between raw and
  displayed offsets.
- Folding is a projection (`DisplayRow` / `FoldedRows`) over the document rows.
  Changing a fold changes an array, not the text.
- Selection is a `TextPosition` (document row + raw UTF-16 offset). It survives
  folding, font changes and late style arrival because it never refers to
  display rows or expanded columns.
- Copy follows the source: rows hidden by a fold are included, padding rows
  contribute nothing (`PaneModel.text(in:)`).
- Implemented interactions: click, drag with autoscroll, double-click word,
  triple-click line, Copy, Select All, fold controls, cursor shapes.
- Not implemented: shift-click extend, word/line-granularity drag after a
  multi-click, keyboard caret movement and extension, dragging selected text out
  of the pane, Find.
- A relevant detail for keyboard selection: a plain click creates an empty
  selection and `mouseUp` clears it, so there is no persistent insertion point
  to move from. Keyboard selection needs a caret concept added to the model.

## The NSTextView option

### What it would give for free

- Selection mechanics: shift-click, drag autoscroll, multi-click granularity
  drags, Services, Look Up.
- Tab rendering via tab stops, removing `TabExpander` and its offset maps.
- Find bar via `NSTextFinder`, which `NSTextView` supports out of the box.
- Complex-script and IME-correct layout (CTLine already handles most of this).

### What stays custom, or gets harder

| Concern | Consequence |
|---|---|
| Full-width row backgrounds | Background attributes only cover glyph extents. Needs a layout-manager or fragment subclass, or `drawBackground` override. |
| Padding rows and hatching | Empty paragraphs with pinned min/max line height, plus custom drawing. |
| Gutter and line numbers | Custom drawing. macOS 27's viewport delegate makes the geometry easier to obtain (see below). |
| Fold controls in a row | Text attachments with view providers, or hit-testing overrides. |
| Folding | Every fold rebuilds the text storage and invalidates the selection range. Needs a storage-range ↔ document-row map in both directions. macOS 27's `shouldEnumerate` content-storage hook can skip collapsed paragraphs but does not remove the mapping problem. |
| Copy | Padding rows and fold markers are in the storage; `copy` must be overridden to reproduce source-aware behaviour. |
| Two panes with identical row heights | Works with pinned paragraph line heights, but is a constraint to hold at every attribute change. |
| Late-arriving styles | Attribute edits trigger relayout; the current renderer applies them without re-layout. |
| TextKit 1 fallback | Touching the legacy `layoutManager` once silently downgrades the view. Much sample code for gutters and full-width backgrounds does this. |
| Performance | Not automatically faster. Uniform-row arithmetic beats height estimation for this content. Very long lines are the most likely regression. |

### Net

Roughly 250 lines of CTLine drawing and selection code are replaced by a
comparable amount of layout-manager subclassing plus a new mapping layer. Kept
side by side with the current renderer, every feature is written twice for the
duration of the trial. That conflicts with the "one renderer around two aligned
panes" and "boring code" principles in `CLAUDE.md`.

## State of TextKit 2 and macOS 27

- There is no TextKit 3. TextKit 2 (`NSTextLayoutManager`,
  `NSTextContentStorage`, `NSTextViewportLayoutController`) is Apple's only
  current engine and WWDC26 reinforced it.
- macOS 27 additions relevant here:
  - `NSTextView` publicly conforms to `NSTextViewportLayoutControllerDelegate`
    (`willLayout`, `configureRenderingSurface`, `didLayout`). Apple's sample uses
    it for line numbers and collapsible sections.
  - `NSTextViewportRenderingSurface` / `...Key` for tracking and caching the
    views or layers that draw text.
  - `NSTextSelectionManager`: gesture-recognizer-based selection (click, drag,
    shift-click, multi-click word/line/paragraph, drag and drop of text) that can
    be attached to any view with a selection data source. `NSTextView` now uses
    it internally. Keyboard selection is separate: Apple points to
    `NSTextSelectionNavigation` for that.
- Ongoing developer criticism (still current as of mid-2026): silent fallback to
  TextKit 1, height-estimation jitter while scrolling, regressions across OS
  versions, no measured performance gain over TextKit 1, custom CoreText faster
  for very large files. Xcode's editor does not use `NSTextView`; TextEdit is a
  thin wrapper around it. Neither fact settles the choice for a diff viewer.
- SwiftUI `TextEditor` is not a candidate: not enough control over layout and
  viewport.
- A custom `NSTextContentManager` / `NSTextElement` model (one element per diff
  row) is conceptually attractive but, as far as we know, cannot be plugged into
  `NSTextView`, which is bound to `NSTextContentStorage`. It would put the
  project at the raw-TextKit tier, driving its own view, which is the current
  architecture with TextKit doing line layout instead of CTLine. Unverified on
  macOS 27.

Sources:
- [Elevate your app's text experience with TextKit, WWDC26 session 370](https://developer.apple.com/videos/play/wwdc2026/370/)
- [NSTextSelectionManager documentation](https://developer.apple.com/documentation/appkit/nstextselectionmanager)
- [NSTextFinder documentation](https://developer.apple.com/documentation/appkit/nstextfinder)
- [Michael Tsai, AppKit in macOS 27](https://mjtsai.com/blog/2026/06/18/appkit-in-macos-27/)
- [Michael Tsai, TextKit 2: The Promised Land](https://mjtsai.com/blog/2025/08/15/textkit-2-the-promised-land/)
- [What's new in TextKit and text views, WWDC22](https://developer.apple.com/videos/play/wwdc2022/10090/)

## Points conceded during review

The recommendation below was reviewed and the following corrections were
accepted:

1. Effort estimates for closing the selection gaps were understated.
   Shift-click alone is small. System-quality keyboard movement, selection
   reversal, word/line dragging, Unicode boundaries, skipping padding, crossing
   folds and dragging text out involve more state and verification than "about
   a hundred lines".
2. `NSTextSelectionManager` does not cover the whole list by itself. It handles
   gesture-driven selection; keyboard selection needs `NSTextSelectionNavigation`
   integration, and outbound text dragging is not guaranteed by adopting it.
   Adoption is an investigation, not a known-small change.
3. Find is not tied to text-input-client plumbing. A custom view can adopt
   `NSTextFinderClient` and get the system find bar. `NSTextView` gets it with
   less work, but folding and source mapping need customisation either way.
4. "Apple's own editors do not use NSTextView" is too sweeping. Xcode does not;
   TextEdit does. Requirements differ by editor.

## Recommendation

Enhance the existing renderer rather than replace it. The current gaps do not
justify a rewrite, and the side-by-side-specific problems (alignment, padding,
folding, source-aware copy) would all have to be solved again under
`NSTextView`.

Closing the gaps properly is more than a checklist of small patches:

- Add a persistent caret to `PaneSelection` so keyboard movement has a start
  point. Decide what a click with no drag leaves behind.
- Shift-click extension, then multi-click granularity drags, then keyboard
  movement and extension (`NSTextSelectionNavigation` semantics as the reference
  for word and line boundaries, whether or not the class is used).
- Dragging selected text out of the pane.
- Find via `NSTextFinderClient` on the pane, with matches mapped through the
  fold projection.

Before writing the selection work by hand, spend a time-boxed hour on
`NSTextSelectionManager` on macOS 27: what the data source requires, whether it
maps onto `TextPosition` and the existing point → position hit test, and whether
it plays with the fold rows and padding cells. Take it only if the data source is
close to what the pane already has; otherwise write the behaviours directly on
the current model and keep the macOS 26 floor.

An `NSTextView` renderer remains a reasonable time-boxed experiment on a branch
if the goal is to evaluate its behaviour, in particular scrolling feel, ligature
rendering and Find. Prototype alignment, folding and copy first, since those are
where it will fail if it fails. Do not ship it behind a setting alongside the
current renderer.

## Open questions

- Exact shape of the `NSTextSelectionManager` data-source protocol and whether
  it tolerates non-text rows (padding, separators).
- Whether `NSTextSelectionNavigation` can be used standalone against a custom
  data source, or only alongside TextKit 2 content storage.
- Whether a custom `NSTextContentManager` can back an `NSTextView` on macOS 27.
- How `NSTextFinderClient` should report matches inside folded rows: expand on
  navigate, or skip.
