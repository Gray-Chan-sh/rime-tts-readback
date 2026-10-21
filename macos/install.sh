#!/bin/sh
# install.sh - install rime-tts-readback for Squirrel (macOS).
#
#   ./install.sh [options]
#
#     --no-build        use the already built binaries in <repo>/bin
#     --patch           add lua_processor@tts_reporter to every *.custom.yaml
#     --no-start        do not start the background reader
#     --menubar         also start the menu bar item and open the control panel
#     --rime-dir <dir>  Rime user directory (default ~/Library/Rime)
#
# It installs:
#   ~/.rime-tts-readback/bin/{rime-tts-watcher,rime-tts-menubar,rime-tts}
#   ~/.rime-tts-readback/share/rime.lua
#   ~/.rime-tts-readback/config.json            (only if missing)
#   ~/Library/Rime/rime.lua
# and creates the queue directory.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")

home_dir="${HOME:-$(cd ~ && pwd)}"
state_dir="${RIME_TTS_STATE:-$home_dir/.rime-tts-readback}"
rime_dir="${RIME_USER_DIR:-$home_dir/Library/Rime}"
queue_dir="${RIME_TTS_DIR:-$rime_dir/tts_queue}"

build=1
patch=0
start=1
menubar=0

while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) build=0 ;;
    --patch)    patch=1 ;;
    --no-start) start=0 ;;
    --menubar)  menubar=1 ;;
    --rime-dir) shift; rime_dir="${1:?--rime-dir needs a path}"; queue_dir="${RIME_TTS_DIR:-$rime_dir/tts_queue}" ;;
    -h|--help)  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

echo "rime-tts-readback installer (macOS)"
echo "  Rime user dir : $rime_dir"
echo "  state dir     : $state_dir"
echo

if [ "$build" = 1 ]; then
  "$here/build.sh" "$root/bin"
fi

[ -x "$root/bin/rime-tts-watcher" ] || { echo "missing $root/bin/rime-tts-watcher (run ./build.sh)" >&2; exit 1; }

mkdir -p "$state_dir/bin" "$state_dir/share" "$rime_dir" "$queue_dir"

# Never overwrite a running executable in place: replacing the bytes of a mapped
# (and signed) binary invalidates its code signature and the next exec is killed
# with SIGKILL (Code Signature Invalid). Write a temp file and rename it instead.
put() {
  cp "$1" "$2.tmp.$$"
  mv -f "$2.tmp.$$" "$2"
}

put "$root/bin/rime-tts-watcher" "$state_dir/bin/rime-tts-watcher"
put "$root/bin/rime-tts-menubar" "$state_dir/bin/rime-tts-menubar"
put "$root/rime/rime.lua" "$state_dir/share/rime.lua"
put "$root/rime/rime.lua" "$rime_dir/rime.lua"
put "$here/rime-tts" "$state_dir/bin/rime-tts"
chmod +x "$state_dir/bin/rime-tts" "$state_dir/bin/rime-tts-watcher" "$state_dir/bin/rime-tts-menubar"
echo "installed: $rime_dir/rime.lua"
echo "installed: $state_dir/bin/{rime-tts,rime-tts-watcher,rime-tts-menubar}"
echo "created  : $queue_dir"

if [ ! -f "$state_dir/config.json" ]; then
  cat >"$state_dir/config.json" <<'JSON'
{
  "Voice": "Tingting",
  "Rate": 0,
  "IdleMs": 60,
  "MaxWaitMs": 200,
  "Volume": 100,
  "CharByChar": false,
  "ReadDigits": true,
  "ReadEnglish": true,
  "AppFilterMode": "all",
  "AppFilterList": [],
  "HotKey": ""
}
JSON
  echo "created  : $state_dir/config.json"
fi

if [ "$patch" = 1 ]; then
  "$state_dir/bin/rime-tts" patch
fi

echo
if [ "$start" = 1 ]; then
  "$state_dir/bin/rime-tts" on
  echo "后台朗读已启动。"
fi
if [ "$menubar" = 1 ]; then
  "$state_dir/bin/rime-tts" menubar
fi

cat <<EOF

Next steps:
  1) If you did not use --patch, add this to each schema's *.custom.yaml in
     $rime_dir :

         patch:
           "engine/processors/@before 0": "lua_processor@tts_reporter"

     (or click "部署到 Rime" in the control panel)
  2) Redeploy Rime:  $state_dir/bin/rime-tts reload
     (or the Squirrel tray icon -> 重新部署)

Control panel:  $state_dir/bin/rime-tts panel
Commands:  $state_dir/bin/rime-tts {start|stop|on|off|status|check|voices|log|panel}
           add $state_dir/bin to your PATH to just type "rime-tts".
EOF