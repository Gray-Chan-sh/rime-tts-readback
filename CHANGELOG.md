# Changelog

## Unreleased

- 控制面板退出时，如果朗读仍在运行，提示是否禁用朗读。选择禁用会设置静音并停止后台朗读，直到手动重新开启；选择保留则按当前状态退出。

## 1.1.0 — 2026-10-22

首个三平台版本。Windows、macOS、Linux 共用同一套 `rime/rime.lua` 上报层、
`tts_queue` 队列协议和 `config.json` 语义。

### Windows

- 新增「朗读数字」「朗读英文」两个独立开关；`abc123` 可按字符逐个朗读。
- 上屏合并改为可配置的 `IdleMs` / `MaxWaitMs`，连续上屏只读一次。
- 方案补丁位置修正为 `engine/processors/@before 0`。
- `Rime_tts_watcher.ps1` 拆分 ASCII 部分，保持 PowerShell 5.1 兼容。
- GUI / 托盘补齐静音、启停、试听、部署、移除、打开日志等操作。

### macOS

- 新增原生菜单栏应用与控制面板（Swift/AppKit），空闲时无 Dock 图标。
- 常驻 `rime-tts-watcher` 使用 `AVSpeechSynthesizer`，避免 `say(1)` 的进程握手延迟。
- 支持部署/撤销 `rime.lua`、方案补丁、Squirrel 重载、登录启动。
- 新增 DMG：自包含 `.app`，ad-hoc 签名；macOS 13+，Apple Silicon。

### Linux

- 新增 fcitx5-rime / ibus-rime / fcitx4-rime 支持，纯 Python 3 标准库。
- 朗读器、CLI、Tk 控制面板、可选 GTK3 托盘、X11 全局快捷键。
- TTS 优先 `spd-say`，回退 `espeak-ng` / `espeak`。
- 新增 AppImage：内置 CPython + Tk，单文件运行。
- 支持 XDG 登录自启；AppImage 使用 `--reader-daemon` 保持挂载点存活。

### 共享 / 构建

- `rime/rime.lua` 只读上屏 commit，Lua 路径不阻塞输入。
- 三端共用队列协议和配置语义。
- CI 三平台构建，tag 自动发布 zip/exe/dmg/AppImage/tar.gz 与 `SHA256SUMS.txt`。
- 文档补充三平台安装、预编译包和平台差异说明。

### 下载

- Windows：`RimeTtsReadback-1.1.0.exe`
- macOS：`rime-tts-readback-1.1.0.dmg`
- Linux：`rime-tts-readback-1.1.0-x86_64.AppImage`

### 注意

- macOS DMG 为 Apple Silicon（arm64）构建，未公证；首次打开如被 Gatekeeper
  拦截，右键 →「打开」。
- Linux AppImage 自带 Python/Tk；语音仍需系统的 `spd-say` 或 `espeak-ng`，
  托盘仍需要系统的 GTK3 PyGObject。
