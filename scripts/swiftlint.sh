#!/bin/zsh
# SwiftLint over the files pre-commit passes in; same check as `make lint`.
# Keep EXPECTED in sync with the container image in .github/workflows/lint.yml.
set -eu

EXPECTED=0.65.1

# As in the Makefile: use the real Xcode even when xcode-select points at the CLT.
# SwiftLint loads sourcekitd from DEVELOPER_DIR's toolchain and the CLT does not ship it.
if [[ -z ${DEVELOPER_DIR:-} && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if ! command -v swiftlint >/dev/null; then
    print -u2 "swiftlint not found: brew install swiftlint"
    exit 1
fi

version=$(swiftlint --version 2>/dev/null | tail -1)
if [[ $version != "$EXPECTED" ]]; then
    message="warning: SwiftLint $version; CI lints with $EXPECTED, so results may differ."
    # pre-commit shows a hook's output only when it fails, so prefer the terminal,
    # falling back to stderr when there is none (a GUI client, say).
    ( print -- $message > /dev/tty ) 2>/dev/null || print -u2 -- $message
fi

# --force-exclude so .swiftlint.yml's exclusions still apply to explicitly passed paths.
exec swiftlint lint --strict --force-exclude "$@"
