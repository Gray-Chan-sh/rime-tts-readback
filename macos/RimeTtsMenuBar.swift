// RimeTtsMenuBar.swift - the macOS app: menu bar switch + control panel host
//
// A menu bar item (no Dock icon while idle) that can
//   * open the control panel (the counterpart of the Windows GUI)
//   * mute / unmute readback            (the tts_off flag file)
//   * start / stop the reader daemon
//   * deploy / remove the Lua side in ~/Library/Rime and reload Squirrel
//   * open the log / config, toggle launch-at-login, speak a test phrase
//   * quit
//
// The window itself lives in RimeTtsPanel.swift; this file owns the paths, the
// deployment / process helpers and the PanelActions implementation.
//
// Build: see build.sh (main.swift + this file + RimeTtsModel/Panel.swift)
//
// ASCII-only source on purpose.

import Foundation
import AppKit
import Darwin

let APP_VERSION = "1.0.0"
let AGENT_LABEL = "com.graychan.rime-tts-readback.menubar"

// ---------------------------------------------------------------- paths

let fm = FileManager.default
let env = ProcessInfo.processInfo.environment
let homeDir = env["HOME"] ?? fm.homeDirectoryForCurrentUser.path
let stateDir = env["RIME_TTS_STATE"] ?? homeDir + "/.rime-tts-readback"
let rimeDir = env["RIME_USER_DIR"] ?? homeDir + "/Library/Rime"

let queueDir = env["RIME_TTS_DIR"] ?? rimeDir + "/tts_queue"
let offFile = rimeDir + "/tts_off"
let configFile = stateDir + "/config.json"
let logFile = stateDir + "/watcher.log"
let pidFile = stateDir + "/watcher.pid"
let panelRequestFile = stateDir + "/panel.request"
let agentPlist = homeDir + "/Library/LaunchAgents/" + AGENT_LABEL + ".plist"

let squirrelApp = "/Library/Input Methods/Squirrel.app"
let squirrelBinary = squirrelApp + "/Contents/MacOS/Squirrel"

let selfPath: String = {
    let raw = CommandLine.arguments.first ?? ""
    let abs = raw.hasPrefix("/") ? raw : (Bundle.main.executablePath ?? raw)
    if let resolved = realpath(abs, nil) { defer { free(resolved) }; return String(cString: resolved) }
    return abs
}()

func firstExisting(_ candidates: [String]) -> String? {
    candidates.first { fm.fileExists(atPath: $0) }
}

var watcherBinary: String {
    firstExisting([
        stateDir + "/bin/rime-tts-watcher",
        (selfPath as NSString).deletingLastPathComponent + "/rime-tts-watcher",
    ]) ?? stateDir + "/bin/rime-tts-watcher"
}

var rimeLuaSource: String? {
    firstExisting([
        stateDir + "/share/rime.lua",
        (selfPath as NSString).deletingLastPathComponent + "/rime.lua",
        (selfPath as NSString).deletingLastPathComponent + "/../rime/rime.lua",
    ])
}

// ---------------------------------------------------------------- small helpers

func run(_ launchPath: String, _ args: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func watcherPid() -> pid_t? {
    guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
          let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
    return kill(pid, 0) == 0 ? pid : nil
}

var isRunning: Bool { watcherPid() != nil }
var isMuted: Bool { fm.fileExists(atPath: offFile) }
var isDeployed: Bool {
    guard let lua = try? String(contentsOfFile: rimeDir + "/rime.lua", encoding: .utf8) else { return false }
    return lua.contains("tts_reporter")
}

// ---------------------------------------------------------------- deployment

func enabledSchemas() -> [String] {
    for f in [rimeDir + "/default.custom.yaml", rimeDir + "/build/default.yaml"] {
        guard let text = try? String(contentsOfFile: f, encoding: .utf8) else { continue }
        var found: [String] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("-") else { continue }
            let body = line.dropFirst()
                .replacingOccurrences(of: "{", with: " ")
                .replacingOccurrences(of: "}", with: " ")
            // "- schema: luna_pinyin" / "- { schema: luna_pinyin }"
            guard let range = body.range(of: "schema:") else { continue }
            let rest = body[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let token = rest.split(separator: " ").first else { continue }
            let name = token.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
            if !name.isEmpty && !found.contains(name) { found.append(name) }
        }
        if !found.isEmpty { return found }
    }
    let build = (try? fm.contentsOfDirectory(atPath: rimeDir + "/build")) ?? []
    let fromBuild = build.filter { $0.hasSuffix(".schema.yaml") }
        .map { $0.replacingOccurrences(of: ".schema.yaml", with: "") }
    if !fromBuild.isEmpty { return fromBuild }
    // last resort: schema files that live directly in the user directory
    let root = (try? fm.contentsOfDirectory(atPath: rimeDir)) ?? []
    return root.filter { $0.hasSuffix(".schema.yaml") }
        .map { $0.replacingOccurrences(of: ".schema.yaml", with: "") }
}

@discardableResult
func addReadbackPatch(_ path: String) -> Bool {
    var text: String
    if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
        text = existing
    } else {
        text = "patch:\n"
    }

    // The processor must run *first*: appended after the editor it never sees a
    // bare digit (the editor/selector consume or reject it before we are called).
    if text.contains("@before 0") && text.contains("lua_processor@tts_reporter") {
        return false
    }
    if text.contains("lua_processor@tts_reporter") || text.contains("rime-tts-readback") {
        // upgrade the old "engine/processors/+:" (append) form
        _ = removeReadbackPatch(path)
        text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "patch:\n"
    }

    var out: [String] = []
    var inserted = false
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        out.append(line)
        if !inserted && line.trimmingCharacters(in: .whitespaces) == "patch:" {
            out.append("  # >>> rime-tts-readback >>>")
            out.append("  \"engine/processors/@before 0\": \"lua_processor@tts_reporter\"")
            out.append("  # <<< rime-tts-readback <<<")
            inserted = true
        }
    }
    if !inserted {
        out.append("")
        out.append("patch:")
        out.append("  # >>> rime-tts-readback >>>")
        out.append("  \"engine/processors/@before 0\": \"lua_processor@tts_reporter\"")
        out.append("  # <<< rime-tts-readback <<<")
    }
    try? (out.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    return true
}

@discardableResult
func removeReadbackPatch(_ path: String) -> Bool {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
    guard text.contains("rime-tts-readback") else { return false }
    var kept: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let s = String(line)
        if s.contains("rime-tts-readback") { continue }
        if s.contains("lua_processor@tts_reporter") { continue }
        kept.append(s)
    }
    var out: [String] = []
    var i = 0
    while i < kept.count {
        let line = kept[i]
        if line.trimmingCharacters(in: .whitespaces) == "engine/processors/+:" {
            var j = i + 1
            while j < kept.count, kept[j].trimmingCharacters(in: .whitespaces).isEmpty
                    || kept[j].trimmingCharacters(in: .whitespaces).hasPrefix("#") { j += 1 }
            if j >= kept.count || !kept[j].trimmingCharacters(in: .whitespaces).hasPrefix("-") {
                i += 1
                continue // drop a now-empty "engine/processors/+:" block
            }
        }
        out.append(line)
        i += 1
    }
    try? (out.joined(separator: "\n")).write(toFile: path, atomically: true, encoding: .utf8)
    return true
}

func reloadRime() -> String {
    guard fm.fileExists(atPath: squirrelBinary) else { return "未找到 Squirrel，请手动重新部署" }
    let r = run(squirrelBinary, ["--reload"])
    return r.status == 0 ? "已重新部署 Rime" : "重新部署失败 (exit=\(r.status))"
}

func deployReadback() -> String {
    var messages: [String] = []
    try? fm.createDirectory(atPath: rimeDir, withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: queueDir, withIntermediateDirectories: true)
    if let src = rimeLuaSource {
        do {
            let dst = rimeDir + "/rime.lua"
            if fm.fileExists(atPath: dst) { try? fm.removeItem(atPath: dst) }
            try fm.copyItem(atPath: src, toPath: dst)
            messages.append("已安装 rime.lua")
        } catch { messages.append("复制 rime.lua 失败: \(error.localizedDescription)") }
    } else {
        messages.append("找不到 rime.lua（请重新运行 install.sh）")
    }
    var schemas = enabledSchemas()
    if schemas.isEmpty {
        // no default.custom.yaml / build yet (fresh install): patch what is there
        schemas = ((try? fm.contentsOfDirectory(atPath: rimeDir)) ?? [])
            .filter { $0.hasSuffix(".custom.yaml") }
            .map { $0.replacingOccurrences(of: ".custom.yaml", with: "") }
    }
    if schemas.isEmpty {
        messages.append("未检测到已启用方案，请手动给方案加补丁")
    }
    for schema in schemas {
        let file = rimeDir + "/" + schema + ".custom.yaml"
        messages.append(addReadbackPatch(file) ? "已加入补丁: \(schema).custom.yaml" : "已有补丁: \(schema).custom.yaml")
    }
    try? fm.removeItem(atPath: offFile)   // deploying implies "unmute"
    messages.append(reloadRime())
    startWatcher()
    return messages.joined(separator: "\n")
}

func removeReadback() -> String {
    var messages: [String] = []
    for name in ((try? fm.contentsOfDirectory(atPath: rimeDir)) ?? []) where name.hasSuffix(".custom.yaml") {
        if removeReadbackPatch(rimeDir + "/" + name) { messages.append("已移除补丁: \(name)") }
    }
    try? fm.removeItem(atPath: rimeDir + "/rime.lua")
    messages.append("已删除 rime.lua")
    try? fm.removeItem(atPath: offFile)
    stopWatcher()
    for name in ((try? fm.contentsOfDirectory(atPath: queueDir)) ?? []) {
        try? fm.removeItem(atPath: queueDir + "/" + name)
    }
    messages.append(reloadRime())
    return messages.joined(separator: "\n")
}

// ---------------------------------------------------------------- watcher control

@discardableResult
func startWatcher() -> Bool {
    guard isRunning == false else { return false }
    guard fm.fileExists(atPath: watcherBinary) else { return false }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: watcherBinary)
    p.arguments = ["--quiet"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    // give it a moment to write its pid file, so the icon/state is right immediately
    for _ in 0..<30 {
        if isRunning { return true }
        usleep(10_000)
    }
    return isRunning
}

func stopWatcher() {
    guard let pid = watcherPid() else { return }
    kill(pid, SIGTERM)
    for _ in 0..<20 {
        if kill(pid, 0) != 0 { break }
        usleep(50_000)
    }
}

// ---------------------------------------------------------------- autostart

var autostartEnabled: Bool { fm.fileExists(atPath: agentPlist) }

func setAutostart(_ on: Bool) -> Bool {
    if on {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(AGENT_LABEL)</string>
          <key>ProgramArguments</key>
          <array><string>\(selfPath)</string><string>--background</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><false/>
          <key>ProcessType</key><string>Interactive</string>
        </dict>
        </plist>
        """
        try? fm.createDirectory(atPath: (agentPlist as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? plist.write(toFile: agentPlist, atomically: true, encoding: .utf8)
        _ = run("/bin/launchctl", ["load", "-w", agentPlist])
        return true
    }
    _ = run("/bin/launchctl", ["unload", "-w", agentPlist])
    try? fm.removeItem(atPath: agentPlist)
    return false
}

// ---------------------------------------------------------------- headless modes
// Same code paths as the menu items, so they can be scripted and tested.

func statusReport() -> String {
    let state = !isDeployed ? "未部署" : isMuted ? "已静音" : isRunning ? "已启用" : "已启用（后台未运行）"
    return """
    Rime 回读（macOS）v\(APP_VERSION)
    状态     : \(state)
    Rime 目录: \(rimeDir)
    队列目录 : \(queueDir)
    配置     : \(configFile)
    日志     : \(logFile)
    开机自启 : \(autostartEnabled ? "开" : "关")
    """
}

// ---------------------------------------------------------------- menu

final class Controller: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var watchdog: Timer?
    var lastRestart = Date.distantPast
    var userStopped = false
    var panel: PanelController?
    let hotKey = GlobalHotKey()
    var hotKeyEnabled = false

    func setUp() {
        statusItem.button?.imagePosition = .imageOnly
        let menu = NSMenu()
        menu.delegate = self
        // Every item has an explicit target; validation would only get in the way
        // (and can leave items greyed out while the app is not frontmost).
        menu.autoenablesItems = false
        statusItem.menu = menu
        refreshIcon()
        if isDeployed && !isMuted { startWatcher() }

        hotKey.onPress = { [weak self] in
            guard let self = self, isDeployed else { return }
            self.toggleMute()
            self.panel?.refresh()
            self.refreshIcon()
        }
        applyHotKeyFromConfig()

        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(watchdog!, forMode: .common)
    }

    func tick() {
        // keep the icon fresh and restart the reader if it died on its own
        refreshIcon()
        panel?.refreshStatus()
        if fm.fileExists(atPath: panelRequestFile) {
            try? fm.removeItem(atPath: panelRequestFile)
            showPanel()
        }
        if !userStopped && !isMuted && isDeployed && !isRunning && Date().timeIntervalSince(lastRestart) > 30 {
            lastRestart = Date()
            startWatcher()
        }
    }

    func refreshIcon() {
        // A text bubble, not a loudspeaker: the menu bar already has a volume icon
        // and the two looked almost identical (SF Symbols' speaker.wave.2.fill).
        let name: String
        let tip: String
        var slashed = false
        if !isDeployed {
            name = "questionmark.circle"
            tip = "Rime 回读：未部署"
        } else if isMuted {
            name = "character.bubble.fill"
            slashed = true
            tip = "Rime 回读：已静音"
        } else if isRunning {
            name = "character.bubble.fill"
            tip = "Rime 回读：已启用"
        } else {
            name = "character.bubble"
            tip = "Rime 回读：后台未运行"
        }
        let image = menuBarImage(name, slashed: slashed, description: tip)
        statusItem.button?.image = image
        statusItem.button?.toolTip = tip
    }

    /// Template image at menu bar size; `slashed` adds the "muted" diagonal.
    func menuBarImage(_ symbol: String, slashed: Bool, description: String) -> NSImage? {
        var base = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        if base == nil {
            // older SF Symbols: still better than no icon at all
            base = NSImage(systemSymbolName: "text.bubble.fill", accessibilityDescription: description)
                ?? NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: description)
        }
        guard let base = base else { return nil }
        let size = NSSize(width: 18, height: 18)
        guard slashed else {
            base.isTemplate = true
            return base
        }
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            let path = NSBezierPath()
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.move(to: NSPoint(x: 5, y: 5))
            path.line(to: NSPoint(x: 13.5, y: 13.5))
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    // ---- menu content
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = !isDeployed ? "未部署"
            : isMuted ? "已静音"
            : isRunning ? "已启用" : "已启用（后台未运行）"
        menu.addItem(disabled("Rime 回读：\(state)  v\(APP_VERSION)"))
        menu.addItem(.separator())

        menu.addItem(item("打开控制面板…", #selector(showPanel), key: "o"))
        menu.addItem(.separator())

        if isDeployed {
            menu.addItem(item(isMuted ? "取消静音（开始朗读）" : "静音", #selector(toggleMute), key: "m"))
        } else {
            menu.addItem(item("部署到 Rime", #selector(deploy), key: "d"))
        }
        menu.addItem(item(isRunning ? "停止后台朗读" : "启动后台朗读", #selector(toggleWatcher)))

        let test = item("试听（朗读一句话）", #selector(testSpeak))
        test.isEnabled = isDeployed && !isMuted
        menu.addItem(test)
        menu.addItem(.separator())

        menu.addItem(item("仅重新部署 Rime", #selector(reloadOnly), key: "r"))
        if isDeployed { menu.addItem(item("删除回读功能", #selector(removeFeature))) }
        menu.addItem(.separator())

        menu.addItem(item("打开日志", #selector(openLog)))
        menu.addItem(item("打开配置", #selector(openConfig)))
        menu.addItem(item("打开 Rime 目录", #selector(openRimeDir)))
        if fm.fileExists(atPath: queueDir) { menu.addItem(item("清空队列", #selector(clearQueue))) }
        menu.addItem(.separator())

        let login = item("开机自启", #selector(toggleAutostart))
        login.state = autostartEnabled ? .on : .off
        login.target = self
        menu.addItem(login)
        menu.addItem(item("关于 / 检测", #selector(about)))
        menu.addItem(.separator())
        menu.addItem(item("退出", #selector(quit), key: "q"))
    }

    // ---- helpers
    func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }
    func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    func alert(_ title: String, _ message: String, style: NSAlert.Style = .informational) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = style
        a.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // ---- panel / hotkey

    @objc func showPanel() {
        if panel == nil {
            panel = PanelController(actions: self)
        }
        panel?.present()
    }

    func applyHotKeyFromConfig() {
        let config = ReadbackConfig.load(from: configFile)
        _ = setHotKey(!config.hotKey.isEmpty)
    }

    @discardableResult
    func setHotKey(_ on: Bool) -> Bool {
        if on {
            hotKeyEnabled = hotKey.register()
        } else {
            hotKey.unregister()
            hotKeyEnabled = false
        }
        return hotKeyEnabled
    }

    // ---- actions
    @objc func toggleMute() {
        if isMuted {
            try? fm.removeItem(atPath: offFile)
            if !isRunning { userStopped = false; startWatcher() }
        } else {
            try? "1".write(toFile: offFile, atomically: true, encoding: .utf8)
        }
        refreshIcon()
        panel?.refresh()
    }

    @objc func toggleWatcher() {
        if isRunning {
            userStopped = true
            stopWatcher()
        } else {
            userStopped = false
            startWatcher()
        }
        refreshIcon()
        panel?.refresh()
    }

    @objc func deploy() {
        alert("部署回读功能", deployReadback())
        userStopped = false
        refreshIcon()
        panel?.refresh()
    }

    @objc func removeFeature() {
        alert("删除回读功能", removeReadback())
        refreshIcon()
        panel?.refresh()
    }

    @objc func reloadOnly() {
        alert("重新部署 Rime", reloadRime())
        panel?.refresh()
    }

    @objc func testSpeak() {
        guard fm.fileExists(atPath: watcherBinary) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: watcherBinary)
        p.arguments = ["--queue", stateDir + "/test_queue", "--off-file", stateDir + "/test_off",
                       "--config", configFile, "--run-seconds", "6", "--quiet"]
        try? fm.createDirectory(atPath: stateDir + "/test_queue", withIntermediateDirectories: true)
        try? "对于这个问题，我们需要注意。".write(toFile: stateDir + "/test_queue/test.txt",
                                                 atomically: true, encoding: .utf8)
        try? p.run()
    }

    @objc func openLog() {
        if !fm.fileExists(atPath: logFile) { try? "".write(toFile: logFile, atomically: true, encoding: .utf8) }
        _ = run("/usr/bin/open", ["-R", logFile])
    }

    @objc func openConfig() {
        if !fm.fileExists(atPath: configFile) {
            let defaults = """
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
              "AppFilterList": []
            }
            """
            try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
            try? defaults.write(toFile: configFile, atomically: true, encoding: .utf8)
        }
        _ = run("/usr/bin/open", ["-t", configFile])
    }

    @objc func openRimeDir() {
        _ = run("/usr/bin/open", [rimeDir])
    }

    @objc func clearQueue() {
        for name in ((try? fm.contentsOfDirectory(atPath: queueDir)) ?? []) {
            try? fm.removeItem(atPath: queueDir + "/" + name)
        }
    }

    @objc func toggleAutostart() {
        _ = setAutostart(!autostartEnabled)
    }

    @objc func about() {
        alert("关于 Rime 回读", aboutText())
    }

    func aboutText() -> String {
        let voices = run(watcherBinary, ["--list-voices"]).out
            .split(separator: "\n").prefix(6).joined(separator: "\n")
        return """
        Rime 回读（macOS）v\(APP_VERSION)

        Rime 用户目录 : \(rimeDir)
        队列目录      : \(queueDir)
        配置          : \(configFile)
        日志          : \(logFile)
        Squirrel      : \(fm.fileExists(atPath: squirrelApp) ? "已安装" : "未检测到")
        rime.lua      : \(isDeployed ? "已安装" : "未安装")
        后台朗读      : \(isRunning ? "运行中" : "已停止")
        开机自启      : \(autostartEnabled ? "开" : "关")

        部分可用语音：
        \(voices)
        """
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

// ---------------------------------------------------------------- panel actions
// The window is deliberately dumb: it only edits config.json and calls these.

extension Controller: PanelActions {
    func panelState() -> ReadbackState {
        var version: String? = nil
        if fm.fileExists(atPath: squirrelApp) {
            let info = Bundle(path: squirrelApp)?.infoDictionary
                ?? (NSDictionary(contentsOfFile: squirrelApp + "/Contents/Info.plist") as? [String: Any])
            version = info?["CFBundleShortVersionString"] as? String
                ?? info?["CFBundleVersion"] as? String
                ?? "?"
        }
        var patched: [String] = []
        for name in ((try? fm.contentsOfDirectory(atPath: rimeDir)) ?? []).sorted()
        where name.hasSuffix(".custom.yaml") {
            let path = rimeDir + "/" + name
            if let text = try? String(contentsOfFile: path, encoding: .utf8),
               text.contains("rime-tts-readback") {
                patched.append(String(name.dropLast(".custom.yaml".count)))
            }
        }
        let queueCount = ((try? fm.contentsOfDirectory(atPath: queueDir)) ?? [])
            .filter { $0.hasSuffix(".txt") }.count
        return ReadbackState(squirrelVersion: version,
                             rimeDir: rimeDir,
                             luaInstalled: isDeployed,
                             patchedSchemas: patched,
                             muted: isMuted,
                             watcherRunning: isRunning,
                             autostart: autostartEnabled,
                             queueCount: queueCount)
    }

    func panelConfig() -> ReadbackConfig {
        ReadbackConfig.load(from: configFile)
    }

    func panelSave(_ config: ReadbackConfig) {
        config.save(to: configFile)
    }

    func panelInstall() -> String {
        var text = deployReadback()
        _ = setAutostart(true)
        userStopped = false
        startWatcher()
        refreshIcon()
        text += "\n已开启登录时自动启动。"
        return text
    }

    func panelDeploy() -> String {
        let text = deployReadback()
        userStopped = false
        refreshIcon()
        return text
    }

    func panelRemove() -> String {
        let text = removeReadback()
        refreshIcon()
        return text
    }

    func panelRedeploy() -> String {
        reloadRime()
    }

    func panelToggleMute() -> Bool {
        toggleMute()
        return isMuted
    }

    func panelToggleWatcher() -> Bool {
        toggleWatcher()
        return isRunning
    }

    func panelSetAutostart(_ on: Bool) -> Bool {
        _ = setAutostart(on)
        refreshIcon()
        return autostartEnabled
    }

    func panelSetHotKey(_ on: Bool) -> Bool {
        let ok = setHotKey(on)
        return ok
    }

    func panelOpenLog() { openLog() }
    func panelOpenConfig() { openConfig() }
    func panelOpenRimeDir() { openRimeDir() }
    func panelClearQueue() {
        clearQueue()
        panel?.refresh()
    }
    func panelAbout() -> String { aboutText() }
}

// ---------------------------------------------------------------- entry

let instanceLockPath = stateDir + "/menubar.pid"
var sharedController: Controller?
var menuSignalSources: [DispatchSourceSignal] = []

enum RimeTtsApp {
    static func helpText() -> String {
        """
        rime-tts-menubar \(APP_VERSION) - Rime 回读（macOS）

        usage: rime-tts-menubar [--background] [--show] [--deploy|--remove|--status|--help]

          (no option)   打开控制面板并常驻菜单栏
          --background  只常驻菜单栏，不打开窗口（登录自启用）
          --show        已经运行时，让现有实例打开控制面板
          --deploy      部署 rime.lua + 方案补丁，然后重新加载 Squirrel
          --remove      撤销补丁、删除 rime.lua、停止朗读
          --status      打印当前状态
        """
    }

    static func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: "Rime 回读")
        appItem.submenu = appMenu

        let about = NSMenuItem(title: "关于 Rime 回读",
                               action: #selector(Controller.about), keyEquivalent: "")
        about.target = sharedController
        appMenu.addItem(about)

        let panel = NSMenuItem(title: "打开控制面板",
                               action: #selector(Controller.showPanel), keyEquivalent: "o")
        panel.target = sharedController
        appMenu.addItem(panel)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Rime 回读",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Rime 回读",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化",
                           action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭",
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    static func run() {
        let args = Array(CommandLine.arguments.dropFirst())

        // headless modes first: no NSApplication, so CI and scripts stay quiet
        if args.contains("--deploy") { print(deployReadback()); exit(0) }
        if args.contains("--remove") { print(removeReadback()); exit(0) }
        if args.contains("--status") { print(statusReport()); exit(0) }
        if args.contains("--help") || args.contains("-h") { print(helpText()); exit(0) }

        // ------------------------------------------------------------ single instance
        try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        let lockFd = open(instanceLockPath, O_CREAT | O_RDWR, 0o644)
        if lockFd >= 0 {
            if flock(lockFd, LOCK_EX | LOCK_NB) != 0 {
                if args.contains("--show") {
                    // another instance owns the lock: ask it to raise its window
                    try? "1".write(toFile: panelRequestFile, atomically: true, encoding: .utf8)
                }
                // A launchd start (login item) must never pop an alert when the
                // app is already running; just let the first instance win.
                if args.contains("--background") || args.contains("--show") {
                    exit(0)
                }
                let alert = NSAlert()
                alert.messageText = "Rime 回读已在运行"
                alert.informativeText = "菜单栏图标已经存在，请查看通知栏。"
                alert.addButton(withTitle: "好")
                alert.runModal()
                exit(0)
            }
            ftruncate(lockFd, 0)
            _ = "\(getpid())".withCString { write(lockFd, $0, strlen($0)) }
        }

        // ------------------------------------------------------------ main
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = Controller()
        sharedController = controller
        buildMainMenu()
        controller.setUp()

        if !args.contains("--background") {
            controller.showPanel()
        }

        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        for sig in [SIGTERM, SIGINT] {
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                try? fm.removeItem(atPath: instanceLockPath)
                exit(0)
            }
            src.resume()
            menuSignalSources.append(src)
        }

        app.run()
    }
}