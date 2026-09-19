#!/bin/zsh
# Usage: scripts/snapshot.sh out.png [repo-path] [changed-file-id]
# Env: NEXT=<n> presses Next Change n times; APPEARANCE=dark|light forces appearance;
#      FOLD=up|down|run|all[,...] clicks separator controls; COLLAPSE=true|false sets the preference.
# Renders the window from inside the app (Debug build), so it works on any Space.
# The repo is seeded as the saved session (openRepositoryRoots), which the app restores.
# -ApplePersistenceIgnoreState keeps a live Xcode-run instance of the same bundle id from
# suppressing this instance's launch window.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$1; repo=${2:-}; select=${3:-}
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
if [[ -n ${COLLAPSE:-} ]]; then defaults write "$suite" collapseUnchanged -bool "$COLLAPSE"; fi
rm -f "$out"
DIFFVIEWER_DEFAULTS_SUITE="$suite" DIFFVIEWER_SNAPSHOT="$out" DIFFVIEWER_NEXT="${NEXT:-0}" DIFFVIEWER_FOLD="${FOLD:-}" DIFFVIEWER_APPEARANCE="${APPEARANCE:-}" DIFFVIEWER_SELECT="$select" "$app" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
for _ in {1..40}; do [[ -f $out ]] && break; sleep 0.5; done
ls -la "$out"
