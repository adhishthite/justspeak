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
    // Latest RMS level while recording, polled by stopRecording's adaptive trailing-capture
    // wait; updated on every buffer (not just the 10Hz meter throttle) so the poll sees a
    // fresh reading.
    private var lastLevelDb: Double = -120.0
    private var lastLevelTime: CFAbsoluteTime = 0

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

            // RMS math runs for every buffer while recording (not just the meter's 10Hz
            // throttle) so stopRecording's adaptive trailing-capture poll always sees a fresh
            // level. int16Pointer is still valid here - it points into outputBuffer, a local
            // var alive for this call. Meter rendering and the onAudioLevel callback stay
            // gated by shouldUpdateMeter as before.
            var sumSquare: Double = 0.0
            let sampleCount = Int(outputBuffer.frameLength)
            for i in 0..<sampleCount {
                let sample = Double(int16Pointer[i])
                sumSquare += sample * sample
            }
            let rms = sqrt(sumSquare / Double(max(sampleCount, 1)))
            let db = 20.0 * log10(max(rms, 1.0) / 32768.0)

            lock.lock()
            lastLevelDb = db
            lastLevelTime = CFAbsoluteTimeGetCurrent()
            lock.unlock()

            if shouldUpdateMeter {
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
    
    func stopRecording(gracePeriodMs: Int, maxTrailMs: Int, silenceThresholdDb: Double) -> (pcmData: Data, duration: Double, chunkCount: Int, capturedBytes: Int) {
        // True hold duration is measured at entry, BEFORE the post-roll wait - otherwise the
        // grace period pads every tap past the caller's micro-click duration threshold.
        let stopRequestTime = CFAbsoluteTimeGetCurrent()

        // 1. Trailing capture: keep streaming while speech energy persists. gracePeriodMs is the
        // required continuous-quiet window; maxTrailMs the hard cap. maxTrailMs <= gracePeriodMs
        // degenerates to the old fixed post-roll. A stale level reading (engine stall) counts as
        // quiet so a wedged tap can never hold the turn to the cap.
        if gracePeriodMs <= 0 {
            // Adaptation and fixed post-roll both disabled - no wait.
        } else if maxTrailMs <= gracePeriodMs {
            usleep(useconds_t(gracePeriodMs * 1000))
        } else {
            let graceSec = Double(gracePeriodMs) / 1000.0
            let maxTrailSec = Double(maxTrailMs) / 1000.0
            var quietStart: CFAbsoluteTime? = nil
            while true {
                usleep(25_000)
                let now = CFAbsoluteTimeGetCurrent()
                lock.lock()
                let levelDb = lastLevelDb
                let levelTime = lastLevelTime
                lock.unlock()

                let speaking = (now - levelTime) <= 0.30 && levelDb >= silenceThresholdDb
                if speaking {
                    quietStart = nil
                } else if quietStart == nil {
                    quietStart = now
                }

                let elapsedSinceEntry = now - stopRequestTime
                if let qs = quietStart, (now - qs) >= graceSec, elapsedSinceEntry >= graceSec {
                    break
                }
                if elapsedSinceEntry >= maxTrailSec {
                    break
                }
            }

            let totalWaitMs = (CFAbsoluteTimeGetCurrent() - stopRequestTime) * 1000.0
            if totalWaitMs > Double(gracePeriodMs) + 1.0 {
                Logger.debug("AUDIO", "Trailing speech captured: +\(Int(totalWaitMs - Double(gracePeriodMs)))ms past post-roll")
            }
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

