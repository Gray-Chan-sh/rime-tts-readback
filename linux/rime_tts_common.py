#!/usr/bin/env python3
"""Shared paths, config, queue and Rime integration helpers (Linux).

This module is deliberately dependency-free: only the Python standard library.
It is the single source of truth for the on-disk contract shared with
rime/rime.lua and (semantically) with the Windows and macOS readers.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

APP_VERSION = "1.1.1"
REPO_URL = "https://github.com/Gray-Chan-sh/rime-tts-readback"

HOME = Path(os.environ.get("HOME") or Path.home())
HERE = Path(__file__).resolve().parent


def _default_state_dir() -> Path:
    # An installed prefix looks like <prefix>/bin/rime_tts_common.py with a
    # sibling share/ directory; use it so `./install.sh --prefix DIR` keeps
    # config/log/pid inside DIR instead of silently falling back to ~.
    if HERE.name == "bin" and (HERE.parent / "share").is_dir():
        return HERE.parent
    return HOME / ".rime-tts-readback"


STATE_DIR = Path(os.environ.get("RIME_TTS_STATE") or _default_state_dir())

PATCH_BEGIN = "# >>> rime-tts-readback >>>"
PATCH_END = "# <<< rime-tts-readback <<<"
PATCH_KEY = '"engine/processors/@before 0"'
PATCH_LINE = PATCH_KEY + ': "lua_processor@tts_reporter"'
PROCESSOR_LINE = "engine/processors/+:"

DEFAULT_CONFIG: Dict[str, Any] = {
    "Voice": "",
    "Rate": 0,
    "IdleMs": 60,
    "MaxWaitMs": 200,
    "Volume": 100,
    "CharByChar": False,
    "ReadDigits": True,
    "ReadEnglish": True,
    "AppFilterMode": "all",
    "AppFilterList": [],
    "HotKey": "",
}

# ---------------------------------------------------------------- Rime paths


def _xdg_data_home() -> Path:
    return Path(os.environ.get("XDG_DATA_HOME") or (HOME / ".local" / "share"))


def _xdg_config_home() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME") or (HOME / ".config"))


def rime_dir_candidates() -> List[Path]:
    data = _xdg_data_home()
    conf = _xdg_config_home()
    return [
        data / "fcitx5" / "rime",   # fcitx5-rime (most common)
        conf / "ibus" / "rime",     # ibus-rime
        conf / "fcitx" / "rime",    # fcitx4-rime
        data / "fcitx" / "rime",
    ]


def detect_rime_dir() -> Path:
    """Same priority as rime/rime.lua's default_base()."""
    override = os.environ.get("RIME_USER_DIR")
    if override:
        return Path(override).expanduser()
    candidates = rime_dir_candidates()
    for p in candidates:
        if p.is_dir():
            return p
    return candidates[0]


RIME_DIR = detect_rime_dir()
QUEUE_DIR = Path(os.environ.get("RIME_TTS_DIR") or (RIME_DIR / "tts_queue"))
OFF_FILE = RIME_DIR / "tts_off"
CONFIG_FILE = STATE_DIR / "config.json"
LOG_FILE = STATE_DIR / "watcher.log"
PID_FILE = STATE_DIR / "watcher.pid"
PANEL_PID = STATE_DIR / "panel.pid"
PANEL_SHOW = STATE_DIR / "panel.show"
TRAY_PID = STATE_DIR / "tray.pid"
SHARE_DIR = STATE_DIR / "share"
ICON_DIR = SHARE_DIR / "icons"
AUTOSTART_FILE = _xdg_config_home() / "autostart" / "rime-tts-readback.desktop"

# ---------------------------------------------------------------- small helpers


def _as_int(value: Any, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _as_bool(value: Any, default: bool) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() in ("1", "true", "yes", "on")
    return default


def run(cmd: List[str], timeout: float = 20.0) -> Tuple[int, str, str]:
    """Run a command, returning (returncode, stdout, stderr). Never raises."""
    try:
        p = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            text=True,
            errors="replace",
        )
        return p.returncode, p.stdout or "", p.stderr or ""
    except FileNotFoundError:
        return 127, "", "not found: " + cmd[0]
    except subprocess.TimeoutExpired:
        return 124, "", "timeout: " + " ".join(cmd)
    except Exception as exc:  # pragma: no cover - defensive
        return 1, "", str(exc)


def is_wayland() -> bool:
    """True on a Wayland session (XWayland alone does not make grabs global)."""
    if os.environ.get("XDG_SESSION_TYPE", "").strip().lower() == "wayland":
        return True
    return bool(os.environ.get("WAYLAND_DISPLAY")) and not os.environ.get("DISPLAY")


def process_running(name: str) -> bool:
    """True if a process whose comm/exe basename is *name* exists."""
    try:
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                comm = (entry / "comm").read_text(errors="replace").strip()
            except OSError:
                continue
            if comm == name:
                return True
    except OSError:
        pass
    return shutil.which("pgrep") is not None and run(["pgrep", "-x", name])[0] == 0


def detect_frontend() -> str:
    if shutil.which("fcitx5-remote") and process_running("fcitx5"):
        return "fcitx5"
    if process_running("ibus-daemon") or shutil.which("ibus"):
        if process_running("ibus-daemon"):
            return "ibus"
    if shutil.which("fcitx5-remote"):
        return "fcitx5 (未运行?)"
    if process_running("fcitx"):
        return "fcitx4"
    return "未检测到 fcitx5 / ibus"


def reload_rime() -> str:
    """Ask the running front end to redeploy. Best effort, never fatal."""
    if shutil.which("fcitx5-remote") and process_running("fcitx5"):
        rc, out, err = run(["fcitx5-remote", "-r"])
        return "已请求 fcitx5 重新加载 Rime" if rc == 0 else f"fcitx5 重新加载失败: {err.strip() or rc}"
    if process_running("ibus-daemon") and shutil.which("ibus"):
        rc, out, err = run(["ibus", "restart"], timeout=30)
        return "已重启 ibus 以重新部署 Rime" if rc == 0 else f"ibus 重启失败: {err.strip() or rc}"
    if process_running("fcitx") and shutil.which("fcitx-remote"):
        rc, out, err = run(["fcitx-remote", "-r"])
        return "已请求 fcitx4 重新加载" if rc == 0 else f"fcitx4 重新加载失败: {err.strip() or rc}"
    return "未找到运行中的 fcitx5 / ibus，请手动重新部署 Rime"


# ---------------------------------------------------------------- config


def load_config(path: Optional[Path] = None) -> Dict[str, Any]:
    path = Path(path or CONFIG_FILE)
    cfg: Dict[str, Any] = dict(DEFAULT_CONFIG)
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return cfg
    if not isinstance(raw, dict):
        return cfg

    if isinstance(raw.get("Voice"), str) and raw["Voice"].strip():
        cfg["Voice"] = raw["Voice"].strip()
    for key in ("Rate", "IdleMs", "MaxWaitMs", "Volume"):
        if key in raw:
            cfg[key] = _as_int(raw.get(key), cfg[key])
    if "CharByChar" in raw:
        cfg["CharByChar"] = _as_bool(raw.get("CharByChar"), cfg["CharByChar"])

    # Legacy master switch: IncludeAscii meant "letters and digits".
    legacy = raw.get("IncludeAscii")
    if "ReadDigits" in raw:
        cfg["ReadDigits"] = _as_bool(raw.get("ReadDigits"), cfg["ReadDigits"])
    elif legacy is not None:
        cfg["ReadDigits"] = _as_bool(legacy, cfg["ReadDigits"])
    if "ReadEnglish" in raw:
        cfg["ReadEnglish"] = _as_bool(raw.get("ReadEnglish"), cfg["ReadEnglish"])
    elif legacy is not None:
        cfg["ReadEnglish"] = _as_bool(legacy, cfg["ReadEnglish"])

    mode = raw.get("AppFilterMode")
    if mode in ("all", "only", "except"):
        cfg["AppFilterMode"] = mode
    if isinstance(raw.get("AppFilterList"), list):
        cfg["AppFilterList"] = [str(x) for x in raw["AppFilterList"] if str(x).strip()]
    if isinstance(raw.get("HotKey"), str):
        cfg["HotKey"] = raw["HotKey"].strip()
    elif isinstance(raw.get("HotKey"), bool):
        cfg["HotKey"] = "ctrl+alt+r" if raw["HotKey"] else ""

    # Clamp to the documented ranges (a hand-edited file should not break the reader).
    cfg["Rate"] = max(-10, min(10, cfg["Rate"]))
    cfg["IdleMs"] = max(0, min(5000, cfg["IdleMs"]))
    cfg["MaxWaitMs"] = max(0, min(10000, cfg["MaxWaitMs"]))
    cfg["Volume"] = max(0, min(100, cfg["Volume"]))
    return cfg


def save_config(cfg: Dict[str, Any], path: Optional[Path] = None) -> None:
    """Merge into the existing JSON so keys unknown to this version survive."""
    path = Path(path or CONFIG_FILE)
    obj: Dict[str, Any] = {}
    try:
        old = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(old, dict):
            obj = old
    except (OSError, ValueError):
        pass
    for key in (
        "Voice", "Rate", "IdleMs", "MaxWaitMs", "Volume", "CharByChar",
        "ReadDigits", "ReadEnglish", "AppFilterMode", "AppFilterList", "HotKey",
    ):
        obj[key] = cfg[key]
    # Keep older readers working (they only understand IncludeAscii).
    obj["IncludeAscii"] = bool(cfg["ReadDigits"] and cfg["ReadEnglish"])
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(obj, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def config_mtime() -> float:
    try:
        return CONFIG_FILE.stat().st_mtime
    except OSError:
        return 0.0


# ---------------------------------------------------------------- queue


def _queue_key(path: Path) -> Tuple[int, int]:
    parts = path.stem.split("_")
    try:
        return int(parts[0]), int(parts[1])
    except (ValueError, IndexError):
        return (2 ** 62, 0)


def queue_files(queue_dir: Optional[Path] = None) -> List[Path]:
    q = Path(queue_dir or QUEUE_DIR)
    try:
        return sorted((p for p in q.iterdir() if p.suffix == ".txt"), key=_queue_key)
    except OSError:
        return []


def queue_count(queue_dir: Optional[Path] = None) -> int:
    return len(queue_files(queue_dir))


def clear_queue(queue_dir: Optional[Path] = None) -> int:
    q = Path(queue_dir or QUEUE_DIR)
    n = 0
    try:
        for p in q.iterdir():
            if p.suffix in (".txt", ".tmp"):
                try:
                    p.unlink()
                    n += 1
                except OSError:
                    pass
    except OSError:
        pass
    return n


def sweep_tmp(queue_dir: Optional[Path] = None, max_age: float = 300.0) -> None:
    import time
    q = Path(queue_dir or QUEUE_DIR)
    now = time.time()
    try:
        for p in q.iterdir():
            if p.suffix == ".tmp":
                try:
                    if now - p.stat().st_mtime > max_age:
                        p.unlink()
                except OSError:
                    pass
    except OSError:
        pass


# ---------------------------------------------------------------- reader state


def _pid_matches(pid: int, needle: str) -> bool:
    """Guard against stale pid files after PID reuse.

    /proc/<pid>/cmdline is NUL separated. If it cannot be read (no /proc,
    permissions) assume the pid is ours rather than declaring it dead.
    """
    try:
        raw = (Path("/proc") / str(pid) / "cmdline").read_bytes()
    except OSError:
        return True
    if not raw:
        return True
    return needle in raw.decode("utf-8", "replace")


def reader_pid() -> Optional[int]:
    try:
        pid = int(PID_FILE.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None
    if pid <= 0:
        return None
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return None
    except PermissionError:
        return pid
    except OSError:
        return None
    return pid if _pid_matches(pid, "rime_tts_reader") else None


def reader_running() -> bool:
    return reader_pid() is not None


def panel_pid() -> Optional[int]:
    try:
        pid = int(PANEL_PID.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None
    if pid <= 0:
        return None
    try:
        os.kill(pid, 0)
    except OSError:
        return None
    return pid if _pid_matches(pid, "rime_tts_panel") else None


def tray_pid() -> Optional[int]:
    try:
        pid = int(TRAY_PID.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None
    if pid <= 0:
        return None
    try:
        os.kill(pid, 0)
    except OSError:
        return None
    return pid if _pid_matches(pid, "rime_tts_tray") else None


# ---------------------------------------------------------------- Rime integration


def enabled_schemas(rime_dir: Optional[Path] = None) -> List[str]:
    rd = Path(rime_dir or RIME_DIR)
    for f in (rd / "default.custom.yaml", rd / "build" / "default.yaml"):
        try:
            text = f.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        found = re.findall(r"(?m)^\s*-\s*\{?\s*schema\s*:\s*([A-Za-z0-9_\-]+)", text)
        if found:
            return _unique(found)
    build = rd / "build"
    if build.is_dir():
        found = [p.name[: -len(".schema.yaml")] for p in build.glob("*.schema.yaml")]
        if found:
            return _unique(found)
    found = [p.name[: -len(".schema.yaml")] for p in rd.glob("*.schema.yaml")]
    return _unique(found)


def _unique(items: Iterable[str]) -> List[str]:
    out: List[str] = []
    for i in items:
        if i not in out:
            out.append(i)
    return out


def custom_yaml_files(rime_dir: Optional[Path] = None) -> List[Path]:
    rd = Path(rime_dir or RIME_DIR)
    try:
        return sorted(rd.glob("*.custom.yaml"))
    except OSError:
        return []


def patched_schemas(rime_dir: Optional[Path] = None) -> List[str]:
    out = []
    for p in custom_yaml_files(rime_dir):
        try:
            if "lua_processor@tts_reporter" in p.read_text(encoding="utf-8", errors="replace"):
                out.append(p.name[: -len(".custom.yaml")])
        except OSError:
            pass
    return out


def lua_installed(rime_dir: Optional[Path] = None) -> bool:
    p = Path(rime_dir or RIME_DIR) / "rime.lua"
    try:
        return p.is_file() and "tts_reporter" in p.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False


def deployed(rime_dir: Optional[Path] = None) -> bool:
    build = Path(rime_dir or RIME_DIR) / "build"
    if not build.is_dir():
        return False
    for p in build.glob("*.schema.yaml"):
        try:
            if "tts_reporter" in p.read_text(encoding="utf-8", errors="replace"):
                return True
        except OSError:
            pass
    return False


def rime_lua_source() -> Optional[Path]:
    """Where the installer keeps rime.lua (state/share) or the repo copy."""
    candidates = [
        HERE.parent / "rime" / "rime.lua",   # running from a git checkout
        SHARE_DIR / "rime.lua",              # installed layout
        HERE.parent / "share" / "rime.lua",  # alternative layout
    ]
    for p in candidates:
        if p.is_file():
            return p
    return None


def install_rime_lua(rime_dir: Optional[Path] = None) -> str:
    src = rime_lua_source()
    if src is None:
        return "找不到 rime.lua（请重新运行 install.sh）"
    dst = Path(rime_dir or RIME_DIR) / "rime.lua"
    try:
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)
        return f"已安装 rime.lua: {dst}"
    except OSError as exc:
        return f"复制 rime.lua 失败: {exc}"


def _drop_empty_old_block(lines: List[str]) -> List[str]:
    """After removing our entry, drop `engine/processors/+:` with an empty list."""
    out: List[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if re.match(r"^\s*" + re.escape(PROCESSOR_LINE) + r"\s*$", line):
            j = i + 1
            while j < len(lines) and (not lines[j].strip() or lines[j].lstrip().startswith("#")):
                j += 1
            if j >= len(lines) or not re.match(r"^\s*-\s", lines[j]):
                i += 1
                continue
        out.append(line)
        i += 1
    return out


def patch_file(path: Path) -> bool:
    """Add (or upgrade to) the @before 0 patch. Returns True if the file changed."""
    path = Path(path)
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        lines = ["patch:"]
    if any(re.match(r"^\s*" + re.escape(PATCH_KEY) + r'\s*:\s*"?lua_processor@tts_reporter"?\s*$', l) for l in lines):
        return False

    kept: List[str] = []
    for line in lines:
        if "rime-tts-readback" in line:
            continue
        if "lua_processor@tts_reporter" in line:
            continue
        kept.append(line)
    kept = _drop_empty_old_block(kept)

    out: List[str] = []
    inserted = False
    for line in kept:
        out.append(line)
        if not inserted and re.match(r"^patch:\s*$", line):
            out.append("  " + PATCH_BEGIN)
            out.append("  " + PATCH_LINE)
            out.append("  " + PATCH_END)
            inserted = True
    if not inserted:
        out.extend(["", "patch:", "  " + PATCH_BEGIN, "  " + PATCH_LINE, "  " + PATCH_END])
    _write_lines(path, out)
    return True


def unpatch_file(path: Path) -> bool:
    """Remove every trace of our patch. Returns True if the file changed."""
    path = Path(path)
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False
    if "lua_processor@tts_reporter" not in text and "rime-tts-readback" not in text:
        return False
    lines = [
        l for l in text.splitlines()
        if "rime-tts-readback" not in l and "lua_processor@tts_reporter" not in l
    ]
    _write_lines(path, _drop_empty_old_block(lines))
    return True


def _write_lines(path: Path, lines: List[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.replace(tmp, path)


# ---------------------------------------------------------------- autostart


def autostart_enabled() -> bool:
    return AUTOSTART_FILE.is_file()


def set_autostart(enabled: bool, exec_line: Optional[str] = None) -> bool:
    try:
        if enabled:
            line = exec_line or f"{desktop_quote(sys.executable)} {desktop_quote(str(HERE / 'rime-tts'))} start"
            AUTOSTART_FILE.parent.mkdir(parents=True, exist_ok=True)
            AUTOSTART_FILE.write_text(
                "[Desktop Entry]\n"
                "Type=Application\n"
                "Name=Rime 回读\n"
                "Comment=朗读 Rime 上屏的文字\n"
                f"Exec={line}\n"
                "Terminal=false\n"
                "X-GNOME-Autostart-enabled=true\n",
                encoding="utf-8",
            )
        else:
            AUTOSTART_FILE.unlink(missing_ok=True)
        return True
    except OSError:
        return False


def desktop_quote(value: str) -> str:
    """Quote one Exec argument for a .desktop file (not a shell command)."""
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("`", "\\`")
        .replace("$", "\\$")
    )
    return '"' + escaped + '"'


# ---------------------------------------------------------------- state snapshot


def snapshot() -> Dict[str, Any]:
    return {
        "version": APP_VERSION,
        "frontend": detect_frontend(),
        "rime_dir": str(RIME_DIR),
        "rime_dir_exists": RIME_DIR.is_dir(),
        "lua_installed": lua_installed(),
        "patched": patched_schemas(),
        "deployed": deployed(),
        "muted": OFF_FILE.exists(),
        "reader_running": reader_running(),
        "reader_pid": reader_pid(),
        "panel_running": panel_pid() is not None,
        "tray_running": tray_pid() is not None,
        "queue_count": queue_count(),
        "queue_dir": str(QUEUE_DIR),
        "autostart": autostart_enabled(),
        "config": str(CONFIG_FILE),
        "config_exists": CONFIG_FILE.is_file(),
    }


def headline(st: Optional[Dict[str, Any]] = None) -> str:
    st = st or snapshot()
    if not st["rime_dir_exists"]:
        return "未找到 Rime 目录"
    if not st["lua_installed"]:
        return "未部署"
    if st["muted"]:
        return "已静音"
    if st["reader_running"]:
        return "已启用"
    return "后台未运行"
