#!/bin/zsh
# Usage: scripts/snapshot.sh out.png [repo-path] [changed-file-id]
# Env: NEXT=<n> presses Next Change n times; APPEARANCE=dark|light forces appearance;
#      FOLD=up|down|run|all[,...] clicks separator controls; COLLAPSE=true|false sets the preference;
#      FIND=<query> opens the find bar with that query.
# Renders the window from inside the app (Debug build), so it works on any Space.
# The repo is seeded as the saved session (openRepositoryRoots), which the app restores.
# -ApplePersistenceIgnoreState keeps a live Xcode-run instance of the same bundle id from
# suppressing this instance's launch window.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$1; repo=${2:-}; select=${3:-}
app=$PWD/build/Build/Products/Debug/DiffViewer.app/Contents/MacOS/DiffViewer
# Scripted runs keep their state in their own defaults suite and only ever quit their own
# instances, so an Xcode-run DiffViewer keeps its session and preferences.
# The absolute path is what `pkill -f` matches, so launch with it.
suite=com.selwin.DiffViewer.scripted
pkill -f "$app" 2>/dev/null || true
sleep 0.5
if [[ -n $repo ]]; then
  defaults write "$suite" openRepositoryRoots -array "$repo"
  defaults delete "$suite" lastActiveRepositoryRoot 2>/dev/null || true
fi
if [[ -n ${COLLAPSE:-} ]]; then defaults write "$suite" collapseUnchanged -bool "$COLLAPSE"; fi
rm -f "$out"
log=$(mktemp -t snapshot)
DIFFVIEWER_DEFAULTS_SUITE="$suite" DIFFVIEWER_SNAPSHOT="$out" DIFFVIEWER_NEXT="${NEXT:-0}" DIFFVIEWER_FIND="${FIND:-}" DIFFVIEWER_FOLD="${FOLD:-}" DIFFVIEWER_APPEARANCE="${APPEARANCE:-}" DIFFVIEWER_SELECT="$select" "$app" -ApplePersistenceIgnoreState YES >/dev/null 2>"$log" &
pid=$!
# A failed hook exits the app without writing $out, so stop waiting when it is gone.
for _ in {1..40}; do [[ -f $out ]] && break; kill -0 $pid 2>/dev/null || break; sleep 0.5; done
# The render is done; nobody looks at this window.
pkill -f "$app" 2>/dev/null || true
# Surface hook failures; the rest of the app's stderr is system logging.
grep '^### ' "$log" >&2 || true
rm -f "$log"
ls -la "$out"
