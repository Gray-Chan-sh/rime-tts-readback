# rime-tts-readback

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

---

## Requirements

- Windows 10 / 11
- Weasel (Rime for Windows) **with Lua support** — `lua_processor` / `rime.lua` must work
- A SAPI voice for the language you type (default target: `Microsoft Huihui Desktop`, zh-CN)
  - list voices: `Add-Type -AssemblyName System.Speech; (New-Object System.Speech.Synthesis.SpeechSynthesizer).GetInstalledVoices() | % { $_.VoiceInfo.Name }`
- PowerShell 5.1 (built in)

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

## Control panel (GUI)

`windows\RimeTtsReadback.bat` opens a WinForms control panel (no extra dependencies) that
does everything without editing files by hand:

- **Detect** — finds the Rime/Weasel install and version, the user directory, whether the
  readback integration is *installed* and *deployed*, whether the background reader is
  running, and whether it is muted.
- **部署到 Rime** — installs `rime.lua`, the scripts and the `lua_processor@tts_reporter`
  patch into every enabled schema, then redeploys Rime.
- **启用 / 禁用** — mute / unmute. Disabling also stops the reader and makes `rime.lua`
  stop writing (through the `Rime_tts_off` flag), so nothing accumulates.
- **删除回读功能** — removes the patches and `rime.lua` from Rime and redeploys.
- **仅重新部署** — runs a Rime redeploy on its own.
- **Parameters** — voice (picked from the installed SAPI voices, with a preview button),
  `Rate`, `BreakMs`, `IdleMs`, `MaxWaitMs`, `Threshold`, `PadMs`, `IncludeAscii`, saved to
  `%USERPROFILE%\Rime_tts_config.json`, which the reader loads on startup.
- **Tray icon** — a colour-coded dot in the notification area shows whether readback is
  available (green = available, orange = not ready, grey = disabled / not installed).
  Minimizing or closing the window hides it to the tray; click the icon to restore,
  right-click for 显示窗口 / 启用 / 禁用 / 退出.
- **Global hotkey** — `Ctrl+Alt+R` toggles readback on/off system-wide (configurable in the
  panel: `Ctrl`/`Alt`/`Shift`/`Win` + `A-Z`, `0-9`, `F1-F12`, `Space`).

Headless:

```
powershell -STA -File RimeTtsReadback.Gui.ps1 -Check   # print a detection report
powershell -STA -File RimeTtsReadback.Gui.ps1          # open the window
```

## Configuration

Edit the parameters at the top of `windows\Rime_tts_watcher.ps1`, then restart the watcher.
(With the GUI you just use the Parameters box; it writes `%USERPROFILE%\Rime_tts_config.json`
and restarts the reader.)

| Parameter | Default | Meaning |
|---|---|---|
| `-Voice` | `Microsoft Huihui Desktop` | SAPI voice |
| `-Rate` | `0` | speech rate, -10..10 (lower = each character longer) |
| `-BreakMs` | `30` | silence inserted between characters |
| `-IdleMs` | `60` | commits arriving within this window are merged into one utterance |
| `-MaxWaitMs` | `200` | never wait longer than this before speaking |
| `-Threshold` / `-PadMs` | `180` / `15` | silence detection threshold and padding |
| `-IncludeAscii` | `true` | also speak ASCII letters/digits |

The log lives at `%USERPROFILE%\Rime_tts_watcher.log`.

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
│  └─ make-icons.ps1                    # regenerates icons/ (GDI+, multi-size DIB)
└─ install.ps1
```

## Known limitations

- **ASCII / numbers typed in "direct" (ASCII) mode may not be spoken.** Rime does not
  emit a *commit* event for every pass-through keystroke, so nothing reaches the queue.
  Chinese candidates that are actually committed work reliably.
- Output is character-by-character by design (proof-reading aid), so a long sentence
  takes as long as it takes to say. It cannot be faster than speech.
- The design deliberately never spawns a process from inside the input method. An early
  version used `os.execute()` in the commit handler; that blocks the IME thread and can
  freeze the whole desktop. Do not put anything blocking in the Lua path.

## License

MIT — see [LICENSE](LICENSE).
