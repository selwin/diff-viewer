#!/bin/zsh
# Keeps xcodebuild output readable: errors, warnings, test results, final status.
grep -E --line-buffered '(error:|warning:|Test Case|Test Suite|passed|failed|BUILD|TEST|\*\* )' || true
