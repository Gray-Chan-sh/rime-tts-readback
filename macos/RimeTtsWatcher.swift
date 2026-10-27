// rime-tts-watcher.swift - rime-tts-readback reader for macOS
//
// Speaks the text that Rime commits (writes to the queue from rime.lua), one
// utterance per commit batch. Candidate/preedit text is never involved.
//
// Why this is not a port of the Windows PowerShell reader:
//   * macOS has no SAPI and no SoundPlayer. Speech comes from AVFoundation.
//   * The legacy `say(1)` command costs ~0.8-1.4 s per invocation on modern macOS
//     (process + speech-service handshake), which is far too slow for readback, so
//     we keep a single long-lived AVSpeechSynthesizer instead. Utterances then
//     start in single-digit milliseconds and there is no need for the Windows
//     trick of synthesising to a WAV, trimming silence and normalising the peak.
//   * AVSpeechSynthesizer only works while an AppKit run loop is running, so this
//     binary sets up an accessory NSApplication even though it shows no UI.
//
// Build:  swiftc -O RimeTtsWatcher.swift -o rime-tts-watcher
// Run:    rime-tts-watcher [options]        (see --help)
//
// ASCII-only source on purpose.

import Foundation
import AppKit
import AVFoundation
import Darwin

let APP_VERSION = "1.1.1"

// ---------------------------------------------------------------- paths

let fm = FileManager.default
let env = ProcessInfo.processInfo.environment
let homeDir = env["HOME"] ?? fm.homeDirectoryForCurrentUser.path
let stateDir = env["RIME_TTS_STATE"] ?? homeDir + "/.rime-tts-readback"
let rimeDir  = env["RIME_USER_DIR"] ?? homeDir + "/Library/Rime"

// ---------------------------------------------------------------- options

struct Options {
    var queueDir = env["RIME_TTS_DIR"] ?? rimeDir + "/tts_queue"
    var offFile  = rimeDir + "/tts_off"
    var configFile = stateDir + "/config.json"
    var logFile  = stateDir + "/watcher.log"
    var pidFile  = stateDir + "/watcher.pid"

    var voice = ""            // SAPI-style name ("Tingting"), an identifier, or a language code
    var rate = 0              // -10..10, same meaning as the Windows reader
    var idleMs = 60
    var maxWaitMs = 200
    var volume = 100          // 0..100 (macOS already renders at full scale)
    var charByChar = false
    var readDigits = true
    var readEnglish = true
    var appFilterMode = "all" // all | only | except
    var appFilterList: [String] = []

    var fake = false          // --fake: log what would be spoken, make no sound
    var runSeconds = 0.0      // 0 = run until killed
    var listVoices = false
    var check = false
    var quiet = false
}

var opts = Options()

func usage() {
    print("""
    rime-tts-watcher \(APP_VERSION) - speak the text Rime commits (macOS)

    usage: rime-tts-watcher [options]

      --voice <name>        voice: name (Tingting), identifier, or language (zh-CN)
      --rate <n>            -10..10, lower reads each character longer  (default 0)
      --idle-ms <n>         group commits arriving this close together  (default 60)
      --max-wait-ms <n>     never wait longer than this before speaking  (default 200)
      --volume <n>          0..100                                       (default 100)
      --char-by-char        separate characters with a comma pause
      --no-ascii            do not read ASCII letters or digits
      --no-digits           do not read digits
      --no-english          do not read ASCII letters
      --only-apps <list>    comma separated bundle ids / app names
      --except-apps <list>  comma separated bundle ids / app names
      --queue <dir>         queue directory        (default \(opts.queueDir))
      --off-file <path>     mute flag               (default \(opts.offFile))
      --config <path>       JSON config, hot reloaded (default \(opts.configFile))
      --log <path>          log file                (default \(opts.logFile))
      --run-seconds <n>     exit after n seconds (testing)
      --fake                do not make any sound, just log
      --list-voices         print installed voices and exit
      --check               print a detection report and exit
      -h, --help            this text
    """)
}

func argValue(_ args: [String], _ i: inout Int) -> String {
    i += 1
    return i < args.count ? args[i] : ""
}

let argv = Array(CommandLine.arguments.dropFirst())
var ai = 0
while ai < argv.count {
    let a = argv[ai]
    switch a {
    case "--voice":        opts.voice = argValue(argv, &ai)
    case "--rate":         opts.rate = Int(argValue(argv, &ai)) ?? opts.rate
    case "--idle-ms":      opts.idleMs = Int(argValue(argv, &ai)) ?? opts.idleMs
    case "--max-wait-ms":  opts.maxWaitMs = Int(argValue(argv, &ai)) ?? opts.maxWaitMs
    case "--volume":       opts.volume = Int(argValue(argv, &ai)) ?? opts.volume
    case "--char-by-char": opts.charByChar = true
    case "--no-ascii":     opts.readDigits = false; opts.readEnglish = false
    case "--no-digits":    opts.readDigits = false
    case "--no-english":   opts.readEnglish = false
    case "--only-apps":
        opts.appFilterMode = "only"
        opts.appFilterList = argValue(argv, &ai).split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    case "--except-apps":
        opts.appFilterMode = "except"
        opts.appFilterList = argValue(argv, &ai).split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    case "--queue":        opts.queueDir = argValue(argv, &ai)
    case "--off-file":     opts.offFile = argValue(argv, &ai)
    case "--config":       opts.configFile = argValue(argv, &ai)
    case "--log":          opts.logFile = argValue(argv, &ai)
    case "--run-seconds":  opts.runSeconds = Double(argValue(argv, &ai)) ?? 0
    case "--fake":         opts.fake = true
    case "--quiet":        opts.quiet = true
    case "--list-voices":  opts.listVoices = true
    case "--check":        opts.check = true
    case "-h", "--help":   usage(); exit(0)
    default:
        FileHandle.standardError.write("unknown option: \(a)\n".data(using: .utf8)!)
        usage(); exit(2)
    }
    ai += 1
}

// ---------------------------------------------------------------- app plumbing

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, no menu bar

// ---------------------------------------------------------------- voices

func allVoices() -> [AVSpeechSynthesisVoice] {
    AVSpeechSynthesisVoice.speechVoices()
}

func resolveVoice(_ spec: String) -> AVSpeechSynthesisVoice? {
    let voices = allVoices()
    if spec.isEmpty { return AVSpeechSynthesisVoice(language: "zh-CN") ?? voices.first }
    if spec.contains(".") {                                  // looks like an identifier
        if let v = AVSpeechSynthesisVoice(identifier: spec) { return v }
    }
    let needle = spec.lowercased()
    let exact = voices.filter { $0.name.lowercased() == needle }
    if let v = exact.first { return v }
    let fuzzy = voices.filter {
        $0.name.lowercased().contains(needle) || $0.language.lowercased() == needle
    }
    // prefer a Chinese voice when several match
    if let v = fuzzy.first(where: { $0.language.lowercased().hasPrefix("zh") }) { return v }
    if let v = fuzzy.first { return v }
    if spec.contains("-") {                                   // looks like a language code
        return AVSpeechSynthesisVoice(language: spec)
    }
    return AVSpeechSynthesisVoice(language: "zh-CN") ?? voices.first
}

if opts.listVoices {
    for v in allVoices().sorted(by: { $0.language < $1.language }) {
        print(String(format: "%-8@ %-42@ %@", v.language as NSString, v.name as NSString, v.identifier as NSString))
    }
    exit(0)
}

// ---------------------------------------------------------------- log

let maxLogBytes: UInt64 = 1_048_576

func log(_ message: String) {
    let line = timestamp() + " " + message + "\n"
    if let h = FileHandle(forWritingAtPath: opts.logFile) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.write(toFile: opts.logFile, atomically: true, encoding: .utf8)
    }
    if !opts.quiet { FileHandle.standardError.write(line.data(using: .utf8)!) }
}

let stampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()
func timestamp() -> String { stampFormatter.string(from: Date()) }

func rotateLogIfNeeded() {
    guard let attrs = try? fm.attributesOfItem(atPath: opts.logFile),
          let size = attrs[.size] as? UInt64, size > maxLogBytes else { return }
    try? fm.removeItem(atPath: opts.logFile + ".1")
    try? fm.moveItem(atPath: opts.logFile, toPath: opts.logFile + ".1")
}

// ---------------------------------------------------------------- check mode

func describeCheck() {
    print("version      : \(APP_VERSION) (macOS)")
    var squirrel = "<not found>"
    let squirrelPath = "/Library/Input Methods/Squirrel.app"
    if let info = NSDictionary(contentsOfFile: squirrelPath + "/Contents/Info.plist") {
        let short = info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        squirrel = "\(squirrelPath)  (v\(short) build \(build))"
    }
    print("Squirrel     : \(squirrel)")
    print("Rime user dir: \(rimeDir)  (exists=\(fm.fileExists(atPath: rimeDir)))")
    print("rime.lua     : \(fm.fileExists(atPath: rimeDir + "/rime.lua") ? "present" : "absent")")
    print("queue dir    : \(opts.queueDir)  (exists=\(fm.fileExists(atPath: opts.queueDir)))")
    let patched = ((try? fm.contentsOfDirectory(atPath: rimeDir)) ?? [])
        .filter { $0.hasSuffix(".custom.yaml") }
        .filter { ((try? String(contentsOfFile: rimeDir + "/" + $0, encoding: .utf8)) ?? "").contains("lua_processor@tts_reporter") }
        .map { $0.replacingOccurrences(of: ".custom.yaml", with: "") }
    print("patched      : \(patched.isEmpty ? "none" : patched.joined(separator: ", "))")
    print("muted        : \(fm.fileExists(atPath: opts.offFile))")
    print("watcher      : \(watcherIsRunning() ? "running" : "stopped")")
    print("config       : \(fm.fileExists(atPath: opts.configFile) ? "present" : "none")")
    let v = resolveVoice(opts.voice)
    print("voice        : \(v?.name ?? "?") [\(v?.language ?? "?")]")
    exit(0)
}

// ---------------------------------------------------------------- config (hot reloaded)

var configStamp: Date? = nil

func applyConfig() {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: opts.configFile)),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

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
    if let v = obj["Voice"] as? String, !v.isEmpty { opts.voice = v }
    if let v = int("Rate")         { opts.rate = v }
    if let v = int("IdleMs")       { opts.idleMs = v }
    if let v = int("MaxWaitMs")    { opts.maxWaitMs = v }
    if let v = int("Volume")       { opts.volume = v }
    if let v = bool("CharByChar")  { opts.charByChar = v }
    let legacyAscii = bool("IncludeAscii")
    if let v = bool("ReadDigits")  { opts.readDigits = v } else if let v = legacyAscii { opts.readDigits = v }
    if let v = bool("ReadEnglish") { opts.readEnglish = v } else if let v = legacyAscii { opts.readEnglish = v }
    if let v = obj["AppFilterMode"] as? String, !v.isEmpty { opts.appFilterMode = v }
    if let v = obj["AppFilterList"] as? [String] { opts.appFilterList = v }
    if let v = obj["VoiceLanguage"] as? String, !v.isEmpty { _ = v } // reserved
}

func reloadConfigIfNeeded(force: Bool) {
    let attrs = try? fm.attributesOfItem(atPath: opts.configFile)
    let stamp = attrs?[.modificationDate] as? Date
    if !force && stamp == configStamp { return }
    configStamp = stamp
    applyConfig()
    speaker.applyVoiceAndRate()
}

// ---------------------------------------------------------------- speech

final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var voice: AVSpeechSynthesisVoice?
    private var pendingText = ""
    private var speaking = false
    private var startedAt = Date()

    override init() {
        super.init()
        synth.delegate = self
    }

    func applyVoiceAndRate() {
        voice = resolveVoice(opts.voice)
        log("voice=\(voice?.name ?? "?") [\(voice?.language ?? "?")] rate=\(opts.rate) charByChar=\(opts.charByChar) vol=\(opts.volume) idle=\(opts.idleMs)ms maxWait=\(opts.maxWaitMs)ms appFilter=\(opts.appFilterMode) [\(opts.appFilterList.joined(separator: ","))]")
    }

    private func speechRate() -> Float {
        let mapped = 0.5 + Double(opts.rate) * 0.035
        return Float(min(max(mapped, 0.10), 0.90))
    }

    func feed(_ text: String) {
        guard !text.isEmpty else { return }
        pendingText += text
        pump()
    }

    private func pump() {
        guard !speaking, !pendingText.isEmpty else { return }
        let text = pendingText
        pendingText = ""
        speak(text)
    }

    private func speak(_ text: String) {
        speaking = true
        startedAt = Date()
        if opts.fake {
            log("fake-speak [\(text)] chars=\(text.count)")
            speaking = false
            return
        }
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = speechRate()
        // ASCII runs are typed an order of magnitude faster than Chinese and are
        // spelled out, so speak them a little faster to keep the queue from lagging.
        let asciiOnly = !text.isEmpty && text.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " ")
        }
        if asciiOnly {
            u.rate = min(0.90, u.rate + 0.06)
        }
        u.volume = Float(min(max(opts.volume, 0), 100)) / 100.0
        synth.speak(u)
    }

    /// Drop everything: queued utterances and the current one.
    func stop() {
        pendingText = ""
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
        speaking = false
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        log("  didStart +\(Int(Date().timeIntervalSince(startedAt) * 1000))ms")
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        log("  didFinish +\(Int(Date().timeIntervalSince(startedAt) * 1000))ms")
        speaking = false
        pump()
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        speaking = false
    }
}

let speaker = Speaker()

// ---------------------------------------------------------------- helpers

func pendingFiles() -> [String] {
    let names = (try? fm.contentsOfDirectory(atPath: opts.queueDir)) ?? []
    // rime.lua names each commit "<time>_<seq>.txt"; compare the numbers, not the
    // strings, so "..._10" does not sort before "..._2".
    func key(_ name: String) -> (Int, Int) {
        let base = (name as NSString).deletingPathExtension
        let parts = base.split(separator: "_")
        if parts.count == 2, let t = Int(parts[0]), let s = Int(parts[1]) { return (t, s) }
        return (Int.max, 0)
    }
    return names.filter { $0.hasSuffix(".txt") }
        .sorted { a, b in
            let ka = key(a), kb = key(b)
            return ka == kb ? a < b : (ka.0, ka.1) < (kb.0, kb.1)
        }
        .map { opts.queueDir + "/" + $0 }
}

func readableChars(_ text: String) -> String {
    var out = ""
    for ch in text {
        if ch.isWhitespace {
            // keep a single word break between ASCII letters ("hello world"),
            // but not around Chinese text where spaces are meaningless
            if let last = out.last, last.isASCII, last.isLetter, !out.hasSuffix(" ") {
                out.append(" ")
            }
            continue
        }
        if !(ch.isLetter || ch.isNumber) { continue }
        let ascii = ch.unicodeScalars.allSatisfy { $0.value < 128 }
        if ascii && ch.isLetter && !opts.readEnglish { continue }
        if ascii && ch.isNumber && !opts.readDigits { continue }
        out.append(ch)
    }
    return out.trimmingCharacters(in: .whitespaces)
}

func buildBody(_ readable: String) -> String {
    // macOS takes plain text, so no SSML and therefore none of the Windows
    // "SAPI repeats the last syllable around <break>" trap. A full-width comma
    // is used for the per-character pause.
    if opts.charByChar {
        return readable.map { String($0) }.joined(separator: "\u{FF0C}")
    }
    // Spell out ASCII letter/digit runs: "abc12" -> "a b c 1 2". Separate letters
    // as well as digits, so the voice never turns a run into a word or a number.
    var out = ""
    var previousWasAscii = false
    for ch in readable {
        let asciiAlnum = ch.isASCII && (ch.isLetter || ch.isNumber)
        if asciiAlnum && previousWasAscii {
            out.append(" ")
        }
        out.append(ch)
        previousWasAscii = asciiAlnum
    }
    return out
}

func frontmostApp() -> (bundle: String, name: String) {
    guard let a = NSWorkspace.shared.frontmostApplication else { return ("", "") }
    return (a.bundleIdentifier ?? "", a.localizedName ?? "")
}

func appAllowed(_ app: (bundle: String, name: String)) -> Bool {
    if opts.appFilterMode == "all" { return true }
    if app.bundle.isEmpty && app.name.isEmpty { return true }
    let list = opts.appFilterList.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    if list.isEmpty { return true }
    var candidate = [app.bundle.lowercased(), app.name.lowercased()]
    if app.name.hasSuffix(".app") { candidate.append(String(app.name.dropLast(4)).lowercased()) }
    let hit = candidate.contains { c in list.contains { $0 == c } }
    return opts.appFilterMode == "only" ? hit : !hit
}

func drainQueue() {
    for f in pendingFiles() { try? fm.removeItem(atPath: f) }
}

func watcherIsRunning() -> Bool {
    guard let pidText = try? String(contentsOfFile: opts.pidFile, encoding: .utf8),
          let pid = pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
    return pid > 0 && kill(pid, 0) == 0
}

// ---------------------------------------------------------------- config dirs

try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
rotateLogIfNeeded()

if opts.check {
    describeCheck()   // exits; stays read-only
}

try? fm.createDirectory(atPath: opts.queueDir, withIntermediateDirectories: true)
reloadConfigIfNeeded(force: true)

// ---------------------------------------------------------------- single instance

func acquireLock() -> Bool {
    let path = opts.pidFile
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    if fd < 0 { return true }                 // cannot lock: do not refuse to run
    if flock(fd, LOCK_EX | LOCK_NB) != 0 { return false }
    ftruncate(fd, 0)
    _ = "\(getpid())".withCString { write(fd, $0, strlen($0)) }
    return true                                // keep fd open for the process lifetime
}

if !acquireLock() {
    FileHandle.standardError.write("rime-tts-watcher: already running\n".data(using: .utf8)!)
    exit(0)
}

// ---------------------------------------------------------------- signals

// Kept alive for the process lifetime: a released DispatchSource stops firing.
// SIGHUP is ignored on purpose: the reader must survive its launcher (menu bar item
// or a terminal session) going away, and only SIGTERM/SIGINT stop it.
signal(SIGHUP, SIG_IGN)
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        log("stopping (signal \(sig))")
        speaker.stop()
        try? fm.removeItem(atPath: opts.pidFile)
        exit(0)
    }
    src.resume()
    signalSources.append(src)
}

// ---------------------------------------------------------------- main loop

// stale queue (including half-written .tmp files) from a previous run
drainQueue()
for n in ((try? fm.contentsOfDirectory(atPath: opts.queueDir)) ?? []) where n.hasSuffix(".tmp") {
    try? fm.removeItem(atPath: opts.queueDir + "/" + n)
}

log("watcher started v\(APP_VERSION) queue=\(opts.queueDir)")

var buffer = ""
var since: Date? = nil
var lastAdd: Date? = nil
var batchApp: (bundle: String, name: String) = ("", "")
var lastSweep = Date()
var lastCfgCheck = Date()
let startedAt = Date()

let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
    if opts.runSeconds > 0 && Date().timeIntervalSince(startedAt) > opts.runSeconds {
        log("run-seconds reached, exiting")
        try? fm.removeItem(atPath: opts.pidFile)
        exit(0)
    }

    if Date().timeIntervalSince(lastCfgCheck) >= 1.0 {
        lastCfgCheck = Date()
        reloadConfigIfNeeded(force: false)
    }

    if fm.fileExists(atPath: opts.offFile) {
        drainQueue()
        buffer = ""; since = nil; lastAdd = nil
        speaker.stop()
        return
    }

    if Date().timeIntervalSince(lastSweep) > 60 {
        lastSweep = Date()
        let cutoff = Date().addingTimeInterval(-300)
        for n in ((try? fm.contentsOfDirectory(atPath: opts.queueDir)) ?? []) where n.hasSuffix(".tmp") {
            let p = opts.queueDir + "/" + n
            if let d = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date, d < cutoff {
                try? fm.removeItem(atPath: p)
            }
        }
    }

    let files = pendingFiles()
    if !files.isEmpty {
        if since == nil {
            since = Date()
            batchApp = frontmostApp()
        }
        for f in files {
            let text = (try? String(contentsOfFile: f, encoding: .utf8)) ?? ""
            try? fm.removeItem(atPath: f)
            if !text.isEmpty { buffer += text }
        }
        lastAdd = Date()
    }

    if buffer.isEmpty { return }

    let now = Date()
    let quiet = lastAdd.map { now.timeIntervalSince($0) * 1000 } ?? 9999
    let waited = since.map { now.timeIntervalSince($0) * 1000 } ?? 0

    // Letters are reported one keypress at a time. Give an ASCII-only batch a
    // longer quiet window so a burst is spelled in one utterance ("a b c d")
    // instead of one utterance per key; Chinese keeps the configured IdleMs.
    let asciiOnly = !buffer.isEmpty && buffer.allSatisfy {
        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " ")
    }
    let idle = Double(opts.idleMs) + (asciiOnly ? 200 : 0)
    let maxWait = asciiOnly ? max(Double(opts.maxWaitMs), 1200) : Double(opts.maxWaitMs)
    guard quiet >= idle || waited >= maxWait else { return }

    let raw = buffer
    let app = batchApp
    buffer = ""; since = nil; lastAdd = nil; batchApp = ("", "")

    let readable = readableChars(raw)
    if readable.isEmpty { return }
    if !appAllowed(app) {
        log("skip (app filter '\(opts.appFilterMode)') app=[\(app.bundle)/\(app.name)] text=[\(readable)]")
        return
    }
    log("read [\(readable)] app=[\(app.bundle)]")
    speaker.feed(buildBody(readable))
}
RunLoop.main.add(timer, forMode: .common)
app.run()