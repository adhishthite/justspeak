// Explicit opt-in hardware check. No network, saved audio, clipboard, or transcription.
extension AudioCaptureEngine {
    func simulateHardwareConfigurationChange() {
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: audioEngine)
    }
}

func runHardwareMicCheck() -> Bool {
    guard CommandLine.arguments.count == 2 else { return false }
    let engine = AudioCaptureEngine(preRollMs: 0, silenceFlushMs: 0)
    let peer = Process()
    let peerOutput = Pipe()
    let peerLock = NSLock()
    var peerReady = false
    var peerLastBuffer: TimeInterval = 0
    var peerText = ""
    var readyChecks = 0
    var interruptions = 0
    var interruptedResults = 0
    engine.onCaptureInterrupted = { _ in interruptions += 1 }

    func pump(until predicate: () -> Bool, timeout: Double) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        return predicate()
    }
    func ready() -> Bool {
        var completed = false
        var result = false
        engine.ensureReady { success in
            result = success; completed = true
        }
        guard pump(until: { completed }, timeout: 4), result else { return false }
        readyChecks += 1
        return true
    }
    func peerIsReady() -> Bool {
        peerLock.lock(); defer { peerLock.unlock() }
        return peerReady && ProcessInfo.processInfo.systemUptime - peerLastBuffer < 0.75
    }
    defer {
        engine.stopEngine()
        peerOutput.fileHandleForReading.readabilityHandler = nil
        if peer.isRunning {
            peer.terminate()
            if !pump(until: { !peer.isRunning }, timeout: 2) { kill(peer.processIdentifier, SIGKILL) }
        }
        print("MIC_CHECK readiness=\(readyChecks) interruptions=\(interruptions) interrupted_results=\(interruptedResults)")
    }

    _ = engine.setup()
    guard ready() else { print("MIC_CHECK FAIL initial_readiness"); return false }
    peer.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    peer.arguments = ["-module-cache-path", NSTemporaryDirectory() + "justspeak-test-module-cache", CommandLine.arguments[1]]
    peer.standardOutput = peerOutput
    peer.standardError = FileHandle.nullDevice
    peerOutput.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        peerLock.lock()
        peerText += text
        peerReady = peerText.contains("PEER_READY")
        if peerReady { peerLastBuffer = ProcessInfo.processInfo.systemUptime }
        peerLock.unlock()
    }
    do { try peer.run() } catch { print("MIC_CHECK FAIL peer_launch"); return false }
    guard pump(until: { peerIsReady() || !peer.isRunning }, timeout: 12), peerIsReady(), peer.isRunning else {
        print("MIC_CHECK FAIL peer_readiness"); return false
    }
    let sharedUntil = ProcessInfo.processInfo.systemUptime + 1
    _ = pump(until: { ProcessInfo.processInfo.systemUptime >= sharedUntil }, timeout: 2)
    guard ready(), peer.isRunning, peerIsReady() else { print("MIC_CHECK FAIL concurrent_readiness"); return false }

    engine.simulateHardwareConfigurationChange()
    guard ready(), peer.isRunning, peerIsReady() else { print("MIC_CHECK FAIL idle_recovery"); return false }
    // Give the new stream a stable interval before the separate mid-turn interruption.
    let stableUntil = ProcessInfo.processInfo.systemUptime + 1.2
    _ = pump(until: { ProcessInfo.processInfo.systemUptime >= stableUntil }, timeout: 2)
    guard engine.startRecording() else { print("MIC_CHECK FAIL capture_start"); return false }
    let captureUntil = ProcessInfo.processInfo.systemUptime + 0.3
    _ = pump(until: { ProcessInfo.processInfo.systemUptime >= captureUntil }, timeout: 1)
    engine.simulateHardwareConfigurationChange()
    let capture = engine.stopRecording(gracePeriodMs: 0, maxTrailMs: 0, silenceThresholdDb: -45)
    guard capture.interrupted, interruptions == 1 else { print("MIC_CHECK FAIL interruption_gate"); return false }
    interruptedResults += 1
    guard ready(), peer.isRunning, peerIsReady() else { print("MIC_CHECK FAIL post_interruption_recovery"); return false }
    print("MIC_CHECK PASS")
    return true
}
exit(runHardwareMicCheck() ? 0 : 1)
