#!/bin/zsh
# swift-format over the files pre-commit passes in; same tool and configuration as
# `make format`. The Format workflow pins Swift 6.3, so a different local toolchain
# can format differently: warn, but do not block the commit over it.
set -eu

# As in the Makefile: use the real Xcode even when xcode-select points at the CLT.
if [[ -z ${DEVELOPER_DIR:-} && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if ! command -v swift >/dev/null; then
    print -u2 "swift-format needs the Swift toolchain: install Xcode 26.6 (Swift 6.3)."
    exit 1
fi

version=$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)
if [[ -n $version && $version != "6.3" ]]; then
    print -u2 "warning: Swift $version; CI formats with 6.3, so results may differ."
fi

exec swift format format --in-place --parallel --configuration .swift-format "$@"
