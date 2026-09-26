#!/bin/zsh
# Places a difft (difftastic, MIT) binary at DiffViewer/Resources/bin/difft.
# Prefers a Homebrew install, otherwise downloads the GitHub release.
set -euo pipefail
cd "$(dirname "$0")/.."
dest=DiffViewer/Resources/bin/difft
mkdir -p "$(dirname "$dest")"
if src=$(command -v difft 2>/dev/null); then
  cp "$(readlink -f "$src")" "$dest"
else
  version=${DIFFT_VERSION:-0.70.0}
  arch=$(uname -m); [[ $arch == arm64 ]] && arch=aarch64
  url="https://github.com/Wilfred/difftastic/releases/download/${version}/difft-${arch}-apple-darwin.tar.gz"
  echo "Downloading $url"
  tmp=$(mktemp -d)
  curl -fsSL "$url" | tar -xz -C "$tmp"
  cp "$tmp/difft" "$dest"
  rm -rf "$tmp"
fi
chmod +x "$dest"
"$dest" --version
