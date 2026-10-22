#!/usr/bin/env python3
"""Actions shared by the Linux CLI, panel and tray."""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

import rime_tts_common as c
import rime_tts_tts as tts

HERE = Path(__file__).resolve().parent
READER = HERE / "rime_tts_reader.py"
PANEL = HERE / "rime_tts_panel.py"
TRAY = HERE / "rime_tts_tray.py"


def _python() -> str:
    return sys.executable or "python3"


def _reader_command() -> List[str]:
    # In an AppImage the interpreter and scripts live on a temporary mount.
    # Starting the AppImage itself keeps that mount alive for the reader's
    # lifetime (AppRun maps --reader-daemon to the foreground reader).
    appimage = os.environ.get("APPIMAGE")
    if appimage:
        return [appimage, "--reader-daemon", "--quiet"]
    return [_python(), str(READER), "--quiet"]


# ---------------------------------------------------------------- reader


def start_reader() -> List[str]:
    pid = c.reader_pid()
    if pid:
        return [f"后台朗读已在运行 (pid {pid})"]
    if not READER.is_file():
        return [f"找不到朗读器: {READER}（先运行 install.sh）"]
    c.STATE_DIR.mkdir(parents=True, exist_ok=True)
    c.QUEUE_DIR.mkdir(parents=True, exist_ok=True)
    try:
        subprocess.Popen(
            _reader_command(),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )
    except OSError as exc:
        return [f"启动失败: {exc}"]
    # An AppImage may need a moment to mount/extract before the reader writes
    # its pid file.
    for _ in range(250):
        pid = c.reader_pid()
        if pid:
            return [f"已启动后台朗读 (pid {pid})"]
        time.sleep(0.02)
    return [f"启动失败，请查看 {c.LOG_FILE}"]


def stop_reader() -> List[str]:
    pid = c.reader_pid()
    if not pid:
        try:
            c.PID_FILE.unlink(missing_ok=True)
        except OSError:
            pass
        return ["后台朗读未在运行"]
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass
    for _ in range(40):
        if not c.reader_running():
            break
        time.sleep(0.05)
    else:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    try:
        c.PID_FILE.unlink(missing_ok=True)
    except OSError:
        pass
    return [f"已停止后台朗读 (pid {pid})"]


def restart_reader() -> List[str]:
    return stop_reader() + start_reader()


def readback_active() -> bool:
    """True while the reader is running and the mute flag is absent."""
    return c.reader_running() and not c.OFF_FILE.exists()


def enable() -> List[str]:
    try:
        c.OFF_FILE.unlink(missing_ok=True)
    except OSError:
        pass
    return ["已取消静音"] + start_reader()


def disable() -> List[str]:
    try:
        c.OFF_FILE.parent.mkdir(parents=True, exist_ok=True)
        c.OFF_FILE.write_text("1", encoding="utf-8")
    except OSError as exc:
        return [f"写入静音标志失败: {exc}"]
    return ["已静音（rime.lua 不再写入）"] + stop_reader()


def toggle() -> List[str]:
    return enable() if c.OFF_FILE.exists() else disable()


# ---------------------------------------------------------------- Rime


def _schemas_to_patch() -> List[str]:
    schemas = c.enabled_schemas()
    if schemas:
        return schemas
    return [p.name[: -len(".custom.yaml")] for p in c.custom_yaml_files()]


def patch_all() -> List[str]:
    msgs: List[str] = []
    if not c.RIME_DIR.is_dir():
        return [f"Rime 用户目录不存在: {c.RIME_DIR}（先安装/启动 Rime，或用 --rime-dir 指定）"]
    schemas = _schemas_to_patch()
    if not schemas:
        msgs.append("未找到启用方案，请手动给方案加补丁")
    for schema in schemas:
        path = c.RIME_DIR / f"{schema}.custom.yaml"
        try:
            changed = c.patch_file(path)
            msgs.append(("已加入补丁: " if changed else "已有补丁: ") + path.name)
        except OSError as exc:
            msgs.append(f"修改 {path.name} 失败: {exc}")
    return msgs


def unpatch_all() -> List[str]:
    msgs: List[str] = []
    for path in c.custom_yaml_files():
        try:
            if c.unpatch_file(path):
                msgs.append(f"已移除补丁: {path.name}")
        except OSError as exc:
            msgs.append(f"修改 {path.name} 失败: {exc}")
    return msgs


def deploy() -> List[str]:
    msgs: List[str] = []
    try:
        c.RIME_DIR.mkdir(parents=True, exist_ok=True)
        c.QUEUE_DIR.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        return [f"创建目录失败: {exc}"]
    msgs.append(c.install_rime_lua())
    msgs.extend(patch_all())
    try:
        c.OFF_FILE.unlink(missing_ok=True)
    except OSError:
        pass
    msgs.append(c.reload_rime())
    msgs.extend(start_reader())
    return msgs


def remove() -> List[str]:
    msgs: List[str] = []
    msgs.extend(stop_reader())
    msgs.extend(unpatch_all())
    try:
        (c.RIME_DIR / "rime.lua").unlink(missing_ok=True)
        msgs.append("已删除 rime.lua")
    except OSError as exc:
        msgs.append(f"删除 rime.lua 失败: {exc}")
    try:
        c.OFF_FILE.unlink(missing_ok=True)
    except OSError:
        pass
    msgs.append(f"已清空队列（{c.clear_queue()} 个文件）")
    msgs.append(c.reload_rime())
    return msgs


def reload_rime() -> List[str]:
    return [c.reload_rime()]


# ---------------------------------------------------------------- panel / tray


def _spawn(
    script: Path,
    args: List[str],
    appimage_args: Optional[List[str]] = None,
) -> Optional[str]:
    if not script.is_file():
        return f"找不到 {script}"
    appimage = os.environ.get("APPIMAGE")
    if appimage and appimage_args is not None:
        cmd = [appimage] + appimage_args
    else:
        cmd = [_python(), str(script)] + args
    try:
        subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )
    except OSError as exc:
        return f"启动失败: {exc}"
    return None


def start_panel(show: bool = True) -> List[str]:
    pid = c.panel_pid()
    if pid:
        if show:
            try:
                c.PANEL_SHOW.parent.mkdir(parents=True, exist_ok=True)
                c.PANEL_SHOW.write_text("1", encoding="utf-8")
            except OSError:
                pass
        return [f"控制面板已在运行 (pid {pid})"]
    err = _spawn(PANEL, [], [] if show else ["--hidden"])
    if err:
        return [err]
    return ["已启动控制面板"]


def start_tray(show_panel: bool = False) -> List[str]:
    if not TRAY.is_file():
        return start_panel(show=show_panel)
    pid = c.tray_pid()
    if pid:
        if show_panel:
            start_panel(show=True)
        return [f"托盘已在运行 (pid {pid})"]
    err = _spawn(
        TRAY,
        ["--panel"] if show_panel else [],
        ["--tray"] + (["--panel"] if show_panel else []),
    )
    if err:
        return [err]
    return ["菜单栏/托盘图标已启动"]


def _stop_pid(pid: Optional[int], pid_file: Path, label: str) -> List[str]:
    if not pid:
        try:
            pid_file.unlink(missing_ok=True)
        except OSError:
            pass
        return []
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass
    for _ in range(40):
        try:
            os.kill(pid, 0)
        except OSError:
            break
        time.sleep(0.05)
    else:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    try:
        pid_file.unlink(missing_ok=True)
    except OSError:
        pass
    return [f"已停止{label} (pid {pid})"]


def stop_panel() -> List[str]:
    return _stop_pid(c.panel_pid(), c.PANEL_PID, "控制面板")


def stop_tray() -> List[str]:
    return _stop_pid(c.tray_pid(), c.TRAY_PID, "托盘图标")


def shutdown() -> List[str]:
    return stop_tray() + stop_panel() + stop_reader()


# ---------------------------------------------------------------- misc


def preview(text: str = "测试 Rime 回读") -> List[str]:
    cfg = c.load_config()
    if tts.speak_once(text, cfg):
        return ["已试听"]
    return ["试听失败：请检查 speech-dispatcher / espeak-ng 与语音设置"]


def open_path(path: Path) -> bool:
    opener = "xdg-open"
    if not path.exists():
        return False
    try:
        subprocess.Popen([opener, str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except OSError:
        return False


def open_log() -> bool:
    if not c.LOG_FILE.exists():
        try:
            c.LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
            c.LOG_FILE.touch()
        except OSError:
            return False
    return open_path(c.LOG_FILE)


def open_config() -> bool:
    if not c.CONFIG_FILE.exists():
        c.save_config(c.DEFAULT_CONFIG)
    return open_path(c.CONFIG_FILE)


def set_autostart(enabled: bool) -> bool:
    # Inside an AppImage the mount path does not survive a reboot.  Start the
    # AppImage itself in the foreground reader mode instead; AppRun keeps the
    # mount alive while the reader runs.
    appimage = os.environ.get("APPIMAGE")
    if appimage:
        line = f"{c.desktop_quote(appimage)} --reader-daemon"
    else:
        entry = HERE / "rime-tts"
        line = f"{c.desktop_quote(_python())} {c.desktop_quote(str(entry))} start"
    return c.set_autostart(enabled, line)


def status_lines() -> List[str]:
    st = c.snapshot()
    return [
        f"Rime 前端 : {st['frontend']}",
        f"用户目录  : {st['rime_dir']}  ({'存在' if st['rime_dir_exists'] else '不存在'})",
        f"rime.lua  : {'已安装' if st['lua_installed'] else '未安装'}",
        f"已打补丁  : {', '.join(st['patched']) if st['patched'] else '无'}",
        f"已部署    : {'是' if st['deployed'] else '否'}",
        f"静音      : {'是' if st['muted'] else '否'}",
        f"后台朗读  : {'运行中 (pid %s)' % st['reader_pid'] if st['reader_running'] else '已停止'}",
        f"托盘      : {'运行中' if st['tray_running'] else '未启动'}",
        f"队列      : {st['queue_count']} 个待读文件  ({st['queue_dir']})",
        f"登录自启  : {'是' if st['autostart'] else '否'}",
        f"配置文件  : {st['config']}",
        f"语音引擎  : {tts.engine_summary()}",
        f"语音      : {tts.resolve_voice(c.load_config())}",
    ]


def check_lines() -> List[str]:
    lines = [f"version      : {c.APP_VERSION} (Linux)"]
    lines.extend(status_lines())
    voices = tts.list_voices()
    lines.append(f"可用语音     : {len(voices)}")
    for v in voices[:8]:
        lines.append(f"  {v['display']}")
    if len(voices) > 8:
        lines.append(f"  ... 其余 {len(voices) - 8} 个（rime-tts voices）")
    return lines
