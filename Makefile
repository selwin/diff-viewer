SHELL := /bin/zsh
.SHELLFLAGS := -o pipefail -c
# Xcode is installed but xcode-select points at the Command Line Tools;
# point xcodebuild at the real Xcode without needing sudo.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

PROJECT   := DiffViewer.xcodeproj
SCHEME    := DiffViewer
DERIVED   := build
CONFIG    ?= Debug
APP       := $(DERIVED)/Build/Products/$(CONFIG)/DiffViewer.app
XCB       := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) -configuration $(CONFIG)
# prek if installed, else pre-commit; both read .pre-commit-config.yaml. Override with
# `make hooks HOOKS=pre-commit`.
HOOKS     ?= $(shell command -v prek >/dev/null 2>&1 && echo prek || echo pre-commit)

.PHONY: all gen difft build run test lint format format-check hooks hooks-all clean open

all: build

difft: DiffViewer/Resources/bin/difft

# Re-fetched when the script changes, so a version bump reaches existing checkouts.
DiffViewer/Resources/bin/difft: scripts/fetch-difft.sh
	scripts/fetch-difft.sh

$(PROJECT): project.yml $(shell find DiffViewer DiffViewerTests -type d)
	xcodegen generate

gen: $(PROJECT)

build: difft gen
	$(XCB) build | scripts/xcfilter.sh

# Scripted runs keep their state in their own defaults suite (see DebugLaunchOptions), so
# they never touch an Xcode-run instance's session or preferences.
run: build
	DIFFVIEWER_DEFAULTS_SUITE=com.selwin.DiffViewer.scripted $(CURDIR)/$(APP)/Contents/MacOS/DiffViewer -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &

test: difft gen
	$(XCB) test | scripts/xcfilter.sh

open: gen
	open $(PROJECT)

# Same checks CI runs (.github/workflows). swiftlint: `brew install swiftlint`; swift-format ships with Xcode.
SOURCES := DiffViewer DiffViewerTests

lint:
	swiftlint lint --strict

format:
	swift format --in-place --parallel --recursive --configuration .swift-format $(SOURCES)

format-check:
	swift format lint --strict --parallel --recursive --configuration .swift-format $(SOURCES)

# Git hooks: $(HOOKS) formats and lints the staged files; a plain post-commit hook reports
# on the unstaged ones, which $(HOOKS) stashes. `-f` replaces the other tool's pre-commit
# hook instead of keeping it as a legacy hook that runs too. An existing post-commit hook
# of another tool is kept, never overwritten.
hooks:
	$(HOOKS) install -f
	@hook="$$(git rev-parse --git-path hooks)/post-commit"; target="$(CURDIR)/scripts/check-unstaged.sh"; \
	if { [ -e "$$hook" ] || [ -L "$$hook" ]; } && [ "$$(readlink "$$hook")" != "$$target" ]; then \
		echo "Kept the existing $$hook; link it to $$target by hand to use it." >&2; \
	else ln -sf "$$target" "$$hook"; fi

hooks-all:
	$(HOOKS) run --all-files

clean:
	rm -rf $(DERIVED) $(PROJECT)
