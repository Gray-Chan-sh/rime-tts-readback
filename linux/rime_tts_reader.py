#!/usr/bin/env python3
"""rime-tts-reader - speak the text Rime commits (Linux).

Watches <Rime user dir>/tts_queue for the little files written by rime.lua,
groups a burst into one utterance, and speaks it through speech-dispatcher or
espeak-ng. Candidate/preedit text is never involved.

Run:    rime-tts-reader [options]     (see --help)
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import signal
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import rime_tts_common as c
import rime_tts_text as textmod
import rime_tts_tts as tts
from rime_tts_hotkey import X11HotKey, parse_hotkey

try:  # Unix only; the pure text/config modules still work elsewhere for tests.
    import fcntl
except ImportError:  # pragma: no cover
    fcntl = None

APP_VERSION = c.APP_VERSION


# ---------------------------------------------------------------- logging


class Logger:
    MAX_BYTES = 1_048_576

    def __init__(self, path: Path, quiet: bool = False):
        self.path = Path(path)
        self.quiet = quiet
        self._rotate_at_start()

    def _rotate_at_start(self) -> None:
        try:
            if self.path.exists() and self.path.stat().st_size > self.MAX_BYTES:
                self._rotate()
        except OSError:
            pass

    def _rotate(self) -> None:
        backup = self.path.with_name(self.path.name + ".1")
        try:
            backup.unlink(missing_ok=True)
            self.path.replace(backup)
        except OSError:
            pass

    def __call__(self, message: str) -> None:
        line = time.strftime("%H:%M:%S") + (".%03d " % (int(time.time() * 1000) % 1000)) + message + "\n"
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self.path.open("a", encoding="utf-8") as fh:
                fh.write(line)
            if self.path.stat().st_size > self.MAX_BYTES:
                self._rotate()
        except OSError:
            pass
        if not self.quiet:
            try:
                sys.stderr.write(line)
                sys.stderr.flush()
            except OSError:
                pass


# ---------------------------------------------------------------- options


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="rime-tts-reader",
        description="speak the text Rime commits (Linux)",
        add_help=True,
    )
    p.add_argument("--voice", help="voice name or language code (empty = auto)")
    p.add_argument("--rate", type=int, help="-10..10, lower reads each character longer")
    p.add_argument("--idle-ms", type=int, help="group commits arriving this close together")
    p.add_argument("--max-wait-ms", type=int, help="never wait longer than this before speaking")
    p.add_argument("--volume", type=int, help="0..100")
    p.add_argument("--char-by-char", action="store_true", default=None,
                   help="separate characters with a comma pause")
    p.add_argument("--no-char-by-char", dest="char_by_char", action="store_false",
                   help="force continuous reading")
    p.add_argument("--no-ascii", action="store_true", help="do not read ASCII letters or digits")
    p.add_argument("--no-digits", action="store_true", help="do not read digits")
    p.add_argument("--no-english", action="store_true", help="do not read ASCII letters")
    p.add_argument("--only-apps", help="comma separated window classes: read only in these")
    p.add_argument("--except-apps", help="comma separated window classes: do not read in these")
    p.add_argument("--hotkey", help='global mute toggle, e.g. "ctrl+alt+r" (X11)')
    p.add_argument("--queue", help="queue directory")
    p.add_argument("--off-file", help="mute flag path")
    p.add_argument("--config", help="JSON config, hot reloaded")
    p.add_argument("--log", help="log file")
    p.add_argument("--pid", help="pid file")
    p.add_argument("--run-seconds", type=float, default=0.0, help="exit after n seconds (testing)")
    p.add_argument("--fake", action="store_true", help="do not make any sound, just log")
    p.add_argument("--quiet", action="store_true", help="do not copy log lines to stderr")
    p.add_argument("--list-voices", action="store_true", help="print installed voices and exit")
    p.add_argument("--check", action="store_true", help="print a detection report and exit")
    return p


def cli_overrides(args: argparse.Namespace) -> Dict[str, Any]:
    ov: Dict[str, Any] = {}
    if args.voice is not None:
        ov["Voice"] = args.voice
    if args.rate is not None:
        ov["Rate"] = args.rate
    if args.idle_ms is not None:
        ov["IdleMs"] = args.idle_ms
    if args.max_wait_ms is not None:
        ov["MaxWaitMs"] = args.max_wait_ms
    if args.volume is not None:
        ov["Volume"] = args.volume
    if args.char_by_char is not None:
        ov["CharByChar"] = bool(args.char_by_char)
    if args.no_ascii:
        ov["ReadDigits"] = False
        ov["ReadEnglish"] = False
    if args.no_digits:
        ov["ReadDigits"] = False
    if args.no_english:
        ov["ReadEnglish"] = False
    if args.only_apps is not None:
        ov["AppFilterMode"] = "only"
        ov["AppFilterList"] = _split_list(args.only_apps)
    if args.except_apps is not None:
        ov["AppFilterMode"] = "except"
        ov["AppFilterList"] = _split_list(args.except_apps)
    if args.hotkey is not None:
        ov["HotKey"] = args.hotkey.strip()
    return ov


def _split_list(value: str) -> List[str]:
    return [x.strip() for x in re.split(r"[,;]", value) if x.strip()]


def merged_config(config_path: Path, overrides: Dict[str, Any]) -> Dict[str, Any]:
    cfg = c.load_config(config_path)
    for key, value in overrides.items():
        cfg[key] = value
    cfg["Rate"] = max(-10, min(10, int(cfg["Rate"])))
    cfg["IdleMs"] = max(0, min(5000, int(cfg["IdleMs"])))
    cfg["MaxWaitMs"] = max(0, min(10000, int(cfg["MaxWaitMs"])))
    cfg["Volume"] = max(0, min(100, int(cfg["Volume"])))
    return cfg


# ---------------------------------------------------------------- helpers


def pending_files(queue_dir: Path) -> List[Path]:
    return c.queue_files(queue_dir)


def drain_queue(queue_dir: Path) -> int:
    return c.clear_queue(queue_dir)


def drain_off(queue_dir: Path) -> int:
    return c.clear_queue(queue_dir)


def frontmost_app() -> Tuple[str, str]:
    """(window class, window title) on X11; ("","") on Wayland/unknown."""
    if c.is_wayland():
        return "", ""
    if shutil.which("xdotool"):
        rc, out, _ = c.run(["xdotool", "getactivewindow", "getwindowclassname"], timeout=2)
        if rc == 0 and out.strip():
            cls = out.strip()
            rc2, name, _ = c.run(["xdotool", "getactivewindow", "getwindowname"], timeout=2)
            return cls, (name.strip() if rc2 == 0 else cls)
    if shutil.which("xprop"):
        rc, out, _ = c.run(["xprop", "-root", "-notype", "_NET_ACTIVE_WINDOW"], timeout=2)
        if rc == 0:
            m = re.search(r"0x[0-9a-fA-F]+", out)
            if m:
                wid = m.group(0)
                rc2, cls_out, _ = c.run(["xprop", "-id", wid, "-notype", "WM_CLASS"], timeout=2)
                names = re.findall(r'"([^"]*)"', cls_out)
                if names:
                    return names[-1], names[0]
    return "", ""


def app_allowed(app: Tuple[str, str], cfg: Dict[str, Any]) -> bool:
    mode = str(cfg.get("AppFilterMode") or "all")
    if mode == "all":
        return True
    if not app[0] and not app[1]:
        return True
    wanted = set()
    for item in cfg.get("AppFilterList") or []:
        value = str(item).strip().lower()
        if value.endswith(".exe"):
            value = value[:-4]
        if value:
            wanted.add(value)
    if not wanted:
        return True
    candidates = {app[0].lower(), app[1].lower()}
    if app[1].lower().endswith(".app"):
        candidates.add(app[1][:-4].lower())
    hit = bool(candidates & wanted)
    return hit if mode == "only" else not hit


def toggle_mute(off_file: Path, log) -> None:
    try:
        if off_file.exists():
            off_file.unlink()
            log("快捷键：已取消静音")
        else:
            off_file.parent.mkdir(parents=True, exist_ok=True)
            off_file.write_text("1", encoding="utf-8")
            log("快捷键：已静音")
    except OSError as exc:
        log(f"快捷键切换静音失败: {exc}")


# ---------------------------------------------------------------- lock


def acquire_lock(pid_file: Path):
    pid_file.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(pid_file), os.O_CREAT | os.O_RDWR, 0o644)
    if fcntl is not None:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            return None
    os.ftruncate(fd, 0)
    os.write(fd, str(os.getpid()).encode("ascii"))
    return fd


# ---------------------------------------------------------------- check


def describe_check(cfg: Dict[str, Any]) -> None:
    print(f"version      : {APP_VERSION} (Linux)")
    st = c.snapshot()
    print(f"frontend     : {st['frontend']}")
    print(f"Rime user dir: {st['rime_dir']}  (exists={st['rime_dir_exists']})")
    print(f"rime.lua     : {'present' if st['lua_installed'] else 'absent'}")
    print(f"queue dir    : {st['queue_dir']}  (exists={Path(st['queue_dir']).is_dir()})")
    print(f"patched      : {', '.join(st['patched']) if st['patched'] else 'none'}")
    print(f"deployed     : {st['deployed']}")
    print(f"muted        : {st['muted']}")
    print(f"watcher      : {'running (pid %s)' % st['reader_pid'] if st['reader_running'] else 'stopped'}")
    print(f"autostart    : {st['autostart']}")
    print(f"config       : {st['config']}  ({'present' if st['config_exists'] else 'none'})")
    print(f"engine       : {tts.engine_summary()}")
    print(f"voice        : {tts.resolve_voice(cfg)}")
    print(f"read digits  : {cfg['ReadDigits']}")
    print(f"read english : {cfg['ReadEnglish']}")


# ---------------------------------------------------------------- main


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)

    queue_dir = Path(args.queue).expanduser() if args.queue else c.QUEUE_DIR
    off_file = Path(args.off_file).expanduser() if args.off_file else c.OFF_FILE
    config_path = Path(args.config).expanduser() if args.config else c.CONFIG_FILE
    log_path = Path(args.log).expanduser() if args.log else c.LOG_FILE
    pid_file = Path(args.pid).expanduser() if args.pid else c.PID_FILE

    overrides = cli_overrides(args)
    cfg = merged_config(config_path, overrides)

    if args.list_voices:
        for v in tts.list_voices():
            print(f"{v['language']:<10} {v['name']:<28} {v['display']}")
        return 0
    if args.check:
        describe_check(cfg)
        return 0

    log = Logger(log_path, quiet=args.quiet)
    speaker = tts.Speaker(cfg, log, fake=args.fake)
    off_file.parent.mkdir(parents=True, exist_ok=True)
    queue_dir.mkdir(parents=True, exist_ok=True)

    lock_fd = acquire_lock(pid_file)
    if lock_fd is None:
        sys.stderr.write("rime-tts-reader: already running\n")
        return 0

    stop = {"flag": False}

    def on_signal(signum, _frame):
        log(f"stopping (signal {signum})")
        stop["flag"] = True

    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            signal.signal(sig, on_signal)
        except (OSError, ValueError):
            pass
    try:
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
    except (AttributeError, OSError, ValueError):
        pass

    # Stale queue from a previous run (including half-written .tmp files).
    drain_off(queue_dir)
    c.sweep_tmp(queue_dir, max_age=0)

    hotkey_spec = str(cfg.get("HotKey") or "").strip()
    hotkey: Optional[X11HotKey] = None

    def start_hotkey(spec: str) -> Optional[X11HotKey]:
        if not spec or parse_hotkey(spec) is None:
            return None
        hk = X11HotKey(spec, lambda: toggle_mute(off_file, log), log)
        hk.start()
        return hk

    hotkey = start_hotkey(hotkey_spec)
    log(
        f"watcher started v{APP_VERSION} queue={queue_dir} engine={tts.engine_summary()} "
        f"voice={tts.resolve_voice(cfg)} rate={cfg['Rate']} charByChar={cfg['CharByChar']} "
        f"digits={cfg['ReadDigits']} english={cfg['ReadEnglish']} vol={cfg['Volume']} "
        f"idle={cfg['IdleMs']}ms appFilter={cfg['AppFilterMode']} [{','.join(cfg['AppFilterList'])}] "
        f"hotkey={hotkey_spec or '-'}"
    )

    buffer = ""
    since: Optional[float] = None
    last_add: Optional[float] = None
    batch_app: Tuple[str, str] = ("", "")
    last_sweep = time.monotonic()
    last_cfg_check = time.monotonic()
    cfg_mtime = _mtime(config_path)
    started = time.monotonic()

    try:
        while not stop["flag"]:
            now = time.monotonic()
            if args.run_seconds and now - started > args.run_seconds:
                log("run-seconds reached, exiting")
                break

            if now - last_cfg_check >= 1.0:
                last_cfg_check = now
                stamp = _mtime(config_path)
                if stamp != cfg_mtime:
                    cfg_mtime = stamp
                    cfg = merged_config(config_path, overrides)
                    speaker.update_config(cfg)
                    new_hotkey = str(cfg.get("HotKey") or "").strip()
                    if new_hotkey != hotkey_spec:
                        if hotkey is not None:
                            hotkey.stop()
                        hotkey_spec = new_hotkey
                        hotkey = start_hotkey(hotkey_spec)
                    log(
                        f"config reloaded: voice={tts.resolve_voice(cfg)} rate={cfg['Rate']} "
                        f"charByChar={cfg['CharByChar']} digits={cfg['ReadDigits']} "
                        f"english={cfg['ReadEnglish']} vol={cfg['Volume']} idle={cfg['IdleMs']}ms "
                        f"appFilter={cfg['AppFilterMode']} [{','.join(cfg['AppFilterList'])}]"
                    )

            if off_file.exists():
                drain_off(queue_dir)
                buffer = ""
                since = None
                last_add = None
                batch_app = ("", "")
                speaker.stop()
                time.sleep(0.1)
                continue

            if now - last_sweep > 60:
                last_sweep = now
                c.sweep_tmp(queue_dir, max_age=300)

            files = pending_files(queue_dir)
            if files:
                if since is None:
                    since = now
                    batch_app = frontmost_app()
                for f in files:
                    try:
                        text = f.read_text(encoding="utf-8", errors="replace")
                    except OSError:
                        text = ""
                    try:
                        f.unlink()
                    except OSError:
                        pass
                    buffer += text
                last_add = now

            if buffer:
                quiet_ms = (now - last_add) * 1000 if last_add else 9999.0
                waited_ms = (now - since) * 1000 if since else 0.0
                ascii_batch = textmod.ascii_only(buffer)
                idle = cfg["IdleMs"] + (200 if ascii_batch else 0)
                max_wait = max(cfg["MaxWaitMs"], 1200) if ascii_batch else cfg["MaxWaitMs"]
                if quiet_ms >= idle or waited_ms >= max_wait:
                    raw, app = buffer, batch_app
                    buffer = ""
                    since = None
                    last_add = None
                    batch_app = ("", "")
                    readable = textmod.readable_chars(raw, cfg["ReadDigits"], cfg["ReadEnglish"])
                    if readable:
                        if app_allowed(app, cfg):
                            log(f"read [{readable}] app=[{app[0]}/{app[1]}]")
                            speaker.feed(textmod.build_body(readable, cfg["CharByChar"]))
                        else:
                            log(f"skip (app filter '{cfg['AppFilterMode']}') app=[{app[0]}/{app[1]}] text=[{readable}]")

            speaker.tick()
            time.sleep(0.02)
    finally:
        if hotkey is not None:
            hotkey.stop()
        speaker.stop()
        try:
            pid_file.unlink(missing_ok=True)
        except OSError:
            pass
        try:
            os.close(lock_fd)
        except OSError:
            pass
    return 0


def _mtime(path: Path) -> float:
    try:
        return path.stat().st_mtime
    except OSError:
        return 0.0


if __name__ == "__main__":
    sys.exit(main())
