// RimeTtsModel.swift - state snapshot + config file model shared by the panel
//
// The config file is the contract between the panel and the reader
// (~/.rime-tts-readback/config.json, hot reloaded by the watcher).  Keys that the
// panel does not know about are preserved on save, so the reader and older
// versions can keep their own settings.
//
// ASCII-only source on purpose.

import Foundation

// ---------------------------------------------------------------- state

struct ReadbackState {
    var squirrelVersion: String?      // nil = Squirrel not installed
    var rimeDir: String
    var luaInstalled: Bool
    var patchedSchemas: [String]
    var muted: Bool
    var watcherRunning: Bool
    var autostart: Bool
    var queueCount: Int

    /// Short one-word state used by the header pill.
    var headline: String {
        if squirrelVersion == nil { return "未安装鼠须管" }
        if !luaInstalled { return "未部署" }
        if muted { return "已静音" }
        if watcherRunning { return "已启用" }
        return "后台未运行"
    }

    var headlineColor: HeadlineColor {
        if squirrelVersion == nil { return .red }
        if !luaInstalled { return .orange }
        if muted { return .gray }
        if watcherRunning { return .green }
        return .orange
    }

    enum HeadlineColor { case green, orange, gray, red }
}

// ---------------------------------------------------------------- config

struct ReadbackConfig {
    var voice = "Tingting"
    var rate = 0                 // -10..10
    var idleMs = 60              // grouping window
    var maxWaitMs = 200          // hard upper bound
    var readDigits = true        // report/filter 0-9
    var readEnglish = true       // report/filter ASCII letters
    var volume = 100             // 0..100
    var charByChar = false
    var appFilterMode = "all"    // all | only | except
    var appFilterList: [String] = []
    var hotKey = ""              // "" = off, "ctrl+alt+r" = enabled

    static func load(from path: String) -> ReadbackConfig {
        var c = ReadbackConfig()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return c
        }
        func int(_ key: String) -> Int? {
            if let n = obj[key] as? NSNumber { return n.intValue }
            if let s = obj[key] as? String { return Int(s) }
            return nil
        }
        func bool(_ key: String) -> Bool? {
            if let b = obj[key] as? Bool { return b }
            if let n = obj[key] as? NSNumber { return n.boolValue }
            return nil
        }
        if let v = obj["Voice"] as? String, !v.isEmpty { c.voice = v }
        if let v = int("Rate") { c.rate = v }
        if let v = int("IdleMs") { c.idleMs = v }
        if let v = int("MaxWaitMs") { c.maxWaitMs = v }
        if let v = int("Volume") { c.volume = v }
        if let v = bool("CharByChar") { c.charByChar = v }
        // legacy single switch: IncludeAscii meant "letters and digits"
        let legacyAscii = bool("IncludeAscii")
        if let v = bool("ReadDigits") { c.readDigits = v } else if let v = legacyAscii { c.readDigits = v }
        if let v = bool("ReadEnglish") { c.readEnglish = v } else if let v = legacyAscii { c.readEnglish = v }
        if let v = obj["AppFilterMode"] as? String, ["all", "only", "except"].contains(v) { c.appFilterMode = v }
        if let v = obj["AppFilterList"] as? [String] { c.appFilterList = v }
        if let v = obj["HotKey"] as? String { c.hotKey = v }
        if let v = int("HotKey") { c.hotKey = v != 0 ? "ctrl+alt+r" : "" }
        return c
    }

    /// Merge into the existing JSON so unknown keys survive.
    func save(to path: String) {
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let old = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            obj = old
        }
        obj["Voice"] = voice
        obj["Rate"] = rate
        obj["IdleMs"] = idleMs
        obj["MaxWaitMs"] = maxWaitMs
        obj["Volume"] = volume
        obj["CharByChar"] = charByChar
        obj["ReadDigits"] = readDigits
        obj["ReadEnglish"] = readEnglish
        // keep the old key pointing at the conservative "both" for older builds
        obj["IncludeAscii"] = readDigits && readEnglish
        obj["AppFilterMode"] = appFilterMode
        obj["AppFilterList"] = appFilterList
        obj["HotKey"] = hotKey
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

// ---------------------------------------------------------------- voice

struct VoiceOption {
    let name: String
    let language: String
    let identifier: String

    /// "Tingting  -  中文（中国大陆）"
    var title: String { "\(name)  -  \(language)" }

    /// Chinese voices first, then by language, then by name.
    static func sorted(_ voices: [VoiceOption]) -> [VoiceOption] {
        voices.sorted { a, b in
            let az = a.language.hasPrefix("zh")
            let bz = b.language.hasPrefix("zh")
            if az != bz { return az }
            if a.language != b.language { return a.language < b.language }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}
