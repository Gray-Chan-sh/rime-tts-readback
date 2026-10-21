// RimeTtsPanel.swift - the control panel window (counterpart of the Windows GUI)
//
// AppKit, built in code, no nib/storyboard: the binary is a plain command line
// executable, so there is no bundle to load resources from.
//
// Sections:
//   status       - Squirrel / rime.lua / patched schemas / reader / queue
//   actions      - one-click install, deploy, mute, start/stop, remove, redeploy
//   voice        - voice picker + preview, rate, volume, grouping, char-by-char
//   app filter   - all / only / except + running application picker
//   extras       - launch at login, global hotkey, log / config / about
//
// The window only draws and edits the config file; every action is implemented by
// Controller in RimeTtsMenuBar.swift through the PanelActions protocol.

import AppKit
import AVFoundation
import Carbon.HIToolbox

// ---------------------------------------------------------------- actions

protocol PanelActions: AnyObject {
    func panelState() -> ReadbackState
    func panelConfig() -> ReadbackConfig
    func panelSave(_ config: ReadbackConfig)
    func panelInstall() -> String
    func panelDeploy() -> String
    func panelRemove() -> String
    func panelRedeploy() -> String
    func panelToggleMute() -> Bool       // returns "muted" after the call
    func panelToggleWatcher() -> Bool    // returns "running" after the call
    func panelSetAutostart(_ on: Bool) -> Bool
    func panelSetHotKey(_ on: Bool) -> Bool
    func panelOpenLog()
    func panelOpenConfig()
    func panelOpenRimeDir()
    func panelClearQueue()
    func panelAbout() -> String
}

// ---------------------------------------------------------------- app info

struct AppInfo {
    let bundleID: String
    let name: String
    let icon: NSImage

    static func resolve(_ bundleID: String) -> AppInfo {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            return AppInfo(bundleID: bundleID, name: name,
                           icon: NSWorkspace.shared.icon(forFile: url.path))
        }
        let fallback = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        return AppInfo(bundleID: bundleID, name: bundleID, icon: fallback)
    }

    static func running() -> [AppInfo] {
        var seen = Set<String>()
        var out: [AppInfo] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let id = app.bundleIdentifier,
                  !seen.contains(id) else { continue }
            seen.insert(id)
            out.append(AppInfo(bundleID: id,
                               name: app.localizedName ?? id,
                               icon: app.icon ?? NSImage()))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// ---------------------------------------------------------------- global hotkey

/// Carbon hotkey (no Accessibility permission needed, unlike a global event monitor).
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onPress: (() -> Void)?

    @discardableResult
    func register() -> Bool {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        let install = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            if let userData = userData {
                Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().onPress?()
            }
            return noErr
        }, 1, &spec, ptr, &handlerRef)
        guard install == noErr else { return false }

        let hotKeyID = EventHotKeyID(signature: OSType(0x5254_5442), id: 1)   // 'RTTB'
        let reg = RegisterEventHotKey(UInt32(kVK_ANSI_R),
                                      UInt32(controlKey | optionKey),
                                      hotKeyID,
                                      GetApplicationEventTarget(), 0, &hotKeyRef)
        if reg != noErr {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let h = hotKeyRef { UnregisterEventHotKey(h); hotKeyRef = nil }
        if let e = handlerRef { RemoveEventHandler(e); handlerRef = nil }
    }

    deinit { unregister() }
}

// ---------------------------------------------------------------- preview

final class VoicePreview {
    private let synth = AVSpeechSynthesizer()

    func speak(voice: String, rate: Int, volume: Int) {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: "对于这个问题，我们需要注意。")
        let all = AVSpeechSynthesisVoice.speechVoices()
        utterance.voice = all.first { $0.name == voice }
            ?? all.first { $0.identifier == voice }
            ?? all.first { $0.language == voice }
            ?? all.first { $0.language.hasPrefix("zh") }
        let mapped = 0.5 + Double(rate) * 0.035
        utterance.rate = Float(min(max(mapped, 0.10), 0.90))
        utterance.volume = Float(min(max(volume, 0), 100)) / 100.0
        synth.speak(utterance)
    }
}

// ---------------------------------------------------------------- pill

final class PillView: NSView {
    private let label = NSTextField(labelWithString: "")
    var color: NSColor = .systemGray {
        didSet { needsDisplay = true }
    }
    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = color.cgColor
    }
}

// ---------------------------------------------------------------- small views

final class CardView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.65).cgColor
    }
}

private func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
    let f = NSTextField(labelWithString: s)
    f.font = NSFont.systemFont(ofSize: size, weight: weight)
    return f
}

private func smallLabel(_ s: String) -> NSTextField {
    let f = label(s, size: 11)
    f.textColor = .tertiaryLabelColor
    return f
}

private func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .horizontal
    s.alignment = .centerY
    s.spacing = spacing
    return s
}

private func vstack(_ views: [NSView], spacing: CGFloat = 9) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .vertical
    s.alignment = .leading
    s.spacing = spacing
    return s
}

private func flexibleSpacer() -> NSView {
    let v = NSView()
    v.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    v.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    return v
}

// ---------------------------------------------------------------- panel

final class PanelController: NSWindowController, NSWindowDelegate,
                             NSTableViewDataSource, NSTableViewDelegate {
    weak var actions: PanelActions?

    // status
    private let pill = PillView()
    private let rimeValue = NSTextField(labelWithString: "")
    private let rimePathValue = NSTextField(labelWithString: "")
    private let integrationValue = NSTextField(labelWithString: "")
    private let readerValue = NSTextField(labelWithString: "")
    private let installedValue = NSTextField(labelWithString: "")

    // actions
    private let installButton = NSButton()
    private let deployButton = NSButton()
    private let muteButton = NSButton()
    private let readerButton = NSButton()
    private let removeButton = NSButton()
    private let redeployButton = NSButton()

    // voice
    private let voicePopup = NSPopUpButton()
    private let previewButton = NSButton()
    private let rateSlider = NSSlider()
    private let rateValue = NSTextField(labelWithString: "0")
    private let volumeSlider = NSSlider()
    private let volumeValue = NSTextField(labelWithString: "100")
    private let idleField = NSTextField(string: "60")
    private let maxWaitField = NSTextField(string: "200")
    private let charByCharCheck = NSButton()
    private let digitCheck = NSButton()
    private let englishCheck = NSButton()

    // app filter
    private let filterMode = NSSegmentedControl()
    private let filterTable = NSTableView()
    private let addAppButton = NSButton()
    private let removeAppButton = NSButton()
    private let filterHint = NSTextField(labelWithString: "")

    // extras
    private let autostartCheck = NSButton()
    private let hotKeyCheck = NSButton()
    private let queueLabel = NSTextField(labelWithString: "")

    // data
    private var filterItems: [String] = []
    private var voices: [VoiceOption] = []
    private let preview = VoicePreview()
    private var saveTimer: Timer?
    private var syncing = false
    private var appCache: [String: AppInfo] = [:]
    private var appPicker: AppPickerController?

    // ------------------------------------------------------------ init

    init(actions: PanelActions) {
        self.actions = actions
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Rime 回读"
        window.minSize = NSSize(width: 720, height: 540)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        window.center()
        window.makeFirstResponder(nil)

        loadVoices()
        loadConfig()
        refresh()

        previewButton.target = self
        previewButton.action = #selector(previewTapped)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func present() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)
        loadConfig()
        refresh()
    }

    func windowWillClose(_ notification: Notification) {
        // back to a quiet menu bar helper once the window is gone
        NSApp.setActivationPolicy(.accessory)
    }

    // ------------------------------------------------------------ layout

    private func buildContent() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 20, right: 20)

        let header = buildHeader()
        let status = buildStatusCard()
        let actionsCard = buildActionsCard()
        let voiceCard = buildVoiceCard()
        let filterCard = buildFilterCard()
        let extras = buildExtras()

        let cards: [NSView] = [header, status, actionsCard, voiceCard, filterCard, extras]
        root.addArrangedSubview(header)
        for card in cards.dropFirst() { root.addArrangedSubview(card) }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = root

        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            root.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        for card in cards {
            card.translatesAutoresizingMaskIntoConstraints = false
            card.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        }

        let container = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func buildHeader() -> NSView {
        let title = label("Rime 回读", size: 22, weight: .semibold)
        let subtitle = label("鼠须管（Squirrel）上屏文字朗读  ·  v\(APP_VERSION)", size: 12)
        subtitle.textColor = .secondaryLabelColor
        let titles = vstack([title, subtitle], spacing: 2)

        let refresh = NSButton(title: "刷新检测", target: self, action: #selector(refreshTapped))
        refresh.bezelStyle = .rounded

        let row = hstack([titles, flexibleSpacer(), pill, refresh], spacing: 10)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 2, right: 0)
        return row
    }

    private func statusRow(_ title: String, _ value: NSView) -> NSStackView {
        let t = label(title, size: 12)
        t.textColor = .secondaryLabelColor
        t.alignment = .right
        t.widthAnchor.constraint(equalToConstant: 74).isActive = true
        return hstack([t, value], spacing: 10)
    }

    private func buildStatusCard() -> NSView {
        rimeValue.font = NSFont.systemFont(ofSize: 12)
        rimePathValue.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        rimePathValue.textColor = .secondaryLabelColor
        rimePathValue.lineBreakMode = .byTruncatingMiddle
        rimePathValue.isSelectable = true
        rimePathValue.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let openDir = NSButton(title: "打开", target: self, action: #selector(openRimeDirTapped))
        openDir.bezelStyle = .rounded
        openDir.controlSize = .small

        installedValue.font = NSFont.systemFont(ofSize: 12)
        integrationValue.font = NSFont.systemFont(ofSize: 12)
        readerValue.font = NSFont.systemFont(ofSize: 12)

        return cardView("状态", [
            statusRow("鼠须管", rimeValue),
            statusRow("Rime 目录", hstack([rimePathValue, openDir])),
            statusRow("集成", integrationValue),
            statusRow("朗读器", readerValue),
        ])
    }

    private func buildActionsCard() -> NSView {
        for b in [installButton, deployButton, muteButton, readerButton, removeButton, redeployButton] {
            b.bezelStyle = .rounded
        }
        installButton.title = "一键安装"
        installButton.target = self
        installButton.action = #selector(installTapped)
        installButton.bezelColor = .controlAccentColor
        installButton.contentTintColor = .white

        deployButton.title = "部署到 Rime"
        deployButton.target = self
        deployButton.action = #selector(deployTapped)

        muteButton.title = "静音"
        muteButton.target = self
        muteButton.action = #selector(muteTapped)

        readerButton.title = "停止后台朗读"
        readerButton.target = self
        readerButton.action = #selector(readerTapped)

        removeButton.title = "删除回读"
        removeButton.target = self
        removeButton.action = #selector(removeTapped)

        redeployButton.title = "重新部署 Rime"
        redeployButton.target = self
        redeployButton.action = #selector(redeployTapped)

        let row1 = hstack([installButton, deployButton, muteButton, readerButton], spacing: 8)
        let row2 = hstack([redeployButton, removeButton, flexibleSpacer(),
                           queueLabel, NSButton(title: "清空队列", target: self,
                                                action: #selector(clearQueueTapped))], spacing: 8)
        queueLabel.font = NSFont.systemFont(ofSize: 11)
        queueLabel.textColor = .tertiaryLabelColor

        return cardView("操作", [row1, row2])
    }

    private func buildVoiceCard() -> NSView {
        voicePopup.target = self
        voicePopup.action = #selector(voiceChanged)
        voicePopup.widthAnchor.constraint(equalToConstant: 330).isActive = true

        previewButton.title = "试听"
        previewButton.bezelStyle = .rounded

        rateSlider.minValue = -10
        rateSlider.maxValue = 10
        rateSlider.doubleValue = 0
        rateSlider.numberOfTickMarks = 0
        rateSlider.isContinuous = true
        rateSlider.target = self
        rateSlider.action = #selector(rateChanged)
        rateSlider.widthAnchor.constraint(equalToConstant: 300).isActive = true
        rateValue.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        volumeSlider.minValue = 0
        volumeSlider.maxValue = 100
        volumeSlider.doubleValue = 100
        volumeSlider.isContinuous = true
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        volumeSlider.widthAnchor.constraint(equalToConstant: 300).isActive = true
        volumeValue.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        for f in [idleField, maxWaitField] {
            f.alignment = .right
            f.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            f.target = self
            f.action = #selector(groupingChanged)
            f.widthAnchor.constraint(equalToConstant: 58).isActive = true
        }

        charByCharCheck.setButtonType(.switch)
        charByCharCheck.title = "逐字朗读（逗号停顿）"
        charByCharCheck.target = self
        charByCharCheck.action = #selector(toggleChanged)

        digitCheck.setButtonType(.switch)
        digitCheck.title = "朗读数字"
        digitCheck.target = self
        digitCheck.action = #selector(toggleChanged)

        englishCheck.setButtonType(.switch)
        englishCheck.title = "朗读英文"
        englishCheck.target = self
        englishCheck.action = #selector(toggleChanged)

        let ms1 = smallLabel("ms"); let ms2 = smallLabel("ms")
        let grouping = hstack([label("窗口", size: 12), idleField, ms1,
                               NSView(), label("最长等待", size: 12), maxWaitField, ms2], spacing: 6)
        grouping.views[3].widthAnchor.constraint(equalToConstant: 18).isActive = true

        return cardView("语音", [
            fieldRow("语音", hstack([voicePopup, previewButton], spacing: 8)),
            fieldRow("语速", hstack([rateSlider, rateValue], spacing: 8)),
            fieldRow("音量", hstack([volumeSlider, volumeValue], spacing: 8)),
            fieldRow("合并", grouping),
            hstack([charByCharCheck, digitCheck, englishCheck], spacing: 16),
        ])
    }

    private func buildFilterCard() -> NSView {
        filterMode.segmentCount = 3
        filterMode.setLabel("全部程序", forSegment: 0)
        filterMode.setLabel("仅这些", forSegment: 1)
        filterMode.setLabel("除这些", forSegment: 2)
        filterMode.selectedSegment = 0
        filterMode.trackingMode = .selectOne
        filterMode.target = self
        filterMode.action = #selector(filterModeChanged)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.title = "程序"
        column.width = 700
        filterTable.addTableColumn(column)
        filterTable.headerView = nil
        filterTable.frame = NSRect(x: 0, y: 0, width: 700, height: 116)
        filterTable.autoresizingMask = [.width]
        filterTable.rowHeight = 24
        filterTable.usesAlternatingRowBackgroundColors = true
        filterTable.allowsMultipleSelection = true
        filterTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        filterTable.dataSource = self
        filterTable.delegate = self

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = filterTable
        scroll.heightAnchor.constraint(equalToConstant: 116).isActive = true

        addAppButton.title = "添加程序…"
        addAppButton.bezelStyle = .rounded
        addAppButton.target = self
        addAppButton.action = #selector(addAppTapped)

        removeAppButton.title = "移除所选"
        removeAppButton.bezelStyle = .rounded
        removeAppButton.target = self
        removeAppButton.action = #selector(removeAppTapped)

        filterHint.font = NSFont.systemFont(ofSize: 11)
        filterHint.textColor = .tertiaryLabelColor

        return cardView("程序筛选", [
            hstack([filterMode, flexibleSpacer(), addAppButton, removeAppButton], spacing: 8),
            scroll,
            filterHint,
        ])
    }

    private func buildExtras() -> NSView {
        autostartCheck.setButtonType(.switch)
        autostartCheck.title = "登录时自动启动"
        autostartCheck.target = self
        autostartCheck.action = #selector(autostartToggled)

        hotKeyCheck.setButtonType(.switch)
        hotKeyCheck.title = "全局快捷键 ⌃⌥R 静音 / 恢复"
        hotKeyCheck.target = self
        hotKeyCheck.action = #selector(hotKeyToggled)

        let log = NSButton(title: "打开日志", target: self, action: #selector(openLogTapped))
        log.bezelStyle = .rounded
        let config = NSButton(title: "打开配置", target: self, action: #selector(openConfigTapped))
        config.bezelStyle = .rounded
        let about = NSButton(title: "关于", target: self, action: #selector(aboutTapped))
        about.bezelStyle = .rounded

        let left = hstack([autostartCheck, hotKeyCheck], spacing: 18)
        let right = hstack([log, config, about], spacing: 8)
        let row = hstack([left, flexibleSpacer(), right], spacing: 10)
        return cardView(nil, [row])
    }

    private func cardView(_ title: String?, _ rows: [NSView]) -> NSView {
        let card = CardView()
        var views: [NSView] = []
        if let title = title {
            let t = label(title, size: 12, weight: .semibold)
            t.textColor = .secondaryLabelColor
            views.append(t)
        }
        views.append(contentsOf: rows)
        let stack = vstack(views)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in views { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
        return card
    }

    private func fieldRow(_ title: String, _ content: NSView, width: CGFloat = 74) -> NSStackView {
        let t = label(title, size: 12)
        t.textColor = .secondaryLabelColor
        t.alignment = .right
        t.widthAnchor.constraint(equalToConstant: width).isActive = true
        return hstack([t, content], spacing: 10)
    }

    // ------------------------------------------------------------ refresh

    func refresh() {
        guard let a = actions else { return }
        let s = a.panelState()

        setPill(s.headline, color: pillColor(s.headlineColor))
        rimeValue.stringValue = s.squirrelVersion.map { "Squirrel \($0)" } ?? "未检测到鼠须管"
        rimeValue.textColor = s.squirrelVersion == nil ? .systemRed : .labelColor
        rimePathValue.stringValue = s.rimeDir
        rimePathValue.toolTip = s.rimeDir
        integrationValue.stringValue = s.luaInstalled
            ? "rime.lua 已安装 · 已打补丁 \(s.patchedSchemas.count) 个方案"
            : "未安装"
        integrationValue.textColor = s.luaInstalled ? .labelColor : .secondaryLabelColor
        readerValue.stringValue = s.watcherRunning
            ? "运行中" + (s.muted ? " · 已静音" : "")
            : "已停止"
        readerValue.textColor = s.watcherRunning ? .labelColor : .secondaryLabelColor
        queueLabel.stringValue = "队列 \(s.queueCount)"

        muteButton.title = s.muted ? "取消静音" : "静音"
        readerButton.title = s.watcherRunning ? "停止后台朗读" : "启动后台朗读"

        installButton.isEnabled = s.squirrelVersion != nil
        deployButton.isEnabled = s.squirrelVersion != nil
        redeployButton.isEnabled = s.squirrelVersion != nil
        muteButton.isEnabled = s.luaInstalled
        readerButton.isEnabled = s.luaInstalled
        removeButton.isEnabled = s.luaInstalled

        if !syncing {
            autostartCheck.state = s.autostart ? .on : .off
        }
        updateFilterUi()
    }

    /// Called from the menu bar watchdog: status labels only, never touches edits.
    func refreshStatus() {
        guard isWindowLoaded, window?.isVisible == true else { return }
        refresh()
    }

    private func pillColor(_ c: ReadbackState.HeadlineColor) -> NSColor {
        switch c {
        case .green: return .systemGreen
        case .orange: return .systemOrange
        case .gray: return .systemGray
        case .red: return .systemRed
        }
    }

    private func setPill(_ text: String, color: NSColor) {
        pill.text = text
        pill.color = color
    }

    // ------------------------------------------------------------ config

    private func loadVoices() {
        var seen = Set<String>()
        var list: [VoiceOption] = []
        for v in AVSpeechSynthesisVoice.speechVoices() {
            let key = v.name + "|" + v.language
            if seen.contains(key) { continue }
            seen.insert(key)
            list.append(VoiceOption(name: v.name, language: v.language, identifier: v.identifier))
        }
        voices = VoiceOption.sorted(list)

        voicePopup.removeAllItems()
        for v in voices {
            voicePopup.addItem(withTitle: v.title)
            voicePopup.lastItem?.representedObject = v.name
        }
    }

    private func selectVoice(_ name: String) {
        if let idx = voices.firstIndex(where: { $0.name == name || $0.identifier == name }) {
            voicePopup.selectItem(at: idx)
            return
        }
        if let idx = voices.firstIndex(where: { $0.language == name || $0.language.hasPrefix(name) }) {
            voicePopup.selectItem(at: idx)
            return
        }
        if voicePopup.numberOfItems > 0 { voicePopup.selectItem(at: 0) }
    }

    private func loadConfig() {
        guard let a = actions else { return }
        let c = a.panelConfig()
        syncing = true
        defer { syncing = false }

        selectVoice(c.voice)
        rateSlider.doubleValue = Double(c.rate)
        rateValue.stringValue = "\(c.rate)"
        volumeSlider.doubleValue = Double(c.volume)
        volumeValue.stringValue = "\(c.volume)"
        idleField.stringValue = "\(c.idleMs)"
        maxWaitField.stringValue = "\(c.maxWaitMs)"
        charByCharCheck.state = c.charByChar ? .on : .off
        digitCheck.state = c.readDigits ? .on : .off
        englishCheck.state = c.readEnglish ? .on : .off
        filterItems = c.appFilterList
        filterTable.reloadData()
        filterMode.selectedSegment = ["all", "only", "except"].firstIndex(of: c.appFilterMode) ?? 0
        hotKeyCheck.state = c.hotKey.isEmpty ? .off : .on
        updateFilterUi()
    }

    private func pushConfig() {
        guard !syncing, let a = actions else { return }
        var c = a.panelConfig()
        c.voice = voicePopup.selectedItem?.representedObject as? String ?? c.voice
        c.rate = rateSlider.integerValue
        c.volume = volumeSlider.integerValue
        c.idleMs = max(0, min(idleField.integerValue, 5000))
        c.maxWaitMs = max(0, min(maxWaitField.integerValue, 20000))
        c.charByChar = charByCharCheck.state == .on
        c.readDigits = digitCheck.state == .on
        c.readEnglish = englishCheck.state == .on
        c.appFilterMode = ["all", "only", "except"][max(0, min(filterMode.selectedSegment, 2))]
        c.appFilterList = filterItems
        c.hotKey = hotKeyCheck.state == .on ? "ctrl+alt+r" : ""
        a.panelSave(c)
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            self?.pushConfig()
        }
    }

    private func updateFilterUi() {
        let active = filterMode.selectedSegment != 0
        addAppButton.isEnabled = active
        removeAppButton.isEnabled = active && filterTable.selectedRow >= 0
        filterTable.isEnabled = active
        filterTable.alphaValue = active ? 1.0 : 0.55
        switch filterMode.selectedSegment {
        case 1: filterHint.stringValue = "只朗读下面列表里的程序，其他程序一律不读。"
        case 2: filterHint.stringValue = "下面列表里的程序不朗读，其他程序正常朗读。"
        default: filterHint.stringValue = "所有程序里上屏的文字都会朗读。"
        }
    }

    // ------------------------------------------------------------ actions

    @objc private func refreshTapped() {
        loadConfig()
        refresh()
    }

    @objc private func installTapped() {
        guard let a = actions else { return }
        let text = a.panelInstall()
        refresh()
        showResult("一键安装", text)
    }

    @objc private func deployTapped() {
        guard let a = actions else { return }
        let text = a.panelDeploy()
        refresh()
        showResult("部署回读功能", text)
    }

    @objc private func removeTapped() {
        guard let a = actions else { return }
        let alert = NSAlert()
        alert.messageText = "删除回读功能？"
        alert.informativeText = "会撤销方案补丁、删除 rime.lua 并停止后台朗读。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = a.panelRemove()
        refresh()
        showResult("删除回读功能", text)
    }

    @objc private func redeployTapped() {
        guard let a = actions else { return }
        let text = a.panelRedeploy()
        refresh()
        showResult("重新部署 Rime", text)
    }

    @objc private func muteTapped() {
        guard let a = actions else { return }
        _ = a.panelToggleMute()
        refresh()
    }

    @objc private func readerTapped() {
        guard let a = actions else { return }
        _ = a.panelToggleWatcher()
        refresh()
    }

    @objc private func clearQueueTapped() {
        actions?.panelClearQueue()
        refresh()
    }

    @objc private func previewTapped() {
        let voice = voicePopup.selectedItem?.representedObject as? String ?? "Tingting"
        preview.speak(voice: voice, rate: rateSlider.integerValue, volume: volumeSlider.integerValue)
    }

    @objc private func voiceChanged() {
        pushConfig()
        previewTapped()
    }

    @objc private func rateChanged() {
        rateValue.stringValue = "\(rateSlider.integerValue)"
        scheduleSave()
    }

    @objc private func volumeChanged() {
        volumeValue.stringValue = "\(volumeSlider.integerValue)"
        scheduleSave()
    }

    @objc private func groupingChanged() {
        pushConfig()
    }

    @objc private func toggleChanged() {
        pushConfig()
    }

    @objc private func filterModeChanged() {
        updateFilterUi()
        pushConfig()
    }

    @objc private func addAppTapped() {
        guard let window = window else { return }
        let picker = AppPickerController()
        appPicker = picker          // the sheet does not retain its controller
        picker.present(in: window) { [weak self] picked in
            guard let self = self else { return }
            for app in picked where !self.filterItems.contains(app.bundleID) {
                self.filterItems.append(app.bundleID)
            }
            self.filterTable.reloadData()
            self.updateFilterUi()
            self.pushConfig()
        } onClose: { [weak self] in
            self?.appPicker = nil
        }
    }

    @objc private func removeAppTapped() {
        let rows = filterTable.selectedRowIndexes.sorted(by: >)
        for row in rows where row < filterItems.count {
            filterItems.remove(at: row)
        }
        filterTable.reloadData()
        updateFilterUi()
        pushConfig()
    }

    @objc private func autostartToggled() {
        guard let a = actions else { return }
        let want = autostartCheck.state == .on
        let now = a.panelSetAutostart(want)
        autostartCheck.state = now ? .on : .off
    }

    @objc private func hotKeyToggled() {
        guard let a = actions else { return }
        let want = hotKeyCheck.state == .on
        let ok = a.panelSetHotKey(want)
        if !ok && want {
            hotKeyCheck.state = .off
            pushConfig()
            showResult("快捷键不可用", "⌃⌥R 已被其他程序占用，请先关闭占用它的程序。")
            return
        }
        hotKeyCheck.state = ok ? .on : .off
        pushConfig()
    }

    @objc private func openLogTapped() { actions?.panelOpenLog() }
    @objc private func openConfigTapped() { actions?.panelOpenConfig() }
    @objc private func openRimeDirTapped() { actions?.panelOpenRimeDir() }

    @objc private func aboutTapped() {
        showResult("关于 Rime 回读", actions?.panelAbout() ?? "")
    }

    private func showResult(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // ------------------------------------------------------------ table

    func numberOfRows(in tableView: NSTableView) -> Int {
        filterItems.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("app")
        var cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
        if cell == nil {
            let c = NSTableCellView()
            c.identifier = id
            let image = NSImageView()
            let text = NSTextField(labelWithString: "")
            image.translatesAutoresizingMaskIntoConstraints = false
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            text.font = NSFont.systemFont(ofSize: 12)
            c.addSubview(image)
            c.addSubview(text)
            c.imageView = image
            c.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 18),
                image.heightAnchor.constraint(equalToConstant: 18),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
                text.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            cell = c
        }
        guard row < filterItems.count else { return cell }
        let bundleID = filterItems[row]
        let info: AppInfo
        if let cached = appCache[bundleID] {
            info = cached
        } else {
            info = AppInfo.resolve(bundleID)
            appCache[bundleID] = info
        }
        cell?.imageView?.image = info.icon
        cell?.textField?.stringValue = "\(info.name)   ·   \(info.bundleID)"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateFilterUi()
    }
}

// ---------------------------------------------------------------- app picker

final class AppPickerController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private var apps: [AppInfo] = []
    private var onPick: (([AppInfo]) -> Void)?
    private var onClose: (() -> Void)?

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 460),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "添加程序"
        super.init(window: w)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        guard let content = window?.contentView else { return }

        let lead = label("选择正在运行的程序（可多选）", size: 12)
        lead.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.title = "程序"
        column.width = 440
        table.addTableColumn(column)
        table.headerView = nil
        table.frame = NSRect(x: 0, y: 0, width: 440, height: 350)
        table.autoresizingMask = [.width]
        table.rowHeight = 26
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        let add = NSButton(title: "添加", target: self, action: #selector(addTapped))
        add.bezelStyle = .rounded
        add.keyEquivalent = "\r"

        let buttons = hstack([flexibleSpacer(), cancel, add], spacing: 8)
        let root = vstack([lead, scroll, buttons], spacing: 12)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        for v in [lead, scroll, buttons] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
    }

    func present(in parent: NSWindow,
                 onPick: @escaping ([AppInfo]) -> Void,
                 onClose: @escaping () -> Void) {
        self.onPick = onPick
        self.onClose = onClose
        apps = AppInfo.running()
        table.reloadData()
        guard let w = window else { return }
        parent.beginSheet(w, completionHandler: nil)
    }

    @objc private func cancelTapped() {
        if let w = window, let parent = w.sheetParent {
            parent.endSheet(w)
        } else {
            window?.close()
        }
        onClose?()
    }

    @objc private func addTapped() {
        let picked = table.selectedRowIndexes.compactMap { $0 < apps.count ? apps[$0] : nil }
        guard !picked.isEmpty else { NSSound.beep(); return }
        if let w = window, let parent = w.sheetParent {
            parent.endSheet(w)
        } else {
            window?.close()
        }
        onPick?(picked)
        onClose?()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { apps.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("pick")
        var cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
        if cell == nil {
            let c = NSTableCellView()
            c.identifier = id
            let image = NSImageView()
            let text = NSTextField(labelWithString: "")
            image.translatesAutoresizingMaskIntoConstraints = false
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            c.addSubview(image)
            c.addSubview(text)
            c.imageView = image
            c.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 20),
                image.heightAnchor.constraint(equalToConstant: 20),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
                text.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            cell = c
        }
        guard row < apps.count else { return cell }
        let app = apps[row]
        cell?.imageView?.image = app.icon
        cell?.textField?.stringValue = "\(app.name)   ·   \(app.bundleID)"
        return cell
    }
}
