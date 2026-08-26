#!/usr/bin/swift
//
//  justspeak.swift
//  JustSpeak - Ultra-Low-Latency Push-to-Talk macOS Voice Dictation
//
//  Zero native compiled dependencies. Pure Apple Swift.
//  Uses AVFoundation, CoreGraphics CGEvent, and Gemini Live WebSockets / REST.
//

import Foundation
import AVFoundation
import AppKit
import CoreGraphics
import ApplicationServices
import Darwin
import SQLite3
import Carbon
import IOKit

// Unbuffer standard output so terminal output flushes immediately in compiled binary
setbuf(stdout, nil)
setbuf(stderr, nil)

// MARK: - ANSI Color Styling & High-Performance Logging

enum ANSI {
    static let reset = "\u{001B}[0m"
    static let bold = "\u{001B}[1m"
    static let dim = "\u{001B}[2m"
    static let red = "\u{001B}[31m"
    static let green = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let blue = "\u{001B}[34m"
    static let magenta = "\u{001B}[35m"
    static let cyan = "\u{001B}[36m"
    static let white = "\u{001B}[37m"
    static let gray = "\u{001B}[90m"
    static let clearLine = "\u{001B}[2K\r"
}

struct Logger {
    static var isVerbose: Bool = true
    
    // POSIX microsecond timestamp formatter (zero heap allocations)
    static func timestamp() -> String {
        var tv = timeval()
        gettimeofday(&tv, nil)
        var tm_val = tm()
        localtime_r(&tv.tv_sec, &tm_val)
        var buf = [CChar](repeating: 0, count: 32)
        strftime(&buf, buf.count, "%H:%M:%S", &tm_val)
        let ms = Int(tv.tv_usec) / 1000
        return String(cString: buf) + String(format: ".%03d", ms)
    }
    
    static func info(_ tag: String, _ message: String) {
        print("\(ANSI.gray)[\(timestamp())]\(ANSI.reset) \(ANSI.bold)\(ANSI.cyan)[\(tag)]\(ANSI.reset) \(message)")
        fflush(stdout)
    }
    
    static func success(_ tag: String, _ message: String) {
        print("\(ANSI.gray)[\(timestamp())]\(ANSI.reset) \(ANSI.bold)\(ANSI.green)[\(tag)]\(ANSI.reset) \(message)")
        fflush(stdout)
    }
    
    static func warn(_ tag: String, _ message: String) {
        print("\(ANSI.gray)[\(timestamp())]\(ANSI.reset) \(ANSI.bold)\(ANSI.yellow)[\(tag)]\(ANSI.reset) \(message)")
        fflush(stdout)
    }
    
    static func error(_ tag: String, _ message: String) {
        print("\(ANSI.gray)[\(timestamp())]\(ANSI.reset) \(ANSI.bold)\(ANSI.red)[\(tag)]\(ANSI.reset) \(message)")
        fflush(stdout)
    }
    
    static func debug(_ tag: String, _ message: String) {
        guard isVerbose else { return }
        print("\(ANSI.gray)[\(timestamp())] [\(tag)] \(message)\(ANSI.reset)")
        fflush(stdout)
    }
    
    static func meter(_ message: String) {
        print("\(ANSI.clearLine)\(ANSI.gray)[\(timestamp())]\(ANSI.reset) \(message)", terminator: "")
        fflush(stdout)
    }
    
    static func endMeter() {
        print("")
        fflush(stdout)
    }
}

// MARK: - Configuration Manager

// A "wrong => right" vocabulary entry: enforced deterministically post-transcription
// (see ReplacementEngine), with the right-hand side also fed into the boost vocabulary.
struct ReplacementRule {
    let wrong: String
    let right: String
}

struct Config {
    var geminiApiKey: String = ""
    var geminiModel: String = "gemini-3.5-flash-lite"
    var geminiLiveModel: String = "gemini-3.5-transcribe-live"
    var smartTranscription: Bool = true
    // Region-qualified BCP-47 codes, matching the live-transcribe language table (en-IN, mr-IN,
    // hi-IN, ...). Bare "en"/"mr" is not what the documented table lists.
    var languageCodes: [String] = ["en-IN", "mr-IN"]
    var customVocabulary: [String] = []
    var customVocabularyFile: String = ""
    var replacementRules: [ReplacementRule] = []
    var hotkey: String = "right_option"
    var hotkeyMode: String = "push_to_talk" // "push_to_talk" or "toggle"
    var soundFeedback: Bool = true
    var showHUD: Bool = true
    var enableLiveWebSocket: Bool = true
    var restFallbackTimeout: Double = 4.0
    var preRollMs: Int = 400
    // 250ms default: people release the key while the last word is still leaving their mouth;
    // audio keeps streaming during the grace period, so the only cost is commit latency.
    var postRollMs: Int = 250
    var vadMode: String = "manual" // "manual" (PTT key defines speech bounds), "tuned", or "auto"
    var vadSilenceMs: Int = 1500
    // Release the mic (status-bar indicator off) after this many seconds without a dictation;
    // the next key-down re-arms it. 0 = keep the mic always on (lowest latency, indicator lit).
    var micIdleTimeoutSec: Int = 300
    // Token pricing (USD per 1M tokens), used only for the per-dictation cost line in the
    // diagnostics. Defaults match Aug 2026 public-preview pricing for the two default models.
    var liveInputPricePer1M: Double = 3.50   // gemini-3.5-transcribe-live audio input
    var liveOutputPricePer1M: Double = 21.00 // gemini-3.5-transcribe-live text output
    var restInputPricePer1M: Double = 0.30   // gemini-3.5-flash-lite input
    var restOutputPricePer1M: Double = 2.50  // gemini-3.5-flash-lite output
    var restoreClipboard: Bool = true
    var logLevel: String = "verbose"
    // Local dictation history (SQLite). Every turn - success, empty, or error - becomes one row
    // so usage/latency/cost can be analyzed later. Plaintext on disk; disable with HISTORY=false.
    var historyEnabled: Bool = true
    var historyDbPath: String = ""   // empty = ~/.justspeak/history.db

    static func parseVocabulary(from text: String) -> [String] {
        var items: [String] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            if let data = trimmed.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                return arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
        }
        
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let cleanLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanLine.isEmpty || cleanLine.hasPrefix("#") { continue }
            
            if cleanLine.contains(",") {
                let parts = cleanLine.components(separatedBy: ",")
                for part in parts {
                    let cleaned = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty && !cleaned.hasPrefix("#") {
                        items.append(cleaned)
                    }
                }
            } else {
                items.append(cleanLine)
            }
        }
        return items
    }

    // Splits raw vocabulary items into plain boost terms and "wrong => right" replacement
    // rules (first "=>" wins; either side empty after trim discards the item). Rules are
    // deduped by lowercased "wrong", first occurrence wins - matching the boost-term dedupe.
    static func splitVocabularyItems(_ items: [String]) -> (vocab: [String], rules: [ReplacementRule]) {
        var vocab: [String] = []
        var rules: [ReplacementRule] = []
        var seenWrong = Set<String>()
        for item in items {
            guard let arrow = item.range(of: "=>") else {
                vocab.append(item)
                continue
            }
            let wrong = item[item.startIndex..<arrow.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let right = item[arrow.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if wrong.isEmpty || right.isEmpty { continue }
            let key = wrong.lowercased()
            if seenWrong.contains(key) { continue }
            seenWrong.insert(key)
            rules.append(ReplacementRule(wrong: wrong, right: right))
        }
        return (vocab, rules)
    }

    // Canonical BCP-47 casing: language lowercase, script Titlecase, region UPPERCASE
    // ("en-in" -> "en-IN", "pa-guru-in" -> "pa-Guru-IN"). The live-transcribe language table
    // uses region-qualified codes with this casing, so normalize instead of lowercasing away.
    static func normalizeLanguageCode(_ raw: String) -> String {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-")
        return parts.enumerated().map { idx, part in
            let s = String(part)
            if idx == 0 { return s.lowercased() }
            if s.count == 4 { return s.prefix(1).uppercased() + s.dropFirst().lowercased() }
            return s.uppercased()
        }.joined(separator: "-")
    }

    static func loadVocabularyFile(path: String) -> [String] {
        let expanded = NSString(string: path).expandingTildeInPath
        if let content = try? String(contentsOfFile: expanded, encoding: .utf8) {
            return parseVocabulary(from: content)
        }
        return []
    }
    
    static func load() -> Config {
        var config = Config()
        var inlineVocabRaw = ""
        var vocabFile = ""
        var rawLanguages: String? = nil
        
        let currentDir = FileManager.default.currentDirectoryPath
        let execDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
        let envPaths = [
            "\(currentDir)/.env",
            "\(execDir)/.env"
        ]
        
        for envPath in envPaths {
            if let content = try? String(contentsOfFile: envPath, encoding: .utf8) {
                let lines = content.components(separatedBy: .newlines)
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                    
                    let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
                    if parts.count == 2 {
                        let key = parts[0].trimmingCharacters(in: .whitespaces)
                        var value = parts[1].trimmingCharacters(in: .whitespaces)
                        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                            value = String(value.dropFirst().dropLast())
                        }
                        
                        switch key {
                        case "GEMINI_API_KEY": config.geminiApiKey = value
                        case "GEMINI_MODEL": config.geminiModel = value
                        case "GEMINI_LIVE_MODEL": config.geminiLiveModel = value
                        case "SMART_TRANSCRIPTION": config.smartTranscription = (value.lowercased() == "true" || value == "1")
                        case "LANGUAGE_CODES": rawLanguages = value
                        case "CUSTOM_VOCABULARY": inlineVocabRaw = value
                        case "CUSTOM_VOCABULARY_FILE": vocabFile = value
                        case "HOTKEY": config.hotkey = value.lowercased()
                        case "HOTKEY_MODE": config.hotkeyMode = value.lowercased()
                        case "SOUND_FEEDBACK": config.soundFeedback = (value.lowercased() == "true" || value == "1")
                        case "SHOW_HUD": config.showHUD = (value.lowercased() == "true" || value == "1")
                        case "ENABLE_LIVE_WEBSOCKET": config.enableLiveWebSocket = (value.lowercased() == "true" || value == "1")
                        case "RESTORE_CLIPBOARD": config.restoreClipboard = (value.lowercased() == "true" || value == "1")
                        case "REST_FALLBACK_TIMEOUT": if let t = Double(value) { config.restFallbackTimeout = t }
                        case "PRE_ROLL_MS": if let ms = Int(value) { config.preRollMs = min(1000, max(0, ms)) }
                        case "POST_ROLL_MS": if let ms = Int(value) { config.postRollMs = min(500, max(0, ms)) }
                        case "VAD_MODE": if ["manual", "tuned", "auto"].contains(value.lowercased()) { config.vadMode = value.lowercased() }
                        case "VAD_SILENCE_MS": if let ms = Int(value) { config.vadSilenceMs = min(5000, max(200, ms)) }
                        case "MIC_IDLE_TIMEOUT": if let sec = Int(value) { config.micIdleTimeoutSec = min(7200, max(0, sec)) }
                        case "HISTORY": config.historyEnabled = (value.lowercased() == "true" || value == "1")
                        case "HISTORY_DB": config.historyDbPath = value
                        case "LIVE_INPUT_PRICE_PER_1M": if let p = Double(value), p >= 0 { config.liveInputPricePer1M = p }
                        case "LIVE_OUTPUT_PRICE_PER_1M": if let p = Double(value), p >= 0 { config.liveOutputPricePer1M = p }
                        case "REST_INPUT_PRICE_PER_1M": if let p = Double(value), p >= 0 { config.restInputPricePer1M = p }
                        case "REST_OUTPUT_PRICE_PER_1M": if let p = Double(value), p >= 0 { config.restOutputPricePer1M = p }
                        case "LOG_LEVEL": config.logLevel = value.lowercased()
                        default: break
                        }
                    }
                }
                break
            }
        }
        
        let env = ProcessInfo.processInfo.environment
        if let key = env["GEMINI_API_KEY"], !key.isEmpty { config.geminiApiKey = key }
        if let model = env["GEMINI_MODEL"], !model.isEmpty { config.geminiModel = model }
        if let liveModel = env["GEMINI_LIVE_MODEL"], !liveModel.isEmpty { config.geminiLiveModel = liveModel }
        if let smart = env["SMART_TRANSCRIPTION"], !smart.isEmpty { config.smartTranscription = (smart.lowercased() == "true" || smart == "1") }
        if let langs = env["LANGUAGE_CODES"], !langs.isEmpty { rawLanguages = langs }
        if let vocab = env["CUSTOM_VOCABULARY"], !vocab.isEmpty { inlineVocabRaw = vocab }
        if let vf = env["CUSTOM_VOCABULARY_FILE"], !vf.isEmpty { vocabFile = vf }
        if let hk = env["HOTKEY"], !hk.isEmpty { config.hotkey = hk.lowercased() }
        if let mode = env["HOTKEY_MODE"], !mode.isEmpty { config.hotkeyMode = mode.lowercased() }
        if let sound = env["SOUND_FEEDBACK"] { config.soundFeedback = (sound.lowercased() == "true" || sound == "1") }
        if let hud = env["SHOW_HUD"] { config.showHUD = (hud.lowercased() == "true" || hud == "1") }
        if let ws = env["ENABLE_LIVE_WEBSOCKET"] { config.enableLiveWebSocket = (ws.lowercased() == "true" || ws == "1") }
        if let r = env["RESTORE_CLIPBOARD"] { config.restoreClipboard = (r.lowercased() == "true" || r == "1") }
        if let timeout = env["REST_FALLBACK_TIMEOUT"], let t = Double(timeout) { config.restFallbackTimeout = t }
        if let preRoll = env["PRE_ROLL_MS"], let ms = Int(preRoll) { config.preRollMs = min(1000, max(0, ms)) }
        if let postRoll = env["POST_ROLL_MS"], let ms = Int(postRoll) { config.postRollMs = min(500, max(0, ms)) }
        if let vad = env["VAD_MODE"], ["manual", "tuned", "auto"].contains(vad.lowercased()) { config.vadMode = vad.lowercased() }
        if let vadSilence = env["VAD_SILENCE_MS"], let ms = Int(vadSilence) { config.vadSilenceMs = min(5000, max(200, ms)) }
        if let micIdle = env["MIC_IDLE_TIMEOUT"], let sec = Int(micIdle) { config.micIdleTimeoutSec = min(7200, max(0, sec)) }
        if let hist = env["HISTORY"], !hist.isEmpty { config.historyEnabled = (hist.lowercased() == "true" || hist == "1") }
        if let histDb = env["HISTORY_DB"], !histDb.isEmpty { config.historyDbPath = histDb }
        if let p = env["LIVE_INPUT_PRICE_PER_1M"], let v = Double(p), v >= 0 { config.liveInputPricePer1M = v }
        if let p = env["LIVE_OUTPUT_PRICE_PER_1M"], let v = Double(p), v >= 0 { config.liveOutputPricePer1M = v }
        if let p = env["REST_INPUT_PRICE_PER_1M"], let v = Double(p), v >= 0 { config.restInputPricePer1M = v }
        if let p = env["REST_OUTPUT_PRICE_PER_1M"], let v = Double(p), v >= 0 { config.restOutputPricePer1M = v }
        if let log = env["LOG_LEVEL"] { config.logLevel = log.lowercased() }
        
        if let raw = rawLanguages {
            let parsedLangs = raw.components(separatedBy: ",")
                .map { normalizeLanguageCode($0) }
                .filter { !$0.isEmpty }
            if parsedLangs.contains("auto") || parsedLangs.contains("all") {
                config.languageCodes = []
            } else if !parsedLangs.isEmpty {
                config.languageCodes = parsedLangs
            }
        }
        
        config.customVocabularyFile = vocabFile
        
        var combinedVocab: [String] = []
        if !inlineVocabRaw.isEmpty {
            combinedVocab.append(contentsOf: parseVocabulary(from: inlineVocabRaw))
        }
        
        // Check specified vocabulary file or default candidate locations
        var candidateFiles: [String] = []
        if !vocabFile.isEmpty {
            candidateFiles.append(vocabFile)
            if !vocabFile.hasPrefix("/") {
                candidateFiles.append("\(currentDir)/\(vocabFile)")
                candidateFiles.append("\(execDir)/\(vocabFile)")
            }
        } else {
            candidateFiles.append("\(currentDir)/vocabulary.txt")
            candidateFiles.append("\(currentDir)/.vocabulary.txt")
            candidateFiles.append("\(execDir)/vocabulary.txt")
            candidateFiles.append("\(execDir)/.vocabulary.txt")
        }
        
        for candidate in candidateFiles {
            let items = loadVocabularyFile(path: candidate)
            if !items.isEmpty {
                combinedVocab.append(contentsOf: items)
                if config.customVocabularyFile.isEmpty {
                    config.customVocabularyFile = candidate
                }
                break
            }
        }
        
        // Pull "wrong => right" replacement rules out of the raw items; the right-hand side
        // still boosts recognition - never the wrong form, which would just teach the
        // recognizer to keep mishearing it the same way.
        let vocabSplit = splitVocabularyItems(combinedVocab)
        config.replacementRules = vocabSplit.rules
        combinedVocab = vocabSplit.vocab + vocabSplit.rules.map { $0.right }

        // Deduplicate while preserving order
        var seen = Set<String>()
        var deduped: [String] = []
        for word in combinedVocab {
            let normalized = word.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty && !seen.contains(normalized.lowercased()) {
                seen.insert(normalized.lowercased())
                deduped.append(normalized)
            }
        }
        config.customVocabulary = deduped
        
        Logger.isVerbose = (config.logLevel == "verbose")
        return config
    }
}

// MARK: - Binary Helpers (WAV Header Generator)

extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: self.littleEndian) { Array($0) }
    }
}

func createWavData(from pcm16Data: Data, sampleRate: Int = 16000, channels: Int = 1) -> Data {
    var wav = Data()
    let dataSize = pcm16Data.count
    let chunkSize = UInt32(36 + dataSize)
    
    // RIFF Chunk Descriptor
    wav.append("RIFF".data(using: .ascii)!)
    wav.append(contentsOf: chunkSize.littleEndianBytes)
    wav.append("WAVE".data(using: .ascii)!)
    
    // fmt Sub-chunk
    wav.append("fmt ".data(using: .ascii)!)
    wav.append(contentsOf: UInt32(16).littleEndianBytes) // Subchunk1Size (16 for PCM)
    wav.append(contentsOf: UInt16(1).littleEndianBytes)  // AudioFormat (1 = PCM Linear)
    wav.append(contentsOf: UInt16(channels).littleEndianBytes)
    wav.append(contentsOf: UInt32(sampleRate).littleEndianBytes)
    wav.append(contentsOf: UInt32(sampleRate * channels * 2).littleEndianBytes) // ByteRate
    wav.append(contentsOf: UInt16(channels * 2).littleEndianBytes)              // BlockAlign
    wav.append(contentsOf: UInt16(16).littleEndianBytes)                         // BitsPerSample
    
    // data Sub-chunk
    wav.append("data".data(using: .ascii)!)
    wav.append(contentsOf: UInt32(dataSize).littleEndianBytes)
    wav.append(pcm16Data)
    
    return wav
}

// MARK: - Audio Feedback Sound Manager (Apple System Earcons)

final class SoundManager {
    private static let startSoundPaths = [
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/begin_record.caf",
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/siri/jbl_begin.caf"
    ]
    
    private static let commitSoundPaths = [
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/siri/jbl_confirm.caf",
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/end_record.caf",
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/acknowledgment_sent.caf"
    ]
    
    private static let errorSoundPaths = [
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/siri/jbl_cancel.caf",
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/mic_unmute_fail.caf"
    ]
    
    private static var startSound: NSSound? = {
        for path in startSoundPaths {
            if FileManager.default.fileExists(atPath: path), let sound = NSSound(contentsOfFile: path, byReference: true) {
                sound.volume = 0.55
                return sound
            }
        }
        let fallback = NSSound(named: "Blow")
        fallback?.volume = 0.45
        return fallback
    }()
    
    private static var commitSound: NSSound? = {
        for path in commitSoundPaths {
            if FileManager.default.fileExists(atPath: path), let sound = NSSound(contentsOfFile: path, byReference: true) {
                sound.volume = 0.65
                return sound
            }
        }
        let fallback = NSSound(named: "Hero")
        fallback?.volume = 0.45
        return fallback
    }()
    
    private static var errorSound: NSSound? = {
        for path in errorSoundPaths {
            if FileManager.default.fileExists(atPath: path), let sound = NSSound(contentsOfFile: path, byReference: true) {
                sound.volume = 0.55
                return sound
            }
        }
        let fallback = NSSound(named: "Funk")
        fallback?.volume = 0.45
        return fallback
    }()
    
    static func playStartSound() {
        DispatchQueue.global(qos: .userInteractive).async {
            startSound?.stop()
            startSound?.play()
        }
    }
    
    static func playCommitSound() {
        DispatchQueue.global(qos: .userInteractive).async {
            commitSound?.stop()
            commitSound?.play()
        }
    }
    
    static func playErrorSound() {
        DispatchQueue.global(qos: .userInteractive).async {
            errorSound?.stop()
            errorSound?.play()
        }
    }
}

// MARK: - Text Injection & Clipboard Engine

struct TextInjector {
    // Marker types so clipboard managers (Paste, Maccy, Raycast Clipboard History, ...) skip
    // archiving ephemeral dictation text - org.nspasteboard.org convention.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")

    private static func snapshotClipboard() -> [NSPasteboardItem] {
        let pb = NSPasteboard.general
        guard let items = pb.pasteboardItems else { return [] }
        var copiedItems: [NSPasteboardItem] = []
        for item in items {
            let newItem = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    newItem.setData(data, forType: type)
                }
            }
            copiedItems.append(newItem)
        }
        return copiedItems
    }
    
    private static func restoreClipboard(_ savedItems: [NSPasteboardItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if !savedItems.isEmpty {
            pb.writeObjects(savedItems)
        }
    }
    
    static func inject(text: String, restorePreviousClipboard: Bool = true, completionSound: Bool = true) -> (success: Bool, latencyMs: Double) {
        let startTime = CFAbsoluteTimeGetCurrent()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Logger.warn("INJECT", "Refusing to inject empty string.")
            return (false, 0)
        }
        
        // 1. Snapshot previous clipboard to preserve user data
        let previousClipboard = restorePreviousClipboard ? snapshotClipboard() : []
        
        // 2. Put text onto pasteboard for active app injection. Written as an NSPasteboardItem
        // with transient/auto-generated marker types so clipboard managers skip archiving it.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(trimmed, forType: .string)
        item.setData(Data(), forType: transientType)
        item.setData(Data(), forType: autoGeneratedType)
        let pbSuccess = pasteboard.writeObjects([item])
        guard pbSuccess else {
            Logger.error("INJECT", "Failed to write text to NSPasteboard.")
            return (false, 0)
        }
        let ourChangeCount = pasteboard.changeCount

        // 3. Synthesize Cmd+V via CGEvent (posted exclusively to cghidEventTap)
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 0x09 // Virtual keycode for 'v'
        
        var eventSuccess = false
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) {
            
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            
            keyDown.post(tap: .cghidEventTap)
            usleep(10_000) // 10ms key press hold - sufficient for a synthesized Cmd+V to register
            keyUp.post(tap: .cghidEventTap)
            
            eventSuccess = true
        }
        
        // 4. Fallback to AppleScript only if CGEvent dispatch failed
        if !eventSuccess {
            Logger.warn("INJECT", "CGEvent posting failed; executing AppleScript System Events fallback...")
            let appleScript = NSAppleScript(source: "tell application \"System Events\" to keystroke \"v\" using command down")
            var errorInfo: NSDictionary?
            appleScript?.executeAndReturnError(&errorInfo)
            if let error = errorInfo {
                Logger.error("INJECT", "AppleScript fallback error: \(error)")
            } else {
                eventSuccess = true
            }
        }
        
        // 5. Asynchronously restore user's previous clipboard after ~1s (giving slow/Electron
        // apps like Slack/VSCode time to consume it), but only if nothing else has touched the
        // pasteboard since our write - otherwise a user copy (or another app) would get clobbered.
        if restorePreviousClipboard && !previousClipboard.isEmpty {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                guard NSPasteboard.general.changeCount == ourChangeCount else { return }
                restoreClipboard(previousClipboard)
            }
        }

        if completionSound {
            SoundManager.playCommitSound()
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        return (eventSuccess, elapsed)
    }

    /// Puts text on the clipboard WITHOUT synthesizing ⌘V or restoring the previous clipboard -
    /// the copy-only fallback for secure-input and mid-turn focus changes, so the text stays put
    /// for the user to paste manually.
    static func copyOnly(text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(trimmed, forType: .string)
        item.setData(Data(), forType: transientType)
        item.setData(Data(), forType: autoGeneratedType)
        return pasteboard.writeObjects([item])
    }
}

// MARK: - Replacement Engine (Deterministic Wrong→Right Enforcement)

// Post-transcription enforcement layer: the model can be *biased* toward the right spelling
// via boost vocabulary, but this layer *guarantees* it - longest-match-first, word-boundary,
// case-preserving (ALL-CAPS / Title / lower propagation).
enum ReplacementEngine {
    static func apply(_ text: String, rules: [ReplacementRule]) -> String {
        guard !rules.isEmpty else { return text }
        var result = text
        // Longest wrong-form first so "gemini api" wins over "gemini".
        for rule in rules.sorted(by: { $0.wrong.count > $1.wrong.count }) {
            guard !rule.wrong.isEmpty else { continue }
            // Lookarounds instead of \b: word boundaries silently never match when the wrong
            // form starts/ends with punctuation ("e.g.", "c++").
            let pattern = "(?<![\\w])\(NSRegularExpression.escapedPattern(for: rule.wrong))(?![\\w])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed()
            let mutable = NSMutableString(string: result)
            for match in matches {
                let original = ns.substring(with: match.range)
                let replacement = propagateCase(from: original, to: rule.right, wrong: rule.wrong)
                mutable.replaceCharacters(in: match.range, with: replacement)
            }
            result = mutable as String
        }
        return result
    }

    // "KUBERNETES"->"GRPC" stays caps; "Kubernetes"->"GRPC" follows the rule's canonical
    // casing unless the match was ALL-CAPS or the rule carries EXPLICIT casing. A rule is
    // explicitly cased when its right side contains uppercase (gRPC, iPhone) - or when its
    // WRONG side does ("NPM"->"npm" is a deliberate lowercase rule; ALL-CAPS propagation
    // would silently undo it) - or when wrong/right are the same word modulo case.
    static func propagateCase(from original: String, to replacement: String, wrong: String = "") -> String {
        let hasExplicitCasing = replacement.dropFirst().contains(where: { $0.isUppercase })
            || replacement.first?.isUppercase == true
            || wrong.contains(where: { $0.isUppercase })
            || (!wrong.isEmpty && wrong.lowercased() == replacement.lowercased())
        if hasExplicitCasing {
            return replacement // dictionary term carries its own casing (gRPC, iPhone)
        }
        if original == original.uppercased(), original.count > 1 {
            return replacement.uppercased()
        }
        if original.first?.isUppercase == true {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }
}

// MARK: - Dictation History (SQLite)

// SQLite's bind-text destructor macro (SQLITE_TRANSIENT = (sqlite3_destructor_type)-1) isn't
// exposed to Swift by the C header, so it's reconstructed here the standard way.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Records every dictation turn - success, empty, or error - as one row in a local SQLite DB
/// so usage can be analyzed later (cost per day, latency percentiles, word counts). All sqlite3
/// calls happen on `queue`; that serial queue is the thread-safety story, no lock needed.
final class TranscriptionHistoryStore {
    struct TurnRecord {
        var outcome: String
        var text: String?
        var charCount: Int
        var wordCount: Int
        var transport: String?
        var model: String?
        var isLiveRoute: Bool?
        var fallbackReason: String?
        var audioSeconds: Double?
        var firstTokenMs: Double?
        var roundtripMs: Double?
        var captureFinalizeMs: Double?
        var injectMs: Double?
        var totalMs: Double?
        var injected: Bool?
        var inputTokens: Int?
        var outputTokens: Int?
        var tokensMetered: Bool?
        var costUSD: Double?
        var languageCodes: String
        var smartMode: Bool
        var vadMode: String
        var error: String?
    }

    private let queue = DispatchQueue(label: "com.justspeak.history", qos: .utility)
    private var db: OpaquePointer?
    private var failed = false
    private let dbPath: String
    private let sessionId = UUID().uuidString
    private static let isoFormatter = ISO8601DateFormatter()

    var path: String { dbPath }

    init(config: Config) {
        let rawPath = config.historyDbPath.isEmpty ? "~/.justspeak/history.db" : config.historyDbPath
        self.dbPath = (rawPath as NSString).expandingTildeInPath
    }

    // Called on-queue from record(). No-ops once already open or once opening has failed.
    private func openIfNeeded() {
        guard db == nil, !failed else { return }

        let dir = (dbPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            failed = true
            Logger.warn("HISTORY", "Failed to create history directory \(dir): \(error.localizedDescription)")
            return
        }

        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard openResult == SQLITE_OK, let opened = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite3_open_v2 error"
            failed = true
            Logger.warn("HISTORY", "Failed to open history DB at \(dbPath): \(msg)")
            if let handle = handle { sqlite3_close(handle) }
            return
        }
        chmod(dbPath, 0o600)

        if sqlite3_exec(opened, "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=2000;", nil, nil, nil) != SQLITE_OK {
            failed = true
            Logger.warn("HISTORY", "Failed to set history DB pragmas: \(String(cString: sqlite3_errmsg(opened)))")
            sqlite3_close(opened)
            return
        }

        let schema = """
        CREATE TABLE IF NOT EXISTS transcriptions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          ts_utc TEXT NOT NULL,
          ts_epoch REAL NOT NULL,
          session_id TEXT NOT NULL,
          outcome TEXT NOT NULL,
          text TEXT,
          char_count INTEGER NOT NULL DEFAULT 0,
          word_count INTEGER NOT NULL DEFAULT 0,
          transport TEXT,
          model TEXT,
          is_live_route INTEGER,
          fallback_reason TEXT,
          audio_seconds REAL,
          first_token_ms REAL,
          roundtrip_ms REAL,
          capture_finalize_ms REAL,
          inject_ms REAL,
          total_ms REAL,
          injected INTEGER,
          input_tokens INTEGER,
          output_tokens INTEGER,
          tokens_metered INTEGER,
          cost_usd REAL,
          language_codes TEXT,
          smart_mode INTEGER,
          vad_mode TEXT,
          error TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_transcriptions_ts ON transcriptions(ts_epoch);
        CREATE INDEX IF NOT EXISTS idx_transcriptions_session ON transcriptions(session_id);
        """
        if sqlite3_exec(opened, schema, nil, nil, nil) != SQLITE_OK {
            failed = true
            Logger.warn("HISTORY", "Failed to create history schema: \(String(cString: sqlite3_errmsg(opened)))")
            sqlite3_close(opened)
            return
        }

        db = opened
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let value = value {
            sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func bindDouble(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Double?) {
        if let value = value {
            sqlite3_bind_double(stmt, idx, value)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func bindInt(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Int?) {
        if let value = value {
            sqlite3_bind_int64(stmt, idx, Int64(value))
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func bindBool(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Bool?) {
        if let value = value {
            sqlite3_bind_int(stmt, idx, value ? 1 : 0)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    func record(_ r: TurnRecord) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.openIfNeeded()
            guard !self.failed, let db = self.db else { return }

            let sql = """
            INSERT INTO transcriptions (
              ts_utc, ts_epoch, session_id, outcome, text, char_count, word_count,
              transport, model, is_live_route, fallback_reason, audio_seconds,
              first_token_ms, roundtrip_ms, capture_finalize_ms, inject_ms, total_ms,
              injected, input_tokens, output_tokens, tokens_metered, cost_usd,
              language_codes, smart_mode, vad_mode, error
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                self.failed = true
                Logger.warn("HISTORY", "Failed to prepare history insert: \(String(cString: sqlite3_errmsg(db)))")
                sqlite3_finalize(stmt)
                return
            }

            let now = Date()
            self.bindText(stmt, 1, TranscriptionHistoryStore.isoFormatter.string(from: now))
            self.bindDouble(stmt, 2, now.timeIntervalSince1970)
            self.bindText(stmt, 3, self.sessionId)
            self.bindText(stmt, 4, r.outcome)
            self.bindText(stmt, 5, r.text)
            self.bindInt(stmt, 6, r.charCount)
            self.bindInt(stmt, 7, r.wordCount)
            self.bindText(stmt, 8, r.transport)
            self.bindText(stmt, 9, r.model)
            self.bindBool(stmt, 10, r.isLiveRoute)
            self.bindText(stmt, 11, r.fallbackReason)
            self.bindDouble(stmt, 12, r.audioSeconds)
            self.bindDouble(stmt, 13, r.firstTokenMs)
            self.bindDouble(stmt, 14, r.roundtripMs)
            self.bindDouble(stmt, 15, r.captureFinalizeMs)
            self.bindDouble(stmt, 16, r.injectMs)
            self.bindDouble(stmt, 17, r.totalMs)
            self.bindBool(stmt, 18, r.injected)
            self.bindInt(stmt, 19, r.inputTokens)
            self.bindInt(stmt, 20, r.outputTokens)
            self.bindBool(stmt, 21, r.tokensMetered)
            self.bindDouble(stmt, 22, r.costUSD)
            self.bindText(stmt, 23, r.languageCodes)
            self.bindBool(stmt, 24, r.smartMode)
            self.bindText(stmt, 25, r.vadMode)
            self.bindText(stmt, 26, r.error)

            if sqlite3_step(stmt) != SQLITE_DONE {
                self.failed = true
                Logger.warn("HISTORY", "Failed to insert history row: \(String(cString: sqlite3_errmsg(db)))")
            }
            sqlite3_finalize(stmt)
        }
    }

    func close() {
        queue.sync {
            guard let db = self.db else { return }
            sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
            sqlite3_close(db)
            self.db = nil
        }
    }
}

// MARK: - Audio Capture Engine with Pre-roll Ring Buffer & Offloaded Threading

final class AudioCaptureEngine {
    private let audioEngine = AVAudioEngine()
    private var audioConverter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    
    // Dedicated background audio processing queue (keeps CoreAudio render thread non-blocking)
    private let audioProcessingQueue = DispatchQueue(label: "com.justspeak.audioProcessing", qos: .userInteractive)
    
    private let lock = NSLock()
    private(set) var isRecording: Bool = false
    private(set) var isEngineRunning: Bool = false // main-thread-only (setup/suspend/resume)
    private var recordedPCMData = Data()
    private var chunkCount: Int = 0
    private var recordingStartTime: CFAbsoluteTime = 0
    private var lastMeterUpdateTime: CFAbsoluteTime = 0
    
    // Pre-roll rolling ring buffer (default 400ms = 6400 samples @ 16kHz = 12800 bytes)
    private var preRollRingBuffer = Data()
    private let maxPreRollBytes: Int
    private var preRollBytesInTurn = 0
    
    // Streaming chunk accumulator (~150ms chunks = 4800 bytes)
    private var pendingChunkBuffer = Data()
    private let streamingChunkTargetBytes = 4800
    
    var onAudioChunk: ((Data) -> Void)?
    var onAudioLevel: ((Double) -> Void)?
    
    init(preRollMs: Int = 400) {
        // Standard 16kHz 16-bit Mono Linear PCM for speech AI models
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000.0,
            channels: 1,
            interleaved: true
        )!
        // 16,000 samples/sec * 2 bytes/sample = 32 bytes per ms
        self.maxPreRollBytes = max(0, preRollMs * 32)
    }
    
    func setup() -> Bool {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        Logger.info("MIC", "Hardware format: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch, \(inputFormat.formatDescription)")
        Logger.info("MIC", "Target format: 16000 Hz, 1 ch, 16-bit Linear PCM")
        
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            Logger.error("MIC", "Failed to construct AVAudioConverter from \(inputFormat) to \(targetFormat)")
            return false
        }
        self.audioConverter = converter
        
        // Tap callback: ONLY copies incoming buffer and pushes to serial audio queue (0 blocking operations on render thread)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] (buffer, when) in
            guard let self = self else { return }
            let bufferCopy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity)!
            bufferCopy.frameLength = buffer.frameLength
            for i in 0..<Int(buffer.format.channelCount) {
                if let src = buffer.floatChannelData?[i], let dst = bufferCopy.floatChannelData?[i] {
                    memcpy(dst, src, Int(buffer.frameLength) * MemoryLayout<Float>.size)
                }
            }
            
            self.audioProcessingQueue.async {
                self.processIncomingBufferOnQueue(bufferCopy)
            }
        }
        
        do {
            audioEngine.prepare()
            try audioEngine.start()
            isEngineRunning = true
            Logger.success("MIC", "Audio engine pre-warmed & running in background (zero keydown wake-up latency).")
            return true
        } catch {
            Logger.error("MIC", "Could not start AVAudioEngine: \(error.localizedDescription)")
            return false
        }
    }

    // Releases the microphone (the macOS status-bar mic indicator turns off) while keeping the
    // tap installed, so resumeEngine() only pays hardware spin-up. Refuses mid-dictation.
    // Both suspend and resume are main-thread-only, matching where the idle timer and the
    // key-down handler run.
    func suspendEngine() {
        lock.lock()
        let recording = isRecording
        lock.unlock()
        guard isEngineRunning, !recording else { return }

        audioEngine.stop()
        isEngineRunning = false

        // Minutes-old ambient audio must not be prepended to the next dictation as pre-roll.
        lock.lock()
        preRollRingBuffer.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    // Re-acquires the microphone after an idle suspend (~50-200ms hardware spin-up, blocking).
    func resumeEngine() -> Bool {
        guard !isEngineRunning else { return true }
        do {
            audioEngine.prepare()
            try audioEngine.start()
            isEngineRunning = true
            return true
        } catch {
            Logger.error("MIC", "Could not restart AVAudioEngine after idle: \(error.localizedDescription)")
            return false
        }
    }
    
    private func processIncomingBufferOnQueue(_ inputBuffer: AVAudioPCMBuffer) {
        guard let converter = audioConverter else { return }
        
        let ratio = 16000.0 / inputBuffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 64)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }
        
        var error: NSError?
        var consumed = false
        
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if !consumed {
                consumed = true
                outStatus.pointee = .haveData
                return inputBuffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }
        
        if status == .haveData, outputBuffer.frameLength > 0, let int16Pointer = outputBuffer.int16ChannelData?[0] {
            let byteCount = Int(outputBuffer.frameLength) * 2
            let chunkData = Data(bytes: int16Pointer, count: byteCount)

            lock.lock()
            let currentlyRecording = isRecording

            if !currentlyRecording {
                // Maintain 250ms pre-roll circular buffer while idle
                preRollRingBuffer.append(chunkData)
                if preRollRingBuffer.count > maxPreRollBytes {
                    preRollRingBuffer.removeFirst(preRollRingBuffer.count - maxPreRollBytes)
                }
                lock.unlock()
                return
            }

            recordedPCMData.append(chunkData)
            pendingChunkBuffer.append(chunkData)
            chunkCount += 1

            // 10Hz meter throttle decision must happen under the lock since it mutates
            // lastMeterUpdateTime; only snapshot the meter's inputs when actually needed.
            let now = CFAbsoluteTimeGetCurrent()
            var shouldUpdateMeter = false
            var elapsed: Double = 0
            var kbStreamed: Double = 0
            var chunkCountSnapshot = 0
            if (now - lastMeterUpdateTime) > 0.10 {
                lastMeterUpdateTime = now
                shouldUpdateMeter = true
                elapsed = now - recordingStartTime
                kbStreamed = Double(recordedPCMData.count) / 1024.0
                chunkCountSnapshot = chunkCount
            }

            // Coalesce audio into ~150ms frames before dispatching to WebSocket
            var toStream: Data? = nil
            if pendingChunkBuffer.count >= streamingChunkTargetBytes {
                toStream = pendingChunkBuffer
                pendingChunkBuffer.removeAll(keepingCapacity: true)
            }
            lock.unlock()

            // RMS math, meter rendering, and callbacks all run off the lock. int16Pointer is
            // still valid here - it points into outputBuffer, a local var alive for this call.
            if shouldUpdateMeter {
                var sumSquare: Double = 0.0
                let sampleCount = Int(outputBuffer.frameLength)
                for i in 0..<sampleCount {
                    let sample = Double(int16Pointer[i])
                    sumSquare += sample * sample
                }
                let rms = sqrt(sumSquare / Double(max(sampleCount, 1)))
                let db = 20.0 * log10(max(rms, 1.0) / 32768.0)

                let meterBars = renderVolumeMeter(db: db)
                Logger.meter("\(ANSI.bold)\(ANSI.yellow)🎙️  RECORDING\(ANSI.reset) [\(meterBars)] \(String(format: "%5.1f", db)) dB | \(String(format: "%.2fs", elapsed)) | \(String(format: "%.1f", kbStreamed)) KB streamed (#\(chunkCountSnapshot))")
                onAudioLevel?(db)
            }

            if let toStream = toStream {
                onAudioChunk?(toStream)
            }
        }
    }
    
    private func renderVolumeMeter(db: Double) -> String {
        let normalized = max(0.0, min(1.0, (db + 50.0) / 50.0))
        let totalBlocks = 12
        let filledBlocks = Int(round(normalized * Double(totalBlocks)))
        let emptyBlocks = totalBlocks - filledBlocks
        
        let filledStr = String(repeating: "█", count: filledBlocks)
        let emptyStr = String(repeating: "░", count: emptyBlocks)
        return "\(ANSI.green)\(filledStr)\(ANSI.gray)\(emptyStr)\(ANSI.reset)"
    }
    
    func startRecording() {
        lock.lock()
        recordedPCMData.removeAll(keepingCapacity: true)
        pendingChunkBuffer.removeAll(keepingCapacity: true)

        // Prepend rolling pre-roll buffer to prevent clipped first syllable
        preRollBytesInTurn = 0
        var immediatePreRollChunk: Data? = nil
        if !preRollRingBuffer.isEmpty {
            preRollBytesInTurn = preRollRingBuffer.count
            recordedPCMData.append(preRollRingBuffer)
            immediatePreRollChunk = preRollRingBuffer
            preRollRingBuffer.removeAll(keepingCapacity: true)
        }
        
        chunkCount = 0
        recordingStartTime = CFAbsoluteTimeGetCurrent()
        lastMeterUpdateTime = 0
        isRecording = true
        lock.unlock()

        // Immediately dispatch pre-roll audio to WebSocket so speech model receives head-start audio
        if let chunk = immediatePreRollChunk {
            onAudioChunk?(chunk)
        }
    }
    
    func stopRecording(gracePeriodMs: Int = 150) -> (pcmData: Data, duration: Double, chunkCount: Int, capturedBytes: Int) {
        // True hold duration is measured at entry, BEFORE the post-roll sleep - otherwise the
        // grace period pads every tap past the caller's micro-click duration threshold.
        let stopRequestTime = CFAbsoluteTimeGetCurrent()

        // 1. Brief post-roll grace period (150ms) to allow final acoustic phonemes from mic hardware buffer to arrive
        if gracePeriodMs > 0 {
            usleep(useconds_t(gracePeriodMs * 1000))
        }

        // 2. Synchronously drain all in-flight audio processing tasks on the serial queue
        audioProcessingQueue.sync { }

        lock.lock()
        isRecording = false

        // 3. Real captured byte count: taken before the silence flush below is appended, and
        // excluding the prepended pre-roll, so callers see genuine key-held speech audio only.
        let capturedBytes = max(0, recordedPCMData.count - preRollBytesInTurn)

        // 4. Collect any trailing pending chunk; fired via onAudioChunk after the lock is released
        var trailingChunk: Data? = nil
        if !pendingChunkBuffer.isEmpty {
            trailingChunk = pendingChunkBuffer
            pendingChunkBuffer.removeAll(keepingCapacity: true)
        }

        // 5. Append 700ms acoustic lookahead silence flush (22,400 bytes @ 16kHz 16-bit mono)
        // This satisfies the bidirectional acoustic lookahead window required by speech encoders to finalize trailing words
        let silenceFlushBytes = 22400
        let silenceData = Data(count: silenceFlushBytes)
        recordedPCMData.append(silenceData)

        let data = recordedPCMData
        let duration = stopRequestTime - recordingStartTime
        let chunks = chunkCount
        lock.unlock()

        // 6. Fire chunk callbacks outside the lock. Ordering preserved: trailing real audio first, then silence.
        if let trailing = trailingChunk {
            onAudioChunk?(trailing)
        }
        onAudioChunk?(silenceData)

        Logger.endMeter()
        return (data, duration, chunks, capturedBytes)
    }
    
    func stopEngine() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
    }
}

// MARK: - Gemini Live WebSocket Client (TEXT Modality + Manual Activity Detection + Auto-Reconnect)

final class GeminiLiveClient: NSObject, URLSessionWebSocketDelegate {
    private let apiKey: String
    private let model: String
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    
    private let lock = NSLock()
    private(set) var isConnected: Bool = false
    private(set) var isReady: Bool = false
    
    private var currentTurnText: String = ""
    // Multi-segment transcript accumulator. The server's VAD closes a speech segment at every
    // pause: the finished segment arrives as a finalized transcription, then the NEXT segment's
    // interim text starts empty - so treating any single message as "the whole turn so far"
    // wipes every earlier segment (pause mid-utterance -> first sentence lost). Finalized
    // segments accumulate in committedTranscript; interimTranscript holds only the in-progress
    // segment; currentTurnText is always their merge.
    private var committedTranscript: String = ""
    private var interimTranscript: String = ""
    private var firstTokenLatencyMs: Double = 0
    private var turnCommitTime: CFAbsoluteTime = 0
    private var lastTokenReceivedTime: CFAbsoluteTime = 0
    private var lastPostCommitTokenTime: CFAbsoluteTime? = nil
    // Set when a FINAL transcription arrives post-commit; cleared if a later interim shows
    // more content is still streaming in.
    private var lastPostCommitFinalTime: CFAbsoluteTime? = nil

    // API-metered token usage. Server messages carry cumulative usageMetadata for the session,
    // so per-turn usage is the delta from the counts snapshotted at startNewTurn. All under `lock`.
    private var lastSeenPromptTokens: Int = 0
    private var lastSeenResponseTokens: Int = 0
    private var turnBaselinePromptTokens: Int = 0
    private var turnBaselineResponseTokens: Int = 0

    /// API-reported usage for the current/most recent turn, or nil if the server reported
    /// nothing new this turn (caller falls back to a duration-based estimate).
    var lastTurnUsage: (inputTokens: Int, outputTokens: Int)? {
        lock.lock()
        defer { lock.unlock() }
        let dp = lastSeenPromptTokens - turnBaselinePromptTokens
        let dr = lastSeenResponseTokens - turnBaselineResponseTokens
        guard dp > 0 || dr > 0 else { return nil }
        return (max(0, dp), max(0, dr))
    }
    private var isCommitting: Bool = false
    private var hasFiredTurnCompletion: Bool = false
    private var turnCompletion: ((Result<(text: String, firstTokenMs: Double, totalMs: Double), Error>) -> Void)?
    var onLiveTextUpdate: ((String) -> Void)?
    private let smartTranscription: Bool
    private let languageCodes: [String]
    private let customVocabulary: [String]
    private let vadMode: String
    private let vadSilenceMs: Int

    // Conversational models always run with server VAD disabled (their setup hard-codes it);
    // transcribe models do so when VAD_MODE=manual. Either way the client must bracket each
    // turn with explicit activityStart/activityEnd signals.
    private var usesManualActivity: Bool {
        !model.contains("transcribe") || vadMode == "manual"
    }
    
    // Event-driven settlement timers for transcribe-model turn completion (see commitTurn/attemptSettle).
    private static let settleMinPostCommitWait: Double = 0.35
    private static let settleQuietWindow: Double = 0.25
    // With manual activity signaling the server owes an authoritative FINAL inputTranscription
    // after activityEnd. Interims are documented as "speculative partial hypotheses", so in
    // manual mode the interim-quiet fallback waits longer (don't paste speculation while the
    // final is still processing), and an observed final settles after only a short grace in
    // case a second segment's final is right behind it.
    private static let settleFinalGrace: Double = 0.15
    private static let settleInterimQuietManual: Double = 0.60
    private static let settleInitialWaitWithoutTokens: Double = 0.90
    private static let settleMaxWait: Double = 2.20
    // Timers are scheduled on DispatchTime but attemptSettle re-validates the rules against
    // CFAbsoluteTime - two different clocks. A firing that lands marginally early by the
    // CFAbsoluteTime measurement would return without settling and (being one-shot) leave no
    // retry, so every deadline gets a small cushion to guarantee the rule holds at fire time.
    private static let settleTimerCushion: Double = 0.01
    private let settleQueue = DispatchQueue(label: "com.justspeak.settle")
    private var settleWorkItem: DispatchWorkItem?       // reschedulable: initial-wait-without-tokens, then quiet-window checks
    private var settleMaxWorkItem: DispatchWorkItem?    // fixed hard ceiling check
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempts: Int = 0
    
    init(
        apiKey: String,
        model: String = "gemini-3.5-transcribe-live",
        smartTranscription: Bool = true,
        languageCodes: [String] = ["en-IN", "mr-IN"],
        customVocabulary: [String] = [],
        vadMode: String = "manual",
        vadSilenceMs: Int = 1500
    ) {
        self.apiKey = apiKey
        self.model = model
        self.smartTranscription = smartTranscription
        self.languageCodes = languageCodes
        self.customVocabulary = customVocabulary
        self.vadMode = vadMode
        self.vadSilenceMs = vadSilenceMs
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 10.0
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    
    func connect() {
        guard !apiKey.isEmpty else { return }
        
        reconnectWorkItem?.cancel()
        
        let wsUrlString = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        guard let url = URL(string: wsUrlString) else {
            Logger.error("WS", "Invalid WebSocket URL.")
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        
        let task = urlSession.webSocketTask(with: request)
        self.webSocketTask = task
        task.resume()
        
        Logger.info("WS", "Connecting to Gemini Live WebSockets (\(model))...")
        sendSetupMessage()
        listenForMessages()
    }
    
    private func sendSetupMessage() {
        let setupPayload: [String: Any]
        if model.contains("transcribe") {
            // Dedicated STT Live Streaming Model. Documented setup shape (live-transcribe guide):
            // transcription options live in top-level setup.inputAudioTranscription - NOT inside
            // generationConfig - so mode/languages/vocabulary are actually honored by the server.
            var transcriptionConfig: [String: Any] = [
                "mode": smartTranscription ? "SMART" : "VERBATIM"
            ]
            if !languageCodes.isEmpty {
                transcriptionConfig["languageCodes"] = languageCodes
            }
            if !customVocabulary.isEmpty {
                transcriptionConfig["customVocabulary"] = customVocabulary
            }

            var setup: [String: Any] = [
                "model": "models/\(model)",
                "generationConfig": [
                    "responseModalities": ["TEXT"]
                ],
                "inputAudioTranscription": transcriptionConfig
            ]

            // Push-to-talk owns the ground truth of when speech starts and ends (the key hold),
            // so the default is manual activity signaling: server VAD otherwise declares
            // end-of-speech at natural pauses and stops transcribing mid-hold.
            switch vadMode {
            case "manual":
                setup["realtimeInputConfig"] = [
                    "automaticActivityDetection": ["disabled": true]
                ]
            case "tuned":
                // Server VAD stays on but is made maximally pause-tolerant. These generic Live
                // API fields are not documented for the transcribe model specifically; a setup
                // rejection is surfaced by the server-error log line - fall back to VAD_MODE=auto.
                setup["realtimeInputConfig"] = [
                    "automaticActivityDetection": [
                        "disabled": false,
                        "startOfSpeechSensitivity": "START_SENSITIVITY_HIGH",
                        "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
                        "silenceDurationMs": vadSilenceMs
                    ],
                    "turnCoverage": "TURN_INCLUDES_ALL_INPUT"
                ]
            default:
                // "auto": stock server-side VAD, no realtimeInputConfig sent.
                break
            }

            setupPayload = ["setup": setup]
        } else {
            // Multimodal Conversational Audio Model with manual activity detection
            var instruction = """
            You are an ultra-fast, high-precision voice dictation engine.
            Transcribe the user's spoken words verbatim and polish into clean written prose.
            Rules:
            1. Output ONLY the exact transcribed words with proper grammar, punctuation, and capitalization.
            2. Remove speech disfluencies (um, uh, like, you know, stuttering, repeated words).
            3. Never converse, reply to questions, add commentary, or say things like "I understand", "Sure", or "Here is...".
            4. Never wrap text in quotation marks or code fences unless explicitly dictating code.
            5. If the audio is silent or unintelligible, output nothing.
            """
            if !languageCodes.isEmpty {
                instruction += "\nTarget language(s): \(languageCodes.joined(separator: ", "))"
            }
            if !customVocabulary.isEmpty {
                instruction += "\n\nCustom vocabulary and technical terms to recognize accurately: \(customVocabulary.joined(separator: ", "))"
            }
            
            setupPayload = [
                "setup": [
                    "model": "models/\(model)",
                    "generationConfig": [
                        "responseModalities": ["AUDIO"],
                        "thinkingConfig": [
                            "thinkingLevel": "minimal"
                        ]
                    ],
                    "realtimeInputConfig": [
                        "automaticActivityDetection": [
                            "disabled": true
                        ]
                    ],
                    "inputAudioTranscription": [:],
                    "outputAudioTranscription": [:],
                    "systemInstruction": [
                        "parts": [
                            [
                                "text": instruction
                            ]
                        ]
                    ]
                ]
            ]
        }
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: setupPayload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            Logger.error("WS", "Failed to serialize setup message.")
            return
        }
        
        webSocketTask?.send(.string(jsonString)) { [weak self] error in
            if let error = error {
                Logger.error("WS", "Setup message send failed: \(error.localizedDescription)")
                self?.isConnected = false
            } else {
                Logger.debug("WS", "Setup handshake dispatched to server.")
            }
        }
    }
    
    private func listenForMessages() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                self.handleIncomingMessage(message)
                self.listenForMessages() // Continue listening
                
            case .failure(let error):
                self.lock.lock()
                self.isConnected = false
                self.isReady = false
                let pendingCompletion = self.hasFiredTurnCompletion ? nil : self.turnCompletion
                self.turnCompletion = nil
                self.lock.unlock()
                
                Logger.warn("WS", "WebSocket disconnected: \(error.localizedDescription)")
                pendingCompletion?(.failure(error))
                self.scheduleReconnect()
            }
        }
    }
    
    private func handleIncomingMessage(_ message: URLSessionWebSocketTask.Message) {
        var rawData: Data?
        switch message {
        case .string(let str):
            rawData = str.data(using: .utf8)
        case .data(let data):
            rawData = data
        @unknown default:
            break
        }
        
        guard let data = rawData,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Actions to perform once the lock is released: logging, meter text, and callbacks
        // must never run while `lock` is held.
        var serverErrorMessage: String? = nil
        var didCompleteSetup = false
        var shouldScheduleReconnect = false
        var liveTextUpdate: (label: String, elapsedMs: Double, fullText: String, textCopy: String)? = nil
        var turnCompletionFire: (completion: ((Result<(text: String, firstTokenMs: Double, totalMs: Double), Error>) -> Void)?, text: String, firstTokenMs: Double, totalMs: Double)? = nil
        // Set when a post-commit token arrives while committing: elapsed time since turnCommitTime,
        // used after unlock to (re)schedule the settle check. Finals get the short authoritative
        // grace; interims get the (mode-aware) quiet window.
        var quietRescheduleElapsedSinceCommit: Double? = nil
        var quietRescheduleIsFinal = false

        lock.lock()

        // 0. Server error handling
        if let errorObj = json["error"] as? [String: Any] {
            serverErrorMessage = (errorObj["message"] as? String) ?? "Unknown server error"
        }

        // 0b. Usage metadata can accompany any server message; keep the latest cumulative counts.
        if let usage = json["usageMetadata"] as? [String: Any] {
            if let p = usage["promptTokenCount"] as? Int { lastSeenPromptTokens = p }
            if let r = usage["responseTokenCount"] as? Int { lastSeenResponseTokens = r }
        }

        // 1. Handshake confirmation
        if json["setupComplete"] != nil {
            self.isConnected = true
            self.isReady = true
            self.reconnectAttempts = 0
            didCompleteSetup = true
            // Fresh session: server-side cumulative token counters restart from zero.
            self.lastSeenPromptTokens = 0
            self.lastSeenResponseTokens = 0
            self.turnBaselinePromptTokens = 0
            self.turnBaselineResponseTokens = 0
        }
        // 2. Server goAway notification (Server scheduled disconnect)
        else if json["goAway"] != nil {
            shouldScheduleReconnect = true
        }
        // 3. Server content (transcription streaming)
        else if let serverContent = json["serverContent"] as? [String: Any] {
            var updatedText: String? = nil
            var isUserSpeech = false
            var isFinalTranscription = false

            // PRIORITY 1: Finalized inputTranscription (e.g. gemini-3.5-transcribe-live) -
            // closes the current speech segment; earlier segments must be preserved.
            if let inputTrans = serverContent["inputTranscription"] as? [String: Any],
               let text = inputTrans["text"] as? String, !text.isEmpty {
                applyFinalTranscription(text)
                updatedText = mergedTranscript()
                isUserSpeech = true
                isFinalTranscription = true
            }
            // PRIORITY 2: Progressive Interim Transcription - rewrites only the live segment.
            else if let interim = serverContent["interimInputTranscription"] as? [String: Any],
                    let text = interim["text"] as? String, !text.isEmpty {
                applyInterimTranscription(text)
                updatedText = mergedTranscript()
                isUserSpeech = true
            }
            // PRIORITY 3: Alternative inputAudioTranscription (finalized form)
            else if let inputAudio = serverContent["inputAudioTranscription"] as? [String: Any],
                    let text = inputAudio["text"] as? String, !text.isEmpty {
                applyFinalTranscription(text)
                updatedText = mergedTranscript()
                isUserSpeech = true
                isFinalTranscription = true
            }
            // PRIORITY 4: Multimodal text delta from modelTurn (raw append, no segmentation)
            else if let modelTurn = serverContent["modelTurn"] as? [String: Any],
                    let parts = modelTurn["parts"] as? [[String: Any]] {
                var delta = ""
                for part in parts {
                    if let text = part["text"] as? String {
                        delta += text
                    }
                }
                if !delta.isEmpty {
                    committedTranscript += delta
                    updatedText = mergedTranscript()
                }
            } else if let outputTranscription = serverContent["outputTranscription"] as? [String: Any],
                      let text = outputTranscription["text"] as? String, !text.isEmpty {
                committedTranscript += text
                updatedText = mergedTranscript()
            }

            if let newText = updatedText {
                let now = CFAbsoluteTimeGetCurrent()
                self.lastTokenReceivedTime = now
                if self.isCommitting {
                    self.lastPostCommitTokenTime = now
                    if isFinalTranscription {
                        self.lastPostCommitFinalTime = now
                    } else if isUserSpeech {
                        // A speculative interim after a final means more content is still
                        // streaming - the final we saw wasn't the last one.
                        self.lastPostCommitFinalTime = nil
                    }
                    quietRescheduleElapsedSinceCommit = now - self.turnCommitTime
                    quietRescheduleIsFinal = isFinalTranscription
                }
                if currentTurnText.isEmpty && firstTokenLatencyMs == 0 && turnCommitTime > 0 {
                    firstTokenLatencyMs = (now - turnCommitTime) * 1000.0
                }
                currentTurnText = newText
                let textCopy = currentTurnText
                let elapsedMs = turnCommitTime > 0 ? (now - turnCommitTime) * 1000.0 : 0
                let label = isUserSpeech ? "⚡ DICTATING" : "⚡ STREAMING"
                liveTextUpdate = (label: label, elapsedMs: elapsedMs, fullText: currentTurnText, textCopy: textCopy)
            }

            // Explicit turn completion / generation completion
            let isTurnComplete = (serverContent["turnComplete"] as? Bool) ?? (serverContent["turnComplete"] != nil)
            let isGenComplete = (serverContent["generationComplete"] as? Bool) ?? (serverContent["generationComplete"] != nil)

            if (isTurnComplete || isGenComplete) && !currentTurnText.isEmpty && !hasFiredTurnCompletion {
                hasFiredTurnCompletion = true
                isCommitting = false
                settleWorkItem?.cancel()
                settleWorkItem = nil
                settleMaxWorkItem?.cancel()
                settleMaxWorkItem = nil

                let totalLatencyMs = (CFAbsoluteTimeGetCurrent() - turnCommitTime) * 1000.0
                let text = currentTurnText
                currentTurnText = ""
                committedTranscript = ""
                interimTranscript = ""
                let firstToken = firstTokenLatencyMs
                firstTokenLatencyMs = 0

                let completion = self.turnCompletion
                self.turnCompletion = nil

                turnCompletionFire = (completion: completion, text: text, firstTokenMs: firstToken, totalMs: totalLatencyMs)
            }
        }

        lock.unlock()

        // Logging & callbacks all run off the lock, in the same relative order as before.
        if let msg = serverErrorMessage {
            Logger.error("WS", "Server error: \(msg)")
        }
        if didCompleteSetup {
            Logger.success("WS", "Gemini Live session established & ready for streaming.")
        }
        if shouldScheduleReconnect {
            Logger.warn("WS", "Server sent goAway signal. Preemptively scheduling reconnect...")
            self.scheduleReconnect()
        }
        if let update = liveTextUpdate {
            Logger.meter("\(ANSI.bold)\(ANSI.cyan)\(update.label)\(ANSI.reset) [\(String(format: "%.0f", update.elapsedMs))ms]: \(ANSI.bold)\(update.fullText.replacingOccurrences(of: "\n", with: " "))\(ANSI.reset)")
            onLiveTextUpdate?(update.textCopy)
        }
        if let fire = turnCompletionFire {
            Logger.endMeter()
            DispatchQueue.global().async {
                fire.completion?(.success((text: fire.text, firstTokenMs: fire.firstTokenMs, totalMs: fire.totalMs)))
            }
        }
        // A post-commit token arrived: (re)schedule the quiet-window settle check, never
        // earlier than minPostCommitWait after commit. Scheduling happens off-lock; the
        // pointer swap that replaces the previous pending item is its own short lock scope.
        if let elapsedSinceCommit = quietRescheduleElapsedSinceCommit {
            let delay: Double
            if quietRescheduleIsFinal {
                delay = Self.settleFinalGrace + Self.settleTimerCushion
            } else {
                let quiet = usesManualActivity ? Self.settleInterimQuietManual : Self.settleQuietWindow
                delay = max(quiet, Self.settleMinPostCommitWait - elapsedSinceCommit) + Self.settleTimerCushion
            }
            let item = DispatchWorkItem { [weak self] in self?.attemptSettle() }
            lock.lock()
            settleWorkItem?.cancel()
            settleWorkItem = item
            lock.unlock()
            settleQueue.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    // MARK: Segment transcript accumulator (all three helpers assume `lock` is held)

    private func mergedTranscript() -> String {
        if committedTranscript.isEmpty { return interimTranscript }
        if interimTranscript.isEmpty { return committedTranscript }
        let needsSpace = !(committedTranscript.hasSuffix(" ") || committedTranscript.hasSuffix("\n") || interimTranscript.hasPrefix(" "))
        return committedTranscript + (needsSpace ? " " : "") + interimTranscript
    }

    private func applyInterimTranscription(_ text: String) {
        // Some server variants stream the interim as the full turn so far. If it already
        // contains everything committed, only the suffix is the live segment - otherwise the
        // interim IS the live segment and replaces only the previous interim.
        if !committedTranscript.isEmpty && text.hasPrefix(committedTranscript) {
            interimTranscript = String(text.dropFirst(committedTranscript.count))
        } else {
            interimTranscript = text
        }
    }

    private func applyFinalTranscription(_ text: String) {
        if committedTranscript.isEmpty {
            committedTranscript = text
        } else if text.hasPrefix(committedTranscript) {
            // Cumulative final covering the whole turn - replace wholesale.
            committedTranscript = text
        } else if committedTranscript.hasSuffix(text) {
            // Duplicate re-send of the segment just committed - nothing new.
        } else {
            let needsSpace = !(committedTranscript.hasSuffix(" ") || committedTranscript.hasSuffix("\n") || text.hasPrefix(" "))
            committedTranscript += (needsSpace ? " " : "") + text
        }
        interimTranscript = ""
    }

    // Re-validates the settle rules against current authoritative state and, if any rule
    // holds, performs the once-only settle sequence. Safe to call redundantly from a stale
    // or overlapping timer: state (isCommitting/hasFiredTurnCompletion) is the source of
    // truth, not which timer fired.
    private func attemptSettle() {
        lock.lock()
        guard isCommitting, !hasFiredTurnCompletion else {
            lock.unlock()
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsedCommit = now - turnCommitTime
        let text = currentTurnText
        let postCommitTokenTime = lastPostCommitTokenTime
        let postCommitFinalTime = lastPostCommitFinalTime

        var settleWithText = false
        if let finalTime = postCommitFinalTime {
            // An authoritative final transcription landed: settle after only a short grace
            // (long enough for a trailing segment's final to displace this timer), with no
            // minimum-wait floor - waiting longer adds latency, not accuracy.
            settleWithText = !text.isEmpty && (now - finalTime) >= Self.settleFinalGrace
        } else if let postTime = postCommitTokenTime {
            // Only speculative interims so far. In manual-activity mode a final is expected,
            // so wait longer before pasting speculation; otherwise use the tight quiet window.
            let quietWindow = usesManualActivity ? Self.settleInterimQuietManual : Self.settleQuietWindow
            let quietSincePostToken = now - postTime
            settleWithText = elapsedCommit >= Self.settleMinPostCommitWait && !text.isEmpty && quietSincePostToken >= quietWindow
        } else if !text.isEmpty && elapsedCommit >= Self.settleInitialWaitWithoutTokens {
            settleWithText = true
        }

        let timedOut = !settleWithText && elapsedCommit >= Self.settleMaxWait
        guard settleWithText || timedOut else {
            lock.unlock()
            return
        }

        hasFiredTurnCompletion = true
        isCommitting = false
        settleWorkItem?.cancel()
        settleWorkItem = nil
        settleMaxWorkItem?.cancel()
        settleMaxWorkItem = nil

        let totalLatencyMs = elapsedCommit * 1000.0
        currentTurnText = ""
        committedTranscript = ""
        interimTranscript = ""
        let firstToken = firstTokenLatencyMs
        firstTokenLatencyMs = 0
        let cb = turnCompletion
        turnCompletion = nil
        lock.unlock()

        Logger.endMeter()
        DispatchQueue.global().async {
            if !text.isEmpty {
                cb?(.success((text: text, firstTokenMs: firstToken, totalMs: totalLatencyMs)))
            } else {
                cb?(.failure(NSError(domain: "JustSpeak", code: -2, userInfo: [NSLocalizedDescriptionKey: "No speech recognized before timeout."])))
            }
        }
    }
    
    func startNewTurn() {
        lock.lock()
        self.settleWorkItem?.cancel()
        self.settleWorkItem = nil
        self.settleMaxWorkItem?.cancel()
        self.settleMaxWorkItem = nil
        self.isCommitting = false
        self.currentTurnText = ""
        self.committedTranscript = ""
        self.interimTranscript = ""
        self.firstTokenLatencyMs = 0
        self.hasFiredTurnCompletion = false
        self.turnCommitTime = 0
        self.lastTokenReceivedTime = 0
        self.lastPostCommitTokenTime = nil
        self.lastPostCommitFinalTime = nil
        self.turnCompletion = nil
        self.turnBaselinePromptTokens = self.lastSeenPromptTokens
        self.turnBaselineResponseTokens = self.lastSeenResponseTokens
        lock.unlock()
        
        // Dispatch manual activityStart: the key press IS the start of speech whenever
        // server VAD is disabled (conversational models always; transcribe in manual mode)
        if usesManualActivity {
            let startPayload: [String: Any] = [
                "realtimeInput": [
                    "activityStart": [:]
                ]
            ]
            if let startJson = try? JSONSerialization.data(withJSONObject: startPayload),
               let startStr = String(data: startJson, encoding: .utf8) {
                webSocketTask?.send(.string(startStr)) { _ in }
            }
        }
    }
    
    // Base64's alphabet (A-Za-z0-9+/=) needs no JSON escaping, so the fixed-shape
    // envelope is built once and the payload is spliced in directly, skipping
    // JSONSerialization on the hot per-chunk (~150ms) path.
    private static let audioChunkJSONPrefix = "{\"realtimeInput\":{\"audio\":{\"mimeType\":\"audio/pcm;rate=16000\",\"data\":\""
    private static let audioChunkJSONSuffix = "\"}}}"

    func sendAudioChunk(_ pcmChunk: Data) {
        guard isReady else { return }

        let base64Audio = pcmChunk.base64EncodedString()
        let jsonString = Self.audioChunkJSONPrefix + base64Audio + Self.audioChunkJSONSuffix

        webSocketTask?.send(.string(jsonString)) { error in
            if let error = error {
                Logger.debug("WS", "Chunk send error: \(error.localizedDescription)")
            }
        }
    }
    
    func commitTurn(completion: @escaping (Result<(text: String, firstTokenMs: Double, totalMs: Double), Error>) -> Void) {
        lock.lock()
        self.turnCommitTime = CFAbsoluteTimeGetCurrent()
        self.isCommitting = true
        self.lastPostCommitTokenTime = nil
        self.lastPostCommitFinalTime = nil
        self.turnCompletion = completion
        self.hasFiredTurnCompletion = false
        lock.unlock()
        
        // 1. Dispatch audioStreamEnd signal to flush audio encoder pipeline
        let endAudioPayload: [String: Any] = [
            "realtimeInput": [
                "audioStreamEnd": true
            ]
        ]
        if let endAudioJson = try? JSONSerialization.data(withJSONObject: endAudioPayload),
           let endAudioStr = String(data: endAudioJson, encoding: .utf8) {
            webSocketTask?.send(.string(endAudioStr)) { _ in }
        }
        
        // 2. Dispatch manual activityEnd: the key release IS the end of speech whenever
        // server VAD is disabled (after audioStreamEnd so all buffered audio lands inside
        // the activity window)
        if usesManualActivity {
            let endPayload: [String: Any] = [
                "realtimeInput": [
                    "activityEnd": [:]
                ]
            ]
            if let endJson = try? JSONSerialization.data(withJSONObject: endPayload),
               let endStr = String(data: endJson, encoding: .utf8) {
                webSocketTask?.send(.string(endStr)) { _ in }
            }
        }
        
        // 3. Dispatch turnComplete signal to finalize transcript
        let commitPayload: [String: Any] = [
            "clientContent": [
                "turnComplete": true
            ]
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: commitPayload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            completion(.failure(NSError(domain: "JustSpeak", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize commit payload."])))
            return
        }
        
        webSocketTask?.send(.string(jsonString)) { error in
            if let error = error {
                Logger.debug("WS", "Commit turn send error: \(error.localizedDescription)")
            }
        }
        
        // 4. For dedicated STT Transcribe models: schedule event-driven settlement checks
        // instead of polling. Two one-shot items cover the four settle rules:
        //   - settleWorkItem: fires at initialWaitWithoutTokens (rule: pre-commit text, no
        //     post-commit tokens); handleIncomingMessage reschedules this same slot to the
        //     quiet-window deadline each time a post-commit token arrives (rule: quiet window
        //     after post-commit tokens).
        //   - settleMaxWorkItem: fixed hard ceiling at maxWait, never rescheduled.
        // Both call attemptSettle(), which re-validates against authoritative locked state
        // rather than trusting which timer fired.
        if model.contains("transcribe") {
            let initialItem = DispatchWorkItem { [weak self] in self?.attemptSettle() }
            let maxItem = DispatchWorkItem { [weak self] in self?.attemptSettle() }

            lock.lock()
            settleWorkItem?.cancel()
            settleMaxWorkItem?.cancel()
            settleWorkItem = initialItem
            settleMaxWorkItem = maxItem
            lock.unlock()

            settleQueue.asyncAfter(deadline: .now() + Self.settleInitialWaitWithoutTokens + Self.settleTimerCushion, execute: initialItem)
            settleQueue.asyncAfter(deadline: .now() + Self.settleMaxWait + Self.settleTimerCushion, execute: maxItem)
        }
    }
    
    var hasReceivedTokens: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !currentTurnText.isEmpty || firstTokenLatencyMs > 0
    }
    
    private func scheduleReconnect() {
        lock.lock()
        guard reconnectWorkItem == nil else {
            lock.unlock()
            return
        }
        reconnectAttempts += 1
        let delay = min(10.0, pow(2.0, Double(min(reconnectAttempts, 4))))
        Logger.info("WS", "Scheduling WebSocket reconnection in \(String(format: "%.1f", delay))s (Attempt #\(reconnectAttempts))...")
        
        let item = DispatchWorkItem { [weak self] in
            self?.lock.lock()
            self?.reconnectWorkItem = nil
            self?.lock.unlock()
            self?.connect()
        }
        self.reconnectWorkItem = item
        lock.unlock()
        
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: item)
    }
    
    func disconnect() {
        lock.lock()
        settleWorkItem?.cancel()
        settleWorkItem = nil
        settleMaxWorkItem?.cancel()
        settleMaxWorkItem = nil
        lock.unlock()

        reconnectWorkItem?.cancel()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        isConnected = false
        isReady = false
    }
}

// MARK: - Gemini REST Fallback Client (Single-Turn Audio)

struct GeminiRestClient {
    static func transcribe(
        pcmData: Data,
        apiKey: String,
        model: String,
        languageCodes: [String] = [],
        customVocabulary: [String] = [],
        completion: @escaping (Result<(text: String, latencyMs: Double, inputTokens: Int?, outputTokens: Int?), Error>) -> Void
    ) {
        let startTime = CFAbsoluteTimeGetCurrent()
        guard !apiKey.isEmpty else {
            completion(.failure(NSError(domain: "JustSpeak", code: -1, userInfo: [NSLocalizedDescriptionKey: "GEMINI_API_KEY is empty."])))
            return
        }
        
        let wavData = createWavData(from: pcmData, sampleRate: 16000, channels: 1)
        let base64Wav = wavData.base64EncodedString()
        
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "JustSpeak", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid REST URL."])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 10.0
        
        let payload: [String: Any]
        if model.contains("transcribe") {
            // Dedicated STT Foundation Model (Pure Audio, zero developer instruction requirement)
            payload = [
                "contents": [
                    [
                        "parts": [
                            [
                                "inlineData": [
                                    "mimeType": "audio/wav",
                                    "data": base64Wav
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        } else {
            // General Multimodal LLM (Prompt & System Instruction guided)
            var promptText = "Transcribe this audio precisely. Fix punctuation, capitalization, and grammar. Remove filler words (um, uh, you know). Preserve technical terms, acronyms, code snippets, numbers, and formatting. Output ONLY the polished transcription without commentary, explanations, or quotes."
            var systemText = "You are a professional voice dictation engine. Transcribe and polish the spoken audio into clean text. Output ONLY the final text."
            
            if !languageCodes.isEmpty {
                let langList = languageCodes.joined(separator: ", ")
                promptText += "\nTarget language(s): \(langList)"
                systemText += "\nTarget language(s): \(langList)"
            }
            
            if !customVocabulary.isEmpty {
                let vocabList = customVocabulary.joined(separator: ", ")
                promptText += "\nCustom vocabulary & technical terms to recognize accurately: \(vocabList)"
                systemText += "\nCustom vocabulary: \(vocabList)"
            }
            
            payload = [
                "contents": [
                    [
                        "parts": [
                            [
                                "inlineData": [
                                    "mimeType": "audio/wav",
                                    "data": base64Wav
                                ]
                            ],
                            [
                                "text": promptText
                            ]
                        ]
                    ]
                ],
                "generationConfig": [
                    "temperature": 0.0
                ],
                "systemInstruction": [
                    "parts": [
                        [
                            "text": systemText
                        ]
                    ]
                ]
            ]
        }
        
        guard let requestBody = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(.failure(NSError(domain: "JustSpeak", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize REST JSON."])))
            return
        }
        request.httpBody = requestBody
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let data = data else {
                completion(.failure(NSError(domain: "JustSpeak", code: -4, userInfo: [NSLocalizedDescriptionKey: "No data received from Gemini REST API."])))
                return
            }
            
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let rawStr = String(data: data, encoding: .utf8) ?? "Unknown"
                completion(.failure(NSError(domain: "JustSpeak", code: -5, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response: \(rawStr)"])))
                return
            }
            
            if let errorObj = json["error"] as? [String: Any],
               let message = errorObj["message"] as? String {
                completion(.failure(NSError(domain: "GeminiAPI", code: (errorObj["code"] as? Int) ?? -1, userInfo: [NSLocalizedDescriptionKey: message])))
                return
            }
            
            // API-metered usage rides on every generateContent response.
            var inputTokens: Int? = nil
            var outputTokens: Int? = nil
            if let usage = json["usageMetadata"] as? [String: Any] {
                inputTokens = usage["promptTokenCount"] as? Int
                outputTokens = usage["candidatesTokenCount"] as? Int
            }

            if let candidates = json["candidates"] as? [[String: Any]],
               let firstCandidate = candidates.first {
                if let content = firstCandidate["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]],
                   let firstPart = parts.first,
                   let text = firstPart["text"] as? String {
                    completion(.success((text: text, latencyMs: elapsedMs, inputTokens: inputTokens, outputTokens: outputTokens)))
                } else {
                    // Speech model returned empty transcription (e.g. silent or non-speech audio)
                    completion(.success((text: "", latencyMs: elapsedMs, inputTokens: inputTokens, outputTokens: outputTokens)))
                }
            } else {
                completion(.failure(NSError(domain: "JustSpeak", code: -6, userInfo: [NSLocalizedDescriptionKey: "Could not extract candidate text from response."])))
            }
        }
        
        task.resume()
    }
}

// MARK: - Hotkey & Global Input Monitor (with Tap Auto-Recovery)

final class HotkeyManager {
    enum KeyBinding {
        case rightOption
        case leftOption
        case rightControl
        case leftControl
        case rightCmd
        case leftCmd
        case fn
        case fKey(CGKeyCode)
        case custom(CGKeyCode)
        
        static func from(string: String) -> KeyBinding {
            switch string.lowercased() {
            case "right_option", "right_alt", "roption": return .rightOption
            case "left_option", "left_alt", "loption": return .leftOption
            case "right_control", "right_ctrl", "rctrl": return .rightControl
            case "left_control", "left_ctrl", "lctrl": return .leftControl
            case "right_cmd", "right_command", "rcmd": return .rightCmd
            case "left_cmd", "left_command", "lcmd": return .leftCmd
            case "fn", "globe": return .fn
            case "f13": return .fKey(0x69)
            case "f14": return .fKey(0x6B)
            case "f15": return .fKey(0x71)
            case "f16": return .fKey(0x6A)
            case "f17": return .fKey(0x40)
            case "f18": return .fKey(0x4F)
            case "f19": return .fKey(0x50)
            case "f20": return .fKey(0x5A)
            default:
                if let code = UInt16(string) {
                    return .custom(CGKeyCode(code))
                }
                return .rightOption
            }
        }
        
        var name: String {
            switch self {
            case .rightOption: return "Right Option (⌥ Right)"
            case .leftOption: return "Left Option (⌥ Left)"
            case .rightControl: return "Right Control (⌃ Right)"
            case .leftControl: return "Left Control (⌃ Left)"
            case .rightCmd: return "Right Command (⌘ Right)"
            case .leftCmd: return "Left Command (⌘ Left)"
            case .fn: return "Fn / Globe (🌐)"
            case .fKey(let code): return "F-Key (keyCode: \(code))"
            case .custom(let code): return "Custom Key (keyCode: \(code))"
            }
        }
    }
    
    private let binding: KeyBinding
    private let mode: String
    private var isKeyDown: Bool = false
    private var lastStateChangeTime: CFAbsoluteTime = 0
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    
    init(binding: KeyBinding, mode: String) {
        self.binding = binding
        self.mode = mode
    }
    
    func start() -> Bool {
        let eventMask = (1 << CGEventType.flagsChanged.rawValue) |
                        (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.keyUp.rawValue)
        
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                
                // Auto-recover tap if disabled by macOS timeout
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let t = manager.eventTap {
                        CGEvent.tapEnable(tap: t, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                
                manager.handleCGEvent(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPointer
        ) else {
            return false
        }
        
        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        
        return true
    }
    
    private func handleCGEvent(type: CGEventType, event: CGEvent) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        
        switch binding {
        case .rightOption:
            if type == .flagsChanged && keyCode == 61 {
                let isPressed = flags.contains(.maskAlternate)
                updateKeyState(pressed: isPressed)
            }
        case .leftOption:
            if type == .flagsChanged && keyCode == 58 {
                let isPressed = flags.contains(.maskAlternate)
                updateKeyState(pressed: isPressed)
            }
        case .rightControl:
            if type == .flagsChanged && keyCode == 62 {
                let isPressed = flags.contains(.maskControl)
                updateKeyState(pressed: isPressed)
            }
        case .leftControl:
            if type == .flagsChanged && keyCode == 59 {
                let isPressed = flags.contains(.maskControl)
                updateKeyState(pressed: isPressed)
            }
        case .rightCmd:
            if type == .flagsChanged && keyCode == 54 {
                let isPressed = flags.contains(.maskCommand)
                updateKeyState(pressed: isPressed)
            }
        case .leftCmd:
            if type == .flagsChanged && keyCode == 55 {
                let isPressed = flags.contains(.maskCommand)
                updateKeyState(pressed: isPressed)
            }
        case .fn:
            if type == .flagsChanged && keyCode == 63 {
                let isPressed = flags.contains(.maskSecondaryFn)
                updateKeyState(pressed: isPressed)
            }
        case .fKey(let targetCode), .custom(let targetCode):
            if keyCode == targetCode {
                if type == .keyDown {
                    updateKeyState(pressed: true)
                } else if type == .keyUp {
                    updateKeyState(pressed: false)
                }
            }
        }
    }
    
    private func updateKeyState(pressed: Bool) {
        let now = CFAbsoluteTimeGetCurrent()

        if mode == "toggle" {
            // Both toggle transitions fire on a press edge, so the 80ms debounce applies to both.
            guard (now - lastStateChangeTime) > 0.08 else { return } // 80ms debounce
            if pressed && !isKeyDown {
                isKeyDown = true
                lastStateChangeTime = now
                onKeyDown?()
            } else if pressed && isKeyDown {
                isKeyDown = false
                lastStateChangeTime = now
                onKeyUp?()
            }
        } else {
            // Push-to-Talk (Hold): debounce only the press edge. A release must never be
            // swallowed - dropping it would leave isKeyDown stuck true (mic stuck recording)
            // after a press+release faster than the debounce window.
            if pressed && !isKeyDown {
                guard (now - lastStateChangeTime) > 0.08 else { return } // 80ms debounce
                isKeyDown = true
                lastStateChangeTime = now
                onKeyDown?()
            } else if !pressed && isKeyDown {
                isKeyDown = false
                lastStateChangeTime = now
                onKeyUp?()
            }
        }
    }
    
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
    }
}

// MARK: - macOS Permissions Validator

struct PermissionChecker {
    static func verifyAll() -> (accessibility: Bool, microphone: Bool) {
        let isAxTrusted = AXIsProcessTrusted()
        
        var isMicAuthorized = false
        if #available(macOS 14.0, *) {
            isMicAuthorized = (AVAudioApplication.shared.recordPermission == .granted)
        } else {
            isMicAuthorized = (AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
        }
        
        return (isAxTrusted, isMicAuthorized)
    }
    
    static func printDetailedStatus() {
        print("\n\(ANSI.bold)════════════════════════════════════════════════════════════════════════════\(ANSI.reset)")
        print("\(ANSI.bold)  JustSpeak macOS Permissions Diagnostic\(ANSI.reset)")
        print("\(ANSI.bold)════════════════════════════════════════════════════════════════════════════\(ANSI.reset)\n")
        
        let (ax, mic) = verifyAll()
        
        let axStatus = ax ? "\(ANSI.green)✓ GRANTED\(ANSI.reset)" : "\(ANSI.red)✗ NOT GRANTED\(ANSI.reset)"
        let micStatus = mic ? "\(ANSI.green)✓ GRANTED\(ANSI.reset)" : "\(ANSI.red)✗ NOT GRANTED\(ANSI.reset)"
        
        print("  1. Accessibility & CGEventTap:   [\(axStatus)]")
        print("  2. Microphone Access:            [\(micStatus)]")
        print("  3. Input Monitoring (Terminal):  [\(ax ? "\(ANSI.green)✓ ACTIVE\(ANSI.reset)" : "\(ANSI.yellow)? CHECK SETTINGS\(ANSI.reset)")]\n")
        
        if !ax || !mic {
            print("\(ANSI.yellow)\(ANSI.bold)How to grant required permissions on macOS:\(ANSI.reset)")
            if !ax {
                print("  • \(ANSI.bold)Accessibility:\(ANSI.reset) System Settings → Privacy & Security → Accessibility → Toggle ON your Terminal app (Terminal / iTerm2 / VS Code / Cursor / Ghostty)")
                print("  • \(ANSI.bold)Input Monitoring:\(ANSI.reset) System Settings → Privacy & Security → Input Monitoring → Toggle ON your Terminal app")
                
                let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                _ = AXIsProcessTrustedWithOptions(options)
            }
            if !mic {
                print("  • \(ANSI.bold)Microphone:\(ANSI.reset) System Settings → Privacy & Security → Microphone → Toggle ON your Terminal app")
            }
            print("")
        } else {
            print("\(ANSI.green)\(ANSI.bold)All required macOS permissions are properly configured! Ready to speak.\(ANSI.reset)\n")
        }
    }
}

// MARK: - Secure Input Detection

// TN2150: when any app enables secure input (password fields, Terminal's Secure Keyboard
// Entry), synthesized keystrokes and clipboard pastes into it can fail or leak. We refuse
// and fall back to copy-only rather than bypass it.
enum SecureInputMonitor {
    static var isActive: Bool { IsSecureEventInputEnabled() }

    /// The name of the process currently holding secure input, if the window server will say.
    /// The flag is system-wide, so the holder is often NOT the app the user is looking at -
    /// naming it turns "dictation just stopped working" into something actionable.
    static func holderName() -> String? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }

        guard let sessions = IORegistryEntryCreateCFProperty(
            root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [[String: Any]] else { return nil }

        for session in sessions {
            guard let pid = session["kCGSSessionSecureInputPID"] as? Int32, pid != 0 else { continue }
            return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "another app"
        }
        return nil
    }
}

// MARK: - Apple Intelligence & macOS Human Interface Design Palette

enum AppleDesign {
    // Apple Intelligence Display P3 Wide-Gamut Palette
    static let siriCyan    = NSColor(displayP3Red: 0.00, green: 0.82, blue: 1.00, alpha: 1.0) // #00D1FF
    static let siriIndigo  = NSColor(displayP3Red: 0.44, green: 0.24, blue: 0.96, alpha: 1.0) // #703DF5
    static let siriMagenta = NSColor(displayP3Red: 1.00, green: 0.20, blue: 0.60, alpha: 1.0) // #FF3399
    static let siriAmber   = NSColor(displayP3Red: 1.00, green: 0.65, blue: 0.12, alpha: 1.0) // #FFA61F
    static let appleGreen  = NSColor(displayP3Red: 0.19, green: 0.82, blue: 0.35, alpha: 1.0) // #30D158 (Apple systemGreen)
    static let appleCoral  = NSColor(displayP3Red: 1.00, green: 0.27, blue: 0.23, alpha: 1.0) // #FF453A
    static let appleGold   = NSColor(displayP3Red: 1.00, green: 0.80, blue: 0.00, alpha: 1.0) // #FFCC00
    
    // MARK: OKLCH interpolation (Ottosson's OKLab, pure math - no dependencies)
    //
    // The chromatic loop interpolates in OKLCH rather than raw P3 RGB: straight RGB lerps
    // between distant hues dip through darker, muddier midpoints, while OKLCH holds perceived
    // lightness and chroma constant and swings hue along the shortest arc - the gradient stays
    // equally luminous the whole way around. Anchors remain authored as Display P3 values.

    struct OKLCh {
        let L: CGFloat
        let C: CGFloat
        let h: CGFloat // radians
    }

    private static func srgbToLinear(_ c: CGFloat) -> CGFloat {
        let sign: CGFloat = c < 0 ? -1 : 1
        let v = abs(c)
        return sign * (v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4))
    }

    private static func linearToSrgb(_ c: CGFloat) -> CGFloat {
        let sign: CGFloat = c < 0 ? -1 : 1
        let v = abs(c)
        return sign * (v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055)
    }

    private static func signedCbrt(_ v: CGFloat) -> CGFloat {
        v < 0 ? -pow(-v, 1.0 / 3.0) : pow(v, 1.0 / 3.0)
    }

    // Wide-gamut anchors are carried through extended sRGB (components may leave 0...1),
    // which the OKLab linear algebra handles without gamut clipping.
    static func toOKLCh(_ color: NSColor) -> OKLCh {
        let c = color.usingColorSpace(.extendedSRGB) ?? color
        let r = srgbToLinear(c.redComponent)
        let g = srgbToLinear(c.greenComponent)
        let b = srgbToLinear(c.blueComponent)

        let l = signedCbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = signedCbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = signedCbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)

        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s

        return OKLCh(L: L, C: sqrt(a * a + bb * bb), h: atan2(bb, a))
    }

    static func fromOKLCh(_ lch: OKLCh) -> NSColor {
        let a = lch.C * cos(lch.h)
        let bb = lch.C * sin(lch.h)

        let l = pow(lch.L + 0.3963377774 * a + 0.2158037573 * bb, 3)
        let m = pow(lch.L - 0.1055613458 * a - 0.0638541728 * bb, 3)
        let s = pow(lch.L - 0.0894841775 * a - 1.2914855480 * bb, 3)

        let r = linearToSrgb( 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s)
        let g = linearToSrgb(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s)
        let b = linearToSrgb(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)

        return NSColor(colorSpace: .extendedSRGB, components: [r, g, b, 1.0], count: 4)
    }

    // Anchor stops converted once; siriSpectrum below is pure math per call.
    private static let spectrumAnchors: [OKLCh] = [siriCyan, siriIndigo, siriMagenta, siriAmber].map(toOKLCh)

    // Continuous Apple Intelligence 4-phase chromatic loop: Cyan -> Indigo -> Magenta -> Amber -> Cyan
    static func siriSpectrum(at t: CGFloat) -> NSColor {
        let wrapped = t.truncatingRemainder(dividingBy: 1.0)
        let pos = (wrapped < 0 ? wrapped + 1.0 : wrapped) * 4.0
        let seg = Int(pos) % 4
        let frac = pos - CGFloat(Int(pos))

        let c1 = spectrumAnchors[seg]
        let c2 = spectrumAnchors[(seg + 1) % 4]

        // Shortest-arc hue interpolation keeps the loop from detouring through the far
        // side of the hue wheel between adjacent anchors.
        var dh = c2.h - c1.h
        if dh > .pi { dh -= 2 * .pi }
        if dh < -.pi { dh += 2 * .pi }

        return fromOKLCh(OKLCh(
            L: c1.L + (c2.L - c1.L) * frac,
            C: c1.C + (c2.C - c1.C) * frac,
            h: c1.h + dh * frac
        ))
    }
}

// MARK: - Hardware Notch Geometry Detection

struct NotchGeometry {
    let rect: NSRect
    let hasPhysicalNotch: Bool
    
    static func detect(screen: NSScreen) -> NotchGeometry {
        if #available(macOS 12.0, *),
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = right.minX - left.maxX
            let height = screen.frame.height - left.origin.y
            let rect = NSRect(
                x: left.maxX,
                y: screen.frame.height - height,
                width: width,
                height: height
            )
            return NotchGeometry(rect: rect, hasPhysicalNotch: true)
        } else {
            let width: CGFloat = 196
            let height: CGFloat = 34
            let rect = NSRect(
                x: (screen.frame.width - width) / 2.0,
                y: screen.frame.height - height,
                width: width,
                height: height
            )
            return NotchGeometry(rect: rect, hasPhysicalNotch: false)
        }
    }
}

// MARK: - Apple Intelligence Glowing Notch Bezel Aura (Hardware Bezel Illumination)

final class AppleNotchAuraView: NSView {
    enum GlowState {
        case idle
        case listening
        case processing
        case success
        case error
    }
    
    var notchRect: NSRect = .zero
    var audioLevel: CGFloat = 0.0 // 0.0 ... 1.0
    var state: GlowState = .idle
    
    private var phase: CGFloat = 0.0
    private var displayTimer: Timer?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.masksToBounds = false
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
        self.layer?.masksToBounds = false
    }
    
    func startAnimation() {
        displayTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let speed: CGFloat = (self.state == .processing) ? 0.024 : 0.007
            self.phase = (self.phase + speed).truncatingRemainder(dividingBy: 1.0)
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        self.displayTimer = timer
    }
    
    func stopAnimation() {
        displayTimer?.invalidate()
        displayTimer = nil
    }
    
    private func createNotchPath(in bounds: NSRect) -> CGPath {
        let path = CGMutablePath()
        let cornerRadius: CGFloat = 14.0
        let outerCornerRadius: CGFloat = 6.0
        
        let topY = bounds.height
        let bottomY = bounds.height - notchRect.height
        let leftX = (bounds.width - notchRect.width) / 2.0
        let rightX = leftX + notchRect.width
        
        path.move(to: CGPoint(x: leftX - outerCornerRadius, y: topY))
        path.addQuadCurve(to: CGPoint(x: leftX, y: topY - outerCornerRadius),
                          control: CGPoint(x: leftX, y: topY))
        path.addLine(to: CGPoint(x: leftX, y: bottomY + cornerRadius))
        path.addQuadCurve(to: CGPoint(x: leftX + cornerRadius, y: bottomY),
                          control: CGPoint(x: leftX, y: bottomY))
        path.addLine(to: CGPoint(x: rightX - cornerRadius, y: bottomY))
        path.addQuadCurve(to: CGPoint(x: rightX, y: bottomY + cornerRadius),
                          control: CGPoint(x: rightX, y: bottomY))
        path.addLine(to: CGPoint(x: rightX, y: topY - outerCornerRadius))
        path.addQuadCurve(to: CGPoint(x: rightX + outerCornerRadius, y: topY),
                          control: CGPoint(x: rightX, y: topY))
        
        return path
    }
    
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if state == .idle { return }
        
        let path = createNotchPath(in: self.bounds)
        let leftX = (bounds.width - notchRect.width) / 2.0
        let rightX = leftX + notchRect.width
        
        // 16-Stop Continuous Apple Intelligence Chromatic Gradient
        let stops = 16
        var cgColors: [CGColor] = []
        var locations: [CGFloat] = []
        for i in 0...stops {
            let loc = CGFloat(i) / CGFloat(stops)
            let color: NSColor
            if state == .success {
                color = AppleDesign.appleGreen
            } else if state == .error {
                color = AppleDesign.appleCoral
            } else {
                color = AppleDesign.siriSpectrum(at: loc + phase)
            }
            cgColors.append(color.cgColor)
            locations.append(loc)
        }
        
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: cgColors as CFArray, locations: locations) else { return }
        
        // 1. Layer 1: Ethereal Atmospheric Aurora Bloom
        let auraBlur: CGFloat = (state == .listening) ? (16.0 + 20.0 * audioLevel) : 16.0
        let auraWidth: CGFloat = (state == .listening) ? (7.0 + 8.0 * audioLevel) : 7.0
        let dominantGlowColor: NSColor
        if state == .success {
            dominantGlowColor = AppleDesign.appleGreen
        } else if state == .error {
            dominantGlowColor = AppleDesign.appleCoral
        } else {
            dominantGlowColor = AppleDesign.siriSpectrum(at: phase + 0.5)
        }
        
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -3),
            blur: auraBlur,
            color: dominantGlowColor.withAlphaComponent(0.70 + 0.25 * audioLevel).cgColor
        )
        context.addPath(path)
        context.setLineWidth(auraWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.replacePathWithStrokedPath()
        context.clip()
        
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: leftX - 16, y: 0),
            end: CGPoint(x: rightX + 16, y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()
        
        // 2. Layer 2: Precision Apple Intelligence Chromatic Ribbon
        context.saveGState()
        context.addPath(path)
        context.setLineWidth(2.6)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.replacePathWithStrokedPath()
        context.clip()
        
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: leftX - 16, y: 0),
            end: CGPoint(x: rightX + 16, y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()
        
        // 3. Layer 3: Refractive Specular Platinum Core Line
        context.saveGState()
        context.addPath(path)
        context.setStrokeColor(NSColor(white: 1.0, alpha: 0.95).cgColor)
        context.setLineWidth(0.8)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }
}

// MARK: - Apple Intelligence Living Siri Orb View

final class AppleIntelligenceOrbView: NSView {
    enum OrbState {
        case listening
        case processing
        case success
        case error
    }
    
    var state: OrbState = .listening {
        didSet {
            needsDisplay = true
        }
    }
    
    var audioLevel: CGFloat = 0.0 {
        didSet {
            needsDisplay = true
        }
    }
    
    private var phase: CGFloat = 0.0
    private var displayTimer: Timer?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
    }

    func startAnimation() {
        displayTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let speed: CGFloat = (self.state == .processing) ? 0.030 : 0.010
            self.phase = (self.phase + speed).truncatingRemainder(dividingBy: 1.0)
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        self.displayTimer = timer
    }
    
    func stopAnimation() {
        displayTimer?.invalidate()
        displayTimer = nil
    }
    
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let bounds = self.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let maxRadius = min(bounds.width, bounds.height) / 2.0 - 1.0
        
        switch state {
        case .listening:
            drawLivingOrb(in: context, center: center, maxRadius: maxRadius)
            
        case .processing:
            drawProcessingSwirl(in: context, center: center, maxRadius: maxRadius)
            
        case .success:
            drawAppleCheckmark(in: context, center: center, size: maxRadius * 2.0)
            
        case .error:
            drawAppleAlert(in: context, center: center, size: maxRadius * 2.0)
        }
    }
    
    private func drawLivingOrb(in context: CGContext, center: CGPoint, maxRadius: CGFloat) {
        let baseRadius = maxRadius * (0.75 + 0.35 * audioLevel)
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        
        // 3 Overlapping pulsating chromatic lobes
        let lobes = 3
        for i in 0..<lobes {
            let lobeAngle = CGFloat(i) * (2.0 * .pi / CGFloat(lobes)) + phase * 2.0 * .pi
            let offsetDist = 2.0 * (1.0 + audioLevel)
            let lobeCenter = CGPoint(
                x: center.x + offsetDist * cos(lobeAngle),
                y: center.y + offsetDist * sin(lobeAngle)
            )
            let lobeColor = AppleDesign.siriSpectrum(at: phase + CGFloat(i) / CGFloat(lobes))
            
            let colors = [
                lobeColor.withAlphaComponent(0.85).cgColor,
                lobeColor.withAlphaComponent(0.0).cgColor
            ] as CFArray
            let locs: [CGFloat] = [0.0, 1.0]
            if let radialGrad = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locs) {
                context.saveGState()
                context.drawRadialGradient(
                    radialGrad,
                    startCenter: lobeCenter,
                    startRadius: 0,
                    endCenter: lobeCenter,
                    endRadius: baseRadius,
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
                context.restoreGState()
            }
        }
        
        // Luminous Specular Core
        context.saveGState()
        context.setFillColor(NSColor(white: 1.0, alpha: 0.95).cgColor)
        context.setShadow(offset: .zero, blur: 4.0, color: NSColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: center.x - 2.0, y: center.y - 2.0, width: 4.0, height: 4.0))
        context.restoreGState()
    }
    
    private func drawProcessingSwirl(in context: CGContext, center: CGPoint, maxRadius: CGFloat) {
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: phase * 2.0 * .pi)
        context.translateBy(x: -center.x, y: -center.y)
        
        let path = CGMutablePath()
        let r = maxRadius * 0.85
        path.addArc(center: center, radius: r, startAngle: 0, endAngle: 1.5 * .pi, clockwise: false)
        
        context.setStrokeColor(AppleDesign.siriCyan.cgColor)
        context.setLineWidth(2.2)
        context.setLineCap(.round)
        context.setShadow(offset: .zero, blur: 6.0, color: AppleDesign.siriCyan.withAlphaComponent(0.85).cgColor)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }
    
    private func drawAppleCheckmark(in context: CGContext, center: CGPoint, size: CGFloat) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x - 4.5, y: center.y - 0.5))
        path.addLine(to: CGPoint(x: center.x - 1.5, y: center.y - 3.5))
        path.addLine(to: CGPoint(x: center.x + 4.5, y: center.y + 3.5))
        
        context.saveGState()
        context.setShadow(offset: .zero, blur: 6.0, color: AppleDesign.appleGreen.withAlphaComponent(0.85).cgColor)
        context.setStrokeColor(AppleDesign.appleGreen.cgColor)
        context.setLineWidth(2.2)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }
    
    private func drawAppleAlert(in context: CGContext, center: CGPoint, size: CGFloat) {
        let path = CGMutablePath()
        let r = size / 2.0 - 2.0
        path.move(to: CGPoint(x: center.x, y: center.y + r))
        path.addLine(to: CGPoint(x: center.x + r, y: center.y - r))
        path.addLine(to: CGPoint(x: center.x - r, y: center.y - r))
        path.closeSubpath()
        
        context.saveGState()
        context.setShadow(offset: .zero, blur: 6.0, color: AppleDesign.appleCoral.withAlphaComponent(0.85).cgColor)
        context.setFillColor(AppleDesign.appleCoral.cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }
}

// MARK: - Apple Siri Fluid Equalizer Waveform View

final class AppleSiriWaveformView: NSView {
    private var levels: [CGFloat] = [0.12, 0.12, 0.12, 0.12]
    private let barCount = 4
    
    // Tight cyan-to-indigo ramp: one hue family reads as one instrument. A different
    // spectrum color per bar reads as four toys.
    private let barColors: [NSColor] = [
        AppleDesign.siriSpectrum(at: 0.00),
        AppleDesign.siriSpectrum(at: 0.07),
        AppleDesign.siriSpectrum(at: 0.14),
        AppleDesign.siriSpectrum(at: 0.21)
    ]
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
    }
    
    func updateLevel(db: Double) {
        let norm = max(0.08, min(1.0, CGFloat((db + 55.0) / 45.0)))
        let multipliers: [CGFloat] = [0.65, 1.0, 0.92, 0.60]
        for i in 0..<barCount {
            let target = norm * multipliers[i]
            levels[i] = levels[i] * 0.25 + target * 0.75
        }
        needsDisplay = true
    }
    
    func reset() {
        levels = [0.12, 0.12, 0.12, 0.12]
        needsDisplay = true
    }
    
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let bounds = self.bounds
        let barWidth: CGFloat = 3.0
        let spacing: CGFloat = 3.0
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        let startX = (bounds.width - totalWidth) / 2.0
        let maxBarHeight = bounds.height - 4.0
        
        for i in 0..<barCount {
            let barHeight = max(4.0, levels[i] * maxBarHeight)
            let x = startX + CGFloat(i) * (barWidth + spacing)
            let y = (bounds.height - barHeight) / 2.0
            let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
            let path = CGPath(roundedRect: rect, cornerWidth: barWidth / 2.0, cornerHeight: barWidth / 2.0, transform: nil)
            
            context.saveGState()
            let color = barColors[i % barColors.count]
            context.setShadow(offset: .zero, blur: 4.0, color: color.withAlphaComponent(0.60).cgColor)
            context.addPath(path)
            context.setFillColor(color.cgColor)
            context.fillPath()
            context.restoreGState()
        }
    }
}

// MARK: - Apple Dynamic Island Obsidian Acrylic Backplate View

final class AppleIslandBackplateView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        if #available(macOS 10.15, *) {
            self.layer?.cornerCurve = .continuous
        }
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
        if #available(macOS 10.15, *) {
            self.layer?.cornerCurve = .continuous
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let bounds = self.bounds
        let cornerRadius = bounds.height / 2.0
        let pillPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        
        // 1. Deep Obsidian Base - near-opaque so the pill matches the notch's hardware black
        context.saveGState()
        context.addPath(pillPath)
        context.setFillColor(NSColor(calibratedRed: 0.043, green: 0.043, blue: 0.059, alpha: 0.97).cgColor)
        context.fillPath()
        context.restoreGState()
        
        // 2. Continuous Dual-Stage Specular Rim Light Gradient
        let borderPath = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: cornerRadius - 0.5, cornerHeight: cornerRadius - 0.5, transform: nil)
        context.saveGState()
        context.addPath(borderPath)
        context.setLineWidth(1.0)
        context.replacePathWithStrokedPath()
        context.clip()
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let strokeColors = [
            NSColor(white: 1.0, alpha: 0.28).cgColor,
            NSColor(white: 1.0, alpha: 0.10).cgColor,
            NSColor(white: 1.0, alpha: 0.04).cgColor
        ] as CFArray
        let strokeLocations: [CGFloat] = [0.0, 0.5, 1.0]
        if let strokeGradient = CGGradient(colorsSpace: colorSpace, colors: strokeColors, locations: strokeLocations) {
            context.drawLinearGradient(
                strokeGradient,
                start: CGPoint(x: bounds.midX, y: bounds.maxY),
                end: CGPoint(x: bounds.midX, y: bounds.minY),
                options: []
            )
        }
        context.restoreGState()
    }
}

// MARK: - Unified Floating Dynamic Island HUD (Apple Native Craftsmanship)

final class FloatingHUD {
    private let notchPanel: NSPanel
    private let notchGlowView: AppleNotchAuraView
    
    private let pillPanel: NSPanel
    private let pillContentView: NSView
    private let backplateView: AppleIslandBackplateView
    private let orbIcon: AppleIntelligenceOrbView
    private let headerLabel: NSTextField
    private let transcriptLabel: NSTextField
    private let waveformView: AppleSiriWaveformView
    
    private var hideWorkItem: DispatchWorkItem?
    private var currentWidth: CGFloat = 330
    private let minPillWidth: CGFloat = 330
    private let maxPillWidth: CGFloat = 520
    private let pillHeight: CGFloat = 52
    // Tucked nearly flush beneath the notch so the pill reads as the notch extruding,
    // not a separate floating window.
    private let pillGap: CGFloat = 2.0
    private var notchInfo: NotchGeometry
    private var screenFrame: NSRect

    init() {
        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        self.screenFrame = screen.frame
        self.notchInfo = NotchGeometry.detect(screen: screen)
        
        // 1. Setup Hardware Notch Glow Overlay Panel
        let padding: CGFloat = 50.0
        let glowWidth = notchInfo.rect.width + padding * 2
        let glowHeight = notchInfo.rect.height + padding + 12.0
        let glowX = notchInfo.rect.minX - padding
        let glowY = screen.frame.height - glowHeight
        
        self.notchPanel = NSPanel(
            contentRect: NSRect(x: glowX, y: glowY, width: glowWidth, height: glowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        notchPanel.level = .screenSaver
        notchPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        notchPanel.isOpaque = false
        notchPanel.backgroundColor = .clear
        notchPanel.hasShadow = false
        notchPanel.ignoresMouseEvents = true
        notchPanel.alphaValue = 0.0
        
        self.notchGlowView = AppleNotchAuraView(frame: NSRect(x: 0, y: 0, width: glowWidth, height: glowHeight))
        notchGlowView.notchRect = notchInfo.rect
        notchPanel.contentView = notchGlowView
        
        // 2. Setup Floating Dynamic Island Panel
        let initialWidth = minPillWidth
        let pillX = screen.frame.midX - initialWidth / 2.0
        let pillY = screen.frame.height - notchInfo.rect.height - pillHeight - pillGap
        
        self.pillPanel = NSPanel(
            contentRect: NSRect(x: pillX, y: pillY, width: initialWidth, height: pillHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        pillPanel.level = .floating
        pillPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        pillPanel.isOpaque = false
        pillPanel.backgroundColor = .clear
        pillPanel.hasShadow = true
        pillPanel.ignoresMouseEvents = true
        pillPanel.alphaValue = 0.0
        
        // Hardware-black container. The pill reads as a piece of the notch itself - opaque
        // near-black like the bezel glass, not a translucent overlay - so no blur material.
        // (The old NSVisualEffectView blur was painted over by the 0.9-alpha backplate anyway,
        // and its layer shadow was dead code: masksToBounds clips layer shadows; the window
        // shadow comes from pillPanel.hasShadow.)
        self.pillContentView = NSView(frame: NSRect(x: 0, y: 0, width: initialWidth, height: pillHeight))
        pillContentView.wantsLayer = true
        pillContentView.layer?.cornerRadius = pillHeight / 2.0
        if #available(macOS 10.15, *) {
            pillContentView.layer?.cornerCurve = .continuous
        }
        pillContentView.layer?.masksToBounds = true
        
        self.backplateView = AppleIslandBackplateView(frame: NSRect(x: 0, y: 0, width: initialWidth, height: pillHeight))
        pillContentView.addSubview(backplateView)
        
        // Apple Intelligence Living Orb (Top-Left)
        self.orbIcon = AppleIntelligenceOrbView(frame: NSRect(x: 16, y: 27, width: 18, height: 18))
        pillContentView.addSubview(orbIcon)
        
        // Eyebrow state label (Top-Center-Left): a single state word in the NOW PLAYING idiom.
        // State leads; the tool's name is not information the user needs at a glance.
        self.headerLabel = NSTextField(labelWithString: "")
        headerLabel.frame = NSRect(x: 38, y: 27, width: 230, height: 16)
        pillContentView.addSubview(headerLabel)
        
        // Apple Siri Equalizer (Top-Right)
        self.waveformView = AppleSiriWaveformView(frame: NSRect(x: initialWidth - 48, y: 26, width: 32, height: 16))
        pillContentView.addSubview(waveformView)
        
        // Live Transcript / Preview Text (Bottom-Row)
        self.transcriptLabel = NSTextField(labelWithString: "")
        transcriptLabel.font = NSFont.systemFont(ofSize: 13.5, weight: .regular)
        transcriptLabel.frame = NSRect(x: 16, y: 7, width: initialWidth - 32, height: 20)
        transcriptLabel.lineBreakMode = .byTruncatingTail
        pillContentView.addSubview(transcriptLabel)

        pillPanel.contentView = pillContentView

        // Re-run screen-dependent layout whenever the display configuration changes
        // (monitor plugged/unplugged, resolution change, etc.) so the notch aura and
        // pill don't stay pinned to stale geometry. FloatingHUD isn't an NSObject subclass,
        // so use the block-based observer API rather than a @objc selector target.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyScreenLayout()
        }
    }

    // Recomputes screenFrame, notchInfo, and repositions the notch/pill panels to match -
    // the same geometry math used to place them in init().
    private func applyScreenLayout() {
        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        self.screenFrame = screen.frame
        self.notchInfo = NotchGeometry.detect(screen: screen)

        // Notch Glow Overlay Panel geometry
        let padding: CGFloat = 50.0
        let glowWidth = notchInfo.rect.width + padding * 2
        let glowHeight = notchInfo.rect.height + padding + 12.0
        let glowX = notchInfo.rect.minX - padding
        let glowY = screenFrame.height - glowHeight
        notchPanel.setFrame(NSRect(x: glowX, y: glowY, width: glowWidth, height: glowHeight), display: true)
        notchGlowView.frame = NSRect(x: 0, y: 0, width: glowWidth, height: glowHeight)
        notchGlowView.notchRect = notchInfo.rect
        notchGlowView.needsDisplay = true

        // Floating Dynamic Island Panel geometry (preserves currentWidth)
        let pillX = screenFrame.midX - currentWidth / 2.0
        let pillY = screenFrame.height - notchInfo.rect.height - pillHeight - pillGap
        pillPanel.setFrame(NSRect(x: pillX, y: pillY, width: currentWidth, height: pillHeight), display: true)
    }

    private func updatePillWidth(targetWidth: CGFloat) {
        let clamped = max(minPillWidth, min(maxPillWidth, targetWidth))
        guard abs(clamped - currentWidth) > 8.0 else { return }
        currentWidth = clamped
        
        let newX = screenFrame.midX - currentWidth / 2.0
        let newY = screenFrame.height - notchInfo.rect.height - pillHeight - pillGap
        let newRect = NSRect(x: newX, y: newY, width: currentWidth, height: pillHeight)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            pillPanel.animator().setFrame(newRect, display: true)
            pillContentView.frame = NSRect(x: 0, y: 0, width: currentWidth, height: pillHeight)
            backplateView.frame = NSRect(x: 0, y: 0, width: currentWidth, height: pillHeight)
            waveformView.frame = NSRect(x: currentWidth - 48, y: 26, width: 32, height: 16)
            transcriptLabel.frame = NSRect(x: 16, y: 7, width: currentWidth - 32, height: 20)
        }
    }
    
    // MARK: State typography

    // Eyebrow state word: uppercase micro-type with wide tracking (the NOW PLAYING idiom).
    private func setHeader(_ text: String, color: NSColor) {
        headerLabel.attributedStringValue = NSAttributedString(
            string: text.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 9.0, weight: .semibold),
                .foregroundColor: color,
                .kern: 1.1
            ]
        )
    }

    // Transcript line; caret appends a slim tinted insertion mark while text is streaming.
    // Truncation MUST ride inside the attributed string: a label rendering attributedStringValue
    // takes its line-break mode from the string's NSParagraphStyle, not the cell - which is why
    // setting transcriptLabel.lineBreakMode alone never worked. While streaming, truncate the
    // HEAD so the newest words flow into view; finished text truncates the tail as usual.
    private func setTranscript(_ text: String, color: NSColor, caret: Bool, truncation: NSLineBreakMode = .byTruncatingTail) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = truncation
        let body = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13.5, weight: .regular),
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
        if caret {
            body.append(NSAttributedString(
                string: " ▏",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13.5, weight: .regular),
                    .foregroundColor: AppleDesign.siriCyan,
                    .paragraphStyle: paragraph
                ]
            ))
        }
        transcriptLabel.attributedStringValue = body
    }

    // Plain transcript text with any streaming caret stripped.
    private var currentTranscriptText: String {
        var text = transcriptLabel.attributedStringValue.string
        if text.hasSuffix(" ▏") { text = String(text.dropLast(2)) }
        return text
    }

    func showListening() {
        hideWorkItem?.cancel()
        currentWidth = minPillWidth

        // Notch aura only exists where the hardware notch does; on external or non-notch
        // displays the pill stands alone rather than glowing around a phantom cutout.
        let hasNotch = notchInfo.hasPhysicalNotch
        if hasNotch {
            notchGlowView.state = .listening
            notchGlowView.audioLevel = 0.0
            notchGlowView.startAnimation()
        }

        // Pill Layout & Content
        orbIcon.state = .listening
        orbIcon.audioLevel = 0.0
        orbIcon.startAnimation()
        setHeader("Listening", color: NSColor(white: 1.0, alpha: 0.55))
        // The pill appears on key-down, so the user is already holding: say what to do next.
        setTranscript("Speak, then release to paste", color: NSColor(white: 1.0, alpha: 0.45), caret: false)
        transcriptLabel.lineBreakMode = .byTruncatingTail
        waveformView.reset()

        let pillX = screenFrame.midX - minPillWidth / 2.0
        let pillY = screenFrame.height - notchInfo.rect.height - pillHeight - pillGap
        let finalRect = NSRect(x: pillX, y: pillY, width: minPillWidth, height: pillHeight)
        pillContentView.frame = NSRect(x: 0, y: 0, width: minPillWidth, height: pillHeight)
        backplateView.frame = NSRect(x: 0, y: 0, width: minPillWidth, height: pillHeight)
        waveformView.frame = NSRect(x: minPillWidth - 48, y: 26, width: 32, height: 16)
        transcriptLabel.frame = NSRect(x: 16, y: 7, width: minPillWidth - 32, height: 20)

        // Signature entrance: the pill slides out from beneath the notch, as if the notch
        // itself extends. Reduced-motion preference gets a plain fade.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let startRect = reduceMotion ? finalRect : finalRect.offsetBy(dx: 0, dy: 10)
        pillPanel.setFrame(startRect, display: true)

        if hasNotch { notchPanel.orderFrontRegardless() }
        pillPanel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.16 : 0.28
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
            if hasNotch { notchPanel.animator().alphaValue = 1.0 }
            pillPanel.animator().alphaValue = 1.0
            pillPanel.animator().setFrame(finalRect, display: true)
        }
    }
    
    func updateAudioLevel(db: Double) {
        let norm = max(0.0, min(1.0, CGFloat((db + 55.0) / 45.0)))
        notchGlowView.audioLevel = norm
        orbIcon.audioLevel = norm
        waveformView.updateLevel(db: db)
    }
    
    func updateLiveText(_ text: String) {
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }

        // While streaming, the newest words matter most: truncate at the head so the tail
        // of the sentence is always visible, with a slim caret marking the live edge.
        setTranscript(clean, color: .white, caret: true, truncation: .byTruncatingHead)

        // Fluid Dynamic Island auto-expansion based on text width
        let font = transcriptLabel.font ?? NSFont.systemFont(ofSize: 13.5)
        let textWidth = (clean as NSString).size(withAttributes: [.font: font]).width
        let neededWidth = max(minPillWidth, textWidth + 64.0)
        updatePillWidth(targetWidth: neededWidth)
    }

    func showProcessing() {
        hideWorkItem?.cancel()
        notchGlowView.state = .processing
        orbIcon.state = .processing

        setHeader("Polishing", color: AppleDesign.siriCyan)
        // Keep the user's words on screen, just dimmed - wiping them for a status message
        // makes the pill feel like it lost the dictation.
        let existing = currentTranscriptText
        if existing.isEmpty || existing == "Speak, then release to paste" {
            setTranscript("Polishing…", color: NSColor(white: 1.0, alpha: 0.70), caret: false)
        } else {
            setTranscript(existing, color: NSColor(white: 1.0, alpha: 0.70), caret: false)
        }
        waveformView.reset()
    }

    func showSuccess(text: String) {
        hideWorkItem?.cancel()
        notchGlowView.state = .success
        orbIcon.state = .success

        setHeader("Pasted", color: AppleDesign.appleGreen)
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        transcriptLabel.lineBreakMode = .byTruncatingTail
        setTranscript(clean.isEmpty ? "Done" : clean, color: .white, caret: false)
        waveformView.reset()

        let workItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: workItem)
    }

    func showError(message: String) {
        hideWorkItem?.cancel()
        notchGlowView.state = .error
        orbIcon.state = .error

        setHeader("Error", color: AppleDesign.appleCoral)
        transcriptLabel.lineBreakMode = .byTruncatingTail
        setTranscript(message, color: NSColor(white: 1.0, alpha: 0.85), caret: false)
        waveformView.reset()

        let workItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: workItem)
    }

    func hide() {
        // Retract back beneath the notch, mirroring the entrance.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let retractRect = pillPanel.frame.offsetBy(dx: 0, dy: 10)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.notchPanel.animator().alphaValue = 0.0
            self.pillPanel.animator().alphaValue = 0.0
            if !reduceMotion {
                self.pillPanel.animator().setFrame(retractRect, display: true)
            }
        }, completionHandler: {
            if self.notchPanel.alphaValue == 0.0 {
                self.notchPanel.orderOut(nil)
                self.pillPanel.orderOut(nil)
                self.notchGlowView.stopAnimation()
                self.orbIcon.stopAnimation()
            }
        })
    }
}

// MARK: - Orchestrator (Core State Machine)

final class JustSpeakApp {
    private let config: Config
    private let audioCapture: AudioCaptureEngine
    private var liveClient: GeminiLiveClient?
    private var hotkeyManager: HotkeyManager?
    private var hud: FloatingHUD?
    private let history: TranscriptionHistoryStore?

    // Cross-thread "is a turn active" flag - read synchronously from the event-tap thread in
    // handleKeyDown (must stay fast/non-blocking), written only from sessionQueue-executed code.
    private var isProcessing: Bool = false
    private let processingLock = NSLock()

    // Frontmost app snapshotted at key-down (main thread); compared again right before paste
    // so a focus change mid-turn downgrades to clipboard-only instead of pasting into the wrong app.
    private var turnFrontmostPID: pid_t?
    private var turnFrontmostName: String?

    // Serial queue that owns all turn lifecycle state below. Both the WS commit completion and
    // the REST fallback timer used to race directly against a captured `var didFallback` bool
    // with no synchronization, so a slow-arriving WS result and a just-fired fallback timer could
    // both call handleTranscribedText and paste the turn twice. Funneling every route through
    // this serial queue makes turn settlement a single-writer state machine.
    private let sessionQueue = DispatchQueue(label: "com.justspeak.session", qos: .userInteractive)
    private var currentTurnId: UInt64 = 0
    private var turnSettled: Bool = false
    private var pendingFallbackTimer: DispatchWorkItem?

    // Main-thread-only: pending mic release for MIC_IDLE_TIMEOUT. Cancelled on every key-down,
    // re-armed whenever a turn finishes.
    private var micIdleWorkItem: DispatchWorkItem?

    /// Main-thread-only. Schedules the mic to be released after the configured idle window so
    /// the macOS mic indicator turns off between dictation sessions; 0 disables the timeout.
    private func scheduleMicIdleRelease() {
        micIdleWorkItem?.cancel()
        micIdleWorkItem = nil
        guard config.micIdleTimeoutSec > 0 else { return }

        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.micIdleWorkItem = nil
            self.audioCapture.suspendEngine()
            Logger.info("MIC", "Mic released after \(self.config.micIdleTimeoutSec)s idle - indicator off. Next key-down re-arms it.")
        }
        micIdleWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(config.micIdleTimeoutSec), execute: item)
    }

    // Retained so the GCD signal sources aren't deallocated once start() returns control to app.run()
    private var sigintSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?

    init(config: Config) {
        self.config = config
        self.audioCapture = AudioCaptureEngine(preRollMs: config.preRollMs)
        if config.enableLiveWebSocket && !config.geminiApiKey.isEmpty {
            self.liveClient = GeminiLiveClient(
                apiKey: config.geminiApiKey,
                model: config.geminiLiveModel,
                smartTranscription: config.smartTranscription,
                languageCodes: config.languageCodes,
                customVocabulary: config.customVocabulary,
                vadMode: config.vadMode,
                vadSilenceMs: config.vadSilenceMs
            )
        }
        if config.showHUD {
            self.hud = FloatingHUD()
        }
        self.history = config.historyEnabled ? TranscriptionHistoryStore(config: config) : nil
    }
    
    func start() {
        printBanner()
        
        // Handle SIGINT (Ctrl+C) and SIGTERM cleanly. C signal handlers must not call
        // async-signal-unsafe functions like print(), so ignore the raw signal and do the
        // actual work in a GCD dispatch source on the main queue instead.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler { [weak self] in
            self?.printSessionUsageSummary()
            self?.history?.close()
            print("\n\(ANSI.bold)Exiting JustSpeak. Goodbye!\(ANSI.reset)")
            exit(0)
        }
        sigint.resume()
        self.sigintSource = sigint

        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler {
            exit(0)
        }
        sigterm.resume()
        self.sigtermSource = sigterm
        
        // 1. Verify Permissions
        let (ax, mic) = PermissionChecker.verifyAll()
        if !ax || !mic {
            PermissionChecker.printDetailedStatus()
            if !ax {
                Logger.error("PERM", "Missing Accessibility permission. Run 'make check-permissions' for help.")
            }
        }
        
        // 2. Validate API Key
        if config.geminiApiKey.isEmpty {
            Logger.warn("CONFIG", "GEMINI_API_KEY is not set. Add your key to .env or export GEMINI_API_KEY.")
            Logger.warn("CONFIG", "Get your API key at: https://aistudio.google.com/")
        }
        
        // 3. Initialize Audio Capture Engine
        guard audioCapture.setup() else {
            Logger.error("MAIN", "Failed to start Audio Capture Engine.")
            exit(1)
        }
        
        // The mic idle countdown starts at launch: no dictation for the configured window
        // releases the mic until the next key-down.
        scheduleMicIdleRelease()

        // Wire audio chunks to Gemini Live WebSocket streaming
        audioCapture.onAudioChunk = { [weak self] chunk in
            self?.liveClient?.sendAudioChunk(chunk)
        }
        
        // Wire audio level (dB) to Floating HUD
        audioCapture.onAudioLevel = { [weak self] db in
            DispatchQueue.main.async {
                self?.hud?.updateAudioLevel(db: db)
            }
        }
        
        // 4. Pre-warm Gemini Live WebSocket & wire streaming text to HUD
        if config.enableLiveWebSocket {
            liveClient?.onLiveTextUpdate = { [weak self] text in
                DispatchQueue.main.async {
                    self?.hud?.updateLiveText(text)
                }
            }
            liveClient?.connect()
        }

        // Pre-warm the REST fallback route's connection (DNS + TCP + TLS handshake) so that if
        // the REST fallback is ever needed, it isn't paying cold-connection cost on the critical
        // path. Uses URLSession.shared, the same pool GeminiRestClient makes its calls from.
        if !config.geminiApiKey.isEmpty {
            let prewarmStart = CFAbsoluteTimeGetCurrent()
            if let prewarmUrl = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1") {
                var prewarmRequest = URLRequest(url: prewarmUrl)
                prewarmRequest.timeoutInterval = 10.0
                prewarmRequest.setValue(config.geminiApiKey, forHTTPHeaderField: "x-goog-api-key")
                URLSession.shared.dataTask(with: prewarmRequest) { _, response, _ in
                    let elapsedMs = (CFAbsoluteTimeGetCurrent() - prewarmStart) * 1000.0
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    Logger.debug("REST", "Connection pre-warmed (\(String(format: "%.0f", elapsedMs))ms, HTTP \(status))")
                }.resume()
            }
        }

        // 5. Setup Hotkey Listener
        let binding = HotkeyManager.KeyBinding.from(string: config.hotkey)
        let hotkey = HotkeyManager(binding: binding, mode: config.hotkeyMode)
        
        hotkey.onKeyDown = { [weak self] in
            self?.handleKeyDown()
        }
        
        hotkey.onKeyUp = { [weak self] in
            self?.handleKeyUp()
        }
        
        guard hotkey.start() else {
            Logger.error("HOTKEY", "Failed to initialize global CGEventTap. Please grant Accessibility permissions to this terminal.")
            PermissionChecker.printDetailedStatus()
            exit(1)
        }
        self.hotkeyManager = hotkey
        
        Logger.success("READY", "JustSpeak active! Hold \(ANSI.bold)\(binding.name)\(ANSI.reset) to speak, release to paste.")
        print("\(ANSI.gray)Press Ctrl+C to quit at any time.\(ANSI.reset)\n")
        
        // Run AppKit RunLoop with Accessory activation policy (no Dock icon, full window support)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.run()
    }
    
    private func handleKeyDown() {
        processingLock.lock()
        // Protect re-entrancy / double-tap race
        guard !isProcessing else {
            processingLock.unlock()
            return
        }
        processingLock.unlock()

        // Refuse to start a turn while secure input is held (password field, Terminal's Secure
        // Keyboard Entry, ...) - synthesized keystrokes and clipboard pastes into it can fail or
        // leak. Checked here, not just at paste time, so we never spin up the mic for a turn
        // that can only end in copy-only.
        if SecureInputMonitor.isActive {
            let holder = SecureInputMonitor.holderName()
            Logger.warn("SECURE", "Secure input is held by \(holder ?? "another app") - dictation blocked (password field?)")
            if config.soundFeedback {
                SoundManager.playErrorSound()
            }
            hud?.showError(message: "Secure input active — dictation blocked")
            return
        }

        // Frontmost app at key-down, compared again right before paste in handleTranscribedText.
        let front = NSWorkspace.shared.frontmostApplication
        turnFrontmostPID = front?.processIdentifier
        turnFrontmostName = front?.localizedName

        micIdleWorkItem?.cancel()
        micIdleWorkItem = nil

        // Re-arm the mic if the idle timeout released it. The begin earcon plays only after
        // the engine is actually capturing, so the sound always means "speak now" - never
        // before a cold mic is ready.
        if !audioCapture.isEngineRunning {
            let wakeStart = CFAbsoluteTimeGetCurrent()
            if audioCapture.resumeEngine() {
                Logger.info("MIC", "Mic re-armed after idle (\(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - wakeStart) * 1000.0))ms spin-up).")
            }
        }

        if config.soundFeedback {
            SoundManager.playStartSound()
        }

        DispatchQueue.main.async { [weak self] in
            self?.hud?.showListening()
        }

        liveClient?.startNewTurn()
        audioCapture.startRecording()
    }
    
    private func handleKeyUp() {
        // Capture the physical release instant before anything else - this becomes the true
        // start of "Total Key-Up -> Paste" latency measurement.
        let keyUpTime = CFAbsoluteTimeGetCurrent()

        // Flip the HUD to "processing" immediately on the main queue. The tap thread must not
        // block on stopRecording's post-roll sleep + queue drain, so the rest of the turn is
        // handed off to sessionQueue right away.
        DispatchQueue.main.async { [weak self] in
            self?.hud?.showProcessing()
        }

        sessionQueue.async { [weak self] in
            self?.runTurnPipeline(keyUpTime: keyUpTime)
        }
    }

    /// Runs entirely on sessionQueue: finalizes the capture, arbitrates the WS-vs-REST turn
    /// lifecycle, and is the only place that mutates currentTurnId / turnSettled / pendingFallbackTimer.
    private func runTurnPipeline(keyUpTime: CFAbsoluteTime) {
        let pipelineStartTime = CFAbsoluteTimeGetCurrent()
        let (pcmData, duration, chunks, capturedBytes) = audioCapture.stopRecording(gracePeriodMs: config.postRollMs)

        // Discard accidental micro-clicks (< 150ms or < 2KB of real captured audio, ignoring
        // the fixed pre-roll/silence-flush padding that stopRecording always appends)
        guard duration >= 0.15 && capturedBytes > 2000 else {
            Logger.warn("INPUT", "Ignored short click (\(String(format: "%.0f", duration * 1000.0))ms). Hold key while speaking.")
            DispatchQueue.main.async { [weak self] in
                self?.hud?.hide()
                self?.scheduleMicIdleRelease()
            }
            return
        }

        processingLock.lock()
        guard !isProcessing else {
            processingLock.unlock()
            return
        }
        isProcessing = true
        processingLock.unlock()

        currentTurnId += 1
        let turnId = currentTurnId
        turnSettled = false

        Logger.info("AUDIO", "Captured \(String(format: "%.2fs", duration)) audio (\(chunks) chunks, \(String(format: "%.1f", Double(pcmData.count)/1024.0)) KB). Committing turn...")

        let commitDispatchTime = CFAbsoluteTimeGetCurrent()
        let captureFinalizeMs = (commitDispatchTime - pipelineStartTime) * 1000.0

        // Strategy: Try Live WebSocket first; if not ready or on error, fallback seamlessly to REST
        if config.enableLiveWebSocket, let liveClient = self.liveClient, liveClient.isReady {
            let commitStartTime = commitDispatchTime
            let dynamicTimeout = max(config.restFallbackTimeout, min(8.0, duration * 0.4 + 3.0))

            let fallbackTimer = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                guard self.currentTurnId == turnId, !self.turnSettled else { return }
                self.pendingFallbackTimer = nil
                let reason = "WebSocket Settlement Timeout (> \(String(format: "%.1f", dynamicTimeout))s)"
                Logger.warn("WS", "\(reason); executing REST fallback (hedge - WS may still land first)...")
                self.executeRestFallback(turnId: turnId, pcmData: pcmData, duration: duration, keyUpTime: keyUpTime, captureFinalizeMs: captureFinalizeMs, reason: reason)
            }
            pendingFallbackTimer = fallbackTimer
            sessionQueue.asyncAfter(deadline: .now() + dynamicTimeout, execute: fallbackTimer)

            liveClient.commitTurn { [weak self] result in
                guard let self = self else { return }
                self.sessionQueue.async {
                    switch result {
                    case .success(let payload):
                        let roundtripMs = (CFAbsoluteTimeGetCurrent() - commitStartTime) * 1000.0
                        let usage = self.liveClient?.lastTurnUsage
                        self.settle(turnId: turnId, route: "WS", outcome: .success(
                            text: payload.text,
                            transport: "Live WebSocket (\(self.config.geminiLiveModel))",
                            firstTokenMs: payload.firstTokenMs,
                            roundtripMs: roundtripMs,
                            audioDuration: duration,
                            keyUpTime: keyUpTime,
                            captureFinalizeMs: captureFinalizeMs,
                            fallbackReason: nil,
                            isLiveRoute: true,
                            inputTokens: usage?.inputTokens,
                            outputTokens: usage?.outputTokens
                        ))

                    case .failure(let error):
                        guard self.currentTurnId == turnId, !self.turnSettled else { return }
                        // If the hedge timer already fired, a REST call for this turn is in flight
                        // (pendingFallbackTimer was nilled when it ran) - don't launch a duplicate.
                        guard self.pendingFallbackTimer != nil else {
                            Logger.debug("SESSION", "WS failed for turn #\(turnId); hedge REST already in flight.")
                            return
                        }
                        // WS gave a definitive answer (an error); the hedge timer no longer needs
                        // to fire a second, redundant REST call.
                        self.pendingFallbackTimer?.cancel()
                        self.pendingFallbackTimer = nil
                        let reason = "WebSocket Disconnected / Error (\(error.localizedDescription))"
                        Logger.warn("WS", "\(reason). Falling back to REST...")
                        self.executeRestFallback(turnId: turnId, pcmData: pcmData, duration: duration, keyUpTime: keyUpTime, captureFinalizeMs: captureFinalizeMs, reason: reason)
                    }
                }
            }
        } else {
            // Direct REST
            let reason = !config.enableLiveWebSocket ? "Live WebSockets Disabled in Config" : "Live WebSocket Initial Handshake Pending"
            executeRestFallback(turnId: turnId, pcmData: pcmData, duration: duration, keyUpTime: keyUpTime, captureFinalizeMs: captureFinalizeMs, reason: reason)
        }
    }

    /// Result of a settled turn, handed to settle(). Success carries every field the latency
    /// diagnostic printout needs; failure is the REST-fallback-failed error path.
    private enum TurnOutcome {
        case success(text: String, transport: String, firstTokenMs: Double, roundtripMs: Double, audioDuration: Double, keyUpTime: CFAbsoluteTime, captureFinalizeMs: Double, fallbackReason: String?, isLiveRoute: Bool, inputTokens: Int?, outputTokens: Int?)
        case failure(Error)
    }

    // Session-wide usage accumulators, printed on Ctrl+C exit. Guarded by statsLock: written
    // on sessionQueue per turn, read from the main-queue signal handler.
    private let statsLock = NSLock()
    private var sessionTurns = 0
    private var sessionInputTokens = 0
    private var sessionOutputTokens = 0
    private var sessionCostUSD = 0.0

    func printSessionUsageSummary() {
        statsLock.lock()
        let turns = sessionTurns
        let inTok = sessionInputTokens
        let outTok = sessionOutputTokens
        let cost = sessionCostUSD
        statsLock.unlock()
        guard turns > 0 else { return }
        print("\n\(ANSI.bold)📈 Session Usage:\(ANSI.reset) \(turns) dictation\(turns == 1 ? "" : "s") | \(inTok) in / \(outTok) out tokens | ≈ $\(String(format: "%.4f", cost))")
    }

    /// Launches the REST fallback for turnId. Does NOT settle the turn by itself - WS and REST
    /// race, and whichever result reaches settle() first for a still-live turnId wins.
    private func executeRestFallback(turnId: UInt64, pcmData: Data, duration: Double, keyUpTime: CFAbsoluteTime, captureFinalizeMs: Double, reason: String) {
        let restStartTime = CFAbsoluteTimeGetCurrent()
        GeminiRestClient.transcribe(
            pcmData: pcmData,
            apiKey: config.geminiApiKey,
            model: config.geminiModel,
            languageCodes: config.languageCodes,
            customVocabulary: config.customVocabulary
        ) { [weak self] result in
            guard let self = self else { return }
            self.sessionQueue.async {
                switch result {
                case .success(let payload):
                    let roundtripMs = (CFAbsoluteTimeGetCurrent() - restStartTime) * 1000.0
                    self.settle(turnId: turnId, route: "REST", outcome: .success(
                        text: payload.text,
                        transport: "REST API (\(self.config.geminiModel))",
                        firstTokenMs: 0,
                        roundtripMs: roundtripMs,
                        audioDuration: duration,
                        keyUpTime: keyUpTime,
                        captureFinalizeMs: captureFinalizeMs,
                        fallbackReason: reason,
                        isLiveRoute: false,
                        inputTokens: payload.inputTokens,
                        outputTokens: payload.outputTokens
                    ))

                case .failure(let error):
                    self.settle(turnId: turnId, route: "REST", outcome: .failure(error))
                }
            }
        }
    }

    /// The sole place a live turn's result reaches handleTranscribedText or the error path.
    /// Runs only on sessionQueue. A result for a turnId that isn't current, or one that arrives
    /// after the turn already settled, is a loser of the WS/REST hedge race and is dropped.
    private func settle(turnId: UInt64, route: String, outcome: TurnOutcome) {
        guard turnId == currentTurnId, !turnSettled else {
            Logger.debug("SESSION", "Stale result for turn #\(turnId) ignored (\(route))")
            return
        }
        turnSettled = true
        pendingFallbackTimer?.cancel()
        pendingFallbackTimer = nil

        switch outcome {
        case .success(let text, let transport, let firstTokenMs, let roundtripMs, let audioDuration, let keyUpTime, let captureFinalizeMs, let fallbackReason, let isLiveRoute, let inputTokens, let outputTokens):
            handleTranscribedText(
                text,
                transport: transport,
                firstTokenMs: firstTokenMs,
                roundtripMs: roundtripMs,
                audioDuration: audioDuration,
                totalStartTime: keyUpTime,
                captureFinalizeMs: captureFinalizeMs,
                fallbackReason: fallbackReason,
                isLiveRoute: isLiveRoute,
                inputTokens: inputTokens,
                outputTokens: outputTokens
            )

        case .failure(let error):
            Logger.error("REST", "Transcription failed: \(error.localizedDescription)")
            if config.soundFeedback { SoundManager.playErrorSound() }
            DispatchQueue.main.async { [weak self] in
                self?.hud?.showError(message: "Transcription failed — nothing pasted")
            }
            history?.record(TranscriptionHistoryStore.TurnRecord(
                outcome: "error",
                text: nil,
                charCount: 0,
                wordCount: 0,
                transport: route,
                model: nil,
                isLiveRoute: nil,
                fallbackReason: nil,
                audioSeconds: nil,
                firstTokenMs: nil,
                roundtripMs: nil,
                captureFinalizeMs: nil,
                injectMs: nil,
                totalMs: nil,
                injected: nil,
                inputTokens: nil,
                outputTokens: nil,
                tokensMetered: nil,
                costUSD: nil,
                languageCodes: config.languageCodes.joined(separator: ","),
                smartMode: config.smartTranscription,
                vadMode: config.vadMode,
                error: error.localizedDescription
            ))
            processingLock.lock()
            isProcessing = false
            processingLock.unlock()
        }

        // Turn finished either way: start the mic idle countdown.
        DispatchQueue.main.async { [weak self] in
            self?.scheduleMicIdleRelease()
        }
    }

    /// Runs on sessionQueue (called only from settle). isProcessing is cleared here at the end,
    /// which is now a sessionQueue-only write.
    private func handleTranscribedText(
        _ rawText: String,
        transport: String,
        firstTokenMs: Double,
        roundtripMs: Double,
        audioDuration: Double,
        totalStartTime: CFAbsoluteTime,
        captureFinalizeMs: Double,
        fallbackReason: String? = nil,
        isLiveRoute: Bool = true,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil
    ) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Logger.warn("AI", "Received empty transcription from Gemini.")
            DispatchQueue.main.async { [weak self] in
                self?.hud?.showError(message: "No speech detected")
            }
            history?.record(TranscriptionHistoryStore.TurnRecord(
                outcome: "empty",
                text: nil,
                charCount: 0,
                wordCount: 0,
                transport: transport,
                model: isLiveRoute ? config.geminiLiveModel : config.geminiModel,
                isLiveRoute: isLiveRoute,
                fallbackReason: fallbackReason,
                audioSeconds: audioDuration,
                firstTokenMs: firstTokenMs > 0 ? firstTokenMs : nil,
                roundtripMs: roundtripMs,
                captureFinalizeMs: captureFinalizeMs,
                injectMs: nil,
                totalMs: nil,
                injected: nil,
                inputTokens: nil,
                outputTokens: nil,
                tokensMetered: nil,
                costUSD: nil,
                languageCodes: config.languageCodes.joined(separator: ","),
                smartMode: config.smartTranscription,
                vadMode: config.vadMode,
                error: nil
            ))
            processingLock.lock()
            isProcessing = false
            processingLock.unlock()
            return
        }

        // Deterministic wrong->right enforcement (client-side guarantee on top of boost bias).
        let text = ReplacementEngine.apply(trimmed, rules: config.replacementRules)

        print("\n\(ANSI.bold)\(ANSI.magenta)─── Transcribed & Polished Text ─────────────────────────────\(ANSI.reset)")
        print("\(ANSI.bold)\(text)\(ANSI.reset)")
        print("\(ANSI.bold)\(ANSI.magenta)─────────────────────────────────────────────────────────────\(ANSI.reset)")

        // Active Window Injection: paste, unless secure input is held or the frontmost app
        // changed mid-turn - both downgrade to clipboard-only delivery instead of synthesizing
        // a paste into the wrong (or a password) field. Auto-restores the previous clipboard
        // after ~1s on the normal paste path.
        let injected: Bool
        let injectMs: Double
        var copyOnlyReason: String?  // set on downgrade; drives the log message, HUD text and status label

        if SecureInputMonitor.isActive {
            let copyStart = CFAbsoluteTimeGetCurrent()
            _ = TextInjector.copyOnly(text: text)
            injectMs = (CFAbsoluteTimeGetCurrent() - copyStart) * 1000.0
            injected = false
            let holder = SecureInputMonitor.holderName()
            Logger.warn("INJECT", "Secure input is held by \(holder ?? "another app") - copied, not pasted.")
            copyOnlyReason = "secure input"
        } else {
            var frontNow: NSRunningApplication?
            DispatchQueue.main.sync { frontNow = NSWorkspace.shared.frontmostApplication }

            if let priorPid = turnFrontmostPID, let nowPid = frontNow?.processIdentifier, priorPid != nowPid {
                let copyStart = CFAbsoluteTimeGetCurrent()
                _ = TextInjector.copyOnly(text: text)
                injectMs = (CFAbsoluteTimeGetCurrent() - copyStart) * 1000.0
                injected = false
                Logger.warn("INJECT", "Focus moved from \(turnFrontmostName ?? "?") to \(frontNow?.localizedName ?? "?") mid-turn - text copied, not pasted.")
                copyOnlyReason = "focus changed"
            } else {
                (injected, injectMs) = TextInjector.inject(text: text, restorePreviousClipboard: config.restoreClipboard, completionSound: config.soundFeedback)
            }
        }

        if copyOnlyReason != nil, config.soundFeedback {
            // Text still landed - on the clipboard - so this is a commit, not an error sound.
            SoundManager.playCommitSound()
        }

        let totalElapsedMs = (CFAbsoluteTimeGetCurrent() - totalStartTime) * 1000.0

        let injectStatus: String
        if let reason = copyOnlyReason {
            injectStatus = "\(ANSI.yellow)Copied — \(reason)\(ANSI.reset)"
        } else {
            injectStatus = injected ? "\(ANSI.green)Pasted via Cmd+V\(ANSI.reset)" : "\(ANSI.yellow)Copied to Clipboard\(ANSI.reset)"
        }

        DispatchQueue.main.async { [weak self] in
            if let reason = copyOnlyReason {
                let message = reason == "secure input"
                    ? "Secure input active — copied, press ⌘V after leaving the password field"
                    : "Focus changed — copied, press ⌘V"
                self?.hud?.showError(message: message)
            } else {
                self?.hud?.showSuccess(text: text)
            }
        }

        print("\n\(ANSI.bold)📊 Latency Diagnostic Breakdown:\(ANSI.reset)")
        print("  • Primary Route:       \(ANSI.cyan)\(transport)\(ANSI.reset)")
        if let reason = fallbackReason {
            print("  • Fallback Used:       \(ANSI.bold)\(ANSI.yellow)YES ⚠️ [REST Fallback Route Invoked]\(ANSI.reset)")
            print("  • Fallback Reason:     \(ANSI.yellow)\(reason)\(ANSI.reset)")
            print("  • Fallback Model:      \(ANSI.bold)\(config.geminiModel)\(ANSI.reset)")
        } else {
            print("  • Fallback Used:       \(ANSI.green)NO (Direct Live Stream Complete)\(ANSI.reset)")
        }
        print("  • Audio Duration:      \(String(format: "%.2f", audioDuration))s")
        print("  • Capture Finalize:    \(String(format: "%.1f", captureFinalizeMs)) ms (post-roll + drain)")
        if firstTokenMs > 0 {
            print("  • First Token TTFT:    \(ANSI.bold)\(String(format: "%.1f", firstTokenMs)) ms\(ANSI.reset)")
        }
        print("  • API Roundtrip (RTT): \(ANSI.bold)\(String(format: "%.1f", roundtripMs)) ms\(ANSI.reset)")
        print("  • Injection Latency:   \(String(format: "%.1f", injectMs)) ms (\(injectStatus))")

        // Token usage & cost. API-metered when the server reported usageMetadata; otherwise a
        // deterministic estimate from the documented rates (25 audio tokens/sec + ~1s of
        // pre/post-roll & silence padding also billed; output ~4 chars/token).
        let usageMetered = (inputTokens != nil || outputTokens != nil)
        let effectiveInputTokens = inputTokens ?? Int((audioDuration + 1.0) * 25.0)
        let effectiveOutputTokens = outputTokens ?? max(1, text.count / 4)
        let inputPrice = isLiveRoute ? config.liveInputPricePer1M : config.restInputPricePer1M
        let outputPrice = isLiveRoute ? config.liveOutputPricePer1M : config.restOutputPricePer1M
        let turnCostUSD = Double(effectiveInputTokens) / 1_000_000.0 * inputPrice
                        + Double(effectiveOutputTokens) / 1_000_000.0 * outputPrice
        print("  • Tokens & Cost:       \(effectiveInputTokens) in / \(effectiveOutputTokens) out ≈ \(ANSI.bold)$\(String(format: "%.5f", turnCostUSD))\(ANSI.reset) \(ANSI.gray)(\(usageMetered ? "API metered" : "estimated"))\(ANSI.reset)")

        statsLock.lock()
        sessionTurns += 1
        sessionInputTokens += effectiveInputTokens
        sessionOutputTokens += effectiveOutputTokens
        sessionCostUSD += turnCostUSD
        statsLock.unlock()

        history?.record(TranscriptionHistoryStore.TurnRecord(
            outcome: "success",
            text: text,
            charCount: text.count,
            wordCount: text.split { $0.isWhitespace }.count,
            transport: transport,
            model: isLiveRoute ? config.geminiLiveModel : config.geminiModel,
            isLiveRoute: isLiveRoute,
            fallbackReason: fallbackReason,
            audioSeconds: audioDuration,
            firstTokenMs: firstTokenMs > 0 ? firstTokenMs : nil,
            roundtripMs: roundtripMs,
            captureFinalizeMs: captureFinalizeMs,
            injectMs: injectMs,
            totalMs: totalElapsedMs,
            injected: injected,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            tokensMetered: usageMetered,
            costUSD: turnCostUSD,
            languageCodes: config.languageCodes.joined(separator: ","),
            smartMode: config.smartTranscription,
            vadMode: config.vadMode,
            error: nil
        ))

        print("  • \(ANSI.bold)\(ANSI.green)Total Key-Up → Paste:\(ANSI.reset) \(ANSI.bold)\(ANSI.green)\(String(format: "%.1f", totalElapsedMs)) ms ⚡\(ANSI.reset)\n")

        processingLock.lock()
        isProcessing = false
        processingLock.unlock()
    }
    
    private func printBanner() {
        let langDisplay = config.languageCodes.isEmpty ? "\(ANSI.green)Auto (All 80+ Languages)\(ANSI.reset)" : "\(ANSI.green)\(config.languageCodes.joined(separator: ", "))\(ANSI.reset) \(ANSI.gray)(Prioritized)\(ANSI.reset)"
        print("""
        \(ANSI.bold)\(ANSI.cyan)
             _           _   ____                   _    
            | |_   _ ___| |_/ ___| _ __   ___  __ _| | __
         _  | | | | / __| __\\___ \\| '_ \\ / _ \\/ _` | |/ /
        | |_| | |_| \\__ \\ |_ ___) | |_) |  __/ (_| |   < 
         \\___/ \\__,_|___/\\__|____/| .__/ \\___|\\__,_|_|\\_\\
                                  |_|                    
        \(ANSI.reset)\(ANSI.bold)Ultra-Low-Latency Push-to-Talk macOS Voice Dictation\(ANSI.reset)
        \(ANSI.gray)Native Swift • CoreAudio Queue • Gemini Live WebSockets (TEXT Modality)\(ANSI.reset)
        
        Live WS Model:     \(ANSI.bold)\(config.geminiLiveModel)\(ANSI.reset)
        REST Fallback:     \(ANSI.bold)\(config.geminiModel)\(ANSI.reset)
        Language Support:  \(langDisplay)
        Configured Hotkey: \(ANSI.bold)\(config.hotkey)\(ANSI.reset) (\(config.hotkeyMode))
        Live WebSockets:   \(config.enableLiveWebSocket ? "\(ANSI.green)Enabled\(ANSI.reset)" : "\(ANSI.yellow)Disabled (REST Only)\(ANSI.reset)")
        Smart Transcribe:  \(config.smartTranscription ? "\(ANSI.green)Enabled (ITN + Disfluency Removal)\(ANSI.reset)" : "\(ANSI.gray)Verbatim Only\(ANSI.reset)")
        VAD Mode:          \(config.vadMode == "manual" ? "\(ANSI.green)Manual (push-to-talk defines speech bounds)\(ANSI.reset)" : config.vadMode == "tuned" ? "\(ANSI.yellow)Tuned Server VAD (\(config.vadSilenceMs)ms silence window)\(ANSI.reset)" : "\(ANSI.gray)Auto (stock server VAD)\(ANSI.reset)")
        Mic Idle Timeout:  \(config.micIdleTimeoutSec > 0 ? "\(ANSI.green)\(config.micIdleTimeoutSec)s (indicator turns off when idle)\(ANSI.reset)" : "\(ANSI.gray)Disabled (mic always on)\(ANSI.reset)")
        History DB:        \(config.historyEnabled ? "\(ANSI.green)\(history?.path ?? "Disabled")\(ANSI.reset)" : "\(ANSI.gray)Disabled\(ANSI.reset)")
        Custom Vocabulary: \(config.customVocabulary.isEmpty ? "\(ANSI.gray)None configured\(ANSI.reset)" : "\(ANSI.green)\(config.customVocabulary.count) terms active\(ANSI.reset) \(ANSI.gray)(\(config.customVocabulary.prefix(3).joined(separator: ", "))\(config.customVocabulary.count > 3 ? ", ..." : ""))\(ANSI.reset)")\(config.replacementRules.isEmpty ? "" : " \(ANSI.gray)(+ \(config.replacementRules.count) replacement rules)\(ANSI.reset)")
        Sound Feedback:    \(config.soundFeedback ? "\(ANSI.green)Enabled\(ANSI.reset)" : "\(ANSI.gray)Disabled\(ANSI.reset)")
        Floating HUD:      \(config.showHUD ? "\(ANSI.green)Enabled (Dynamic Island Pill)\(ANSI.reset)" : "\(ANSI.gray)Disabled\(ANSI.reset)")
        """)
    }
}

// MARK: - Standalone Diagnostic Tests

struct Diagnostics {
    static func runApiTest(config: Config) {
        print("\n\(ANSI.bold)Testing Gemini API Connectivity... Model: \(config.geminiModel)\(ANSI.reset)")
        
        guard !config.geminiApiKey.isEmpty else {
            Logger.error("TEST", "GEMINI_API_KEY is not configured in .env or environment.")
            exit(1)
        }
        
        let sampleRate = 16000
        var pcmData = Data()
        for i in 0..<sampleRate {
            let sample = Int16(sin(2.0 * Double.pi * 440.0 * Double(i) / Double(sampleRate)) * 16000.0)
            pcmData.append(contentsOf: sample.littleEndianBytes)
        }
        
        let semaphore = DispatchSemaphore(value: 0)
        
        Logger.info("TEST", "Sending test audio to Gemini REST endpoint...")
        GeminiRestClient.transcribe(pcmData: pcmData, apiKey: config.geminiApiKey, model: config.geminiModel, languageCodes: config.languageCodes, customVocabulary: config.customVocabulary) { result in
            defer { semaphore.signal() }
            switch result {
            case .success(let payload):
                Logger.success("TEST", "REST API Connectivity Successful! Latency: \(String(format: "%.1f", payload.latencyMs)) ms")
                print("  Response: \"\(payload.text)\"")
            case .failure(let error):
                Logger.error("TEST", "REST API test failed: \(error.localizedDescription)")
            }
        }
        
        _ = semaphore.wait(timeout: .now() + 10.0)
    }
    
    static func runAudioTest(config: Config) {
        print("\n\(ANSI.bold)Testing 3-Second Microphone Capture & Transcription... Speak into your mic now!\(ANSI.reset)")
        
        let engine = AudioCaptureEngine()
        guard engine.setup() else {
            Logger.error("TEST", "Failed to start AudioCaptureEngine.")
            return
        }
        
        engine.startRecording()
        SoundManager.playStartSound()
        
        for remaining in (1...3).reversed() {
            print("\(ANSI.cyan)Recording... \(remaining)s remaining\(ANSI.reset)")
            Thread.sleep(forTimeInterval: 1.0)
        }
        
        let (pcmData, duration, chunks, _) = engine.stopRecording()
        SoundManager.playCommitSound()
        engine.stopEngine()
        
        Logger.success("TEST", "Recorded \(String(format: "%.2f", duration))s audio (\(chunks) chunks, \(pcmData.count) bytes).")
        
        if config.geminiApiKey.isEmpty {
            Logger.warn("TEST", "Set GEMINI_API_KEY to test AI transcription.")
            return
        }
        
        let sema = DispatchSemaphore(value: 0)
        Logger.info("TEST", "Transcribing captured audio with Gemini...")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        GeminiRestClient.transcribe(pcmData: pcmData, apiKey: config.geminiApiKey, model: config.geminiModel, languageCodes: config.languageCodes, customVocabulary: config.customVocabulary) { result in
            defer { sema.signal() }
            switch result {
            case .success(let payload):
                let total = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                Logger.success("TEST", "Transcription Completed in \(String(format: "%.1f", total)) ms!")
                print("\n\(ANSI.bold)\(ANSI.green)Result:\(ANSI.reset) \"\(payload.text)\"\n")
            case .failure(let error):
                Logger.error("TEST", "Transcription failed: \(error.localizedDescription)")
            }
        }
        
        _ = sema.wait(timeout: .now() + 15.0)
    }
}

// MARK: - CLI Entry Point

let args = CommandLine.arguments
let config = Config.load()

if args.contains("--check-permissions") || args.contains("-p") {
    PermissionChecker.printDetailedStatus()
    exit(0)
}

if args.contains("--test-api") {
    Diagnostics.runApiTest(config: config)
    exit(0)
}

if args.contains("--test-audio") {
    Diagnostics.runAudioTest(config: config)
    exit(0)
}

if args.contains("--help") || args.contains("-h") {
    print("""
    JustSpeak - Ultra-Low-Latency Voice Dictation & Text Polishing
    
    Usage:
      swift justspeak.swift [options]
      make run
    
    Options:
      --check-permissions, -p   Run diagnostic permissions checker
      --test-audio              Test 3-second mic capture and AI transcription
      --test-api                Test Gemini API connection and latency
      --help, -h                Show this help message
    
    Configuration is managed via .env or environment variables.
    """)
    exit(0)
}

let app = JustSpeakApp(config: config)
app.start()
