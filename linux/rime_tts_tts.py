#!/usr/bin/env python3
"""TTS back ends for the Linux reader and panel (standard library only).

Priority:
  1. speech-dispatcher (`spd-say`) - the normal desktop integration; the daemon
     keeps the audio device open, so per-utterance process startup is cheap.
  2. espeak-ng / espeak          - simple fallback that needs no daemon.

The reader keeps at most one utterance in flight and polls the child process,
so mute/stop still works while a sentence is being spoken.
"""

from __future__ import annotations

import re
import shutil
import subprocess
from typing import Any, Dict, List, Optional

from rime_tts_common import run

_CJK_RE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\u3040-\u30ff]")
_LANG_RE = re.compile(r"^[a-z]{2,3}([_-][A-Za-z]{2,4})?$", re.IGNORECASE)

_ENGINE: Optional[str] = None
_SPD_HELP: Optional[str] = None
_SPD_VOICES: Optional[str] = None
_SPD_READY: Optional[bool] = None


def has_cjk(text: str) -> bool:
    return bool(_CJK_RE.search(text))


def looks_like_language(value: str) -> bool:
    return bool(_LANG_RE.match(value.strip()))


def _spd_help() -> str:
    global _SPD_HELP
    if _SPD_HELP is None:
        rc, out, err = run(["spd-say", "--help"], timeout=5)
        _SPD_HELP = (out or "") + (err or "")
    return _SPD_HELP


def _spd_has(short: str, long: str) -> bool:
    help_text = _spd_help()
    return ("--" + long) in help_text or (short + ",") in help_text.replace(" ", "")


def spd_voice_list() -> str:
    """Output of `spd-say -L` (synthesis voices), cached.

    `spd-say -O` lists output *modules* (espeak-ng, ...), not voices; using it
    here would show a bogus one-line list. A successful `-L` also proves the
    speech-dispatcher daemon is reachable, which is what detect_engine needs.
    """
    global _SPD_VOICES, _SPD_READY
    if _SPD_VOICES is None:
        rc, out, _err = run(["spd-say", "-L"], timeout=8)
        _SPD_VOICES = out if rc == 0 else ""
        _SPD_READY = rc == 0
    return _SPD_VOICES


def spd_ready() -> bool:
    global _SPD_READY
    if _SPD_READY is None:
        spd_voice_list()
    return bool(_SPD_READY)


def detect_engine() -> str:
    global _ENGINE
    if _ENGINE is None:
        if shutil.which("spd-say") and spd_ready():
            _ENGINE = "spd-say"
        elif shutil.which("espeak-ng"):
            _ENGINE = "espeak-ng"
        elif shutil.which("espeak"):
            _ENGINE = "espeak"
        else:
            _ENGINE = ""
    return _ENGINE


def engine_summary() -> str:
    eng = detect_engine()
    if eng == "spd-say":
        return "speech-dispatcher (spd-say)"
    if eng:
        if shutil.which("spd-say"):
            return f"{eng}（speech-dispatcher 未运行，已回退）"
        return eng
    if shutil.which("spd-say"):
        return "speech-dispatcher 未运行，且未找到 espeak-ng"
    return "未找到 TTS 引擎（请安装 speech-dispatcher 或 espeak-ng）"


def _language_for(text: str, voice: str) -> str:
    """Voice wins when it looks like a language code; otherwise guess from text."""
    if voice and looks_like_language(voice):
        return voice.replace("_", "-")
    return "zh" if has_cjk(text) else "en"


def _spd_command(text: str, cfg: Dict[str, Any], wait: bool) -> List[str]:
    cmd = ["spd-say"]
    if wait:
        cmd.append("-w")

    rate = max(-100, min(100, int(cfg.get("Rate", 0)) * 10))
    cmd.extend(["-r", str(rate)])

    volume = max(0, min(100, int(cfg.get("Volume", 100))))
    if _spd_has("-i", "volume"):
        # spd-say takes -100..100 (0 = engine default). Config uses 0..100 with
        # 100 = engine default, so 0 really means silent.
        cmd.extend(["-i", str(volume - 100)])

    voice = str(cfg.get("Voice") or "").strip()
    if voice:
        if looks_like_language(voice):
            cmd.extend(["-l", _language_for(text, voice)])
        elif _spd_has("-y", "synthesis-voice"):
            cmd.extend(["-y", voice])
        else:
            cmd.extend(["-l", _language_for(text, "")])
    else:
        cmd.extend(["-l", _language_for(text, "")])

    cmd.append(text)
    return cmd


def _espeak_command(text: str, cfg: Dict[str, Any], exe: str) -> List[str]:
    rate = max(-10, min(10, int(cfg.get("Rate", 0))))
    speed = max(80, min(300, 175 + rate * 8))
    volume = max(0, min(100, int(cfg.get("Volume", 100))))
    voice = str(cfg.get("Voice") or "").strip()
    # The config may hold a speech-dispatcher name such as
    # "Chinese (Mandarin, latin as English)", which espeak cannot resolve.
    # Only pass short code-like names through; otherwise guess from the text.
    language = voice if looks_like_language(voice) else _language_for(text, "")
    return [exe, "-v", language, "-s", str(speed), "-a", str(volume), text]


def build_command(text: str, cfg: Dict[str, Any], wait: bool = True) -> Optional[List[str]]:
    if not text.strip():
        return None
    eng = detect_engine()
    if eng == "spd-say":
        return _spd_command(text, cfg, wait)
    if eng in ("espeak-ng", "espeak"):
        return _espeak_command(text, cfg, eng)
    return None


def stop_command() -> Optional[List[str]]:
    """Ask the engine to stop the current utterance, if it has such a command."""
    if detect_engine() == "spd-say" and shutil.which("spd-say"):
        return ["spd-say", "-S"]
    return None


def speak_once(text: str, cfg: Dict[str, Any]) -> bool:
    """Speak synchronously (panel preview / about dialog)."""
    cmd = build_command(text, cfg, wait=True)
    if not cmd:
        return False
    try:
        p = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        return p.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


# ---------------------------------------------------------------- voices


def _parse_spd_voices(output: str) -> List[Dict[str, str]]:
    voices: List[Dict[str, str]] = []
    for line in output.splitlines():
        raw = line.rstrip()
        if not raw.strip():
            continue
        low = raw.strip().lower()
        if low.startswith(("name", "voice", "language", "list of")):
            continue
        parts = re.split(r"\t+|\s{2,}", raw.strip())
        if len(parts) < 2:
            parts = raw.split()
        if len(parts) < 2:
            continue
        name = parts[0].strip()
        language = parts[1].strip()
        # Some versions print an index first ("1  Tingting  zh").
        if name.isdigit() and len(parts) >= 3:
            name = parts[1].strip()
            language = parts[2].strip()
        if not name:
            continue
        voices.append({
            "name": name,
            "language": language,
            "display": f"{name}  -  {language}",
            "source": "speech-dispatcher",
        })
    return voices


def _parse_espeak_voices(output: str) -> List[Dict[str, str]]:
    voices: List[Dict[str, str]] = []
    for line in output.splitlines():
        raw = line.rstrip()
        if not raw.strip() or raw.lstrip().startswith("Pty"):
            continue
        parts = raw.split()
        if len(parts) < 4:
            continue
        language = parts[1]
        # VoiceName may contain spaces, so use the language code and the last
        # column (file name) as usable values; both work with `-v`.
        file_name = parts[4] if len(parts) >= 5 else language
        title = " ".join(parts[3:4]) or file_name
        voices.append({
            "name": language,
            "language": language,
            "display": f"{title}  -  {language}",
            "source": "espeak",
        })
    return voices


def list_voices(include_variants: bool = False) -> List[Dict[str, str]]:
    """Installed voices, one entry per language/voice by default.

    speech-dispatcher + espeak-ng reports thousands of `Name+Variant` rows
    (13k on a stock Ubuntu), which is unusable in a drop-down. The rows without
    `+` are the base voices and are what `-y` expects, so keep those; a voice
    stored in the config is preserved by the panel even when filtered out.
    """
    voices: List[Dict[str, str]] = []
    if shutil.which("spd-say"):
        output = spd_voice_list()
        if output:
            voices = _parse_spd_voices(output)
            if not include_variants:
                base = [v for v in voices if "+" not in v["name"]]
                if base:
                    voices = base
    if not voices:
        exe = "espeak-ng" if shutil.which("espeak-ng") else ("espeak" if shutil.which("espeak") else "")
        if exe:
            rc, out, err = run([exe, "--voices"], timeout=10)
            if rc == 0:
                voices = _parse_espeak_voices(out)
    seen = set()
    unique = []
    for v in voices:
        if v["name"] in seen:
            continue
        seen.add(v["name"])
        unique.append(v)
    return unique


def resolve_voice(cfg: Dict[str, Any]) -> str:
    voice = str(cfg.get("Voice") or "").strip()
    if voice:
        return voice
    return "(自动：中文/英文)"


# ---------------------------------------------------------------- reader speaker


class Speaker:
    """At most one child TTS process in flight; polled by the reader loop."""

    def __init__(self, cfg: Dict[str, Any], logger, fake: bool = False):
        self.cfg = cfg
        self.log = logger
        self.fake = fake
        self.proc: Optional[subprocess.Popen] = None
        self.pending = ""

    def update_config(self, cfg: Dict[str, Any]) -> None:
        self.cfg = cfg

    def busy(self) -> bool:
        return self.proc is not None or bool(self.pending)

    def feed(self, text: str) -> None:
        if not text:
            return
        self.pending += text
        self._pump()

    def _pump(self) -> None:
        if self.proc is not None or not self.pending:
            return
        text, self.pending = self.pending, ""
        if self.fake:
            self.log(f"fake-speak [{text}] chars={len(text)}")
            return
        cmd = build_command(text, self.cfg, wait=True)
        if not cmd:
            self.log("no TTS engine; install speech-dispatcher or espeak-ng")
            return
        try:
            self.proc = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError as exc:
            self.log(f"TTS启动失败: {exc}")
            self.proc = None

    def tick(self) -> None:
        if self.proc is None:
            self._pump()
            return
        rc = self.proc.poll()
        if rc is None:
            return
        if rc != 0:
            self.log(f"TTS进程退出 code={rc}")
        self.proc = None
        self._pump()

    def stop(self) -> None:
        had_work = self.proc is not None or bool(self.pending)
        self.pending = ""
        proc, self.proc = self.proc, None
        if proc is not None and proc.poll() is None:
            try:
                proc.terminate()
                proc.wait(timeout=1.0)
            except (OSError, subprocess.TimeoutExpired):
                try:
                    proc.kill()
                except OSError:
                    pass
        if not had_work:
            return
        cmd = stop_command()
        if cmd:
            try:
                subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
            except (OSError, subprocess.SubprocessError):
                pass
