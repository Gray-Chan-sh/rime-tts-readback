#!/bin/bash
# make-appimage.sh - build a self-contained Linux AppImage.
#
#   ./make-appimage.sh <version> <out-dir>
#
# The AppImage bundles a portable CPython (including Tk) and the Linux scripts,
# so the control panel works on a machine without python3-tk.  A system TTS
# engine (spd-say, espeak-ng or espeak) is still required for audio, and the
# optional GTK tray uses the system PyGObject.
#
# Environment overrides (useful for mirrors / offline builds):
#   PYTHON_URL         python-build-standalone install_only tarball
#   APPIMAGETOOL_URL   appimagetool x86_64 AppImage
set -euo pipefail

version=${1:?usage: make-appimage.sh <version> <out-dir>}
out_dir=${2:?usage: make-appimage.sh <version> <out-dir>}

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)

python_url=${PYTHON_URL:-https://github.com/astral-sh/python-build-standalone/releases/download/20261021/cpython-3.11.17%2B20261021-x86_64-unknown-linux-gnu-install_only.tar.gz}
appimagetool_url=${APPIMAGETOOL_URL:-https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage}

work=$(mktemp -d "${TMPDIR:-/tmp}/rime-tts-appimage.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

echo "downloading portable Python ..."
curl -fsSL --retry 3 "$python_url" -o "$work/python.tar.gz"
mkdir -p "$work/pyroot"
tar -xzf "$work/python.tar.gz" -C "$work/pyroot"
pyroot="$work/pyroot/python"
test -x "$pyroot/bin/python3"

appdir="$work/RimeTtsReadback.AppDir"
share="$appdir/usr/share/rime-tts"
mkdir -p "$share"

echo "assembling $appdir ..."
cp -a "$pyroot" "$appdir/usr/python"
cp -a "$root/linux" "$share/linux"
cp -a "$root/rime" "$share/rime"
cp -a "$root/icons" "$share/icons"

# Keep the bundle small and deterministic.
find "$appdir" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$appdir" -type f -name '*.pyc' -delete

cat > "$appdir/AppRun" <<'RUN'
#!/bin/sh
set -eu
HERE=$(dirname "$(readlink -f "$0")")
PY="$HERE/usr/python/bin/python3"
SCRIPTS="$HERE/usr/share/rime-tts/linux"
STATE="${RIME_TTS_STATE:-$HOME/.rime-tts-readback}"

# Seed the state directory on first run.  The panel and deploy action expect
# rime.lua and the icons under the state share directory.
mkdir -p "$STATE/share/icons"
if [ ! -f "$STATE/share/rime.lua" ]; then
    cp "$HERE/usr/share/rime-tts/rime/rime.lua" "$STATE/share/rime.lua"
fi
for src in "$HERE"/usr/share/rime-tts/icons/*.png; do
    [ -f "$src" ] || continue
    dst="$STATE/share/icons/$(basename "$src")"
    [ -f "$dst" ] || cp "$src" "$dst"
done

# Login autostart uses this foreground mode so the AppImage mount stays alive
# for the lifetime of the reader.
if [ "${1:-}" = "--reader-daemon" ]; then
    shift
    exec "$PY" "$SCRIPTS/rime_tts_reader.py" --quiet "$@"
fi

if [ "${1:-}" = "--tray" ]; then
    shift
    exec "$PY" "$SCRIPTS/rime_tts_tray.py" "$@"
fi

if [ "$#" -eq 0 ] || [ "${1:-}" = "--hidden" ]; then
    exec "$PY" "$SCRIPTS/rime_tts_panel.py" "$@"
fi

exec "$PY" "$SCRIPTS/rime-tts" "$@"
RUN
chmod +x "$appdir/AppRun"

cat > "$appdir/rime-tts-readback.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Name=Rime TTS Readback
Comment=Read Rime commits aloud
Exec=rime-tts-readback
Icon=rime-tts-readback
Terminal=false
Categories=Utility;Accessibility;
DESK

cp "$root/icons/rime-tts-readback.png" "$appdir/rime-tts-readback.png"
ln -sf rime-tts-readback.png "$appdir/.DirIcon"

echo "downloading appimagetool ..."
curl -fsSL --retry 3 "$appimagetool_url" -o "$work/appimagetool"
chmod +x "$work/appimagetool"

mkdir -p "$out_dir"
out_dir=$(cd "$out_dir" && pwd)
out="$out_dir/rime-tts-readback-$version-x86_64.AppImage"

echo "building $out ..."
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 "$work/appimagetool" "$appdir" "$out"

test -s "$out"
chmod +x "$out"
echo "built: $out"
