#!/bin/sh
# uninstall.sh - remove rime-tts-readback from this Mac.
#
#   ./uninstall.sh [--force] [--keep-redeploy]
#
#   * stops the background reader and the menu bar item
#   * removes lua_processor@tts_reporter from every *.custom.yaml
#   * deletes ~/Library/Rime/rime.lua, the queue and the mute flag
#   * removes the launch-at-login agent
#   * deletes ~/.rime-tts-readback (binaries, config, log)
#   * asks Squirrel to redeploy (unless --keep-redeploy)
#
# The repository folder itself is not touched.

set -u

home_dir="${HOME:-$(cd ~ && pwd)}"
state_dir="${RIME_TTS_STATE:-$home_dir/.rime-tts-readback}"
rime_dir="${RIME_USER_DIR:-$home_dir/Library/Rime}"
queue_dir="${RIME_TTS_DIR:-$rime_dir/tts_queue}"
pid_file="$state_dir/watcher.pid"
menubar_pid_file="$state_dir/menubar.pid"
agent="$home_dir/Library/LaunchAgents/com.graychan.rime-tts-readback.menubar.plist"
squirrel="/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel"
cli="$state_dir/bin/rime-tts"

force=0
redeploy=1
for a in "$@"; do
  case "$a" in
    --force) force=1 ;;
    --keep-redeploy) redeploy=0 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

if [ "$force" = 0 ]; then
  printf 'Remove rime-tts-readback from this machine? (y/N) '
  read -r answer
  case "$answer" in y|Y) ;; *) echo "Cancelled."; exit 0 ;; esac
fi

stop_pid_file() {
  [ -f "$1" ] || return 0
  pid=$(tr -dc '0-9' <"$1")
  [ -n "$pid" ] || return 0
  kill -TERM "$pid" 2>/dev/null
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
  echo "stopped $(basename "$1") (pid $pid)"
}

stop_pid_file "$pid_file"
stop_pid_file "$menubar_pid_file"

# launch-at-login
if [ -f "$agent" ]; then
  launchctl unload -w "$agent" 2>/dev/null
  rm -f "$agent"
  echo "removed launch agent"
fi

# schema patches + rime.lua
if [ -x "$cli" ]; then
  "$cli" unpatch
else
  for f in "$rime_dir"/*.custom.yaml; do
    [ -e "$f" ] || continue
    grep -q 'rime-tts-readback' "$f" 2>/dev/null || continue
    sed -i '' -e '/rime-tts-readback/d' -e '/lua_processor@tts_reporter/d' "$f"
    echo "patch removed: $(basename "$f")"
  done
fi
rm -f "$rime_dir/rime.lua"
echo "removed rime.lua"

# state + queue
rm -rf "$state_dir"
rm -rf "$queue_dir"
rm -f "$rime_dir/tts_off"
echo "removed state, queue and mute flag"

if [ "$redeploy" = 1 ] && [ -x "$squirrel" ]; then
  echo "redeploying Rime ..."
  "$squirrel" --reload >/dev/null 2>&1 || echo "redeploy failed (do it from the Squirrel menu)"
fi

echo "Done. The repository folder was not touched."