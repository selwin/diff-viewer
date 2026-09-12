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

.PHONY: all gen difft build run test clean open

all: build

difft: DiffViewer/Resources/bin/difft

DiffViewer/Resources/bin/difft:
	scripts/fetch-difft.sh

$(PROJECT): project.yml
	xcodegen generate

gen: $(PROJECT)

build: gen difft
	$(XCB) build | scripts/xcfilter.sh

run: build
	open $(APP)

test: gen difft
	$(XCB) test | scripts/xcfilter.sh

open: gen
	open $(PROJECT)

clean:
	rm -rf $(DERIVED) $(PROJECT)
