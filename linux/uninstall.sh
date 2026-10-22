#!/usr/bin/env bash
# uninstall.sh - remove rime-tts-readback from this Linux desktop.
#
#   ./uninstall.sh [options]
#
#     --purge           also delete config.json, the log and the whole state dir
#     --no-reload       do not ask fcitx5 / ibus to redeploy Rime
#     --rime-dir <dir>  Rime user directory (default: auto-detect)
#     --prefix <dir>    install prefix (default ~/.rime-tts-readback)
#     -y, --yes         do not ask for confirmation
#
# Removes the schema patches, rime.lua, tts_queue, tts_off, the tray/panel/
# reader processes and the autostart entry. User data other than tts_queue is
# never touched; rime-tts-readback itself never writes to your Rime configs
# except for *.custom.yaml (patch) and rime.lua (the Lua reporter).

set -eu

here=$(cd "$(dirname "$0")" && pwd)
python_bin="${PYTHON:-python3}"
state_dir="${RIME_TTS_STATE:-${HOME:-$(cd ~ && pwd)}/.rime-tts-readback}"
rime_dir="${RIME_USER_DIR:-}"

purge=0
reload=1
assume_yes=0

while [ $# -gt 0 ]; do
  case "$1" in
    --purge)     purge=1 ;;
    --no-reload) reload=0 ;;
    --rime-dir)  shift; rime_dir="${1:?--rime-dir needs a path}" ;;
    --prefix)    shift; state_dir="${1:?--prefix needs a path}" ;;
    -y|--yes)    assume_yes=1 ;;
    -h|--help)   awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# Safety: the uninstaller deletes <prefix>/bin and <prefix>/share.
case "${state_dir%/}" in
  ""|"$HOME")
    echo "refusing to use $state_dir as an install prefix; choose a subdirectory" >&2
    exit 2
    ;;
esac

if [ -z "$rime_dir" ] && [ -f "$here/rime_tts_common.py" ]; then
  rime_dir=$(cd "$here" && "$python_bin" -c 'import rime_tts_common as c; print(c.RIME_DIR)')
fi
if [ -z "$rime_dir" ]; then
  rime_dir="${HOME}/.local/share/fcitx5/rime"
fi
export RIME_TTS_STATE="$state_dir"
export RIME_USER_DIR="$rime_dir"

echo "rime-tts-readback uninstaller (Linux)"
echo "  Rime user dir : $rime_dir"
echo "  state dir     : $state_dir"
echo

if [ "$assume_yes" != 1 ]; then
  printf '将移除 Rime 中的回读补丁与 rime.lua，并停止后台朗读。继续？[y/N] '
  answer=""
  read -r answer || true
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "已取消"; exit 0 ;;
  esac
fi

installed="$state_dir/bin/rime-tts"
if [ -x "$installed" ]; then
  "$installed" shutdown >/dev/null 2>&1 || true
  if [ "$reload" = 1 ]; then
    "$installed" remove -f || true
  else
    # remove() reloads at the end; emulate it without the reload step.
    (cd "$state_dir/bin" && "$python_bin" - <<'PY'
import rime_tts_common as c
import rime_tts_control as ctl
for line in ctl.stop_reader() + ctl.unpatch_all():
    print(line)
try:
    (c.RIME_DIR / "rime.lua").unlink(missing_ok=True)
    print("已删除 rime.lua")
except OSError as exc:
    print(f"删除 rime.lua 失败: {exc}")
try:
    c.OFF_FILE.unlink(missing_ok=True)
except OSError:
    pass
print(f"已清空队列（{c.clear_queue()} 个文件）")
PY
    )
  fi
else
  echo "未找到已安装的 rime-tts，直接清理文件。"
  if [ -f "$here/rime_tts_common.py" ]; then
    (cd "$here" && "$python_bin" - <<'PY'
import rime_tts_common as c
import rime_tts_control as ctl
for line in ctl.shutdown() + ctl.unpatch_all():
    print(line)
for p in (c.RIME_DIR / "rime.lua",):
    try:
        p.unlink(missing_ok=True)
    except OSError:
        pass
try:
    c.OFF_FILE.unlink(missing_ok=True)
except OSError:
    pass
print(f"已清空队列（{c.clear_queue()} 个文件）")
PY
    )
  fi
fi

# Autostart + application menu entry.
autostart_file="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/rime-tts-readback.desktop"
rm -f "$autostart_file"
apps_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
rm -f "$apps_dir/rime-tts-readback.desktop"

rm -rf "$state_dir/bin" "$state_dir/share"
if [ "$purge" = 1 ]; then
  rm -rf "$state_dir"
  echo "已删除状态目录: $state_dir"
else
  echo "已保留配置与日志: $state_dir（使用 --purge 可一并删除）"
fi

echo
echo "完成。如果 Rime 仍在朗读，请手动重新部署一次 Rime。"
