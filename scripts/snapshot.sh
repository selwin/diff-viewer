#!/bin/zsh
# Usage: scripts/snapshot.sh out.png [repo-path] [changed-file-id]
# Env: NEXT=<n> presses Next Change n times; APPEARANCE=dark|light forces appearance;
#      FOLD=up|down|run|all[,...] clicks separator controls; COLLAPSE=true|false sets the preference.
# Renders the window from inside the app (Debug build), so it works on any Space.
# -ApplePersistenceIgnoreState keeps a live Xcode-run instance of the same bundle id from
# suppressing this instance's launch window.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$1; repo=${2:-}; select=${3:-}
app=build/Build/Products/Debug/DiffViewer.app/Contents/MacOS/DiffViewer
pkill -x DiffViewer 2>/dev/null || true
sleep 0.5
if [[ -n $repo ]]; then defaults write com.selwin.DiffViewer recentRepos -array "$repo"; fi
if [[ -n ${COLLAPSE:-} ]]; then defaults write com.selwin.DiffViewer collapseUnchanged -bool "$COLLAPSE"; fi
rm -f "$out"
DIFFVIEWER_SNAPSHOT="$out" DIFFVIEWER_NEXT="${NEXT:-0}" DIFFVIEWER_FOLD="${FOLD:-}" DIFFVIEWER_APPEARANCE="${APPEARANCE:-}" DIFFVIEWER_SELECT="$select" "$app" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
for _ in {1..40}; do [[ -f $out ]] && break; sleep 0.5; done
ls -la "$out"
