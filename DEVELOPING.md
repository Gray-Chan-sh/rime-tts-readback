# 开发文档（跨平台）

面向要改代码、修 bug 或把功能对齐到其它平台的人。用户文档见 [README.md](README.md) /
[README.en.md](README.en.md)，macOS 使用说明见 [macos/README.md](macos/README.md)。

## 设计不变量

改任何平台前先确认没有破坏这四条：

1. **只朗读真正上屏的文字**。候选窗/预编辑里的编码永远不读。
2. **Lua 路径里绝不做阻塞操作**。早期版本在 commit 回调里 `os.execute()`，会冻住整个
   输入法甚至桌面。`rime.lua` 里只允许 `pcall` 包住的小文件写入。
3. **队列是唯一的跨平台接口**。`rime.lua` 只写文件；朗读器只读文件。两边不共享内存、
   不互相调用、不依赖对方的进程状态。
4. **平台差异只放在朗读器和控制面板里**。Lua 层、队列格式、配置键的语义必须一致。

## 数据流

```
   候选窗 / 预编辑 (cfgf)                  ← 永远不读
            │
       你选字上屏
            │
   rime.lua  ├─ commit_notifier          → 写队列（中文/上屏的英文）
             ├─ 裸数字（未组字时按的 0-9） → 写队列（逐位）
             └─ ascii_mode 下的字母/空格   → 写队列（逐字母、保留词边界）
            │
   ~/.rime-tts-readback/…/tts_queue/<epoch>_<seq>.txt
            │
   平台朗读器（常驻）
            ├─ 按 IdleMs / MaxWaitMs 合并
            ├─ 程序筛选、静音、热加载配置
            └─ TTS：Windows = SAPI + WAV 裁剪；macOS = 常驻 AVSpeechSynthesizer；
                     Linux = spd-say / espeak-ng（单条在飞，轮询子进程）
```

## 队列协议

- 文件名：`<epoch>_<seq>.txt`（`os.time()` 秒 + 进程内自增序号）。
- 写入：先写 `<...>.tmp`，再 `os.rename` 成 `.txt`；朗读器永远看不到半截文件。
- 排序：按两个**数字**排序，不能按字符串（`..._10` 会排到 `..._2` 前面）。
  Windows 用定宽 `D19`/`D9` 键，macOS 直接解析整数。
- 消费：朗读器读完即删；启动时会清掉超过 60 秒的遗留文件。
- 静音：存在 `tts_off`（Windows `Rime_tts_off`）时 Lua 完全不写。
- 队列目录：Windows `%USERPROFILE%\Rime_tts_queue`，macOS `~/Library/Rime/tts_queue`，
  Linux `<Rime 用户目录>/tts_queue`（fcitx5-rime / ibus-rime / fcitx4-rime 自动探测）。
  `RIME_TTS_DIR` 指向**队列目录本身**（三端都认）；`RIME_USER_DIR` 同时改变 Lua 的基准
  目录与朗读器/面板（三端）；`RIME_TTS_STATE` 只影响 Linux 的状态目录。

## Rime 侧（`rime/rime.lua`）

### 处理器必须排在最前面

补丁要写成：

```yaml
patch:
  # >>> rime-tts-readback >>>
  "engine/processors/@before 0": "lua_processor@tts_reporter"
  # <<< rime-tts-readback <<<
```

原因：`ascii_composer` 在“非组字 + 英文模式”下会把数字和字母 `kRejected` 直接交给
前台，它们根本到不了处理器链的后面。只有排在第一位，`func` 才能看到裸键；组字时
返回 `kNoop`，候选选择、拼音输入都不受影响。

旧版本把处理器追加在最后（`engine/processors/+:`），因此**收不到裸数字/字母**。
macOS / Windows / Linux 的部署逻辑都会自动升级旧补丁（保留同一块里的其它处理器）。

### Linux 的 Rime 用户目录

`rime.lua` 在 Linux 上按以下顺序选择（与 `linux/rime_tts_common.py` 保持一致）：

1. `RIME_USER_DIR`（显式覆盖）
2. `$XDG_DATA_HOME/fcitx5/rime`（`~/.local/share/fcitx5/rime`，fcitx5-rime）
3. `$XDG_CONFIG_HOME/ibus/rime`（`~/.config/ibus/rime`，ibus-rime）
4. `$XDG_CONFIG_HOME/fcitx/rime` 与 `$XDG_DATA_HOME/fcitx/rime`（fcitx4-rime）

都不存在时使用第一个候选；安装脚本会先探测再把 `RIME_USER_DIR` 传给后续命令。

### `func` 的规则

- 组字中 → 什么都不做（数字用于选候选，字母是拼音）。
- 裸数字（0-9、小键盘）→ 写队列。
- `ascii_mode` 下的字母 → 写队列；空格也写一个（保留词边界）。
- 其他按键、Ctrl/Alt/Cmd 组合 → 一律 `kNoop`，不拦截。
- 一律 `return 2 (kNoop)`；数字/字母仍然由系统正常插入，打字行为完全不变。

注意：`rime-tts reload`（或 Squirrel `--reload`）**不会重新加载 Lua 模块**，改完
`rime.lua` 必须重启输入法进程才生效。

## 配置（`config.json`）

| 键 | 平台 | 默认 | 含义 |
|---|---|---|---|
| `Voice` | 全 | 平台默认 | 语音名 / 标识符 / 语言代码 |
| `Rate` | 全 | `0` | -10..10；macOS 映射到 `0.5 + rate*0.035`；Linux spd-say 为 `rate*10`，espeak 为 `175 + rate*8` wpm |
| `IdleMs` / `MaxWaitMs` | 全 | `60` / `200` | 合并窗口；ASCII 批次会额外等 200 ms、上限 1.2 s |
| `Volume` | 全 | `100` | Windows 0..200（先峰值归一化）；macOS 0..100；Linux 0..100（100 = 引擎默认，0 = 静音） |
| `CharByChar` | 全 | `false` | 中文逐字加逗号停顿 |
| `ReadDigits` | 全 | `true` | 是否读数字（逐位） |
| `ReadEnglish` | 全 | `true` | 是否读 ASCII 字母（逐字母） |
| `IncludeAscii` | 全（兼容） | — | 旧的总开关；新键缺失时用它推导两个新键 |
| `AppFilterMode` / `AppFilterList` | 全 | `all` / 空 | 程序筛选；列表存 bundle id / 进程名 / X11 WM_CLASS |
| `HotKey` | 全 | `""` | 静音切换快捷键；Windows/macOS `ctrl+alt+r`（`⌃⌥R`），Linux X11 `ctrl+alt+r` |
| `Threshold` / `PadMs` / `BreakMs` | Windows | — | WAV 裁剪参数，macOS / Linux 不需要 |

## 平台现状

| 能力 | Windows | macOS | Linux |
|---|---|---|---|
| 上屏文字朗读 | ✅ | ✅ | ✅ |
| 裸数字逐位 | ✅ | ✅ | ✅ |
| 英文逐字母 | ✅ | ✅（鼠须管英文模式） | ✅（X11 下同左，取决于前端是否补报） |
| 数字/英文分开开关 | ✅ | ✅ | ✅ |
| 控制面板 | WinForms | AppKit | Tk |
| 托盘/菜单栏 | 托盘 | 菜单栏 | GTK3 StatusIcon（X11） |
| 开机自启 | 启动文件夹 | LaunchAgent | XDG autostart `.desktop` |
| 全局快捷键 | `Ctrl+Alt+R`（可捕获） | `⌃⌥R`（Carbon，固定） | X11 `XGrabKey`（Wayland 跳过） |
| 程序筛选 | 前台进程 | 前台 App | X11 前台窗口类；Wayland 降级 |
| 系统 ABC / 其它输入法的英文 | ❌ | ❌（需输入监控，未做） | ❌（不经过 Rime 就没有 commit） |

## 构建与测试

```sh
# macOS（本机）
./macos/build.sh              # -> bin/{rime-tts-watcher,rime-tts-menubar,rime.lua}
./macos/install.sh --no-start # 安装到 ~/.rime-tts-readback 与 ~/Library/Rime

# 不发声的自检
bin/rime-tts-watcher --check
bin/rime-tts-watcher --fake --queue /tmp/q --off-file /tmp/off --run-seconds 2 ...

# Linux（纯标准库，不需要显示器）
cd linux
python3 -m py_compile *.py rime-tts
python3 -m unittest discover -s tests -v
python3 rime_tts_reader.py --check
./install.sh --prefix /tmp/rtts-inst --rime-dir /tmp/rtts-rime --no-start
./uninstall.sh --prefix /tmp/rtts-inst --rime-dir /tmp/rtts-rime --no-reload -y
```

Windows 打包（需要 Windows 或 pwsh + csc）：

```
powershell -ExecutionPolicy Bypass -File tools\build-release.ps1
powershell -ExecutionPolicy Bypass -File tools\build-exe.ps1
```

> Windows 上 `git add` 新文件默认是 644（`core.filemode=false`）。提交 Linux 脚本时用
> `git add --chmod=+x linux/install.sh linux/uninstall.sh linux/rime-tts`，否则用户
> `./install.sh` 会 Permission denied；CI 已改用 `bash ./linux/install.sh` 兜底。

CI（`.github/workflows/build.yml`）：

- Windows：用 `[Parser]::ParseFile` 解析**所有** `.ps1`（不执行；朗读器需要真实桌面会话），
  然后打 zip/exe。
- macOS：`macos-14` 上编译，跑 `--status`、`--help` 和 `sh -n` 检查。
- Linux：`ubuntu-latest` + Python 3.8，跑 `py_compile`、45 个 `unittest`、CLI 自检，
  以及 `install.sh` / `uninstall.sh` 的临时目录冒烟测试。

本机（macOS）没有 PowerShell/Windows，Windows 侧改动只能做语法级保证；Linux 侧可在 WSL
（Ubuntu 24.04）里跑完整无头测试，并借助 WSLg 验证 Tk 面板与 GTK 托盘对象；真实发声、
系统托盘图标与 fcitx5/ibus 联调仍需带桌面的 X11 环境。

## Windows 对齐（已完成）

目标：和 macOS 一样，中文、数字、英文都能（逐位/逐字母）朗读，两个开关分开。

- [x] **补丁位置**：`Add-ReadbackPatch` 改为 `"engine/processors/@before 0"`，
      自动升级旧的 `engine/processors/+:` 块，并保留同一块里的其它处理器。
- [x] **朗读器参数**：`-ReadDigits` / `-ReadEnglish`，缺省时回退到 `-IncludeAscii`；
      `ReadableChars` 按两个开关分别过滤字母和数字。
- [x] **逐位/逐字母**：`Build-Ssml` 把相邻 ASCII 字母/数字用空格拆开
      （`abc123` → `a b c 1 2 3`），保留英文词间空格；**不用 `<break>`**。
- [x] **批量窗口**：ASCII 批次 `IdleMs + 200`、`MaxWaitMs` 至少 1.2 s，避免逐字积压。
- [x] **GUI 拆开关**：勾选、tooltip、`Track-Change`、`ConfigKeys`、加载兼容旧
      `IncludeAscii`；保存时继续写兼容键。
- [x] **验证**：`-Check`、`-Smoke`、PowerShell parser、补丁升级/配置写入测试、
      watcher `-SelfTest`（`abc123` → `a b c 1 2 3`）。真实 Win11 + Weasel / SAPI
      发声与候选数字行为仍需在有桌面的机器上复核。

## Linux 实现说明

选择 **Python 3.8+ 标准库**，不引入 GTK/Qt 运行时依赖：

```
linux/
├─ rime-tts                  # CLI
├─ rime_tts_common.py        # 路径探测、config、队列、补丁、自启动、状态
├─ rime_tts_text.py          # readable_chars / build_body / ascii_only
├─ rime_tts_tts.py           # spd-say / espeak-ng、语音列表、异步 Speaker
├─ rime_tts_reader.py        # 常驻朗读器（flock 单实例、热加载、筛选、热键）
├─ rime_tts_panel.py         # Tk 控制面板
├─ rime_tts_tray.py          # 可选 GTK3 StatusIcon 托盘
├─ rime_tts_hotkey.py        # X11 XGrabKey
├─ rime_tts_control.py       # CLI/面板/托盘共享动作
├─ install.sh / uninstall.sh
└─ tests/                    # unittest
```

关键决策：

- **前端**：自动探测 fcitx5-rime → ibus-rime → fcitx4-rime；`RIME_USER_DIR` 可覆盖，
  与 `rime.lua` 的 `default_base()` 完全一致。
- **语音**：优先 `spd-say`，但只有在 `spd-say -L` 成功（守护进程可达）时才使用，
  否则回退 `espeak-ng` / `espeak`。**注意**：`-L` 才是列语音，`-O` 列的是输出模块；
  `-y` 才是设置语音名，`-n` 是连接名。这两个坑在 WSL 实测中发现并修正。
- **音量**：`config.Volume` 0..100 映射到 spd-say 的 `-100..100`（`volume - 100`），
  即 100 = 引擎默认、0 = 静音；espeak 直接 `-a 0..100`。
- **界面**：Tk 面板是主入口；GTK3 `Gtk.StatusIcon` 托盘是可选增强，`gi` 不可用时
  自动退回面板。GNOME 不显示传统托盘时也不影响面板。
- **程序筛选**：X11 用 `xdotool`（优先）或 `xprop` + `_NET_ACTIVE_WINDOW` 取窗口类；
  取不到（Wayland/无工具）时**不做筛选**，避免误静音。
- **全局快捷键**：X11 `XGrabKey`，同时抓 NumLock/CapsLock 变体；Wayland 或注册失败
  只写日志，不退出朗读器。
- **自启**：`~/.config/autostart/rime-tts-readback.desktop`（XDG），指向
  `rime-tts start`。
- **配置**：与 macOS 完全同名同义，写 `IncludeAscii` 兼容键；朗读器每秒检查 mtime 热加载。
- **队列**：`<Rime 目录>/tts_queue`，文件名 `<epoch>_<seq>.txt`，数字排序；启动时清空
  遗留文件与 `.tmp`。
- **日志**：`~/.rime-tts-readback/watcher.log`，启动时超过 1 MB 轮转为 `.1`。

验证（WSL Ubuntu 24.04，无头）：

- 45 个 unittest 全部通过；
- 真实队列 → 合并 → 文本转换的 fake 朗读器测试（中文合并、`abc123` 拆读、逐字逗号、
  数字开关、静音清队列、单实例）；
- `install.sh --patch` / `uninstall.sh`（补丁保留用户键、卸载清理、`--purge`）；
- WSLg 下实例化 Tk 面板（131 个基础语音）并验证 UI→config 写盘；
- GTK3 托盘菜单构造、X11 `XGrabKey` 注册成功。

未覆盖：真实发声设备、真实系统托盘图标（无托盘管理器）、fcitx5/ibus 联调。

## 已知坑

- **SAPI 中文 + `<break>`**：会把最后一个音节再念一遍（“作为”→“作为为”）。逐字停顿用逗号。
- **`IncludeAscii` 的旧语义**：一个开关同时管字母和数字。新代码优先读
  `ReadDigits`/`ReadEnglish`，缺失时回退。
- **Lua 不随 reload 重载**：改 `rime.lua` 要重启输入法进程。
- **macOS 升级别原地覆盖运行中的二进制**：会触发 `SIGKILL (Code Signature Invalid)`；
  `install.sh` 已改成临时文件 + `mv`。
- **Secure Input**：密码框会让输入法/全局监听都拿不到按键；不要试图绕过。
- **Electron/AX**：系统 ABC 下的英文想通过辅助功能读取并不可靠；要做得走全局键盘监听
  + 输入监控权限（未实现）。
- **PowerShell 5.1**：不要用三元运算符、`??`、`-File` 之外的 PS7 语法；CI 只解析不执行。
- **spd-say 的参数**：`-L` = 列语音（`-O` 是输出模块），`-y` = 语音名（`-n` 是连接名），
  `-i` 范围是 -100..100（0 = 默认）。Linux 代码已按此实现；用错会得到一条假语音或无声。
- **speech-dispatcher 不一定在跑**：只 `which spd-say` 不够，必须用 `spd-say -L` 探测
  守护进程；不可达时回退 espeak-ng。
- **GTK `StatusIcon` 无托盘管理器**：WSLg/无托盘的桌面会打印 `Gtk-CRITICAL
  gtk_widget_get_scale_factor` 警告，属预期；`rime-tts tray` 的 stderr 在后台启动时被丢弃。
- **Tk 是可选包**：Ubuntu 默认不带 `python3-tk`；面板导入时才报错，CLI/朗读器不受影响。
- **不要用 PowerShell 改含中文的 Linux 脚本**：`Set-Content` 默认 ANSI 会破坏 UTF-8；
  用编辑器/`write` 保持 UTF-8 + LF。
- **WSL 测试**：WSLg 可以跑 Tk/GTK 对象与 `XGrabKey`，但没有真实托盘和窗口管理器，
  `frontmost_app()` 返回空（筛选自动跳过），也听不到声音。
