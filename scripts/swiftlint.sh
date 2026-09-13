#!/bin/zsh
# SwiftLint over the files pre-commit passes in; same check as `make lint`.
# Keep EXPECTED in sync with the container image in .github/workflows/lint.yml.
set -eu

EXPECTED=0.65.1

if ! command -v swiftlint >/dev/null; then
    print -u2 "swiftlint not found: brew install swiftlint"
    exit 1
fi

version=$(swiftlint --version 2>/dev/null | tail -1)
if [[ $version != "$EXPECTED" ]]; then
    print -u2 "warning: SwiftLint $version; CI lints with $EXPECTED, so results may differ."
fi

# --force-exclude so .swiftlint.yml's exclusions still apply to explicitly passed paths.
exec swiftlint lint --strict --force-exclude "$@"
