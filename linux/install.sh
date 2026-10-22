#!/usr/bin/env bash
# install.sh - install rime-tts-readback on Linux (fcitx5-rime / ibus-rime / fcitx4-rime).
#
#   ./install.sh [options]
#
#     --patch           add the tts_reporter processor to every enabled schema
#     --no-start        do not start the background reader
#     --tray            start the tray icon (and the reader) after installing
#     --panel           open the control panel after installing
#     --autostart       start the reader automatically at desktop login
#     --rime-dir <dir>  Rime user directory (default: auto-detect)
#     --prefix <dir>    install prefix (default ~/.rime-tts-readback)
#
# It installs:
#   <prefix>/bin/{rime-tts,rime_tts_*.py}
#   <prefix>/share/rime.lua
#   <prefix>/share/icons/*.png
#   <prefix>/config.json                (only if missing)
#   <rime-dir>/rime.lua
#   <rime-dir>/tts_queue/
#   ~/.local/share/applications/rime-tts-readback.desktop
#
# All paths can also be overridden with RIME_TTS_STATE, RIME_USER_DIR and
# RIME_TTS_DIR, matching rime/rime.lua and the other platforms.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")

python_bin="${PYTHON:-python3}"
state_dir="${RIME_TTS_STATE:-${HOME:-$(cd ~ && pwd)}/.rime-tts-readback}"
rime_dir="${RIME_USER_DIR:-}"
queue_dir="${RIME_TTS_DIR:-}"

patch=0
start=1
tray=0
panel=0
autostart=0

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --patch)     patch=1 ;;
    --no-start)  start=0 ;;
    --tray)      tray=1 ;;
    --panel)     panel=1 ;;
    --autostart) autostart=1 ;;
    --rime-dir)  shift; rime_dir="${1:?--rime-dir needs a path}" ;;
    --prefix)    shift; state_dir="${1:?--prefix needs a path}" ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# Never treat the home directory (or the filesystem root) as a throwaway
# prefix; uninstall removes <prefix>/bin and <prefix>/share.
case "${state_dir%/}" in
  ""|"$HOME")
    echo "refusing to use $state_dir as an install prefix; choose a subdirectory" >&2
    exit 2
    ;;
esac

if ! command -v "$python_bin" >/dev/null 2>&1; then
  echo "找不到 $python_bin，请先安装 Python 3.8+。" >&2
  exit 1
fi
if ! "$python_bin" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)'; then
  echo "需要 Python 3.8 或更新版本。" >&2
  exit 1
fi
# The .desktop entry must not depend on the desktop session's PATH.
python_bin=$(command -v "$python_bin")

# Same detection order as rime/rime.lua and rime_tts_common.detect_rime_dir().
if [ -z "$rime_dir" ]; then
  rime_dir=$(cd "$here" && "$python_bin" -c 'import rime_tts_common as c; print(c.RIME_DIR)')
fi
if [ -z "$queue_dir" ]; then
  queue_dir="$rime_dir/tts_queue"
fi
export RIME_TTS_STATE="$state_dir"
export RIME_USER_DIR="$rime_dir"
export RIME_TTS_DIR="$queue_dir"

echo "rime-tts-readback installer (Linux)"
echo "  Rime user dir : $rime_dir"
echo "  state dir     : $state_dir"
echo "  queue dir     : $queue_dir"
echo "  python        : $("$python_bin" -c 'import sys; print(sys.version.split()[0] + " (" + sys.executable + ")")')"
echo

mkdir -p "$state_dir/bin" "$state_dir/share/icons" "$rime_dir" "$queue_dir"

# Atomic replace: an updated script is never observed half-written.
put() {
  cp -f "$1" "$2.tmp.$$"
  mv -f "$2.tmp.$$" "$2"
}

for file in "$here"/rime_tts_*.py "$here"/rime-tts; do
  [ -f "$file" ] || continue
  put "$file" "$state_dir/bin/$(basename "$file")"
done
put "$root/rime/rime.lua" "$state_dir/share/rime.lua"
put "$root/rime/rime.lua" "$rime_dir/rime.lua"

if [ -d "$root/icons" ]; then
  for icon in "$root/icons"/*.png; do
    if [ -f "$icon" ]; then
      put "$icon" "$state_dir/share/icons/$(basename "$icon")"
    fi
  done
fi

chmod +x "$state_dir/bin/rime-tts"
echo "installed: $rime_dir/rime.lua"
echo "installed: $state_dir/bin/{rime-tts,rime_tts_*.py}"
echo "created  : $queue_dir"

if [ ! -f "$state_dir/config.json" ]; then
  (cd "$state_dir/bin" && "$python_bin" -c 'import rime_tts_common as c; c.save_config(c.DEFAULT_CONFIG)')
  echo "created  : $state_dir/config.json"
fi

# Application-menu entry (the panel is the main window; the tray is optional).
apps_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
if mkdir -p "$apps_dir" 2>/dev/null; then
  cat >"$apps_dir/rime-tts-readback.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Rime 回读
GenericName=Read Rime commits aloud
Comment=朗读 Rime 上屏的文字
Exec="$python_bin" "$state_dir/bin/rime-tts" panel
Icon=$state_dir/share/icons/rime-tts-readback.png
Terminal=false
Categories=Utility;Accessibility;
Keywords=rime;tts;speech;readback;
EOF
  echo "installed: $apps_dir/rime-tts-readback.desktop"
fi

if [ "$patch" = 1 ]; then
  "$state_dir/bin/rime-tts" patch
  "$state_dir/bin/rime-tts" reload
fi

echo
if [ "$start" = 1 ]; then
  "$state_dir/bin/rime-tts" on
  echo "后台朗读已启动。"
else
  echo "跳过后台朗读启动；稍后可运行: $state_dir/bin/rime-tts start"
fi
if [ "$autostart" = 1 ]; then
  "$state_dir/bin/rime-tts" autostart on
fi
if [ "$tray" = 1 ]; then
  "$state_dir/bin/rime-tts" tray
fi

cat <<EOF

Next steps:
  1) If you did not use --patch, add this to each enabled schema's *.custom.yaml
     in $rime_dir :

         patch:
           "engine/processors/@before 0": "lua_processor@tts_reporter"

     (or click "安装 / 接管" in the control panel)
  2) Redeploy Rime:  $state_dir/bin/rime-tts reload
     (or the tray icon -> 重新部署 Rime)

Control panel:  $state_dir/bin/rime-tts panel
Tray icon    :  $state_dir/bin/rime-tts tray
Commands     :  $state_dir/bin/rime-tts {start|stop|on|off|status|check|voices|log|panel|tray}
Add $state_dir/bin to your PATH to type "rime-tts" directly.
EOF

if [ "$panel" = 1 ]; then
  "$state_dir/bin/rime-tts" panel
fi

if ! "$python_bin" -c 'import tkinter' >/dev/null 2>&1; then
  echo
  echo "提示: 未安装 Tk（python3-tk），控制面板不可用；CLI 与后台朗读仍可正常工作。" >&2
fi
