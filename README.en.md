# rime-tts-readback

**English** ｜ [简体中文](README.md)

Read back what you **commit** in Rime, character by character, using Windows TTS —
**without** ever reading the pre-edit code shown in the candidate window.

Type `cfgf` with the Wubi input method and the candidate window stays silent; the moment
you commit and `对于` lands in the document, it is spoken one character at a time.

Built and tested on **Weasel / 小狼毫 0.17.4** (librime 1.13.1) with a Chinese SAPI voice
(`Microsoft Huihui Desktop`).

---

## Why not just use a screen reader?

Screen readers (NVDA, Narrator) read the composition string and the candidate window too,
so every keystroke of `c f g f` is announced. This project only listens to Rime's
**commit** event, so only finished, on-screen text is spoken.

## How it works

```
       guess / pre-edit (cfgf)              candidate window  ── never spoken
                 │
        [ you pick a candidate ]
                 │
   rime.lua  commit_notifier ──► writes one small file per commit
                 │               (%USERPROFILE%\Rime_tts_queue\*.txt)
                 │               pure file write: no process spawn, never blocks the IME
                 ▼
   Rime_tts_watcher.ps1 (resident, hidden)
                 │
                 ├─ synthesize the text to a WAV (SSML, ~20 ms)
                 ├─ trim SAPI's leading/trailing silence
                 └─ play the trimmed WAV with SoundPlayer  → audio starts immediately
```

### The latency trick

The Windows SAPI default-audio path looks slow, but it is not:

| Output path | 1 character |
|---|---|
| Synthesize to a WAV file | **~20 ms** |
| Output to NULL | ~3 ms |
| Output to the default audio device | ~950 ms |

That ~950 ms is mostly **silence**: SAPI pads every utterance with roughly 0.45 s of
silence at each end (a one-character WAV is ~0.9 s long). So we synthesize to a WAV,
strip the silence, and play it ourselves. Time-to-audio drops from about a second to
~0.1–0.3 s, and no time is wasted on silence.

SAPI's output is also quiet — its peak is only ~38% of full scale — so the reader
**normalises the peak to 90%** before playing: about **2.4× louder** than raw SAPI at the
default volume, with no clipping.

---

## Requirements

### Tested with

| Component | Version |
|---|---|
| Windows | Windows 11 Pro, build 26300, x64 |
| PowerShell | Windows PowerShell 5.1 (Desktop) |
| .NET Framework | 4.8 |
| Weasel (小狼毫) | 0.17.4 |
| librime | 1.13.1 |
| SAPI voice | `Microsoft Huihui Desktop` (zh-CN) |

### Windows

- **Windows 10 / 11**, x64 recommended. (Windows 8.1 should work — PowerShell 5.1 and
  .NET Framework 4.x are available — but it is untested.)
- **Windows PowerShell 5.1** (built into Windows 10/11). The runtime scripts (control panel and
  reader) are written for, and only tested on, 5.1 — do not run them with PowerShell 7. The
  build scripts in `tools/` do run under `pwsh` (that is what CI uses).
- **.NET Framework 4.x** — the GUI uses WinForms and the reader uses `System.Speech` (SAPI)
  plus `System.Media.SoundPlayer`. This is .NET **Framework**, not .NET Core / .NET 5+.

### Rime

- A Rime front end **with Lua support** (librime-lua): `lua_processor` / `rime.lua` must work.
  - Verified with **Weasel 0.17.4 / librime 1.13.1**. Older builds were not tested one by one.
  - Quick check: the install directory's `rime.dll` contains the string `lua_processor`.
- Other Rime front ends (Squirrel, ibus-rime, fcitx5-rime): `rime/rime.lua` works after a small
  path tweak (`HOME` + the platform separator), but the reader and the control panel are
  Windows-only.

### Voice

- Any installed **SAPI voice**. For Chinese the default target is `Microsoft Huihui Desktop`
  (zh-CN), which ships with Simplified Chinese Windows; pick another one in the panel
  (试听 / Preview) if needed.

  ```
  Add-Type -AssemblyName System.Speech
  (New-Object System.Speech.Synthesis.SpeechSynthesizer).GetInstalledVoices() |
      % { $_.VoiceInfo.Name }
  ```

### Self-check

```
powershell -STA -File RimeTtsReadback.Gui.ps1 -Check
```

prints the app version, the detected Rime install, the enabled schemas, whether the integration
is installed/deployed, whether the reader is running, the autostart state and the available
voices. The panel's **刷新检测 (Refresh)** button reports the same facts.

> There are no `PSVersion` / framework guards in the code — whether it runs depends on the
> environment.

---

## Install

1. Copy the Lua side into your Rime user directory (`%APPDATA%\Rime\`):

   ```
   rime\rime.lua   ->   %APPDATA%\Rime\rime.lua
   ```

2. Attach the reporter to the schemas you use. Add to each `*.custom.yaml`
   (see `rime\wubi86.custom.yaml.example`):

   ```yaml
   patch:
     engine/processors/+:
       - lua_processor@tts_reporter
   ```

3. Copy the Windows side to a stable location (example: `%USERPROFILE%`):

   ```
   windows\*  ->  C:\Users\<you>\
   ```

4. **Redeploy** Rime (tray icon → Redeploy / 重新部署).

5. Start the watcher:

   ```
   windows\Rime_tts_start.bat
   ```

`install.ps1` automates steps 1, 3 and 5 (it does not edit your schemas for you).

---

## Usage

| Action | Command |
|---|---|
| Mute / unmute instantly (watcher keeps running) | `Rime_tts_off.bat` / `Rime_tts_on.bat` |
| Stop / start the background watcher | `Rime_tts_stop.bat` / `Rime_tts_start.bat` |
| Auto-start at logon | put a shortcut to `Rime_tts_start.bat` in `shell:startup` |
| Remove completely | `Rime_tts_stop.bat`, delete `%APPDATA%\Rime\rime.lua`, drop the `lua_processor@tts_reporter` lines, redeploy |

## Uninstall

```
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

Stops the reader, removes the schema patches and `rime.lua`, redeploys Rime, deletes the
autostart entry and the scripts / icons / config / queue / logs under `%USERPROFILE%`.
The repository folder is left untouched.

## Control panel (GUI)

`windows\RimeTtsReadback.bat` opens a WinForms control panel (no extra dependencies) that
does everything without editing files by hand:

- **Detect** — finds the Rime/Weasel install and version, the user directory, whether the
  readback integration is *installed* and *deployed*, whether the background reader is
  running, and whether it is muted.
- **部署到 Rime** — installs `rime.lua`, the scripts and the `lua_processor@tts_reporter`
  patch into every enabled schema, then redeploys Rime.
- **启用 / 禁用** (one toggle button) — mute / unmute. Disabling also stops the reader and
  makes `rime.lua` stop writing (through the `Rime_tts_off` flag), so nothing accumulates.
- **删除回读功能** — removes the patches and `rime.lua` from Rime and redeploys.
- **仅重新部署** — runs a Rime redeploy on its own.
- **Parameters** — voice (picked from the installed SAPI voices, with a preview button),
  `Rate`, `BreakMs`, `IdleMs`, `MaxWaitMs`, `Threshold`, `PadMs`, `Volume`, `CharByChar`,
  `IncludeAscii`, saved to `%USERPROFILE%\Rime_tts_config.json`; the reader hot-reloads it
  (~1 s, no restart needed).
- **Tray icon** — a colour-coded dot in the notification area shows whether readback is
  available (green = available, orange = not ready, grey = disabled / not installed).
  Minimizing or closing the window hides it to the tray; click the icon to restore,
  right-click for 显示窗口 / 启用 / 禁用 / 退出.
  (On Windows 11 a new tray icon may start in the hidden-icons overflow — pin it via
  设置 → 个性化 → 任务栏 → 其他系统托盘图标.)
- **Global hotkey** — `Ctrl+Alt+R` toggles readback on/off system-wide. The capture dialog
  lets you press the keys directly and reports conflicts in real time.
- **Tooltips** — every label, button and field has a balloon tooltip explaining what it does.
- **One-click install** — 部署 + 启用 (+ autostart) in one button.
- **Program filter** — read everywhere (default), or only in listed programs, or everywhere
  except listed programs. The picker lists only programs with a visible window, with icons.
- **Volume / char-by-char** — per-app volume (does not touch the system volume) and a
  toggle between character-by-character and whole-phrase reading.
- **Autostart & watchdog** — optional start-at-logon (tray) and auto-restart of the reader
  if it stops (rate-limited).
- **Single instance** — a second launch shows a notice and exits, so you never end up with
  a duplicate tray icon or a hotkey conflict.
- **About / version** — version, install paths, current hotkey and the repository link.

Headless:

```
powershell -STA -File RimeTtsReadback.Gui.ps1 -Check   # print a detection report
powershell -STA -File RimeTtsReadback.Gui.ps1          # open the window
```

## Configuration

Edit the parameters at the top of `windows\Rime_tts_watcher.ps1`, then restart the watcher.
(With the GUI you just use the Parameters box; it writes `%USERPROFILE%\Rime_tts_config.json`
and the reader hot-reloads it.)

| Parameter | Default | Meaning |
|---|---|---|
| `-Voice` | `Microsoft Huihui Desktop` | SAPI voice |
| `-Rate` | `0` | speech rate, -10..10 (lower = each character longer) |
| `-BreakMs` | `30` | silence inserted between characters (char-by-char mode) |
| `-IdleMs` | `60` | commits arriving within this window are merged into one utterance |
| `-MaxWaitMs` | `200` | never wait longer than this before speaking |
| `-Threshold` / `-PadMs` | `180` / `15` | silence detection threshold and padding |
| `-Volume` | `100` | 0..200, affects this app only; the peak is normalised to 90% first (≈2.4× louder than raw SAPI), >100 clips |
| `-CharByChar` | `true` | per-character reading; `false` = whole phrase |
| `-IncludeAscii` | `true` | also speak ASCII letters/digits |
| `-AppFilterMode` / `-AppFilterList` | `all` / empty | program filter: `all` / `only` / `except` |

The log lives at `%USERPROFILE%\Rime_tts_watcher.log` (rotated at 1 MB).

## Layout

```
rime-tts-readback/
├─ rime/
│  ├─ rime.lua                          # commit_notifier -> queue file (goes to %APPDATA%\Rime)
│  ├─ wubi86.custom.yaml.example        # example schema patch
│  └─ wubi_pinyin.custom.yaml.example
├─ windows/
│  ├─ RimeTtsReadback.Gui.ps1           # WinForms control panel
│  ├─ RimeTtsReadback.bat               # launcher for the GUI
│  ├─ Rime_tts_watcher.ps1              # resident low-latency watcher / speaker
│  ├─ Rime_tts_start.bat / Rime_tts_stop.bat
│  ├─ Rime_tts_stop.ps1
│  └─ Rime_tts_off.bat / Rime_tts_on.bat
├─ icons/
│  ├─ rime-tts-readback.ico             # app icon (sound waves + keyboard)
│  ├─ tray-ok.ico / tray-warn.ico / tray-off.ico
├─ tools/
│  ├─ make-icons.ps1                    # regenerates icons/ (GDI+, multi-size DIB)
│  ├─ build-release.ps1                 # portable zip  -> dist/rime-tts-readback-<v>.zip
│  └─ build-exe.ps1                     # single-file exe -> dist/RimeTtsReadback-<v>.exe
├─ .github/workflows/build.yml          # CI: builds zip + exe, publishes release assets
├─ install.ps1
└─ uninstall.ps1
```

## Known limitations

- **Only text that is *committed* through Rime is spoken.** Text typed directly (ASCII
  pass-through, or apps that bypass the IME) does not emit a commit event, so it never
  reaches the queue and is not read. This is by design — it is exactly what keeps the
  candidate window's pre-edit letters silent.
- Output is character-by-character by design (proof-reading aid), so a long sentence
  takes as long as it takes to say. It cannot be faster than speech.
- The design deliberately never spawns a process from inside the input method. An early
  version used `os.execute()` in the commit handler; that blocks the IME thread and can
  freeze the whole desktop. Do not put anything blocking in the Lua path.
- The program filter uses the foreground window, so switching apps extremely fast can very
  occasionally misjudge.

## Build & release

```
powershell -ExecutionPolicy Bypass -File tools\build-release.ps1   # dist\rime-tts-readback-<v>.zip
powershell -ExecutionPolicy Bypass -File tools\build-exe.ps1       # dist\RimeTtsReadback-<v>.exe
```

- `build-release.ps1` packs the whole project into a zip (portable scripts, no installer).
- `build-exe.ps1` packs everything into a **single self-extracting .exe**, compiled with the
  `csc.exe` that ships with Windows (no downloads). On run it extracts to
  `%LOCALAPPDATA%\RimeTtsReadback\<version>\` (only when the version/content changes) and
  launches the control panel; command-line arguments are forwarded to the GUI script.

CI: `.github/workflows/build.yml` builds both on every push to `main`, uploads them as
artifacts, and — for `v*` tags — attaches them to the GitHub release.

## License

MIT — see [LICENSE](LICENSE).
