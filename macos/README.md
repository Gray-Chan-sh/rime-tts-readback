# macOS 版（鼠须管 Squirrel）

Windows 版那套「SAPI + WinForms + 注册表」在 macOS 上不存在，所以这里不是移植，而是**同一套设计的两地实现**：

```
       你选字上屏
            │
   rime.lua commit_notifier ──► 每次上屏写一个小文件
            │                   ~/Library/Rime/tts_queue/*.txt
            ▼
   rime-tts-watcher（常驻、无界面）
            │
            ├─ 按 IdleMs/MaxWaitMs 合并同一批上屏
            └─ AVSpeechSynthesizer.speak()   → 立即出声
```

和 Windows 版的关键差异：**不需要**合成 WAV、裁静音、归一化那套。macOS 的语音引擎每句话前后没有 0.45 秒静音，
而且 `say(1)` 每次调用有约 0.8–1.4 秒的进程/语音服务握手开销（实测），所以这里用一个常驻进程内的
`AVSpeechSynthesizer`，实测出声起点 **1–20 ms**。

---

## 要求

| 项目 | 说明 |
|---|---|
| macOS | 13 及以上（与 Squirrel 1.x 一致） |
| 鼠须管 | 带 lua 插件，官方 1.1.x 已内置（`Squirrel.app/Contents/Frameworks/rime-plugins/librime-lua.dylib`） |
| 构建工具 | Xcode Command Line Tools（`xcode-select --install`），只为编译 Swift |
| 语音 | 系统自带 `Tingting`（zh-CN）；`rime-tts voices` 可列出全部 |

Rime 用户目录：`~/Library/Rime`。

---

## 安装

```sh
cd macos
./install.sh --patch          # 编译 + 安装 + 给所有 *.custom.yaml 加补丁 + 启动后台
./install.sh --patch --menubar   # 顺便打开控制面板（菜单栏同时常驻）
```

`install.sh` 做的事：

1. 用 `swiftc` 编译朗读器和菜单栏程序（`main.swift` + `RimeTtsMenuBar.swift` +
   `RimeTtsPanel.swift` + `RimeTtsModel.swift`）到 `bin/`；
2. 安装到 `~/.rime-tts-readback/bin/`（含 `rime-tts` 命令行）；
3. 把 `rime/rime.lua` 安装到 `~/Library/Rime/rime.lua`；
4. 建好 `~/Library/Rime/tts_queue`；
5. `--patch` 时给每个 `*.custom.yaml` 插入：

   ```yaml
   patch:
     # >>> rime-tts-readback >>>
     "engine/processors/@before 0": "lua_processor@tts_reporter"
     # <<< rime-tts-readback <<<
   ```

6. 启动后台朗读。

然后**重新部署**鼠须管（菜单栏「ㄓ」→ 重新部署，或 `rime-tts reload`）。

> 不想用 `--patch` 也行：控制面板里的「部署到 Rime」按钮做同样的事，而且只会改已启用方案。

### 装到 PATH

```sh
echo 'export PATH="$HOME/.rime-tts-readback/bin:$PATH"' >> ~/.zshrc
```

---

## 命令行

| 操作 | 命令 |
|---|---|
| 静音 / 恢复 | `rime-tts off` / `rime-tts on` |
| 停止 / 启动后台 | `rime-tts stop` / `rime-tts start` |
| 状态 | `rime-tts status` |
| 完整检测报告 | `rime-tts check` |
| 可用语音 | `rime-tts voices` |
| 部署 / 删除回读 | `rime-tts deploy` / `rime-tts remove` |
| 只改补丁 | `rime-tts patch` / `rime-tts unpatch` |
| 重新部署 Rime | `rime-tts reload` |
| 看日志 | `rime-tts log -f` |
| 编辑配置 | `rime-tts config` |
| 打开控制面板 | `rime-tts panel` |

## 控制面板

`rime-tts panel`（或点菜单栏图标里的「打开控制面板…」）打开和 Windows 版对应的原生窗口：

- **状态**：鼠须管版本、Rime 目录、`rime.lua` 是否安装、打了几个方案补丁、朗读器是否在跑、队列长度；
- **操作**：一键安装（部署 + 自启）、部署到 Rime、静音/取消静音、启动/停止后台、删除回读、仅重新部署、清空队列；
- **语音**：语音下拉框（中文语音排在最前）+ 试听、语速、音量、合并窗口、最长等待、逐字朗读、朗读数字、朗读英文；
- **程序筛选**：全部 / 仅这些 / 除这些，点「添加程序…」从**正在运行的程序**里带图标多选，列表里存 bundle id；
- **其它**：登录自启、全局快捷键 `⌃⌥R`（静音/恢复）、打开日志、打开配置、关于。

改动会立刻写入 `~/.rime-tts-readback/config.json`，朗读器约 1 秒内热加载，不用重启。
关掉窗口只会退回菜单栏（窗口开着时 Dock 里会出现图标，关掉后恢复「无 Dock 图标」），
后台朗读、快捷键和菜单栏都不受影响。

macOS 面板没有 Windows 的 `Threshold` / `PadMs` / `BreakMs`——那三个是合成 WAV、裁静音用的，
macOS 直接喂 `AVSpeechUtterance`，不需要。

## 菜单栏图标

`rime-tts menubar` 或 `install.sh --menubar`：启动后常驻菜单栏并打开控制面板；
关掉窗口后只剩状态图标（没有 Dock 图标）。状态图标：

- 实心文字气泡（里面一个 A）：已启用（后台在跑）
- 文字气泡 + 斜杠：已静音
- 空心文字气泡：已部署，但后台没跑
- ❓：还没部署

菜单里可以：打开控制面板、静音/取消静音、启动/停止后台、试听、重新部署、删除回读、打开日志/配置/Rime 目录、
清空队列、开机自启、关于。点「打开控制面板…」（或 `rime-tts panel`）就是下面的完整窗口。

---

## 配置

`~/.rime-tts-readback/config.json`，**改完约 1 秒内热加载**，不用重启：

```json
{
  "Voice": "Tingting",
  "Rate": 0,
  "IdleMs": 60,
  "MaxWaitMs": 200,
  "Volume": 100,
  "CharByChar": false,
  "ReadDigits": true,
  "ReadEnglish": true,
  "AppFilterMode": "all",
  "AppFilterList": [],
  "HotKey": ""
}
```

| 参数 | 默认 | 含义 |
|---|---|---|
| `Voice` | `Tingting` | 语音名、语音标识符，或语言代码（`zh-CN`） |
| `Rate` | `0` | -10..10，与 Windows 同义（映射到 `AVSpeechUtterance.rate`） |
| `IdleMs` / `MaxWaitMs` | `60` / `200` | 上屏合并窗口 |
| `Volume` | `100` | 0..100（macOS 输出已是满刻度，没有 Windows 那套峰值归一化） |
| `CharByChar` | `false` | `true` 用全角逗号分隔每个字 |
| `ReadDigits` | `true` | 是否读数字（逐个读） |
| `ReadEnglish` | `true` | 是否读 ASCII 字母（含鼠须管英文模式下直接敲的字母） |
| `AppFilterMode` / `AppFilterList` | `all` / 空 | `all` / `only` / `except`，列表项写 **bundle id**（如 `com.apple.Safari`）或应用名 |
| `HotKey` | 空 | `ctrl+alt+r` = 启用 `⌃⌥R` 全局静音/恢复；空 = 关闭。面板里的勾选框会维护它 |

日志：`~/.rime-tts-readback/watcher.log`（超过 1 MB 自动轮转）。

> Windows 版在中文里不能用 SSML `<break>`（SAPI 的 bug）。macOS 走的是纯文本
> `AVSpeechUtterance`，没有 SSML，所以这条坑在这里不存在。

---

## 目录布局

```
~/.rime-tts-readback/          状态目录（RIME_TTS_STATE 可覆盖）
├─ bin/
│  ├─ rime-tts                 命令行
│  ├─ rime-tts-watcher         常驻朗读器
│  └─ rime-tts-menubar         菜单栏图标
├─ share/rime.lua              「部署到 Rime」用的源文件
├─ config.json
├─ watcher.log
└─ watcher.pid

~/Library/Rime/                Rime 用户目录（RIME_USER_DIR 可覆盖）
├─ rime.lua
├─ tts_queue/                  上屏队列（RIME_TTS_DIR 可覆盖）
└─ tts_off                     静音标志
```

队列放在 Rime 用户目录里而不是 `$HOME`，这样即使将来鼠须管以沙盒方式运行也写得进去。
要把队列放到别处就设 `RIME_TTS_DIR`（它指向**队列目录本身**），`rime.lua` 与朗读器两边都认它；
`RIME_USER_DIR` 只影响朗读器/菜单栏认定的 Rime 目录。

---

## 开机自启

控制面板或菜单栏 →「登录时自动启动」，会写
`~/Library/LaunchAgents/com.graychan.rime-tts-readback.menubar.plist`（`launchctl load -w`，
程序参数带 `--background`，所以登录时只常驻菜单栏、不弹窗口）。
菜单栏程序自己会拉起并看护朗读器进程，所以不需要第二个 LaunchAgent。
如果登录项启动时已经有一个实例在跑，它只会安静退出，不会弹「已在运行」。

## 卸载

```sh
./uninstall.sh            # 交互确认
./uninstall.sh --force    # 不问
```

停止后台与菜单栏、去掉所有 `*.custom.yaml` 里的补丁、删除 `rime.lua`、删除状态目录与队列、
移除自启项、重新部署 Rime。仓库目录不动。

---

## 已知限制 / 注意

- 只有**经 Rime 上屏**的内容才会被朗读（和 Windows 版一致，这是设计目标）。
  唯一例外是**裸数字**：没在组字时按下的 0-9 会被 `rime.lua` 直接补报进队列，按键本身照常交给系统，
  不影响输入，也不会在读候选时误报。数字一律**逐个读**（`12` 读作「一、二」，不是「十二」），
  数字之间用短空格分隔、语速再略快一点，连续数字会先合并成一句再逐位念，避免念数字拖住后面的汉字。
  鼠须管**英文模式**下敲的字母也会补报，并按**字母逐个**念（`abc` → a b c，`abc123` → a b c 1 2 3）；
  切到系统 ABC 等其他输入法时，输入法看不到按键，仍然读不到。
- `Rate` 与 Windows 的 SAPI 语速不是同一套引擎，同一数值听感会不同；先用「试听」调。
- 语音列表里带括号的「个人语音」（如 `Eddy (中文（中国大陆）)`）也能用，名字要写全。
- 程序筛选基于「当前前台应用」，取的是**这一批上屏的第一条**到达时的前台应用。
- 全局快捷键 `⌃⌥R` 用 Carbon `RegisterEventHotKey` 注册，不需要辅助功能权限；被别的程序占用时，
  面板会提示并自动取消勾选。
- 菜单栏图标与朗读器都不签名。自己编译自用没问题；要分发给别人则需要签名 + 公证。

---

## 跨平台

`rime/rime.lua`、队列格式和配置键在 Windows / macOS / Linux 之间共享。
Windows 已完成逐位数字、逐字母英文与分开的开关；Linux 实现见
[../linux/README.md](../linux/README.md)，平台对齐清单见 [../DEVELOPING.md](../DEVELOPING.md)。
