#!/bin/zsh
# Usage: scripts/screenshot.sh out.png [repo-path] [changed-file-id] [delay-seconds]
# Env: OPEN=<JSON array of paths> opens further repositories as tabs of the same window.
# Relaunches the Debug build on the repo (seeded as the saved session), optionally selects
# a file, and captures the window.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$1; repo=${2:-}; select=${3:-}; delay=${4:-3}
app=build/Build/Products/Debug/DiffViewer.app/Contents/MacOS/DiffViewer
# Scripted runs keep their state in their own defaults suite and only ever quit their own
# instances, so an Xcode-run DiffViewer keeps its session and preferences.
suite=com.selwin.DiffViewer.scripted
pkill -f "$PWD/$app" 2>/dev/null || true
sleep 0.5
if [[ -n $repo ]]; then
  defaults write "$suite" openRepositoryRoots -array "$repo"
  defaults delete "$suite" lastActiveRepositoryRoot 2>/dev/null || true
fi
DIFFVIEWER_DEFAULTS_SUITE="$suite" DIFFVIEWER_OPEN="${OPEN:-}" DIFFVIEWER_NEXT="${NEXT:-0}" DIFFVIEWER_APPEARANCE="${APPEARANCE:-}" DIFFVIEWER_SELECT="$select" "$app" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
sleep "$delay"
id=$(swift scripts/windowid.swift DiffViewer)
screencapture -x -o -l "$id" "$out"
echo "$out"
