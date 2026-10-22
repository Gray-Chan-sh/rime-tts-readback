#!/usr/bin/env python3
"""rime-tts-panel - Tk control panel for rime-tts-readback (Linux).

Same job as the macOS panel and the Windows WinForms window: show the current
state, deploy/remove the integration, mute, start/stop the reader and edit the
shared config. Every change is written to ~/.rime-tts-readback/config.json,
which the reader hot reloads within a second.

Only the Python standard library is used. Run `rime-tts panel` to open it.
"""

from __future__ import annotations

import os
import shutil
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import rime_tts_common as c
import rime_tts_control as ctl
import rime_tts_tts as tts
from rime_tts_hotkey import parse_hotkey

FILTER_MODES = [("all", "全部应用都朗读"), ("only", "只在下列应用朗读"), ("except", "下列应用不朗读")]
MODE_LABELS = [label for _, label in FILTER_MODES]
MODE_VALUES = [mode for mode, _ in FILTER_MODES]
HOTKEY_EXAMPLE = "ctrl+alt+r"


# ---------------------------------------------------------------- X11 helpers


def running_apps() -> List[str]:
    """Window classes of currently mapped windows (X11 only, best effort)."""
    apps: List[str] = []
    if c.is_wayland():
        return apps
    if shutil.which("wmctrl"):
        rc, out, _ = c.run(["wmctrl", "-lx"], timeout=2)
        if rc == 0:
            for line in out.splitlines():
                parts = line.split(None, 3)
                if len(parts) >= 3:
                    cls = parts[2].strip()
                    if cls and cls not in apps:
                        apps.append(cls)
    return sorted(apps, key=str.lower)


def _icon_path(name: str) -> Optional[str]:
    dirs = [c.ICON_DIR, HERE.parent / "icons"]
    for directory in dirs:
        for suffix in (".png", ".ico"):
            p = directory / (name + suffix)
            if p.is_file():
                return str(p)
    return None


# ---------------------------------------------------------------- panel


class Panel:
    def __init__(self, root, show_window: bool = True):
        self.root = root
        self.cfg: Dict[str, Any] = c.load_config()
        self._save_job = None
        self._status_job = None
        self._closing = False
        self._voice_choices: List[str] = []

        root.title("Rime 回读")
        root.minsize(760, 640)
        icon = _icon_path("rime-tts-readback")
        if icon and icon.endswith(".png"):
            try:
                import tkinter as tk

                # Tk drops the image unless a reference is kept.
                self._icon_photo = tk.PhotoImage(file=icon)
                root.iconphoto(True, self._icon_photo)
            except Exception:
                pass
        if not show_window:
            root.withdraw()

        self._build()
        self._load_into_ui()
        self.refresh_status()
        self._poll_show()

        root.protocol("WM_DELETE_WINDOW", self.on_close)

    # ------------------------------------------------------------ layout

    def _build(self) -> None:
        import tkinter as tk
        from tkinter import ttk

        self.tk = tk
        self.ttk = ttk

        outer = ttk.Frame(self.root, padding=10)
        outer.pack(fill="both", expand=True)

        columns = ttk.Frame(outer)
        columns.pack(fill="both", expand=True)
        columns.columnconfigure(0, weight=1, uniform="col")
        columns.columnconfigure(1, weight=1, uniform="col")

        left = ttk.Frame(columns)
        left.grid(row=0, column=0, sticky="nsew", padx=(0, 6))
        right = ttk.Frame(columns)
        right.grid(row=0, column=1, sticky="nsew", padx=(6, 0))

        self._build_status(left)
        self._build_actions(left)
        self._build_speech(right)
        self._build_text(right)
        self._build_filter(right)
        self._build_extras(right)
        self._build_footer(outer)

    def _card(self, parent, title: str):
        from tkinter import ttk

        frame = ttk.LabelFrame(parent, text=title, padding=8)
        frame.pack(fill="x", pady=(0, 8))
        return frame

    def _status_row(self, parent, row: int, title: str):
        from tkinter import ttk

        ttk.Label(parent, text=title, width=9).grid(row=row, column=0, sticky="w", pady=1)
        value = ttk.Label(parent, text="-")
        value.grid(row=row, column=1, sticky="w", pady=1)
        return value

    def _build_status(self, parent) -> None:
        card = self._card(parent, "状态")
        self.lbl_headline = self._status_row(card, 0, "总览")
        self.lbl_frontend = self._status_row(card, 1, "Rime 前端")
        self.lbl_dir = self._status_row(card, 2, "用户目录")
        self.lbl_lua = self._status_row(card, 3, "rime.lua")
        self.lbl_patch = self._status_row(card, 4, "补丁")
        self.lbl_deploy = self._status_row(card, 5, "已部署")
        self.lbl_reader = self._status_row(card, 6, "后台朗读")
        self.lbl_queue = self._status_row(card, 7, "队列")
        self.lbl_engine = self._status_row(card, 8, "语音引擎")

    def _build_actions(self, parent) -> None:
        from tkinter import ttk

        card = self._card(parent, "操作")
        grid = ttk.Frame(card)
        grid.pack(fill="x")
        for i in range(3):
            grid.columnconfigure(i, weight=1)

        def button(text, command, row, col, width=10):
            b = ttk.Button(grid, text=text, command=command, width=width)
            b.grid(row=row, column=col, sticky="ew", padx=2, pady=2)
            return b

        self.btn_install = button("安装 / 接管", self.on_install, 0, 0, 11)
        self.btn_deploy = button("重新部署", self.on_redeploy, 0, 1)
        self.btn_mute = button("静音", self.on_toggle_mute, 0, 2)
        self.btn_reader = button("停止后台", self.on_toggle_reader, 1, 0, 11)
        self.btn_remove = button("移除集成", self.on_remove, 1, 1)
        button("清空队列", self.on_clear_queue, 1, 2)
        button("打开 Rime 目录", self.on_open_rime, 2, 0, 11)
        button("检查报告", self.on_check, 2, 1)
        button("刷新", self.refresh_status, 2, 2)

    def _build_speech(self, parent) -> None:
        from tkinter import ttk

        card = self._card(parent, "语音")
        card.columnconfigure(1, weight=1)

        ttk.Label(card, text="语音", width=7).grid(row=0, column=0, sticky="w")
        self.voice_var = self.tk.StringVar()
        self.voice_box = ttk.Combobox(card, textvariable=self.voice_var, state="readonly")
        self.voice_box.grid(row=0, column=1, sticky="ew", padx=(0, 4))
        self.voice_box.bind("<<ComboboxSelected>>", lambda _e: self._schedule_save())
        ttk.Button(card, text="试听", width=6, command=self.on_preview).grid(row=0, column=2)

        self.rate_var = self.tk.IntVar(value=0)
        self.rate_label = ttk.Label(card, text="0", width=5)
        ttk.Label(card, text="语速", width=7).grid(row=1, column=0, sticky="w", pady=(6, 0))
        scale = ttk.Scale(card, from_=-10, to=10, orient="horizontal",
                          command=lambda v: self._on_rate(float(v)))
        scale.grid(row=1, column=1, sticky="ew", pady=(6, 0))
        self.rate_label.grid(row=1, column=2, sticky="e", pady=(6, 0))

        self.volume_var = self.tk.IntVar(value=100)
        self.volume_label = ttk.Label(card, text="100", width=5)
        ttk.Label(card, text="音量", width=7).grid(row=2, column=0, sticky="w")
        scale = ttk.Scale(card, from_=0, to=100, orient="horizontal",
                          command=lambda v: self._on_volume(float(v)))
        scale.grid(row=2, column=1, sticky="ew")
        self.volume_label.grid(row=2, column=2, sticky="e")

        self.idle_var = self.tk.StringVar(value="60")
        self.maxwait_var = self.tk.StringVar(value="200")
        ttk.Label(card, text="合并窗口", width=7).grid(row=3, column=0, sticky="w")
        idle_row = ttk.Frame(card)
        idle_row.grid(row=3, column=1, columnspan=2, sticky="w")
        ttk.Entry(idle_row, textvariable=self.idle_var, width=7).pack(side="left")
        ttk.Label(idle_row, text=" ms 空闲后朗读；最长等待").pack(side="left")
        ttk.Entry(idle_row, textvariable=self.maxwait_var, width=7).pack(side="left")
        ttk.Label(idle_row, text=" ms").pack(side="left")
        ttk.Label(card, text="", width=7).grid(row=4, column=0)
        ttk.Label(card, text="不按回车也会按期朗读；拆分连续上屏时调大这两个值",
                  foreground="#666666").grid(row=4, column=1, columnspan=2, sticky="w")
        for var in (self.idle_var, self.maxwait_var):
            var.trace_add("write", lambda *_a: self._schedule_save())

    def _build_text(self, parent) -> None:
        from tkinter import ttk

        card = self._card(parent, "文本")
        self.charbychar_var = self.tk.BooleanVar(value=False)
        self.digits_var = self.tk.BooleanVar(value=True)
        self.english_var = self.tk.BooleanVar(value=True)

        ttk.Checkbutton(card, text="逐字朗读（每字之间停顿）", variable=self.charbychar_var,
                        command=self._schedule_save).pack(anchor="w")
        ttk.Checkbutton(card, text="朗读阿拉伯数字（逐位）", variable=self.digits_var,
                        command=self._schedule_save).pack(anchor="w")
        ttk.Checkbutton(card, text="朗读英文字母（逐字母）", variable=self.english_var,
                        command=self._schedule_save).pack(anchor="w")
        ttk.Label(card, text="示例：abc123 → a b c 1 2 3；关闭后只读中文。",
                  foreground="#666666").pack(anchor="w", pady=(4, 0))

    def _build_filter(self, parent) -> None:
        from tkinter import ttk

        card = self._card(parent, "程序筛选（X11）")
        card.columnconfigure(1, weight=1)

        self.mode_var = self.tk.StringVar(value=MODE_LABELS[0])
        ttk.Label(card, text="模式", width=7).grid(row=0, column=0, sticky="w")
        mode_box = ttk.Combobox(card, textvariable=self.mode_var, values=MODE_LABELS, state="readonly")
        mode_box.grid(row=0, column=1, columnspan=2, sticky="ew")
        mode_box.bind("<<ComboboxSelected>>", lambda _e: self._schedule_save())

        self.app_list = self.tk.Listbox(card, height=5, exportselection=False)
        self.app_list.grid(row=1, column=0, columnspan=2, sticky="nsew", pady=(6, 2))
        scroll = ttk.Scrollbar(card, orient="vertical", command=self.app_list.yview)
        scroll.grid(row=1, column=2, sticky="ns", pady=(6, 2))
        self.app_list.configure(yscrollcommand=scroll.set)

        buttons = ttk.Frame(card)
        buttons.grid(row=2, column=0, columnspan=3, sticky="w")
        ttk.Button(buttons, text="添加运行中程序", command=self.on_add_app).pack(side="left", padx=(0, 4))
        ttk.Button(buttons, text="手动输入…", command=self.on_add_app_manual).pack(side="left", padx=(0, 4))
        ttk.Button(buttons, text="移除", command=self.on_remove_app).pack(side="left")

        self.filter_hint = ttk.Label(card, text="", foreground="#666666", wraplength=320, justify="left")
        self.filter_hint.grid(row=3, column=0, columnspan=3, sticky="w", pady=(4, 0))

    def _build_extras(self, parent) -> None:
        from tkinter import ttk

        card = self._card(parent, "启动与快捷键")
        card.columnconfigure(1, weight=1)
        self.autostart_var = self.tk.BooleanVar(value=False)
        ttk.Checkbutton(card, text="登录时自动启动后台朗读", variable=self.autostart_var,
                        command=self.on_toggle_autostart).grid(row=0, column=0, columnspan=2, sticky="w")

        ttk.Label(card, text="静音快捷键", width=10).grid(row=1, column=0, sticky="w", pady=(6, 0))
        self.hotkey_var = self.tk.StringVar(value="")
        ttk.Entry(card, textvariable=self.hotkey_var).grid(row=1, column=1, sticky="ew", pady=(6, 0))
        self.hotkey_var.trace_add("write", lambda *_a: self._schedule_save())
        ttk.Label(card, text=f"留空关闭；例如 {HOTKEY_EXAMPLE}。Wayland 下不可用。",
                  foreground="#666666").grid(row=2, column=0, columnspan=2, sticky="w")

    def _build_footer(self, parent) -> None:
        from tkinter import ttk

        footer = ttk.Frame(parent)
        footer.pack(fill="both", expand=False, pady=(2, 0))
        row = ttk.Frame(footer)
        row.pack(fill="x")
        ttk.Button(row, text="打开日志", command=self.on_open_log).pack(side="left", padx=(0, 4))
        ttk.Button(row, text="打开配置", command=self.on_open_config).pack(side="left", padx=(0, 4))
        ttk.Button(row, text="关于", command=self.on_about).pack(side="left")

        self.message = ttk.Label(footer, text="", foreground="#1f6feb")
        self.message.pack(fill="x", pady=(6, 0))

        self.result = self.tk.Text(footer, height=5, wrap="word", state="disabled")
        self.result.pack(fill="both", expand=True, pady=(6, 0))

    # ------------------------------------------------------------ ui <-> config

    def _load_into_ui(self) -> None:
        cfg = self.cfg
        self._refresh_voices(cfg.get("Voice", ""))

        self.rate_var.set(int(cfg["Rate"]))
        self.rate_label.configure(text=str(int(cfg["Rate"])))
        self.volume_var.set(int(cfg["Volume"]))
        self.volume_label.configure(text=str(int(cfg["Volume"])))
        self.idle_var.set(str(int(cfg["IdleMs"])))
        self.maxwait_var.set(str(int(cfg["MaxWaitMs"])))
        self.charbychar_var.set(bool(cfg["CharByChar"]))
        self.digits_var.set(bool(cfg["ReadDigits"]))
        self.english_var.set(bool(cfg["ReadEnglish"]))

        mode = cfg.get("AppFilterMode", "all")
        self.mode_var.set(MODE_LABELS[MODE_VALUES.index(mode)] if mode in MODE_VALUES else MODE_LABELS[0])
        self.app_list.delete(0, "end")
        for item in cfg.get("AppFilterList", []):
            self.app_list.insert("end", item)
        self.hotkey_var.set(str(cfg.get("HotKey") or ""))
        self.autostart_var.set(c.autostart_enabled())
        self._update_filter_hint()

    def _refresh_voices(self, selected: str = "") -> None:
        voices = tts.list_voices()
        self._voice_choices = [v["name"] for v in voices]
        labels = ["(自动：按文字选择中/英文)"] + [v["display"] for v in voices]
        self.voice_box.configure(values=labels)
        if selected and selected in self._voice_choices:
            self.voice_var.set(labels[self._voice_choices.index(selected) + 1])
        elif selected:
            # A language code or a name the engine cannot list: keep it visible.
            self.voice_box.configure(values=labels + [selected])
            self.voice_var.set(selected)
        else:
            self.voice_var.set(labels[0])

    def _voice_value(self) -> str:
        choice = self.voice_var.get()
        labels = list(self.voice_box.cget("values"))
        if choice in labels:
            idx = labels.index(choice)
            if idx == 0:
                return ""
            if idx <= len(self._voice_choices):
                return self._voice_choices[idx - 1]
        return choice

    def _collect(self) -> Dict[str, Any]:
        cfg = dict(self.cfg)
        cfg["Voice"] = self._voice_value()
        cfg["Rate"] = self.rate_var.get()
        cfg["Volume"] = self.volume_var.get()
        cfg["IdleMs"] = _clamp_int(self.idle_var.get(), cfg["IdleMs"], 0, 5000)
        cfg["MaxWaitMs"] = _clamp_int(self.maxwait_var.get(), cfg["MaxWaitMs"], 0, 10000)
        cfg["CharByChar"] = bool(self.charbychar_var.get())
        cfg["ReadDigits"] = bool(self.digits_var.get())
        cfg["ReadEnglish"] = bool(self.english_var.get())
        mode = MODE_VALUES[MODE_LABELS.index(self.mode_var.get())]
        cfg["AppFilterMode"] = mode
        cfg["AppFilterList"] = [self.app_list.get(i) for i in range(self.app_list.size())]
        cfg["HotKey"] = self.hotkey_var.get().strip()
        return cfg

    def _schedule_save(self) -> None:
        if self._save_job is not None:
            try:
                self.root.after_cancel(self._save_job)
            except Exception:
                pass
        self._save_job = self.root.after(250, self.save_now)

    def save_now(self) -> None:
        self._save_job = None
        try:
            cfg = self._collect()
        except Exception as exc:  # partially built UI
            self._say(f"读取界面失败: {exc}")
            return
        try:
            c.save_config(cfg)
        except OSError as exc:
            self._say(f"保存配置失败: {exc}")
            return
        self.cfg = cfg
        hotkey = cfg["HotKey"]
        if hotkey and parse_hotkey(hotkey) is None:
            self._say(f"已保存；快捷键 '{hotkey}' 无法识别（示例 {HOTKEY_EXAMPLE}）")
        else:
            self._say("配置已保存，后台会自动生效")
        self._update_filter_hint()

    def _on_rate(self, value: float) -> None:
        self.rate_var.set(int(round(value)))
        self.rate_label.configure(text=str(int(round(value))))
        self._schedule_save()

    def _on_volume(self, value: float) -> None:
        self.volume_var.set(int(round(value)))
        self.volume_label.configure(text=str(int(round(value))))
        self._schedule_save()

    def _update_filter_hint(self) -> None:
        mode = self.mode_var.get()
        if mode == MODE_LABELS[0]:
            text = "当前：所有程序里上屏的文字都会朗读。"
        elif running_apps():
            text = "列表可留空；留空时等同于全部应用。"
        else:
            text = ("无法枚举窗口（需要 X11 与 wmctrl）。可直接手动输入窗口类名，"
                    "例如 firefox 或 org.gnome.Terminal。")
        if c.is_wayland():
            text = "Wayland 会话：无法判断前台程序，筛选会被跳过（照常朗读）。"
        self.filter_hint.configure(text=text)

    # ------------------------------------------------------------ actions

    def on_install(self) -> None:
        self._run(ctl.deploy)

    def on_redeploy(self) -> None:
        self._run(ctl.reload_rime)

    def on_toggle_mute(self) -> None:
        if c.OFF_FILE.exists():
            self._run(ctl.enable)
        else:
            self._run(ctl.disable)

    def on_toggle_reader(self) -> None:
        if c.reader_running():
            self._run(ctl.stop_reader)
        else:
            self._run(ctl.start_reader)

    def on_remove(self) -> None:
        from tkinter import messagebox

        if not messagebox.askyesno("移除集成", "将移除 Rime 中的补丁与 rime.lua，并停止后台朗读。\n继续？", parent=self.root):
            return
        self._run(ctl.remove)

    def on_clear_queue(self) -> None:
        n = c.clear_queue()
        self._say(f"已清空队列（{n} 个文件）")
        self.refresh_status()

    def on_open_rime(self) -> None:
        if not ctl.open_path(c.RIME_DIR):
            self._say(f"Rime 目录不存在: {c.RIME_DIR}")

    def on_open_log(self) -> None:
        if not ctl.open_log():
            self._say(f"无法打开日志: {c.LOG_FILE}")

    def on_open_config(self) -> None:
        if not ctl.open_config():
            self._say(f"无法打开配置: {c.CONFIG_FILE}")

    def on_preview(self) -> None:
        cfg = self._collect()
        ok = tts.speak_once("测试 Rime 回读，abc 123", cfg)
        self._say("已试听" if ok else "试听失败：请检查 speech-dispatcher / espeak-ng 与语音设置")

    def on_check(self) -> None:
        self._run(ctl.check_lines)

    def on_toggle_autostart(self) -> None:
        want = bool(self.autostart_var.get())
        ok = ctl.set_autostart(want)
        self._say(("已设置登录自启" if want else "已取消登录自启") if ok else "写入自启动项失败")
        self.autostart_var.set(c.autostart_enabled())

    def on_add_app(self) -> None:
        from tkinter import messagebox

        apps = running_apps()
        if not apps:
            messagebox.showinfo(
                "运行中的程序",
                "无法枚举窗口（需要 X11 与 wmctrl）。\n请用“手动输入…”填写窗口类名。",
                parent=self.root,
            )
            return
        existing = set(self.app_list.get(0, "end"))
        for app in apps:
            if app not in existing:
                self.app_list.insert("end", app)
        self._schedule_save()
        self._say(f"已加入 {len(apps)} 个运行中的窗口类，可移除不需要的项")

    def on_add_app_manual(self) -> None:
        from tkinter import simpledialog

        value = simpledialog.askstring("添加程序", "窗口类名（例如 firefox）：", parent=self.root)
        if value is None:
            return
        value = value.strip()
        if not value:
            return
        if value not in self.app_list.get(0, "end"):
            self.app_list.insert("end", value)
            self._schedule_save()

    def on_remove_app(self) -> None:
        selection = list(self.app_list.curselection())
        if not selection:
            return
        for index in reversed(selection):
            self.app_list.delete(index)
        self._schedule_save()

    def on_about(self) -> None:
        from tkinter import messagebox

        messagebox.showinfo(
            "关于 Rime 回读",
            f"Rime 回读 {c.APP_VERSION}（Linux 版）\n\n"
            "Rime 上屏后朗读：只读取已 commit 的文字，不经过候选/预编辑。\n"
            f"配置：{c.CONFIG_FILE}\n"
            f"日志：{c.LOG_FILE}\n\n"
            f"{c.REPO_URL}",
            parent=self.root,
        )

    # ------------------------------------------------------------ runtime

    def _run(self, action) -> None:
        try:
            messages = action()
        except Exception as exc:  # keep the panel alive on unexpected errors
            messages = [f"操作失败: {exc}"]
        self._say(*messages)
        self.refresh_status()
        self._reload_config()

    def _reload_config(self) -> None:
        """Pull values changed outside the panel (CLI, hand edited JSON)."""
        cfg = c.load_config()
        if cfg == self.cfg:
            return
        self.cfg = cfg
        self._load_into_ui()

    def refresh_status(self) -> None:
        if self._closing:
            return
        if self._status_job is not None:
            try:
                self.root.after_cancel(self._status_job)
            except Exception:
                pass
            self._status_job = None
        try:
            st = c.snapshot()
        except Exception as exc:
            self._say(f"读取状态失败: {exc}")
            self._status_job = self.root.after(2000, self.refresh_status)
            return
        headline = c.headline(st)
        self.lbl_headline.configure(text=headline)
        self.lbl_frontend.configure(text=st["frontend"])
        self.lbl_dir.configure(text=st["rime_dir"])
        self.lbl_lua.configure(text="已安装" if st["lua_installed"] else "未安装")
        self.lbl_patch.configure(text=", ".join(st["patched"]) if st["patched"] else "无")
        self.lbl_deploy.configure(text="是" if st["deployed"] else "否")
        reader = ("运行中 (pid %s)" % st["reader_pid"]) if st["reader_running"] else "已停止"
        self.lbl_reader.configure(text=reader)
        self.lbl_queue.configure(text=f"{st['queue_count']} 个文件  {st['queue_dir']}")
        self.lbl_engine.configure(text=tts.engine_summary())

        self.btn_mute.configure(text="取消静音" if st["muted"] else "静音")
        self.btn_reader.configure(text="停止后台" if st["reader_running"] else "启动后台")
        self.autostart_var.set(bool(st["autostart"]))

        self._status_job = self.root.after(2000, self.refresh_status)

    def _poll_show(self) -> None:
        try:
            if c.PANEL_SHOW.exists():
                c.PANEL_SHOW.unlink(missing_ok=True)
                self.show_window()
        except OSError:
            pass
        self.root.after(500, self._poll_show)

    def show_window(self) -> None:
        try:
            self.root.deiconify()
            self.root.lift()
            self.root.focus_force()
        except Exception:
            pass

    def _say(self, *messages) -> None:
        line = "  ".join(str(m) for m in messages if str(m).strip())
        if not line:
            return
        self.message.configure(text=line.splitlines()[0])
        try:
            self.result.configure(state="normal")
            self.result.insert("end", time.strftime("%H:%M:%S ") + line + "\n")
            self.result.see("end")
            self.result.configure(state="disabled")
        except Exception:
            pass

    def on_close(self) -> None:
        self._closing = True
        if self._save_job is not None:
            try:
                self.root.after_cancel(self._save_job)
            except Exception:
                pass
            self.save_now()
        if self._status_job is not None:
            try:
                self.root.after_cancel(self._status_job)
            except Exception:
                pass
        try:
            if c.panel_pid() == os.getpid():
                c.PANEL_PID.unlink(missing_ok=True)
        except OSError:
            pass
        try:
            self.root.destroy()
        except Exception:
            pass


def _clamp_int(value: Any, default: int, low: int, high: int) -> int:
    try:
        number = int(str(value).strip())
    except (TypeError, ValueError):
        return int(default)
    return max(low, min(high, number))


def main(argv: Optional[List[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    show_window = "--hidden" not in argv

    try:
        import tkinter as tk
    except ImportError:
        sys.stderr.write("缺少 Tk（请安装 python3-tk）\n")
        return 1

    # Single instance: ask the running panel to show itself before creating a
    # second Tk root (otherwise a blank window flashes).
    existing = c.panel_pid()
    if existing and existing != os.getpid():
        try:
            c.PANEL_SHOW.parent.mkdir(parents=True, exist_ok=True)
            c.PANEL_SHOW.write_text("1", encoding="utf-8")
        except OSError:
            pass
        return 0

    try:
        root = tk.Tk()
    except tk.TclError as exc:
        sys.stderr.write(f"无法打开图形界面: {exc}\n")
        return 1

    try:
        c.STATE_DIR.mkdir(parents=True, exist_ok=True)
        c.PANEL_PID.write_text(str(os.getpid()), encoding="utf-8")
    except OSError:
        pass

    Panel(root, show_window=show_window)
    try:
        root.mainloop()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
