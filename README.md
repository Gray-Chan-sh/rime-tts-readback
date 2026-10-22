# rime-tts-readback

[English](README.en.md) ｜ **简体中文**

逐字朗读你在 Rime 里**上屏**的内容，使用 Windows 自带语音（TTS）——
**绝不朗读**候选窗里显示的编码。

用五笔输入 `cfgf` 时候选框保持安静；当你选字上屏、`对于` 落到文档里，才会被逐字读出。

在 **小狼毫 / Weasel 0.17.4**（librime 1.13.1）上开发与验证，中文语音使用
`Microsoft Huihui Desktop`。

macOS 上用**鼠须管 Squirrel** + 系统语音（`Tingting`），见 [macos/README.md](macos/README.md)。
Linux 上支持 **fcitx5-rime / ibus-rime / fcitx4-rime**，用 speech-dispatcher 或 espeak-ng 朗读，
见 [linux/README.md](linux/README.md)。三端共用同一个 Lua 上报层与同一份 `config.json` 语义，
只有「朗读器」和「控制面板」按平台各写一份。

## 平台支持

| 平台 | 状态 | 说明 |
|---|---|---|
| Windows 10/11（小狼毫 Weasel） | ✅ 已实现并验证 | 本文档 |
| macOS 13+（鼠须管 Squirrel） | ✅ 已实现并验证 | [macos/README.md](macos/README.md) |
| Linux（fcitx5-rime / ibus-rime / fcitx4-rime） | ✅ 已实现（WSL Ubuntu 验证；托盘/快捷键需 X11） | [linux/README.md](linux/README.md) |

跨平台架构、队列协议、配置键和**平台对齐清单**见 [DEVELOPING.md](DEVELOPING.md)。

---

## 为什么不用现成的读屏软件？

读屏软件（NVDA、讲述人）会连**输入编码**和候选窗一起读，于是每敲一下 `c f g f` 都被念出来。
本项目只监听 Rime 的**上屏(commit)**事件，所以只有最终落到屏幕上的文字才会被朗读。

## 工作原理

```
       编码 / 预编辑 (cfgf)              候选窗  ── 从不朗读
                 │
        [ 你选字上屏 ]
                 │
   rime.lua  commit_notifier ──► 每次上屏写一个小文件
                 │               (%USERPROFILE%\Rime_tts_queue\*.txt)
                 │               纯文件写入：不起进程、不阻塞输入法
                 ▼
   Rime_tts_watcher.ps1（常驻、隐藏）
                 │
                 ├─ 把文字合成成 WAV（SSML，约 20ms）
                 ├─ 裁掉 SAPI 首尾的静音
                 └─ 用 SoundPlayer 播放裁剪后的 WAV  → 立即出声
```

> 上图是 Windows 的链路。macOS 版共用前半段（`rime.lua` → 队列文件），后半段换成常驻的
> `AVSpeechSynthesizer`：没有 SAPI 的前后静音，也没有 `SoundPlayer`，因此**不需要**合成 WAV、
> 裁静音、归一化。细节见 [macos/README.md](macos/README.md)。

### 低延迟的关键

Windows SAPI 的"默认音频输出"看起来慢，其实不然：

| 输出方式 | 1 个字 |
|---|---|
| 合成到 WAV 文件 | **约 20ms** |
| 输出到 NULL | 约 3ms |
| 输出到默认音频设备 | 约 950ms |

那 ~950ms 几乎全是**静音**：SAPI 会在每句话前后各塞约 0.45 秒静音（一个字的 WAV 约 0.9 秒长）。
所以我们自己合成成 WAV、裁掉静音、再播放。出声延迟从约 1 秒降到 **0.1–0.3 秒**，也不浪费时间播静音。

另外，SAPI 的输出**本身很轻**（峰值只有满刻度的约 38%），所以后台会**先把语音峰值归一化到 90%** 再播放：
默认音量下就比原始 SAPI 响约 **2.4 倍**，且不产生削波。

---

## 系统要求

### 实测环境

| 项目 | 版本 |
|---|---|
| Windows | Windows 11 专业版，build 26300，x64 |
| PowerShell | Windows PowerShell 5.1 (Desktop) |
| .NET Framework | 4.8 |
| 小狼毫 Weasel | 0.17.4 |
| librime | 1.13.1 |
| SAPI 语音 | `Microsoft Huihui Desktop` (zh-CN) |

### Windows

- **Windows 10 / 11**，推荐 x64。（Win 8.1 理论可行——有 PowerShell 5.1 和 .NET Framework 4.x——但未验证。）
- **Windows PowerShell 5.1**（Win10/11 自带）。运行时脚本（控制面板与朗读器）是按 5.1 写、且只在 5.1 上验证的——**不要用 PowerShell 7 运行**。`tools/` 里的构建脚本在 `pwsh` 下也能跑（CI 就是用它）。
- **.NET Framework 4.x**——界面用 WinForms，朗读用 `System.Speech`(SAPI) + `System.Media.SoundPlayer`。依赖的是 .NET **Framework**，不是 .NET Core / .NET 5+。

### Rime

- 需要**带 lua 插件（librime-lua）**的 Rime 前端：`lua_processor` / `rime.lua` 必须能用。
  - 已用 **Weasel 0.17.4 / librime 1.13.1** 验证；更早版本未逐个测试。
  - 快速自检：安装目录的 `rime.dll` 里含 `lua_processor` 字样。
- 其它前端：`rime/rime.lua` 已经是跨平台的（自动使用 `HOME` 与正确的路径分隔符）。
  - **鼠须管 Squirrel**：朗读器 + 控制面板见 [macos/README.md](macos/README.md)。
  - **ibus-rime / fcitx5-rime / fcitx4-rime**：自动探测 Rime 用户目录（也可用 `RIME_USER_DIR`
    指定），朗读器、控制面板、托盘与全局快捷键见 [linux/README.md](linux/README.md)。

### 语音

- 任意已安装的 **SAPI 语音**。中文默认使用 `Microsoft Huihui Desktop`（zh-CN，简体中文 Windows 自带）；
  没有的话可在面板里换一个（"试听"可验证）。

  ```
  Add-Type -AssemblyName System.Speech
  (New-Object System.Speech.Synthesis.SpeechSynthesizer).GetInstalledVoices() |
      % { $_.VoiceInfo.Name }
  ```

### 自检

```
powershell -STA -File RimeTtsReadback.Gui.ps1 -Check
```

会打印：程序版本、检测到的 Rime 安装、已启用方案、是否已安装/已部署、后台是否在运行、开机自启状态、可用语音。
面板上的「刷新检测」按钮给出同样的信息。

> 代码里没有 `PSVersion` / 框架的硬性检查——能不能跑取决于实际环境。

### macOS

- **macOS 13 及以上**，鼠须管 **Squirrel 1.x**（官方包内置 `librime-lua`，无需自己编译插件）。
- **Xcode Command Line Tools**（`xcode-select --install`）——只在构建时用来跑 `swiftc`，日常运行不需要 Xcode。
- 语音用系统自带的 `Tingting`（zh-CN），`rime-tts voices` 可列出全部可用语音。
- 自检：`rime-tts check`。完整说明见 [macos/README.md](macos/README.md)。

### Linux

- **Python 3.8+**（只用标准库）；控制面板需要 Tk（Debian/Ubuntu 的 `python3-tk`，
  Fedora 的 `python3-tkinter`）。
- **带 librime-lua 的前端**：fcitx5-rime、ibus-rime 或 fcitx4-rime。
- **TTS**：优先 `speech-dispatcher`（`spd-say`，桌面集成最好），否则回退 `espeak-ng` / `espeak`。
  Debian/Ubuntu：

  ```sh
  sudo apt install speech-dispatcher espeak-ng python3-tk
  ```

- **可选**：`wmctrl`（面板里列举运行中的程序）、`notify-send`（托盘操作气泡）、
  `xdotool` 或 `xprop`（程序筛选与前台窗口判断）。
- **X11**：托盘（GTK3 `StatusIcon`）与全局快捷键需要 X11。Wayland 下会降级：
  托盘可能不显示、快捷键跳过、程序筛选不生效（照常朗读），其余功能不受影响。
- 自检：`rime-tts check`。完整说明见 [linux/README.md](linux/README.md)。

---

## 安装

1. 把 Lua 部分复制到 Rime 用户目录（`%APPDATA%\Rime\`）：

   ```
   rime\rime.lua   ->   %APPDATA%\Rime\rime.lua
   ```

2. 把你使用的方案挂上"报告器"。在每个 `*.custom.yaml` 里加上（参考 `rime\wubi86.custom.yaml.example`）：

   ```yaml
   patch:
     "engine/processors/@before 0": "lua_processor@tts_reporter"
   ```

3. 把 Windows 部分复制到一个固定位置（例如 `%USERPROFILE%`）：

   ```
   windows\*  ->  C:\Users\<你>\
   ```

4. **重新部署** Rime（托盘图标 → 重新部署）。

5. 启动朗读器：

   ```
   windows\Rime_tts_start.bat
   ```

`install.ps1` 可自动完成第 1、3、5 步（它不会替你改方案补丁）。

### macOS

```sh
cd macos
./install.sh --patch --menubar   # 编译 + 安装 + 打补丁 + 启动后台 + 打开控制面板
rime-tts reload                  # 或菜单栏「ㄓ」→ 重新部署
```

`install.sh` 会装到 `~/.rime-tts-readback/`（可执行文件、配置、日志），把 `rime.lua` 放进
`~/Library/Rime/`，并建好 `~/Library/Rime/tts_queue/`。不想用 `--patch` 的话，控制面板里的
「部署到 Rime」按钮做同样的事。详见 [macos/README.md](macos/README.md)。

### Linux

```sh
cd linux
./install.sh --patch --tray    # 安装 + 打补丁 + 启动后台 + 托盘图标
```

`install.sh` 会装到 `~/.rime-tts-readback/`，自动探测 fcitx5-rime / ibus-rime / fcitx4-rime 的
用户目录（也可 `--rime-dir` 或 `RIME_USER_DIR` 指定），把 `rime.lua` 放进去并建好 `tts_queue/`。
常用选项：`--patch`、`--no-start`、`--tray`、`--panel`、`--autostart`、`--prefix`。
不放心自动打补丁就不加 `--patch`，之后在面板里点「安装 / 接管」。详见 [linux/README.md](linux/README.md)。

---

## 用法

| 操作 | 命令 |
|---|---|
| 立即静音 / 恢复（后台继续运行） | `Rime_tts_off.bat` / `Rime_tts_on.bat` |
| 停止 / 启动后台朗读 | `Rime_tts_stop.bat` / `Rime_tts_start.bat` |
| 开机自启 | 把 `Rime_tts_start.bat` 的快捷方式放进 `shell:startup` |
| 彻底移除 | `Rime_tts_stop.bat`，删除 `%APPDATA%\Rime\rime.lua`，去掉 `lua_processor@tts_reporter` 那几行，再重新部署 |

macOS 上对应的是 `rime-tts off/on/stop/start`、菜单栏图标里的「开机自启」和 `uninstall.sh`。
Linux 上同样是 `rime-tts off/on/stop/start`，另加 `panel`（控制面板）、`tray`（托盘）、
`autostart on/off` 与 `shutdown`（一次停掉托盘/面板/朗读器）。

## 卸载

```
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

停止朗读器、移除方案补丁与 `rime.lua`、重新部署 Rime、删除自启项，以及 `%USERPROFILE%` 下的
脚本 / 图标 / 配置 / 队列 / 日志。仓库目录本身不受影响。

## 控制面板（GUI）

`windows\RimeTtsReadback.bat` 打开一个 WinForms 控制面板（无额外依赖），不用手改文件：

- **检测**——找到 Rime/小狼毫 的安装与版本、用户目录、回读功能是否*已安装*/*已部署*、后台是否在运行、是否静音。
- **部署到 Rime**——安装 `rime.lua` 与脚本，给所有已启用方案加上 `lua_processor@tts_reporter` 补丁，然后重新部署。
- **启用 / 禁用**（同一个按钮）——静音 / 取消静音；禁用时还会停止后台，并让 `rime.lua` 停止写入（通过 `Rime_tts_off` 标志），不会堆积。
- **删除回读功能**——从 Rime 移除补丁与 `rime.lua`，并重新部署。
- **仅重新部署**——只跑一次 Rime 重新部署。
- **参数**——语音（从已装 SAPI 语音中选择，带试听）、`Rate`、`BreakMs`、`IdleMs`、`MaxWaitMs`、`Threshold`、`PadMs`、`Volume`、`CharByChar`、`ReadDigits`、`ReadEnglish`，保存到 `%USERPROFILE%\Rime_tts_config.json`；后台会**热加载**（约 1 秒内生效，无需重启）。
- **托盘图标**——通知栏的彩色圆点表示回读是否可用（绿=可用，橙=未就绪，灰=已禁用/未安装）。最小化或关闭窗口会缩到托盘；单击图标恢复，右键菜单为 显示窗口 / 启用 / 禁用 / 退出。（Win11 上新图标可能先在"隐藏的图标"里，可在 设置 → 个性化 → 任务栏 → 其他系统托盘图标 里固定。）
- **全局快捷键**——`Ctrl+Alt+R` 在任意程序里切换启用/禁用。设置时会弹出**按键捕获对话框**：直接按组合键即可，并实时报告是否被占用。
- **气泡提示**——每个标签、按钮、输入项都有气泡说明。
- **一键安装**——一个按钮完成 部署 + 启用（+ 自启）。
- **程序筛选**——默认全部程序都读；也可"仅在这些程序中读"或"除这些程序外都读"；选择列表只列**有可见窗口的程序**，并带图标。
- **音量 / 逐字**——程序内音量（不动系统音量），以及"逐字朗读 / 整句连读"开关。
- **开机自启 & 看门狗**——可选开机以托盘方式启动；后台意外停止时自动重启（限流）。
- **单实例**——重复启动只弹提示并退出，不会出现两个托盘图标或快捷键冲突。
- **关于 / 版本**——版本、安装路径、当前快捷键，以及仓库链接（可点击 / 可复制）。

无界面用法：

```
powershell -STA -File RimeTtsReadback.Gui.ps1 -Check   # 打印检测报告
powershell -STA -File RimeTtsReadback.Gui.ps1          # 打开窗口
```

### macOS 控制面板

macOS 版有一个功能对应的原生面板：`rime-tts panel`，或点菜单栏图标里的「打开控制面板…」。

- 状态检测、一键安装、部署到 Rime、静音、停止/启动后台、删除回读、仅重新部署；
- 语音（带试听）、语速、音量、合并窗口、最长等待，以及逐字朗读 / 朗读数字 / 朗读英文三个开关；
- 程序筛选：全部 / 仅这些 / 除这些，可从正在运行的程序里带图标勾选（存 bundle id）；
- 登录自启、全局快捷键 `⌃⌥R`（Carbon 注册，不需要辅助功能权限）、打开日志/配置、关于；
- 改参数即写 `config.json`，朗读器约 1 秒内热加载。

窗口关掉就退回菜单栏，后台朗读和快捷键不受影响。面板和菜单栏是同一个程序
（`main.swift` + `RimeTtsMenuBar.swift` + `RimeTtsPanel.swift` + `RimeTtsModel.swift` 编译而成）。
macOS 不需要 Windows 那套 WAV 裁剪参数，所以面板里没有 `Threshold` / `PadMs` / `BreakMs`。

### Linux 控制面板与托盘

`rime-tts panel` 打开 Tk 控制面板，`rime-tts tray` 启动 GTK3 托盘（两者都只是
`rime-tts` 的子命令，装好后也可以从应用菜单「Rime 回读」打开）：

- 状态检测、安装 / 接管、重新部署、静音、启动/停止后台、移除集成、清空队列、打开 Rime 目录；
- 语音下拉 + 试听、语速、音量、合并窗口、最长等待、逐字朗读、朗读数字、朗读英文；
- 程序筛选：全部 / 仅这些 / 除这些，可一键加入当前运行中的窗口类（需要 X11 + `wmctrl`）；
- 登录自启，以及 X11 全局静音快捷键（默认 `ctrl+alt+r`）；
- 打开日志 / 配置、检查报告、关于；
- 改参数即写 `config.json`，朗读器约 1 秒内热加载。

托盘菜单包含打开面板、静音、后台开关、试听、重新部署、清空队列、打开日志/配置、关于与退出。
GNOME 3.26+ 默认不显示传统托盘图标；此时仍可用面板，或安装 AppIndicator 扩展。
Wayland 下 `Gtk.StatusIcon`、`XGrabKey` 与窗口类枚举都不可用，会分别降级（不崩溃）：
面板照常工作，静音可用 `rime-tts on/off` 或 `tts_off` 标志。

## 配置

可以直接改 `windows\Rime_tts_watcher.ps1` 顶部的参数，然后重启朗读器。
（用 GUI 更方便：在"参数"里改，它会写入 `%USERPROFILE%\Rime_tts_config.json`，后台会热加载。）

| 参数 | 默认 | 含义 |
|---|---|---|
| `-Voice` | `Microsoft Huihui Desktop` | SAPI 语音 |
| `-Rate` | `0` | 语速 -10..10（越小每个字读得越长越清晰） |
| `-IdleMs` | `60` | 这段时间内到达的上屏会合并成一次朗读 |
| `-MaxWaitMs` | `200` | 最多等这么久就开读 |
| `-Threshold` / `-PadMs` | `180` / `15` | 静音判定阈值与保留边距 |
| `-Volume` | `100` | 音量 0..200（只影响本程序）。后台会先把语音峰值归一化到 90%，所以 100 就比原始 SAPI 响约 2.4 倍；>100 会削波 |
| `-CharByChar` | `false` | `true` = 逐字（字间用逗号停顿，约 0.4 秒/字，更慢但便于核对）；`false` = 整句连读 |
| `-ReadDigits` | `true` | 朗读 ASCII 数字（逐位）；关闭后只跳过数字 |
| `-ReadEnglish` | `true` | 朗读 ASCII 字母（逐字母）；关闭后只跳过字母 |
| `-IncludeAscii` | `true` | 旧版总开关；未显式给出 `-ReadDigits` / `-ReadEnglish` 时作为它们的默认值 |
| `-AppFilterMode` / `-AppFilterList` | `all` / 空 | 程序筛选：`all` / `only` / `except` |

macOS 与 Linux 读同一个 `config.json`（键名相同：`Voice`、`Rate`、`IdleMs`、`MaxWaitMs`、
`Volume`、`CharByChar`、`ReadDigits`、`ReadEnglish`、`AppFilterMode`、`AppFilterList`、`HotKey`），
路径都是 `~/.rime-tts-readback/config.json`。
写入时仍会附带兼容键 `IncludeAscii = ReadDigits && ReadEnglish`，旧版朗读器也能继续工作；
读取旧配置时若没有 `ReadDigits` / `ReadEnglish`，则回退到 `IncludeAscii`。

日志位于 `%USERPROFILE%\Rime_tts_watcher.log`（超过 1 MB 自动轮转）；macOS 与 Linux 都是
`~/.rime-tts-readback/watcher.log`。

## 目录结构

```
rime-tts-readback/
├─ rime/
│  ├─ rime.lua                          # commit_notifier -> 队列文件（三端通用）
│  ├─ wubi86.custom.yaml.example        # 方案补丁示例
│  └─ wubi_pinyin.custom.yaml.example
├─ windows/                             # Windows 实现
│  ├─ RimeTtsReadback.Gui.ps1           # WinForms 控制面板
│  ├─ RimeTtsReadback.bat               # 面板启动器
│  ├─ Rime_tts_watcher.ps1              # 常驻低延迟朗读器
│  ├─ Rime_tts_start.bat / Rime_tts_stop.bat
│  ├─ Rime_tts_stop.ps1
│  └─ Rime_tts_off.bat / Rime_tts_on.bat
├─ macos/                               # macOS 实现（鼠须管）
│  ├─ RimeTtsWatcher.swift              # 常驻朗读器（AVSpeechSynthesizer）
│  ├─ main.swift                        # 程序入口
│  ├─ RimeTtsMenuBar.swift              # 菜单栏图标 + 部署/移除 + 面板动作
│  ├─ RimeTtsPanel.swift                # 控制面板窗口（AppKit）
│  ├─ RimeTtsModel.swift                # 状态快照 + config.json 读写
│  ├─ rime-tts                          # 命令行
│  ├─ build.sh / install.sh / uninstall.sh
│  └─ README.md
├─ linux/                               # Linux 实现（fcitx5-rime / ibus-rime / fcitx4-rime）
│  ├─ rime_tts_common.py                # 路径探测、配置、队列、补丁、自启动
│  ├─ rime_tts_text.py                  # 文本过滤 / 逐位逐字母
│  ├─ rime_tts_tts.py                   # speech-dispatcher / espeak-ng
│  ├─ rime_tts_reader.py                # 常驻朗读器
│  ├─ rime_tts_panel.py                 # Tk 控制面板
│  ├─ rime_tts_tray.py                  # GTK3 托盘（可选）
│  ├─ rime_tts_hotkey.py                # X11 全局快捷键
│  ├─ rime_tts_control.py               # CLI / 面板 / 托盘共享动作
│  ├─ rime-tts                          # 命令行入口
│  ├─ install.sh / uninstall.sh
│  ├─ tests/                            # unittest（配置、补丁、文本、队列）
│  └─ README.md
├─ icons/
│  ├─ rime-tts-readback.ico             # 应用图标（声波 + 键盘）
│  ├─ rime-tts-readback.png             # Linux 面板 / 应用菜单
│  ├─ tray-ok.ico / tray-warn.ico / tray-off.ico
│  └─ tray-ok.png / tray-warn.png / tray-off.png
├─ tools/
│  ├─ make-icons.ps1                    # 重新生成 icons/（GDI+，多尺寸 DIB）
│  ├─ build-release.ps1                 # 便携 zip  -> dist/rime-tts-readback-<v>.zip
│  └─ build-exe.ps1                     # 单文件 exe -> dist/RimeTtsReadback-<v>.exe
├─ .github/workflows/build.yml          # CI：构建 Windows zip/exe，编译 macOS，测试 Linux
├─ install.ps1 / uninstall.ps1
├─ DEVELOPING.md                        # 跨平台架构、队列协议、平台对齐清单
└─ README.md / README.en.md
```

## 已知限制

- **只有经 Rime 上屏(commit)的内容才会被朗读**（裸数字除外，见下）。直接输入（ASCII 直通、或绕过输入法的程序）不会产生 commit 事件，因此不会进队列、也不会被朗读。这是**有意为之**——正是它保证了候选窗里的编码不被读出。
- 输出是**逐字**的（面向校对），所以长句就是需要那么久，无法比语音本身更快。
- 设计上**绝不在输入法内部启动进程**。早期版本在 commit 回调里用 `os.execute()`，会阻塞输入法线程、甚至冻住整个桌面。**不要在 Lua 路径里放任何阻塞操作。**
- **裸数字**是唯一例外：没在组字时按下的 0-9 由 `rime.lua` 直接补报进队列（处理器放在 `engine/processors` 最前面，按键照常放行，不影响输入，也不会在读候选时误报）。数字**逐个读**（`12` → 「一、二」），数字间用短空格、语速略快，连续数字先合并再逐位念；鼠须管英文模式下敲的字母同样会补报，并按字母逐个念（`abc` → a b c）；直接敲的中文拼音和系统 ABC 输入法下的字母仍然不读。
- 程序筛选依赖"当前前台窗口"，极快切换程序时可能极小概率误判。
- **不要在中文里用 SSML 的 `<break>`**：SAPI 的中文引擎有 bug——中文文本中插入 `<break>` 会让它把最后一个音节再念一遍（"作为" → "作为为"），且与 break 时长无关。所以"逐字朗读"改用**逗号**来产生停顿。
- macOS 用的是另一套语音引擎：`Rate`/`Volume` 与 SAPI 的数值**不能直接对照**，先用「试听」调到顺耳。
- macOS 的 `say(1)` 每次调用有约 0.8–1.4 秒的启动开销（实测），所以朗读器用的是常驻的
  `AVSpeechSynthesizer`；朗读器若被手动杀掉，用 `rime-tts start` 重启（菜单栏图标也会自动看护）。
- macOS 的两个二进制是本地编译、**未签名**的。自己用没问题，分发给别人需要签名 + 公证。
- Linux 的托盘依赖 GTK3 `Gtk.StatusIcon`（传统托盘）。GNOME 3.26+ 默认不显示它；
  可安装 AppIndicator 扩展，或直接用 `rime-tts panel`。
- Linux 的全局快捷键与程序筛选依赖 **X11**。Wayland 下快捷键会被跳过、前台程序无法识别
  （此时不做筛选，照常朗读）；静音仍可用 `rime-tts on/off`、面板或 `tts_off` 标志。
- Linux 的朗读走 `spd-say` 或 `espeak-ng`，音色/语速由所装引擎决定，与 SAPI / `AVSpeechSynthesizer`
  的数值**不能直接对照**；先用面板「试听」调整。
- `pip`/虚拟环境同样可用，但安装脚本只依赖系统 `python3`；没有 Tk 时面板不可用，CLI 与朗读器不受影响。

## 构建与发布

```
powershell -ExecutionPolicy Bypass -File tools\build-release.ps1   # dist\rime-tts-readback-<v>.zip
powershell -ExecutionPolicy Bypass -File tools\build-exe.ps1       # dist\RimeTtsReadback-<v>.exe
```

- `build-release.ps1` 把整个项目打包成 zip（便携脚本，无安装程序）。
- `build-exe.ps1` 把全部内容打包成**单文件自解压 exe**，用 Windows 自带的 `csc.exe` 编译（无需下载）。
  运行时释放到 `%LOCALAPPDATA%\RimeTtsReadback\<版本>\`（仅当版本/内容变化时），然后启动控制面板；
  命令行参数会转发给 GUI 脚本。
- macOS 侧：`macos/build.sh` 用 `swiftc` 编译两个二进制（需要 Xcode Command Line Tools）；
  macOS 的二进制不签名，随源码分发、由用户本地编译。

CI：`.github/workflows/build.yml` 在每次推送到 `main` 时构建 Windows 的 zip + exe，在 `macos-14`
上编译检查 macOS 二进制，并在 `ubuntu-latest` 上做 Linux 的 `py_compile`、单元测试、CLI 与
安装/卸载冒烟测试；对 `v*` 标签，还会把 Windows 产物挂到对应的 GitHub Release。

## 许可证

MIT —— 见 [LICENSE](LICENSE)。
