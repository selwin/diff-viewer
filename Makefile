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

.PHONY: all gen difft build run test lint format format-check hooks hooks-all clean open

all: build

difft: DiffViewer/Resources/bin/difft

DiffViewer/Resources/bin/difft:
	scripts/fetch-difft.sh

$(PROJECT): project.yml $(shell find DiffViewer DiffViewerTests -type d)
	xcodegen generate

gen: $(PROJECT)

build: difft gen
	$(XCB) build | scripts/xcfilter.sh

run: build
	open $(APP)

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

# Git hooks running format and lint over the staged files: `brew install pre-commit`.
hooks:
	pre-commit install

hooks-all:
	pre-commit run --all-files

clean:
	rm -rf $(DERIVED) $(PROJECT)
