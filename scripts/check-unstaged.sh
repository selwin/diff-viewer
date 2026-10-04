#!/bin/zsh
# Reports swift-format and SwiftLint problems in Swift files that are modified or
# untracked but not staged. pre-commit stashes those files while any of its hooks run,
# even at post-commit, so `make hooks` links this script in as a plain git post-commit
# hook. Report only: it modifies nothing, and git ignores a post-commit hook's exit
# status, so it never blocks the commit.
set -eu

# As in the Makefile: use the real Xcode even when xcode-select points at the CLT.
if [[ -z ${DEVELOPER_DIR:-} && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

cd "$(git rev-parse --show-toplevel)"

# NUL-separated, so paths with spaces survive; -f drops files deleted in the working tree.
files=()
for file in ${(0)"$(git ls-files -z --modified --others --exclude-standard -- DiffViewer DiffViewerTests)"}; do
    [[ $file == *.swift && -f $file ]] && files+=($file)
done
files=(${(u)files})

(( ${#files} )) || exit 0

failed=0
print -- "Checking unstaged Swift files (report only; the commit is unaffected):"

if xcrun --find swift >/dev/null 2>&1; then
    xcrun swift format lint --strict --parallel --configuration .swift-format $files || failed=1
else
    print -u2 "swift-format needs the Swift toolchain: install Xcode 27 (Swift 6.4)."
    failed=1
fi

if command -v swiftlint >/dev/null; then
    swiftlint lint --strict --force-exclude $files || failed=1
else
    print -u2 "swiftlint not found: brew install swiftlint"
    failed=1
fi

exit $failed
