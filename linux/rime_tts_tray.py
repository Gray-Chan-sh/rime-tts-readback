#!/usr/bin/env python3
"""rime-tts-tray - optional tray / status icon for rime-tts-readback (Linux).

Uses GTK3's Gtk.StatusIcon, which works on X11 sessions that still show
legacy tray icons (KDE, XFCE, Cinnamon, MATE, i3bar+stalonetray, ...). On
GNOME 3.26+ there is no legacy tray, so the icon may not appear; the tray then
still keeps the reader running and the menu can be reached via `rime-tts panel`.

When GTK (gi) is not installed the tray degrades to opening the Tk panel. Only
the Python standard library plus the optional PyGObject binding is used.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import rime_tts_common as c
import rime_tts_control as ctl
import rime_tts_tts as tts

ICON_NAMES = {
    "ok": "tray-ok",
    "muted": "tray-off",
    "warn": "tray-warn",
    "off": "tray-off",
}


def _icon_for_state(st: Dict[str, Any]) -> str:
    if not st["rime_dir_exists"] or not st["lua_installed"]:
        return "warn"
    if st["muted"] or not st["reader_running"]:
        return "muted"
    return "ok"


def _icon_path(name: str) -> Optional[str]:
    dirs = [c.ICON_DIR, HERE.parent / "icons"]
    for directory in dirs:
        for suffix in (".png", ".ico"):
            p = directory / (name + suffix)
            if p.is_file():
                return str(p)
    return None


def _notify(title: str, body: str) -> None:
    """Best-effort desktop notification, never fatal."""
    if not body:
        return
    try:
        import shutil
        import subprocess

        if shutil.which("notify-send"):
            subprocess.Popen(
                ["notify-send", "-a", "Rime 回读", title, body],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
    except Exception:
        pass


# ---------------------------------------------------------------- GTK tray


class Tray:
    def __init__(self, show_panel: bool = False):
        import gi

        gi.require_version("Gtk", "3.0")
        from gi.repository import GLib, Gtk

        self.Gtk = Gtk
        self.GLib = GLib
        self.last_state: Dict[str, Any] = {}

        self.icon = Gtk.StatusIcon()
        self.icon.set_title("Rime 回读")
        self.icon.set_tooltip_text("Rime 回读")
        self.icon.connect("activate", lambda *_a: self.open_panel())
        self.icon.connect("popup-menu", self.on_popup_menu)
        self.icon.set_visible(True)

        self.menu = self._build_menu()
        self.refresh()
        GLib.timeout_add(2000, self.refresh)

        if show_panel:
            GLib.timeout_add(300, lambda: (self.open_panel(), False)[1])

    # ------------------------------------------------------------ menu

    def _build_menu(self):
        Gtk = self.Gtk
        menu = Gtk.Menu()

        def item(label: str, callback) -> None:
            entry = Gtk.MenuItem(label=label)
            entry.connect("activate", lambda *_a: callback())
            menu.append(entry)

        item("打开控制面板", self.open_panel)
        menu.append(Gtk.SeparatorMenuItem())
        self.mute_item = Gtk.CheckMenuItem(label="静音")
        self.mute_item.connect("toggled", self.on_mute_toggled)
        menu.append(self.mute_item)
        self.reader_item = Gtk.CheckMenuItem(label="后台朗读")
        self.reader_item.connect("toggled", self.on_reader_toggled)
        menu.append(self.reader_item)
        item("试听", self.on_preview)
        menu.append(Gtk.SeparatorMenuItem())
        item("重新部署 Rime", self.on_redeploy)
        item("清空队列", self.on_clear_queue)
        item("打开日志", self.on_open_log)
        item("打开配置", self.on_open_config)
        item("关于", self.on_about)
        menu.append(Gtk.SeparatorMenuItem())
        item("退出（停止后台朗读）", self.on_quit)
        menu.show_all()
        return menu
    def on_popup_menu(self, _icon, button, activate_time) -> None:
        self.menu.popup(None, None, self.Gtk.StatusIcon.position_menu,
                        self.icon, button, activate_time)

    # ------------------------------------------------------------ state

    def refresh(self) -> bool:
        try:
            st = c.snapshot()
        except Exception:
            return True
        state = _icon_for_state(st)
        path = _icon_path(ICON_NAMES[state])
        if path:
            try:
                self.icon.set_from_file(path)
            except Exception:
                self.icon.set_from_icon_name("audio-volume-high")
        else:
            self.icon.set_from_icon_name("audio-volume-high" if state == "ok" else "audio-volume-muted")

        headline = c.headline(st)
        lines = [
            headline,
            f"队列 {st['queue_count']} 个待读",
        ]
        if not st["rime_dir_exists"]:
            lines.append(f"未找到 Rime 目录: {st['rime_dir']}")
        elif not st["lua_installed"]:
            lines.append("还没有部署 rime.lua")
        self.icon.set_tooltip_text("\n".join(lines))

        # Block signals while syncing so the menu does not re-run actions.
        for widget, handler, value in (
            (self.mute_item, self.on_mute_toggled, bool(st["muted"])),
            (self.reader_item, self.on_reader_toggled, bool(st["reader_running"])),
        ):
            widget.handler_block_by_func(handler)
            widget.set_active(value)
            widget.handler_unblock_by_func(handler)
        self.last_state = st
        self.icon.set_visible(True)
        return True

    # ------------------------------------------------------------ actions

    def _run(self, action) -> None:
        try:
            messages = action()
        except Exception as exc:
            messages = [f"操作失败: {exc}"]
        self._report(*messages)
        self.refresh()

    def _report(self, *messages) -> None:
        text = "  ".join(str(m) for m in messages if str(m).strip())
        if text:
            _notify("Rime 回读", text.splitlines()[0])

    def open_panel(self) -> None:
        self._run(ctl.start_panel)

    def on_mute_toggled(self, widget) -> None:
        want_muted = bool(widget.get_active())
        if want_muted == bool(self.last_state.get("muted")):
            return
        self._run(ctl.disable if want_muted else ctl.enable)

    def on_reader_toggled(self, widget) -> None:
        want_running = bool(widget.get_active())
        if want_running == bool(self.last_state.get("reader_running")):
            return
        self._run(ctl.start_reader if want_running else ctl.stop_reader)

    def on_preview(self) -> None:
        self._run(ctl.preview)

    def on_redeploy(self) -> None:
        self._run(ctl.reload_rime)

    def on_clear_queue(self) -> None:
        count = c.clear_queue()
        self._report(f"已清空队列（{count} 个文件）")
        self.refresh()

    def on_open_log(self) -> None:
        if not ctl.open_log():
            self._report(f"无法打开日志: {c.LOG_FILE}")

    def on_open_config(self) -> None:
        if not ctl.open_config():
            self._report(f"无法打开配置: {c.CONFIG_FILE}")

    def on_about(self) -> None:
        Gtk = self.Gtk
        dialog = Gtk.AboutDialog()
        dialog.set_program_name("Rime 回读")
        dialog.set_version(c.APP_VERSION)
        dialog.set_comments("Rime 上屏后朗读（Linux 版）")
        dialog.set_website(c.REPO_URL)
        dialog.set_logo_icon_name("audio-volume-high")
        dialog.run()
        dialog.destroy()

    def on_quit(self) -> None:
        ctl.stop_reader()
        try:
            if c.tray_pid() == os.getpid():
                c.TRAY_PID.unlink(missing_ok=True)
        except OSError:
            pass
        self.Gtk.main_quit()


def main(argv: Optional[List[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    show_panel = "--panel" in argv

    try:
        import gi  # noqa: F401
        gi.require_version("Gtk", "3.0")
        from gi.repository import Gtk  # noqa: F401
    except Exception as exc:
        sys.stderr.write(f"GTK3 托盘不可用（{exc}），改为打开控制面板。\n")
        messages = ctl.start_panel(show=True)
        sys.stderr.write("\n".join(messages) + "\n")
        failed = any(("找不到" in m) or ("失败" in m) for m in messages)
        return 1 if failed else 0

    import gi

    gi.require_version("Gtk", "3.0")
    from gi.repository import GLib, Gtk  # noqa: F401

    existing = c.tray_pid()
    if existing and existing != os.getpid():
        sys.stderr.write(f"托盘已在运行 (pid {existing})，打开控制面板。\n")
        ctl.start_panel(show=True)
        return 0

    try:
        c.STATE_DIR.mkdir(parents=True, exist_ok=True)
        c.TRAY_PID.write_text(str(os.getpid()), encoding="utf-8")
    except OSError:
        pass

    # The tray is the desktop entry point: make sure the reader is alive.
    ctl.start_reader()
    Tray(show_panel=show_panel)
    try:
        Gtk.main()
    except KeyboardInterrupt:
        pass
    finally:
        try:
            if c.tray_pid() == os.getpid():
                c.TRAY_PID.unlink(missing_ok=True)
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
