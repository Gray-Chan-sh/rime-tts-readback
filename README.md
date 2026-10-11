# rime-tts-readback

[English](README.en.md) ｜ **简体中文**

逐字朗读你在 Rime 里**上屏**的内容，使用 Windows 自带语音（TTS）——
**绝不朗读**候选窗里显示的编码。

用五笔输入 `cfgf` 时候选框保持安静；当你选字上屏、`对于` 落到文档里，才会被逐字读出。

在 **小狼毫 / Weasel 0.17.4**（librime 1.13.1）上开发与验证，中文语音使用
`Microsoft Huihui Desktop`。

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

### 低延迟的关键

Windows SAPI 的"默认音频输出"看起来慢，其实不然：

| 输出方式 | 1 个字 |
|---|---|
| 合成到 WAV 文件 | **约 20ms** |
| 输出到 NULL | 约 3ms |
| 输出到默认音频设备 | 约 950ms |

那 ~950ms 几乎全是**静音**：SAPI 会在每句话前后各塞约 0.45 秒静音（一个字的 WAV 约 0.9 秒长）。
所以我们自己合成成 WAV、裁掉静音、再播放。出声延迟从约 1 秒降到 **0.1–0.3 秒**，也不浪费时间播静音。

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
- 其它前端（鼠须管 Squirrel、ibus-rime、fcitx5-rime）：`rime/rime.lua` 稍改路径（`HOME` + 平台分隔符）即可用，但朗读器与控制面板是 Windows 专属。

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

---

## 安装

1. 把 Lua 部分复制到 Rime 用户目录（`%APPDATA%\Rime\`）：

   ```
   rime\rime.lua   ->   %APPDATA%\Rime\rime.lua
   ```

2. 把你使用的方案挂上"报告器"。在每个 `*.custom.yaml` 里加上（参考 `rime\wubi86.custom.yaml.example`）：

   ```yaml
   patch:
     engine/processors/+:
       - lua_processor@tts_reporter
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

---

## 用法

| 操作 | 命令 |
|---|---|
| 立即静音 / 恢复（后台继续运行） | `Rime_tts_off.bat` / `Rime_tts_on.bat` |
| 停止 / 启动后台朗读 | `Rime_tts_stop.bat` / `Rime_tts_start.bat` |
| 开机自启 | 把 `Rime_tts_start.bat` 的快捷方式放进 `shell:startup` |
| 彻底移除 | `Rime_tts_stop.bat`，删除 `%APPDATA%\Rime\rime.lua`，去掉 `lua_processor@tts_reporter` 那几行，再重新部署 |

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
- **参数**——语音（从已装 SAPI 语音中选择，带试听）、`Rate`、`BreakMs`、`IdleMs`、`MaxWaitMs`、`Threshold`、`PadMs`、`Volume`、`CharByChar`、`IncludeAscii`，保存到 `%USERPROFILE%\Rime_tts_config.json`；后台会**热加载**（约 1 秒内生效，无需重启）。
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

## 配置

可以直接改 `windows\Rime_tts_watcher.ps1` 顶部的参数，然后重启朗读器。
（用 GUI 更方便：在"参数"里改，它会写入 `%USERPROFILE%\Rime_tts_config.json`，后台会热加载。）

| 参数 | 默认 | 含义 |
|---|---|---|
| `-Voice` | `Microsoft Huihui Desktop` | SAPI 语音 |
| `-Rate` | `0` | 语速 -10..10（越小每个字读得越长越清晰） |
| `-BreakMs` | `30` | 逐字朗读时字间插入的静音（毫秒） |
| `-IdleMs` | `60` | 这段时间内到达的上屏会合并成一次朗读 |
| `-MaxWaitMs` | `200` | 最多等这么久就开读 |
| `-Threshold` / `-PadMs` | `180` / `15` | 静音判定阈值与保留边距 |
| `-Volume` | `100` | 音量 0..100（只影响本程序） |
| `-CharByChar` | `true` | 逐字朗读；`false` 为整句连读 |
| `-IncludeAscii` | `true` | 是否也朗读 ASCII 字母/数字 |
| `-AppFilterMode` / `-AppFilterList` | `all` / 空 | 程序筛选：`all` / `only` / `except` |

日志位于 `%USERPROFILE%\Rime_tts_watcher.log`（超过 1 MB 自动轮转）。

## 目录结构

```
rime-tts-readback/
├─ rime/
│  ├─ rime.lua                          # commit_notifier -> 队列文件（放到 %APPDATA%\Rime）
│  ├─ wubi86.custom.yaml.example        # 方案补丁示例
│  └─ wubi_pinyin.custom.yaml.example
├─ windows/
│  ├─ RimeTtsReadback.Gui.ps1           # WinForms 控制面板
│  ├─ RimeTtsReadback.bat               # 面板启动器
│  ├─ Rime_tts_watcher.ps1              # 常驻低延迟朗读器
│  ├─ Rime_tts_start.bat / Rime_tts_stop.bat
│  ├─ Rime_tts_stop.ps1
│  └─ Rime_tts_off.bat / Rime_tts_on.bat
├─ icons/
│  ├─ rime-tts-readback.ico             # 应用图标（声波 + 键盘）
│  ├─ tray-ok.ico / tray-warn.ico / tray-off.ico
├─ tools/
│  ├─ make-icons.ps1                    # 重新生成 icons/（GDI+，多尺寸 DIB）
│  ├─ build-release.ps1                 # 便携 zip  -> dist/rime-tts-readback-<v>.zip
│  └─ build-exe.ps1                     # 单文件 exe -> dist/RimeTtsReadback-<v>.exe
├─ .github/workflows/build.yml          # CI：构建 zip + exe 并发布到 Release
├─ install.ps1
└─ uninstall.ps1
```

## 已知限制

- **只有经 Rime 上屏(commit)的内容才会被朗读。** 直接输入（ASCII 直通、或绕过输入法的程序）不会产生 commit 事件，因此不会进队列、也不会被朗读。这是**有意为之**——正是它保证了候选窗里的编码不被读出。
- 输出是**逐字**的（面向校对），所以长句就是需要那么久，无法比语音本身更快。
- 设计上**绝不在输入法内部启动进程**。早期版本在 commit 回调里用 `os.execute()`，会阻塞输入法线程、甚至冻住整个桌面。**不要在 Lua 路径里放任何阻塞操作。**
- 数字/英文只有在**经输入法上屏**时才会读；直接敲的不会（同上）。
- 程序筛选依赖"当前前台窗口"，极快切换程序时可能极小概率误判。

## 构建与发布

```
powershell -ExecutionPolicy Bypass -File tools\build-release.ps1   # dist\rime-tts-readback-<v>.zip
powershell -ExecutionPolicy Bypass -File tools\build-exe.ps1       # dist\RimeTtsReadback-<v>.exe
```

- `build-release.ps1` 把整个项目打包成 zip（便携脚本，无安装程序）。
- `build-exe.ps1` 把全部内容打包成**单文件自解压 exe**，用 Windows 自带的 `csc.exe` 编译（无需下载）。
  运行时释放到 `%LOCALAPPDATA%\RimeTtsReadback\<版本>\`（仅当版本/内容变化时），然后启动控制面板；
  命令行参数会转发给 GUI 脚本。

CI：`.github/workflows/build.yml` 在每次推送到 `main` 时构建两者并上传为 artifacts；对 `v*` 标签，
还会把它们挂到对应的 GitHub Release。

## 许可证

MIT —— 见 [LICENSE](LICENSE)。
