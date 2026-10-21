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
            └─ TTS：Windows = SAPI + WAV 裁剪；macOS = 常驻 AVSpeechSynthesizer
```

## 队列协议

- 文件名：`<epoch>_<seq>.txt`（`os.time()` 秒 + 进程内自增序号）。
- 写入：先写 `<...>.tmp`，再 `os.rename` 成 `.txt`；朗读器永远看不到半截文件。
- 排序：按两个**数字**排序，不能按字符串（`..._10` 会排到 `..._2` 前面）。
  Windows 用定宽 `D19`/`D9` 键，macOS 直接解析整数。
- 消费：朗读器读完即删；启动时会清掉超过 60 秒的遗留文件。
- 静音：存在 `tts_off`（Windows `Rime_tts_off`）时 Lua 完全不写。
- 队列目录：Windows `%USERPROFILE%\Rime_tts_queue`，macOS `~/Library/Rime/tts_queue`。
  `RIME_TTS_DIR` 指向**队列目录本身**（两边都认），`RIME_USER_DIR` / `RIME_TTS_STATE`
  只影响朗读器和面板。

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
macOS 的部署逻辑会自动升级旧补丁；Windows 还没做（见待办）。

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
| `Rate` | 全 | `0` | -10..10；macOS 映射到 `0.5 + rate*0.035` |
| `IdleMs` / `MaxWaitMs` | 全 | `60` / `200` | 合并窗口；ASCII 批次会额外等 200 ms、上限 1.2 s |
| `Volume` | 全 | `100` | Windows 0..200（先峰值归一化）；macOS 0..100 |
| `CharByChar` | 全 | `false` | 中文逐字加逗号停顿 |
| `ReadDigits` | macOS / 待对齐 | `true` | 是否读数字（逐位） |
| `ReadEnglish` | macOS / 待对齐 | `true` | 是否读 ASCII 字母（逐字母） |
| `IncludeAscii` | 全（兼容） | — | 旧的总开关；新键缺失时用它推导两个新键 |
| `AppFilterMode` / `AppFilterList` | 全 | `all` / 空 | 程序筛选；列表存 bundle id / 进程名 |
| `HotKey` | macOS | `""` | `"ctrl+alt+r"` 启用 `⌃⌥R` |
| `Threshold` / `PadMs` / `BreakMs` | Windows | — | WAV 裁剪参数，macOS 不需要 |

## 平台现状

| 能力 | Windows | macOS | Linux |
|---|---|---|---|
| 上屏文字朗读 | ✅ | ✅ | ❌（仅 Lua 可用） |
| 裸数字逐位 | ❌ Lua 已支持，补丁位置/朗读器未跟上 | ✅ | ❌ |
| 英文逐字母 | ❌ | ✅（鼠须管英文模式） | ❌ |
| 数字/英文分开开关 | ❌（一个 `IncludeAscii`） | ✅ | ❌ |
| 控制面板 | WinForms | AppKit | ❌ |
| 托盘/菜单栏 | 托盘 | 菜单栏 | ❌ |
| 开机自启 | 启动文件夹 | LaunchAgent | ❌ |
| 全局快捷键 | `Ctrl+Alt+R`（可捕获） | `⌃⌥R`（Carbon，固定） | ❌ |
| 系统 ABC / 其它输入法的英文 | ❌ | ❌（需输入监控，未做） | ❌ |

## 构建与测试

```sh
# macOS（本机）
./macos/build.sh              # -> bin/{rime-tts-watcher,rime-tts-menubar,rime.lua}
./macos/install.sh --no-start # 安装到 ~/.rime-tts-readback 与 ~/Library/Rime

# 不发声的自检
bin/rime-tts-watcher --check
bin/rime-tts-watcher --fake --queue /tmp/q --off-file /tmp/off --run-seconds 2 ...
```

Windows 打包（需要 Windows 或 pwsh + csc）：

```
powershell -ExecutionPolicy Bypass -File tools\build-release.ps1
powershell -ExecutionPolicy Bypass -File tools\build-exe.ps1
```

CI（`.github/workflows/build.yml`）：

- Windows：用 `[Parser]::ParseFile` 解析**所有** `.ps1`（不执行；朗读器需要真实桌面会话），
  然后打 zip/exe。
- macOS：`macos-14` 上编译，跑 `--status`、`--help` 和 `sh -n` 检查。

本机（macOS）没有 PowerShell/Windows，Windows 侧改动只能做语法级保证；Linux 完全没有
运行环境。

## Windows 对齐清单

目标：和 macOS 一样，中文、数字、英文都能（逐位/逐字母）朗读，两个开关分开。

- [ ] **补丁位置**：`windows/RimeTtsReadback.Gui.ps1` 的 `Add-ReadbackPatch` 改成
      `"engine/processors/@before 0": "lua_processor@tts_reporter"`，并升级旧补丁：
      识别我们标记的 `engine/processors/+:` 块，删掉后再插新形式
      （`Remove-ReadbackPatch` 已有清理逻辑，可复用）。
- [ ] **朗读器参数**：`Rime_tts_watcher.ps1` 增加 `-ReadDigits` / `-ReadEnglish`，
      缺省时回退到 `-IncludeAscii`；`ReadableChars` 按这两个开关分别过滤字母和数字。
- [ ] **逐位/逐字母**：`Build-Ssml` 之前把相邻 ASCII 字母/数字用空格拆开
      （`abc123` → `a b c 1 2 3`），并保留英文词间空格；**不要用 `<break>`**
      （中文 SAPI 有重复末音节的 bug）。
- [ ] **批量窗口**：ASCII 批次单独放宽 Idle/MaxWait，否则每个字母一次 SAPI 调用会积压。
      可参考 macOS：`IdleMs + 200`，上限 1.2 s。
- [ ] **GUI 拆开关**：把「朗读英文与数字」拆成两个勾选；配置写 `ReadDigits` /
      `ReadEnglish`；加载时兼容旧 `IncludeAscii`；补 tooltip、`Track-Change` 映射、
      `$script:ConfigKeys`。
- [ ] **实机验证**：Win11 + Weasel 0.17.4 / PowerShell 5.1；
      中文模式下的数字用于选候选、不进队列；英文模式逐字母；关掉开关后不读。

## Linux 落地（待决策）

目前只有 `rime/rime.lua` 可以复用，而且它默认的非 Windows 路径是
`~/Library/Rime`（macOS），Linux 上必须改用 `RIME_TTS_DIR` 或做路径探测。

需要先定的事：

- **前端**：ibus-rime（`~/.config/ibus/rime`）还是 fcitx5-rime（`~/.local/share/fcitx5/rime`）。
  两者都要求带 `librime-lua` 的包。
- **语音**：`speech-dispatcher`（`spd-say`，最接近系统集成） / `espeak-ng`（简单、机械） /
  `piper` + `paplay`（质量好但重）。要实测启动延迟，决定是否常驻 / 用 SSIP 连接。
- **界面**：GTK4/libadwaita 或 Qt 面板；托盘用 StatusNotifierItem/AppIndicator；
  也可以先做 CLI（`rime-tts start/stop/on/off/status`）。
- **程序筛选**：X11 用 `_NET_ACTIVE_WINDOW`；Wayland 没有可靠的全局焦点，需要降级或放弃。
- **全局快捷键**：X11 `XGrabKey`；Wayland 走 GlobalShortcuts portal（支持有限）。
- **自启**：`~/.config/autostart/rime-tts-readback.desktop`（或 systemd user unit）。

建议的目录：

```
linux/
├─ rime-tts                  # CLI
├─ reader.(c|rs|py)          # 常驻朗读器
├─ panel/                    # 可选 GUI
└─ README.md
```

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
