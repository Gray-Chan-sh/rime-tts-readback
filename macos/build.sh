#!/bin/sh
# build.sh - compile the two macOS binaries.
#
#   ./build.sh [outdir]        default outdir: <repo>/bin
#
# Needs the Xcode command line tools (swiftc). Install them with:
#   xcode-select --install

set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
out=${1:-"$root/bin"}

command -v swiftc >/dev/null 2>&1 || {
  echo "swiftc not found. Install the Xcode command line tools first:" >&2
  echo "  xcode-select --install" >&2
  exit 1
}

mkdir -p "$out"

echo "building rime-tts-watcher ..."
swiftc -O "$here/RimeTtsWatcher.swift" -o "$out/rime-tts-watcher"
echo "building rime-tts-menubar ..."
swiftc -O "$here/main.swift" "$here/RimeTtsMenuBar.swift" "$here/RimeTtsModel.swift" \
  "$here/RimeTtsPanel.swift" -o "$out/rime-tts-menubar" -framework Carbon

cp "$root/rime/rime.lua" "$out/rime.lua"

echo "built into $out:"
ls -l "$out" | sed 's/^/  /'