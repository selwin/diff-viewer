# Image preview for binary files

Full plan: side-by-side old/new images for a single binary selection. `DiffContent`
stays unchanged; `DiffLoader` publishes `imagePreview` next to `.binary` content.

## Stage 1: `ImagePreview` model and decoder (no UI)
**Goal**: `ImagePreview` (App layer) with per-side `CGImage`, original pixel size and byte
count, decoded off main with cancellation forwarded; `DiffEngine.Sources` gains
`oldExists`/`newExists`.
**Success Criteria**: `make build` clean under strict concurrency; model stores no `Data`.
**Tests**: `ImagePreviewTests` (extension gate, sizes, absent vs empty vs junk sides,
downsampling, EXIF rotation); `DiffEngine.sources` existence flags.
**Status**: Complete

## Stage 2: `DiffLoader` publishes `imagePreview`
**Goal**: single-file `.binary` image selections publish content + preview in one turn;
cleared on selection change, entering All changes, or no selection.
**Success Criteria**: existing binary loader test unchanged and green.
**Tests**: `DiffLoaderTests` (PNG → preview, `.bin` → nil, rename, clearing, same-file
reload, superseded load).
**Status**: Not Started

## Stage 3: `ImagePreviewView` + wiring
**Goal**: two equal panes, divider, checkerboard, captions, notices, accessible; `DiffDetailView`
picks preview vs placeholder; `FileSizeText` shared formatter.
**Success Criteria**: snapshots correct in light and dark; `.bin` and All changes unchanged.
**Tests**: `FileSizeText` only.
**Status**: Not Started

## Stage 4: Visual verification and docs
**Goal**: scratch repo fixtures, snapshots per case, memory check on rapid selection,
`TODO.md` and `CLAUDE.md` updated.
**Success Criteria**: all snapshots right; `make test`, `make lint`, `make format-check` clean.
**Status**: Not Started
