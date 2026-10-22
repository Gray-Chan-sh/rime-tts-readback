# rime-tts-readback

**English** ｜ [简体中文](README.md)

Read back what you **commit** in Rime, character by character, using Windows TTS —
**without** ever reading the pre-edit code shown in the candidate window.

Type `cfgf` with the Wubi input method and the candidate window stays silent; the moment
you commit and `对于` lands in the document, it is spoken one character at a time.

Built and tested on **Weasel / 小狼毫 0.17.4** (librime 1.13.1) with a Chinese SAPI voice
(`Microsoft Huihui Desktop`).

On macOS it runs on **Squirrel / 鼠须管** with the system voice (`Tingting`) — see
[macos/README.md](macos/README.md). On Linux it supports **fcitx5-rime / ibus-rime /
fcitx4-rime** with speech-dispatcher or espeak-ng — see [linux/README.md](linux/README.md).
All three share the same Lua reporter and the same `config.json` semantics; only the reader
and the control panel are written per platform.

## Platforms

| Platform | Status | Notes |
|---|---|---|
| Windows 10/11 (Weasel / 小狼毫) | ✅ implemented and tested | this document |
| macOS 13+ (Squirrel / 鼠须管) | ✅ implemented and tested | [macos/README.md](macos/README.md) |
| Linux (fcitx5-rime / ibus-rime / fcitx4-rime) | ✅ implemented (verified in WSL; tray/hotkey need X11) | [linux/README.md](linux/README.md) |

Architecture, queue protocol, config keys and the **platform parity checklist**:
[DEVELOPING.md](DEVELOPING.md).

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

> The diagram shows the Windows path. The macOS build shares the first half (`rime.lua` →
> queue file) and replaces the second half with a resident `AVSpeechSynthesizer`: there is no
> SAPI padding and no `SoundPlayer`, so no WAV rendering, silence trimming or peak
> normalisation is needed. See [macos/README.md](macos/README.md). The Linux build also shares
> the queue and speaks through `spd-say` / `espeak-ng`; see [linux/README.md](linux/README.md).

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
- Other Rime front ends: `rime/rime.lua` is already cross-platform (it uses `HOME` and the
  right path separator).
  - **Squirrel / 鼠须管**: the reader and control panel live in
    [macos/](macos/README.md).
  - **ibus-rime / fcitx5-rime / fcitx4-rime**: the Rime user directory is auto-detected (or
    set `RIME_USER_DIR`); reader, control panel, tray and global hotkey live in
    [linux/README.md](linux/README.md).

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

### macOS

- **macOS 13+** with **Squirrel 1.x** (the official build already bundles `librime-lua`; no
  plugin build required).
- **Xcode Command Line Tools** (`xcode-select --install`) — only to compile the two Swift
  binaries; no Xcode needed at runtime.
- Voice: the built-in `Tingting` (zh-CN); `rime-tts voices` lists them all.
- Self-check: `rime-tts check`. Full guide: [macos/README.md](macos/README.md).

### Linux

- **Python 3.8+** (standard library only); the control panel needs Tk (`python3-tk` on
  Debian/Ubuntu, `python3-tkinter` on Fedora).
- A Rime front end **with librime-lua**: fcitx5-rime, ibus-rime or fcitx4-rime.
- **TTS**: `speech-dispatcher` (`spd-say`) is preferred, with `espeak-ng` / `espeak` as the
  fallback. On Debian/Ubuntu:

  ```sh
  sudo apt install speech-dispatcher espeak-ng python3-tk
  ```

- Optional: `wmctrl` (list running programs in the panel), `notify-send` (tray notifications),
  `xdotool` or `xprop` (app filter / foreground window).
- **X11** is required for the tray (GTK3 `StatusIcon`) and the global hotkey. On Wayland the
  tray may not show, the hotkey is skipped and the app filter has no effect (reading continues);
  everything else still works.
- Self-check: `rime-tts check`. Full guide: [linux/README.md](linux/README.md).

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
     "engine/processors/@before 0": "lua_processor@tts_reporter"
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

### macOS

```sh
cd macos
./install.sh --patch --menubar   # build + install + patch schemas + start + open the control panel
rime-tts reload                  # or Squirrel menu -> 重新部署
```

`install.sh` installs into `~/.rime-tts-readback/` (binaries, config, log), copies `rime.lua`
into `~/Library/Rime/` and creates `~/Library/Rime/tts_queue/`. Without `--patch`, the
**部署到 Rime** button in the control panel does the same.
Details: [macos/README.md](macos/README.md).

### Linux

```sh
cd linux
./install.sh --patch --tray    # install + patch schemas + start reader + tray icon
```

`install.sh` installs into `~/.rime-tts-readback/`, auto-detects the fcitx5-rime / ibus-rime /
fcitx4-rime user directory (or use `--rime-dir` / `RIME_USER_DIR`), copies `rime.lua` there and
creates `tts_queue/`. Common flags: `--patch`, `--no-start`, `--tray`, `--panel`,
`--autostart`, `--prefix`. Skip `--patch` if you prefer to click **安装 / 接管** in the panel.
Details: [linux/README.md](linux/README.md).

### Prebuilt packages (Releases)

Download from [Releases](https://github.com/Gray-Chan-sh/rime-tts-readback/releases):

| Platform | File | How to run |
|---|---|---|
| Windows | `RimeTtsReadback-<version>.exe` | Double-click |
| macOS | `rime-tts-readback-<version>.dmg` | Drag to Applications, open, menu bar icon -> Deploy |
| Linux | `rime-tts-readback-<version>-x86_64.AppImage` | `chmod +x`, then double-click (or `./...AppImage`) |
| Fallback | `...-macos.zip` / `...-linux.tar.gz` | Extract and run `./install.sh` |

The macOS build is Apple Silicon (arm64) and not notarized; right-click -> Open the first
time if Gatekeeper blocks it. The Linux AppImage bundles Python and Tk; audio still uses the
system `spd-say` or `espeak-ng`. Checksums are in `SHA256SUMS.txt` on the release.

---

## Usage

| Action | Command |
|---|---|
| Mute / unmute instantly (watcher keeps running) | `Rime_tts_off.bat` / `Rime_tts_on.bat` |
| Stop / start the background watcher | `Rime_tts_stop.bat` / `Rime_tts_start.bat` |
| Auto-start at logon | put a shortcut to `Rime_tts_start.bat` in `shell:startup` |
| Remove completely | `Rime_tts_stop.bat`, delete `%APPDATA%\Rime\rime.lua`, drop the `lua_processor@tts_reporter` lines, redeploy |

On macOS the equivalents are `rime-tts off/on/stop/start`, the **登录时自动启动** item and
`uninstall.sh`.
On Linux they are the same `rime-tts off/on/stop/start`, plus `panel` (control panel), `tray`,
`autostart on/off` and `shutdown` (stops tray, panel and reader in one go).

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
  `ReadDigits`, `ReadEnglish`, saved to `%USERPROFILE%\Rime_tts_config.json`; the reader
  hot-reloads it (~1 s, no restart needed).
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

### macOS control panel

The macOS build has a native panel with the same jobs: `rime-tts panel`, or
**打开控制面板…** in the menu bar item.

- Detect, one-click install, deploy to Rime, mute, start/stop the reader, remove, redeploy;
- voice (with preview), rate, volume, grouping window, max wait, plus three toggles:
  char-by-char, read digits, read English;
- program filter: all / only these / except these, picked from the running applications
  with icons (stored as bundle ids);
- launch at login, global hotkey `⌃⌥R` (registered with Carbon, no Accessibility permission
  needed), open log/config, about;
- every change is written to `config.json` and hot-reloaded by the reader within ~1 s.

Closing the window just goes back to the menu bar (the Dock icon appears while it is open and
disappears again on close); the reader, the hotkey and the menu bar keep working.
The panel is part of the same binary (`main.swift` + `RimeTtsMenuBar.swift` +
`RimeTtsPanel.swift` + `RimeTtsModel.swift`).
There are no `Threshold` / `PadMs` / `BreakMs` controls: those belong to the Windows WAV
rendering path, and macOS feeds `AVSpeechUtterance` directly.

### Linux control panel and tray

`rime-tts panel` opens the Tk control panel; `rime-tts tray` starts the GTK3 tray icon (both are
subcommands of `rime-tts`, and after installing you can also launch **Rime 回读** from the
application menu):

- detect, install / take over, redeploy, mute, start/stop the reader, remove, clear the queue,
  open the Rime directory;
- voice picker with preview, rate, volume, grouping window, max wait, char-by-char, read digits,
  read English;
- program filter (all / only / except) with a one-click list of currently running window classes
  (X11 + `wmctrl`);
- launch at login and an X11 global mute hotkey (default `ctrl+alt+r`);
- open log/config, check report, about;
- every change is written to `config.json` and hot-reloaded by the reader within ~1 s.

The tray menu has open panel, mute, reader toggle, preview, redeploy, clear queue, open
log/config, about and quit. GNOME 3.26+ does not show legacy tray icons by default; use the panel
or install an AppIndicator extension. Under Wayland, `Gtk.StatusIcon`, `XGrabKey` and window-class
enumeration are unavailable and degrade independently: the panel still works, and mute remains
available through `rime-tts on/off` or the `tts_off` flag.

## Configuration

Edit the parameters at the top of `windows\Rime_tts_watcher.ps1`, then restart the watcher.
(With the GUI you just use the Parameters box; it writes `%USERPROFILE%\Rime_tts_config.json`
and the reader hot-reloads it.)

| Parameter | Default | Meaning |
|---|---|---|
| `-Voice` | `Microsoft Huihui Desktop` | SAPI voice |
| `-Rate` | `0` | speech rate, -10..10 (lower = each character longer) |
| `-IdleMs` | `60` | commits arriving within this window are merged into one utterance |
| `-MaxWaitMs` | `200` | never wait longer than this before speaking |
| `-Threshold` / `-PadMs` | `180` / `15` | silence detection threshold and padding |
| `-Volume` | `100` | 0..200, affects this app only; the peak is normalised to 90% first (≈2.4× louder than raw SAPI), >100 clips |
| `-CharByChar` | `false` | `true` = per-character (characters separated by a comma pause, ~0.4 s each, slower); `false` = whole phrase |
| `-ReadDigits` | `true` | speak ASCII digits (one by one); when off, digits are skipped only |
| `-ReadEnglish` | `true` | speak ASCII letters (spelled out); when off, letters are skipped only |
| `-IncludeAscii` | `true` | legacy master switch; used as the default for `-ReadDigits` / `-ReadEnglish` when those are not given |
| `-AppFilterMode` / `-AppFilterList` | `all` / empty | program filter: `all` / `only` / `except` |

macOS and Linux read the same `config.json` (same keys: `Voice`, `Rate`, `IdleMs`, `MaxWaitMs`,
`Volume`, `CharByChar`, `ReadDigits`, `ReadEnglish`, `AppFilterMode`, `AppFilterList`, `HotKey`) at
`~/.rime-tts-readback/config.json`. Writes also include the compatibility key
`IncludeAscii = ReadDigits && ReadEnglish` so older readers keep working; when reading an older
config without the two new keys they fall back to `IncludeAscii`.

The log lives at `%USERPROFILE%\Rime_tts_watcher.log` (rotated at 1 MB); on Linux/macOS it is
`~/.rime-tts-readback/watcher.log`.

## Layout

```
rime-tts-readback/
├─ rime/
│  ├─ rime.lua                          # commit_notifier -> queue file (shared by Windows/macOS)
│  ├─ wubi86.custom.yaml.example        # example schema patch
│  └─ wubi_pinyin.custom.yaml.example
├─ windows/                             # Windows implementation
│  ├─ RimeTtsReadback.Gui.ps1           # WinForms control panel
│  ├─ RimeTtsReadback.bat               # launcher for the GUI
│  ├─ Rime_tts_watcher.ps1              # resident low-latency watcher / speaker
│  ├─ Rime_tts_start.bat / Rime_tts_stop.bat
│  ├─ Rime_tts_stop.ps1
│  └─ Rime_tts_off.bat / Rime_tts_on.bat
├─ macos/                               # macOS implementation (Squirrel)
│  ├─ RimeTtsWatcher.swift              # resident reader (AVSpeechSynthesizer)
│  ├─ main.swift                        # entry point
│  ├─ RimeTtsMenuBar.swift              # menu bar item + deploy/remove + panel actions
│  ├─ RimeTtsPanel.swift                # control panel window (AppKit)
│  ├─ RimeTtsModel.swift                # state snapshot + config.json I/O
│  ├─ rime-tts                          # command line
│  ├─ build.sh / install.sh / uninstall.sh
│  └─ README.md
├─ linux/                               # Linux implementation (fcitx5-rime / ibus-rime / fcitx4-rime)
│  ├─ rime_tts_common.py                # paths, config, queue, patch, autostart
│  ├─ rime_tts_text.py                  # text filtering / digit & letter spelling
│  ├─ rime_tts_tts.py                   # speech-dispatcher / espeak-ng back ends
│  ├─ rime_tts_reader.py                # resident reader
│  ├─ rime_tts_panel.py                 # Tk control panel
│  ├─ rime_tts_tray.py                  # optional GTK3 tray
│  ├─ rime_tts_hotkey.py                # X11 global hotkey
│  ├─ rime_tts_control.py               # actions shared by CLI / panel / tray
│  ├─ rime-tts                          # command line entry point
│  ├─ install.sh / uninstall.sh
│  ├─ tests/                            # unittest (config, patch, text, queue)
│  └─ README.md
├─ icons/
│  ├─ rime-tts-readback.ico             # app icon (sound waves + keyboard)
│  ├─ rime-tts-readback.png             # Linux panel / application menu
│  ├─ tray-ok.ico / tray-warn.ico / tray-off.ico
│  └─ tray-ok.png / tray-warn.png / tray-off.png
├─ tools/
│  ├─ make-icons.ps1                    # regenerates icons/ (GDI+, multi-size DIB)
│  ├─ build-release.ps1                 # portable zip  -> dist/rime-tts-readback-<v>.zip
│  └─ build-exe.ps1                     # single-file exe -> dist/RimeTtsReadback-<v>.exe
├─ .github/workflows/build.yml          # CI: Windows zip/exe, macOS compile, Linux tests
├─ install.ps1 / uninstall.ps1
├─ DEVELOPING.md                        # architecture, queue protocol, parity checklist
└─ README.md / README.en.md
```

## Known limitations

- **Only text that is *committed* through Rime is spoken** (bare digits are the one
  exception, see below). Text typed directly (ASCII pass-through, or apps that bypass
  the IME) does not emit a commit event, so it never reaches the queue and is not read.
  This is by design — it is exactly what keeps the candidate window's pre-edit letters
  silent.
- **Bare digits** (0-9 typed while not composing) are reported directly by `rime.lua`:
  Rime rejects them and the front end inserts them, so no commit event fires. The
  processor sits first in `engine/processors` and still lets the key through, so typing
  and candidate selection are unchanged. Digits are read **one by one** (`12` → "one, two",
  never "twelve"), separated by a short space and spoken slightly faster; a burst of digits
  is merged into one utterance first so it does not hold up the next Chinese text. Letters
  typed in Squirrel's ASCII mode are reported the same way and **spelled out letter by
  letter** (`abc` → a b c, `abc123` → a b c 1 2 3). Letters typed with the system ABC
  layout are still invisible to the input method and are not read.
- Output is character-by-character by design (proof-reading aid), so a long sentence
  takes as long as it takes to say. It cannot be faster than speech.
- The design deliberately never spawns a process from inside the input method. An early
  version used `os.execute()` in the commit handler; that blocks the IME thread and can
  freeze the whole desktop. Do not put anything blocking in the Lua path.
- The program filter uses the foreground window, so switching apps extremely fast can very
  occasionally misjudge.
- **Do not use SSML `<break>` with Chinese text.** SAPI's Chinese engine has a bug: a `<break>`
  inside Chinese text makes it repeat the last syllable ("作为" → "作为为"), regardless of the
  break time. That is why the per-character mode uses a **comma** for the pause instead.
- On macOS the engine is different: `Rate` / `Volume` do not map to SAPI's numbers, so tune by
  ear (试听). `say(1)` costs ~0.8–1.4 s per invocation (measured), which is why the reader keeps
  a resident `AVSpeechSynthesizer`; use `rime-tts start` if you kill it. The two macOS binaries
  are compiled locally and **unsigned** — fine for personal use, code signing + notarisation
  needed to distribute them.
- On Linux the tray relies on GTK3 `Gtk.StatusIcon` (legacy tray). GNOME 3.26+ hides it by
  default; install an AppIndicator extension or use `rime-tts panel`.
- On Linux the global hotkey and the app filter require **X11**. Under Wayland the hotkey is
  skipped and the foreground program cannot be identified (so no filtering is applied and reading
  continues); mute still works via `rime-tts on/off`, the panel or the `tts_off` flag.
- On Linux speech goes through `spd-say` or `espeak-ng`; voices/rates depend on the installed
  engine and do not map to SAPI / `AVSpeechSynthesizer` numbers. Tune with the panel's preview.
- `pip`/virtualenvs work, but the installer only needs the system `python3`; without Tk the panel
  is unavailable while the CLI and reader keep working.

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
- macOS: `macos/build.sh` compiles the two Swift binaries with `swiftc` (Xcode command line
  tools required). They are unsigned, shipped as source and built locally.

CI: `.github/workflows/build.yml` builds the Windows zip + exe on every push to `main`, compiles
the macOS binaries on `macos-14`, runs Linux `py_compile`, unit tests plus CLI/install smoke tests
on `ubuntu-latest`, uploads the artifacts, and — for `v*` tags — attaches the Windows assets to
the GitHub release.

## License

MIT — see [LICENSE](LICENSE).
