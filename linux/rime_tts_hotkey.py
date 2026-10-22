#!/usr/bin/env python3
"""Optional X11 global hotkey (XGrabKey) for the Linux reader.

Wayland has no reliable global-key API without a portal/compositor extension;
there we deliberately do nothing and the caller logs a hint. The daemon keeps
running either way.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import os
import struct
import threading
import time
from typing import Callable, Optional


class _XErrorEvent(ctypes.Structure):
    _fields_ = [
        ("type", ctypes.c_int),
        ("display", ctypes.c_void_p),
        ("resourceid", ctypes.c_ulong),
        ("serial", ctypes.c_ulong),
        ("error_code", ctypes.c_ubyte),
        ("request_code", ctypes.c_ubyte),
        ("minor_code", ctypes.c_ubyte),
    ]


_XErrorHandler = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.POINTER(_XErrorEvent))

SHIFT = 1 << 0
LOCK = 1 << 1
CONTROL = 1 << 2
MOD1 = 1 << 3
MOD2 = 1 << 4
MOD4 = 1 << 6

_KEY_NAMES = {
    "space": "space",
    "tab": "Tab",
    "enter": "Return",
    "return": "Return",
    "esc": "Escape",
    "escape": "Escape",
    "backspace": "BackSpace",
    "delete": "Delete",
    "insert": "Insert",
    "home": "Home",
    "end": "End",
    "pageup": "Prior",
    "pagedown": "Next",
    "left": "Left",
    "right": "Right",
    "up": "Up",
    "down": "Down",
}


def _is_wayland() -> bool:
    if os.environ.get("XDG_SESSION_TYPE", "").strip().lower() == "wayland":
        return True
    return bool(os.environ.get("WAYLAND_DISPLAY")) and not os.environ.get("DISPLAY")


def parse_hotkey(spec: str):
    """'ctrl+alt+r' -> (modifier_mask, keysym_name) or None."""
    if not spec or not spec.strip():
        return None
    mods = 0
    key: Optional[str] = None
    for part in spec.replace(" ", "").split("+"):
        p = part.lower()
        if not p:
            continue
        if p in ("ctrl", "control"):
            mods |= CONTROL
        elif p in ("alt", "option", "opt"):
            mods |= MOD1
        elif p == "shift":
            mods |= SHIFT
        elif p in ("super", "win", "meta", "cmd", "command"):
            mods |= MOD4
        else:
            key = _KEY_NAMES.get(p, part if len(part) == 1 else part.capitalize())
    if not key or mods == 0:
        return None
    return mods, key


class X11HotKey:
    def __init__(self, spec: str, on_press: Callable[[], None], log: Callable[[str], None]):
        self.spec = spec
        self.on_press = on_press
        self.log = log
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._error: Optional[int] = None

    def start(self) -> None:
        parsed = parse_hotkey(self.spec)
        if parsed is None:
            return
        if _is_wayland():
            self.log("全局快捷键在 Wayland 会话下不可用（需要 X11）")
            return
        if not os.environ.get("DISPLAY"):
            self.log("没有 DISPLAY，跳过全局快捷键")
            return
        self._thread = threading.Thread(target=self._run, args=(parsed,), daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=1.0)
            self._thread = None

    # ------------------------------------------------------------ thread
    def _run(self, parsed) -> None:
        mods, key_name = parsed
        lib_name = ctypes.util.find_library("X11") or "libX11.so.6"
        try:
            x = ctypes.CDLL(lib_name)
        except OSError as exc:
            self.log(f"无法加载 libX11: {exc}")
            return

        x.XOpenDisplay.argtypes = [ctypes.c_char_p]
        x.XOpenDisplay.restype = ctypes.c_void_p
        x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        x.XDefaultRootWindow.restype = ctypes.c_ulong
        x.XStringToKeysym.argtypes = [ctypes.c_char_p]
        x.XStringToKeysym.restype = ctypes.c_ulong
        x.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        x.XKeysymToKeycode.restype = ctypes.c_ubyte
        x.XGrabKey.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_uint, ctypes.c_ulong,
                               ctypes.c_int, ctypes.c_int, ctypes.c_int]
        x.XGrabKey.restype = ctypes.c_int
        x.XUngrabKey.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_uint, ctypes.c_ulong]
        x.XUngrabKey.restype = ctypes.c_int
        x.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
        x.XPending.argtypes = [ctypes.c_void_p]
        x.XPending.restype = ctypes.c_int
        x.XNextEvent.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        x.XNextEvent.restype = ctypes.c_int
        x.XSetErrorHandler.argtypes = [_XErrorHandler]
        x.XSetErrorHandler.restype = ctypes.c_void_p
        x.XCloseDisplay.argtypes = [ctypes.c_void_p]
        x.XCloseDisplay.restype = ctypes.c_int

        dpy = x.XOpenDisplay(None)
        if not dpy:
            self.log("无法打开 X11 显示，跳过全局快捷键")
            return
        root = x.XDefaultRootWindow(dpy)
        keysym = x.XStringToKeysym(key_name.encode("utf-8"))
        keycode = x.XKeysymToKeycode(dpy, keysym)
        if not keycode:
            self.log(f"未知按键: {key_name}")
            x.XCloseDisplay(dpy)
            return

        def on_error(_dpy, event):
            self._error = event.contents.error_code
            return 0

        handler = _XErrorHandler(on_error)
        x.XSetErrorHandler(handler)

        grabbed = []
        # Grab the NumLock/CapsLock variants too, otherwise the same combination
        # stops working as soon as either lock is on.
        for extra in (0, LOCK, MOD2, LOCK | MOD2):
            mask = mods | extra
            x.XGrabKey(dpy, keycode, mask, root, False, 1, 1)  # GrabModeAsync
            grabbed.append(mask)
        x.XSync(dpy, False)
        if self._error is not None:
            self.log(f"全局快捷键 {self.spec} 注册失败（X11 错误 {self._error}，可能被占用）")
            for mask in grabbed:
                x.XUngrabKey(dpy, keycode, mask, root)
            x.XSync(dpy, False)
            x.XCloseDisplay(dpy)
            return

        self.log(f"全局快捷键已注册: {self.spec}")
        event = (ctypes.c_char * 192)()
        while not self._stop.is_set():
            while x.XPending(dpy) > 0:
                x.XNextEvent(dpy, ctypes.byref(event))
                if struct.unpack_from("i", event, 0)[0] == 2:  # KeyPress
                    try:
                        self.on_press()
                    except Exception as exc:  # pragma: no cover - defensive
                        self.log(f"快捷键回调失败: {exc}")
            time.sleep(0.05)

        for mask in grabbed:
            x.XUngrabKey(dpy, keycode, mask, root)
        x.XSync(dpy, False)
        x.XCloseDisplay(dpy)
