# rime-tts-readback（Linux）

在 fcitx5-rime / ibus-rime / fcitx4-rime 上，把**已经上屏（commit）**的文字逐字朗读出来。
候选窗和预编辑里的编码永远不会被读。

与 Windows / macOS 共用：

- 同一个 `rime/rime.lua` 上报层；
- 同一个队列协议（`tts_queue/<epoch>_<seq>.txt`、`tts_off`）；
- 同一份配置语义（`config.json` 的键名、默认值、`IncludeAscii` 兼容键）。

Linux 端只用 **Python 3 标准库**：朗读器、CLI、Tk 控制面板、可选 GTK3 托盘。
不依赖 Python 第三方包，也不需要编译。

## 功能

- **常驻朗读器**：监听 Rime 队列，按 `IdleMs` / `MaxWaitMs` 合并连续上屏，低延迟出声。
- **只读 commit**：不读候选、不读预编辑，不在 Lua 路径里启动进程。
- **逐位数字 / 逐字母英文**：`abc123` → `a b c 1 2 3`，两个开关独立。
- **逐字朗读**：字间用全角逗号停顿（不用 SSML `<break>`）。
- **热加载**：面板或手改 `config.json` 后约 1 秒生效，无需重启。
- **程序筛选**：全部 / 仅这些窗口 / 除这些窗口（X11 窗口类）。
- **静音**：`rime-tts off` 或面板/托盘；Lua 立即停止写队列，朗读器清空积压。
- **控制面板**：状态、安装/接管、部署、启停、语音试听、参数、筛选、自启、快捷键。
- **托盘图标**：GTK3 `StatusIcon`（可选，X11）。
- **全局快捷键**：X11 `XGrabKey`，默认 `ctrl+alt+r` 切换静音。
- **登录自启**：XDG autostart `.desktop`。
- **单实例**：朗读器用 `flock`，面板/托盘用 pid 文件；重复启动不会叠加。

## 系统要求

- **Python 3.8+**（Ubuntu 24.04 自带 3.12）。
- **Tk**（仅控制面板需要）：Debian/Ubuntu `python3-tk`，Fedora `python3-tkinter`。
- **带 librime-lua 的 Rime 前端**：fcitx5-rime、ibus-rime 或 fcitx4-rime。
- **TTS**（二选一，优先第一个）：
  - `speech-dispatcher`（`spd-say`）——桌面集成最好；
  - `espeak-ng` / `espeak`——无需守护进程的回退。
- **可选工具**：
  - `wmctrl`：面板里列举运行中的窗口类；
  - `xdotool` / `xprop`：判断前台程序（没有时筛选自动跳过）；
  - `notify-send`：托盘操作气泡。
- **X11** 才能用托盘和全局快捷键；Wayland 下会自动降级（见下文）。

Debian / Ubuntu：

```sh
sudo apt install python3-tk speech-dispatcher espeak-ng wmctrl xdotool x11-utils
```

## 安装

```sh
cd linux
./install.sh --patch --tray
```

如果从压缩包解压后丢了可执行位（`Permission denied`），把命令换成
`bash install.sh --patch --tray`；卸载同理，用 `bash uninstall.sh`。

`install.sh` 会：

1. 把 Python 文件装到 `~/.rime-tts-readback/bin/`，`rime.lua` 放到
   `~/.rime-tts-readback/share/`；
2. 自动探测 Rime 用户目录，复制 `rime.lua` 并创建 `tts_queue/`；
3. 创建默认 `config.json`（已存在则不覆盖）；
4. 写入应用菜单项 `~/.local/share/applications/rime-tts-readback.desktop`；
5. 可选地给已启用方案打补丁、启动后台、启动托盘、设置自启。

选项：

| 选项 | 作用 |
|---|---|
| `--patch` | 给所有已启用方案加 `"engine/processors/@before 0"` 补丁 |
| `--no-start` | 不启动后台朗读器 |
| `--tray` | 启动 GTK 托盘（同时确保朗读器在跑） |
| `--panel` | 安装完打开控制面板 |
| `--autostart` | 设置登录自启 |
| `--rime-dir <dir>` | 指定 Rime 用户目录（默认自动探测） |
| `--prefix <dir>` | 指定安装目录（默认 `~/.rime-tts-readback`） |

安装后把 `~/.rime-tts-readback/bin` 加进 `PATH`，就可以直接运行 `rime-tts`：

```sh
export PATH="$HOME/.rime-tts-readback/bin:$PATH"   # 写进 ~/.bashrc / ~/.zshrc
```

> 不需要 root。不要用 `sudo` 运行安装脚本或朗读器。

### 手动安装（可选）

```sh
mkdir -p ~/.rime-tts-readback/bin
cp linux/rime_tts_*.py linux/rime-tts ~/.rime-tts-readback/bin/
chmod +x ~/.rime-tts-readback/bin/rime-tts
cp rime/rime.lua ~/.rime-tts-readback/share/rime.lua
cp rime/rime.lua ~/.local/share/fcitx5/rime/rime.lua      # 换成你的 Rime 目录
mkdir -p ~/.local/share/fcitx5/rime/tts_queue
~/.rime-tts-readback/bin/rime-tts patch
~/.rime-tts-readback/bin/rime-tts reload
~/.rime-tts-readback/bin/rime-tts start
```

## 快速开始

```sh
rime-tts check     # 检查前端、目录、补丁、部署、引擎、语音
rime-tts deploy    # 安装 rime.lua + 打补丁 + 重新部署 + 启动后台
rime-tts panel     # 打开控制面板
```

`rime-tts deploy` 会修改你的 `*.custom.yaml`。如果不希望自动改：

```sh
rime-tts patch     # 只打补丁
rime-tts unpatch   # 只移除补丁
```

补丁内容：

```yaml
patch:
  "engine/processors/@before 0": "lua_processor@tts_reporter"
```

处理器必须排在 `engine/processors` **最前面**：非组字英文模式下，`ascii_composer`
会把裸数字/字母直接交给前台，排在后面的处理器收不到。组字时它返回 `kNoop`，
不影响选候选和拼音输入。

> 改完 `rime.lua` 后 `rime-tts reload` **不会重新加载 Lua 模块**，必须重启输入法进程
> （fcitx5：`fcitx5 -r -d` 或注销重登；ibus：`ibus restart`）。

## 命令行

```text
rime-tts start | stop | restart      后台朗读器
rime-tts on | off | toggle           静音标志（rime.lua 不再写队列）
rime-tts status                      单行状态
rime-tts check                       完整检测报告
rime-tts voices                      列出语音
rime-tts preview [文本]              用当前设置试听
rime-tts log [-f]                    打开日志 / tail -f
rime-tts config                      打开 config.json
rime-tts panel                       控制面板
rime-tts tray                        托盘图标（并确保朗读器在跑）
rime-tts patch | unpatch             添加 / 移除方案补丁
rime-tts deploy | remove             完整部署 / 移除
rime-tts reload                      请求 fcitx5 / ibus 重新部署 Rime
rime-tts clear-queue                 丢弃待读队列
rime-tts autostart on|off|status     XDG 登录自启
rime-tts shutdown                    停掉托盘、面板、朗读器
```

`rime-tts remove` 会先询问；`-f` / `--yes` 跳过确认。

## 控制面板与托盘

`rime-tts panel` 打开 Tk 面板：

- **状态**：前端、Rime 目录、`rime.lua`、补丁、部署、后台、队列、引擎；
- **操作**：安装/接管、重新部署、静音、启停后台、移除集成、清空队列、打开 Rime 目录；
- **语音**：下拉选择 + 试听；语速、音量；合并窗口与最长等待；
- **文本**：逐字朗读、朗读数字、朗读英文；
- **程序筛选**：全部 / 仅这些 / 除这些，可一键加入运行中的窗口类，也可手动输入；
- **启动与快捷键**：登录自启、X11 静音快捷键（留空关闭）；
- 打开日志/配置、检查报告、关于。

修改即写 `config.json`，朗读器约 1 秒内热加载。

`rime-tts tray` 启动 GTK3 托盘：

- 图标颜色：绿 = 正常，橙 = 未安装/未部署，灰 = 静音或后台停止；
- 菜单：打开面板、静音、后台开关、试听、重新部署、清空队列、打开日志/配置、关于、退出；
- 左键点击打开面板。

GNOME 3.26+ 默认不显示传统托盘图标（`Gtk.StatusIcon`）。可以安装 AppIndicator 扩展，
或直接使用 `rime-tts panel`。KDE / XFCE / Cinnamon / MATE 等通常可直接显示。

## 配置

默认路径：`~/.rime-tts-readback/config.json`（`RIME_TTS_STATE` 可改）。

| 键 | 默认 | 含义 |
|---|---|---|
| `Voice` | `""` | spd-say 语音名 / 语言代码；空 = 按文字自动中/英文 |
| `Rate` | `0` | -10..10；spd-say `rate*10`，espeak `175 + rate*8` wpm |
| `IdleMs` | `60` | 这段时间内到达的上屏合并成一次朗读 |
| `MaxWaitMs` | `200` | 最多等这么久就开读 |
| `Volume` | `100` | 0..100；spd-say 映射到 -100..100（100 = 引擎默认，0 = 静音） |
| `CharByChar` | `false` | 逐字朗读（逗号停顿） |
| `ReadDigits` | `true` | 朗读 ASCII 数字（逐位） |
| `ReadEnglish` | `true` | 朗读 ASCII 字母（逐字母） |
| `AppFilterMode` | `all` | `all` / `only` / `except` |
| `AppFilterList` | `[]` | 窗口类名列表（X11 `WM_CLASS`） |
| `HotKey` | `""` | 如 `ctrl+alt+r`；空 = 关闭；仅 X11 |

兼容：读取旧配置时如果没有 `ReadDigits` / `ReadEnglish`，回退到 `IncludeAscii`；
保存时总会写 `IncludeAscii = ReadDigits && ReadEnglish`，旧版朗读器仍能工作。

队列与状态：

```
<Rime 用户目录>/tts_queue/<epoch>_<seq>.txt   待读文件
<Rime 用户目录>/tts_off                       静音标志
~/.rime-tts-readback/config.json              配置
~/.rime-tts-readback/watcher.log              日志（>1 MB 轮转）
~/.rime-tts-readback/watcher.pid              朗读器 pid
~/.rime-tts-readback/{panel,tray}.pid         面板/托盘 pid
~/.config/autostart/rime-tts-readback.desktop 登录自启
```

环境变量（与 macOS / Windows 语义一致）：

- `RIME_USER_DIR`：Rime 用户目录；
- `RIME_TTS_DIR`：队列目录本身（优先于 `RIME_USER_DIR/tts_queue`）；
- `RIME_TTS_STATE`：状态/配置/日志目录。

### Rime 目录探测顺序

1. `RIME_USER_DIR`
2. `$XDG_DATA_HOME/fcitx5/rime`（默认 `~/.local/share/fcitx5/rime`）
3. `$XDG_CONFIG_HOME/ibus/rime`（默认 `~/.config/ibus/rime`）
4. `$XDG_CONFIG_HOME/fcitx/rime` / `$XDG_DATA_HOME/fcitx/rime`（fcitx4）

与 `rime/rime.lua` 的探测顺序一致。

## 自启动与快捷键

```sh
rime-tts autostart on
rime-tts autostart status
rime-tts autostart off
```

会写 `~/.config/autostart/rime-tts-readback.desktop`，执行
`rime-tts start`（只启动朗读器，不弹面板）。

快捷键格式：`ctrl+alt+r`、`super+shift+m`、`ctrl+alt+space` 等，必须包含至少一个修饰键。
`ctrl` / `control`、`alt` / `option`、`shift`、`super` / `win` / `meta` / `cmd` 都可用。
Wayland 下会记录日志并跳过，不会影响朗读。

## Wayland / GNOME 限制

| 功能 | X11 | Wayland |
|---|---|---|
| 上屏朗读 | ✅ | ✅ |
| 静音（CLI/面板） | ✅ | ✅ |
| 控制面板 | ✅ | ✅ |
| 托盘 `StatusIcon` | ✅（有托盘管理器时） | 通常不显示 |
| 程序筛选 | ✅ | ❌ 不筛选，照常朗读 |
| 全局快捷键 | ✅ | ❌ 跳过 |

Wayland 下仍可用 `rime-tts off` / `on`、面板按钮或直接创建 `tts_off` 文件静音。
部分桌面可通过 XWayland 显示托盘；行为取决于桌面环境。

## 卸载

```sh
cd linux
./uninstall.sh            # 保留 config.json / 日志
./uninstall.sh --purge    # 连状态目录一起删
```

会停止朗读器/托盘/面板，移除方案补丁与 `rime.lua`，清空队列，重新部署 Rime，
删除自启项与应用菜单项。`--no-reload` 可跳过重新部署，`-y` 跳过确认。

## 故障排查

先跑：

```sh
rime-tts check
rime-tts log
```

**完全没有队列文件**

- `rime-tts check` 看 Rime 目录 / 补丁 / `rime.lua` 是否就绪；
- 确认前端带 `librime-lua`（fcitx5-rime / ibus-rime 的发行版包通常带）；
- 确认补丁在 `*.custom.yaml` 里，且重新部署后 `build/*.schema.yaml` 含 `tts_reporter`；
- `tts_off` 是否存在；
- 改过 `rime.lua` 后是否重启了输入法进程（reload 不够）。

**有队列但不读**

- `rime-tts status` 看后台是否在跑；`rime-tts start`；
- `rime-tts log` 看 `read [...]` 或 `skip (app filter ...)`；
- 程序筛选：切到「全部应用」再试；
- 日志里 `TTS进程退出` → 检查引擎与语音。

**没有声音**

```sh
rime-tts voices          # 是否有语音
spd-say "测试"           # speech-dispatcher 是否正常
espeak-ng "测试"         # 回退引擎是否正常
rime-tts preview
```

- `rime-tts check` 显示 `speech-dispatcher 未运行` 时，启动/重装 speech-dispatcher，
  或直接依赖 espeak-ng；
- 面板 `Volume` 调到 100（spd-say 的引擎默认）；0 是静音；
- 检查桌面音频输出与 `pactl info`。

**面板打不开**

- 安装 Tk：`sudo apt install python3-tk`；
- 无图形会话（SSH）时只能用 CLI。

**托盘不显示**

- GNOME 3.26+ 默认无传统托盘；装 AppIndicator 扩展或用面板；
- 确认在 X11 会话（`echo $XDG_SESSION_TYPE`）。

**快捷键无效**

- Wayland 不支持；
- 组合键被其它程序占用（日志会写注册失败）；
- `ctrl+alt+r` 在部分桌面被占用，可换成 `super+alt+r`。

**程序筛选无效**

- Wayland 下不可用；
- 安装 `wmctrl`（面板列举）与 `xdotool` 或 `xprop`（前台判断）；
- 列表里填的是 X11 `WM_CLASS`（如 `firefox`、`kitty`），不是窗口标题。

## 测试

```sh
cd linux
python3 -m py_compile *.py rime-tts
python3 -m unittest discover -s tests -v

# 不发声的朗读器端到端测试
python3 rime_tts_reader.py --fake --queue /tmp/q --off-file /tmp/off \
  --config /tmp/cfg.json --log /tmp/log --pid /tmp/pid --run-seconds 5
```

WSL（Ubuntu 24.04 + WSLg）可以跑全部无头测试，并实例化 Tk 面板 / GTK 托盘对象、
注册 X11 快捷键；真实发声、系统托盘图标和 fcitx5/ibus 联调需要带桌面的 Linux。

## 已知差异

- Linux 没有 Windows 的 WAV 裁剪参数（`Threshold` / `PadMs` / `BreakMs`）。
- 语音、语速、音量的数值由 speech-dispatcher / espeak-ng 决定，和 SAPI、
  `AVSpeechSynthesizer` 不能直接对照；用「试听」调。
- espeak-ng 的音色偏机械；需要更好音质可自行安装 Piper 等引擎（当前未集成）。
- 与 macOS 一样，系统 ABC 输入法直接把字母交给应用、不经过 Rime，因此不会被朗读。
