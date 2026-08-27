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
        GeminiRestClient.transcribe(pcmData: pcmData, apiKey: config.geminiApiKey, model: config.geminiModel, languageCodes: config.languageCodes, customVocabulary: config.customVocabulary) {
            result in
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

        let (pcmData, duration, chunks, _) = engine.stopRecording(gracePeriodMs: config.postRollMs, maxTrailMs: config.postRollMaxMs, silenceThresholdDb: config.trailSilenceDb)
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
        GeminiRestClient.transcribe(pcmData: pcmData, apiKey: config.geminiApiKey, model: config.geminiModel, languageCodes: config.languageCodes, customVocabulary: config.customVocabulary) {
            result in
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
