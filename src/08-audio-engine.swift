// MARK: - Audio Capture Engine with Pre-roll Ring Buffer & Offloaded Threading

final class AudioCaptureEngine {
    private let audioEngine = AVAudioEngine()
    private var audioConverter: AVAudioConverter?
    private let targetFormat: AVAudioFormat

    // Dedicated background audio processing queue (keeps CoreAudio render thread non-blocking)
    private let audioProcessingQueue = DispatchQueue(label: "com.justspeak.audioProcessing", qos: .userInteractive)

    private let lock = NSLock()
    private(set) var isRecording: Bool = false
    private(set) var isEngineRunning: Bool = false  // main-thread-only (setup/suspend/resume)
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

    // Streaming chunk accumulator (CHUNK_MS; default 150ms = 4800 bytes, docs suggest ~100ms
    // for the dedicated transcribe model)
    private var pendingChunkBuffer = Data()
    private let streamingChunkTargetBytes: Int

    // Synthetic trailing silence appended at stopRecording (SILENCE_FLUSH_MS; 0 disables)
    private let silenceFlushBytes: Int

    // Silence-gate statistics, accumulated inline as audio arrives so stopRecording never
    // rescans the whole clip on the key-up critical path. Framing is continuous across
    // chunks AND across the pre-roll/live boundary, matching the old whole-clip scan
    // exactly. All under `lock`; per-frame dB values are classified against the caller's
    // threshold at stopRecording time (the threshold is a stopRecording argument).
    private static let speechFrameSamples = 320  // 20ms of 16kHz mono
    private var turnMaxAbsSample: Int32 = 0
    private var frameSumSquares: Double = 0
    private var frameSampleCount: Int = 0
    private var frameDbValues: [Double] = []
    private var statSampleCount: Int = 0

    var onAudioChunk: ((Data) -> Void)?
    var onAudioLevel: ((Double) -> Void)?

    // Main-thread-only (written in setup and the configuration-change handler, read at
    // key-down): the device the engine is actually capturing from, for the log and the
    // history row. Never assume the system default - an external display's mic often is.
    private(set) var currentInput: InputDeviceCatalog.Device?
    private let preferredInputDevice: String
    private var autoInput: Bool { preferredInputDevice.lowercased() == "auto" }
    // Main-thread-only: a lid flip arrived mid-dictation; re-pin once the turn is over.
    private var pendingReselect = false

    init(preRollMs: Int = 400, chunkMs: Int = 150, silenceFlushMs: Int = 700, inputDevice: String = "") {
        self.preferredInputDevice = inputDevice
        // Standard 16kHz 16-bit Mono Linear PCM for speech AI models
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000.0,
            channels: 1,
            interleaved: true
        )!
        // 16,000 samples/sec * 2 bytes/sample = 32 bytes per ms
        self.maxPreRollBytes = max(0, preRollMs * 32)
        self.streamingChunkTargetBytes = max(640, chunkMs * 32)
        self.silenceFlushBytes = max(0, silenceFlushMs * 32)
    }

    func setup() -> Bool {
        let inputNode = audioEngine.inputNode
        applyInputDeviceSelection()
        let inputFormat = inputNode.outputFormat(forBus: 0)

        Logger.info("MIC", "Input device: \(currentInputLabel)")
        Logger.info("MIC", "Hardware format: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch, \(inputFormat.formatDescription)")
        Logger.info("MIC", "Target format: 16000 Hz, 1 ch, 16-bit Linear PCM")

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            Logger.error("MIC", "Failed to construct AVAudioConverter from \(inputFormat) to \(targetFormat)")
            return false
        }
        self.audioConverter = converter

        installTap(on: inputNode, format: inputFormat)

        // Device changes (AirPods connect/disconnect, default-input switch) invalidate both
        // the tap's captured format and the converter; AVAudioEngine posts this after
        // reconfiguring itself. Handled on main - isEngineRunning is main-thread-only.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
        // A lid open/close with an external display attached always reshuffles the screen
        // list; that's the trigger for INPUT_DEVICE=auto (the HAL itself often stays quiet).
        if autoInput {
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.reselectForLidState()
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

    // Tap callback: ONLY copies incoming buffer and pushes to serial audio queue (0 blocking operations on render thread)
    private func installTap(on inputNode: AVAudioInputNode, format: AVAudioFormat) {
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] (buffer, when) in
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
    }

    // Main-thread-only (observer queue is .main). Rebuilds the tap and converter around the
    // new input device's format, then restarts the engine only if it was meant to be running
    // (an idle-suspended mic stays suspended; the next key-down re-arms it as usual).
    private func handleConfigurationChange() {
        // The engine has already stopped itself; a pinned INPUT_DEVICE must survive the
        // default-input flip that usually triggers this (if the pinned device vanished, the
        // HAL has already fallen back).
        rebuildInput(wasRunning: isEngineRunning, reason: "Input device changed")
    }

    // INPUT_DEVICE=auto, main-thread-only. No-op unless the lid state now wants a different
    // device than the unit is on; deferred to the end of the turn while recording (the
    // rebuild would drop the buffers mid-dictation).
    func reselectForLidState() {
        guard autoInput else { return }
        let devices = InputDeviceCatalog.inputDevices()
        guard let target = targetInput(in: devices), let unit = audioEngine.inputNode.audioUnit,
            activeDevice(of: unit) != target.id
        else { return }

        lock.lock()
        let recording = isRecording
        lock.unlock()
        if recording {
            pendingReselect = true
            return
        }
        pendingReselect = false
        let wasRunning = isEngineRunning
        if wasRunning { audioEngine.stop() }
        rebuildInput(wasRunning: wasRunning, reason: "Lid \(InputDeviceCatalog.lidClosed() == true ? "closed" : "open")")
    }

    // Main-thread-only, called after each turn settles.
    func applyPendingReselect() {
        guard pendingReselect else { return }
        reselectForLidState()
    }

    // Engine must already be stopped (or never started). Pins/records the input device,
    // rebuilds the tap and converter around its format, restarts only if it was running.
    private func rebuildInput(wasRunning: Bool, reason: String) {
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        applyInputDeviceSelection()
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            Logger.error("MIC", "\(reason) but converter rebuild failed (\(inputFormat)) - dictation disabled until restart.")
            isEngineRunning = false
            return
        }
        // audioConverter is read on audioProcessingQueue; hop onto it so the swap can't
        // tear a conversion in progress. (A stale-format buffer already queued just fails
        // its convert and is dropped - one buffer, ~64ms, at worst.)
        audioProcessingQueue.sync { self.audioConverter = converter }

        installTap(on: inputNode, format: inputFormat)

        lock.lock()
        let recording = isRecording
        lock.unlock()
        if recording {
            Logger.warn("MIC", "Input device changed mid-dictation - this turn may be truncated.")
        }

        if wasRunning {
            audioEngine.prepare()
            do {
                try audioEngine.start()
                isEngineRunning = true
                Logger.info("MIC", "\(reason) - engine rebuilt on \(currentInputLabel) (\(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) ch).")
            } catch {
                isEngineRunning = false
                Logger.error("MIC", "\(reason) and engine restart failed: \(error.localizedDescription) - next key-down will retry.")
            }
        } else {
            Logger.info("MIC", "\(reason) while mic idle - tap rebuilt for \(currentInputLabel).")
        }
    }

    private func targetInput(in devices: [InputDeviceCatalog.Device]) -> InputDeviceCatalog.Device? {
        if autoInput {
            return InputDeviceCatalog.autoSelection(in: devices, lidClosed: InputDeviceCatalog.lidClosed() ?? false)
        }
        return InputDeviceCatalog.match(preferredInputDevice, in: devices)
    }

    var currentInputLabel: String {
        guard let d = currentInput else { return "unknown input" }
        return d.label + (d.isDefault ? " (system default)" : "")
    }

    // Pins the AUHAL behind inputNode to the configured device (the property must be set
    // before the engine initializes the unit, which prepare()/start() does), then records
    // whichever device the unit ended up on - pinned, or the default when nothing matched.
    private func applyInputDeviceSelection() {
        let devices = InputDeviceCatalog.inputDevices()
        let unit = audioEngine.inputNode.audioUnit

        if !preferredInputDevice.isEmpty {
            if let match = targetInput(in: devices) {
                // Skip the write when already on the device: on a configuration change the
                // unit is initialized and the property write would fail, but the pin holds.
                if let unit = unit, activeDevice(of: unit) != match.id {
                    var deviceID = match.id
                    let status = AudioUnitSetProperty(
                        unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                        &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
                    if status != noErr {
                        Logger.warn("MIC", "Could not pin input to \(match.label) (OSStatus \(status)) - using whatever the engine has.")
                    }
                }
            } else if !autoInput {
                let available = devices.map { $0.name }.joined(separator: ", ")
                Logger.warn("MIC", "INPUT_DEVICE \"\(preferredInputDevice)\" matched no input device - using the system default. Available: \(available)")
            }
        }

        if let unit = unit, let activeID = activeDevice(of: unit) {
            currentInput =
                devices.first(where: { $0.id == activeID })
                ?? InputDeviceCatalog.describe(activeID, isDefault: activeID == InputDeviceCatalog.defaultInputDevice())
        } else {
            currentInput = devices.first(where: { $0.isDefault })
        }
    }

    private func activeDevice(of unit: AudioUnit) -> AudioDeviceID? {
        var activeID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &activeID, &size)
        guard status == noErr, activeID != 0 else { return nil }
        return activeID
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
            accumulateStats(samples: int16Pointer, count: Int(outputBuffer.frameLength))

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

            // Audio delivery leads everything else on this queue: stdout is unbuffered and the
            // meter write below is a synchronous flush, so a slow or blocked terminal must
            // never sit between a finished chunk and its trip to the WebSocket.
            if let toStream = toStream {
                onAudioChunk?(toStream)
            }

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

            // HUD level first, terminal meter last - the print is the only call here that can
            // block on an external consumer.
            if shouldUpdateMeter {
                onAudioLevel?(db)
                let meterBars = renderVolumeMeter(db: db)
                Logger.meter(
                    "\(ANSI.bold)\(ANSI.yellow)🎙️  RECORDING\(ANSI.reset) [\(meterBars)] \(String(format: "%5.1f", db)) dB | \(String(format: "%.2fs", elapsed)) | \(String(format: "%.1f", kbStreamed)) KB streamed (#\(chunkCountSnapshot))"
                )
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

    // Assumes `lock` is held. Streams samples into the peak + 20ms-frame RMS accumulators.
    // Pure math - no I/O or callbacks under the lock.
    private func accumulateStats(samples: UnsafePointer<Int16>, count: Int) {
        for i in 0..<count {
            let s = Int32(samples[i])
            let a = abs(s)
            if a > turnMaxAbsSample { turnMaxAbsSample = a }
            let norm = Double(s) / 32768.0
            frameSumSquares += norm * norm
            frameSampleCount += 1
            if frameSampleCount == Self.speechFrameSamples {
                let rms = (frameSumSquares / Double(Self.speechFrameSamples)).squareRoot()
                frameDbValues.append(20 * log10(max(rms, 1e-9)))
                frameSumSquares = 0
                frameSampleCount = 0
            }
        }
        statSampleCount += count
    }

    // Assumes `lock` is held. Byte-pair assembly because Data's storage isn't guaranteed
    // 2-byte aligned; only used for the pre-roll (≤400ms), live audio feeds the pointer
    // variant directly.
    private func accumulateStats(data: Data) {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return }
        var samples = [Int16](repeating: 0, count: sampleCount)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<sampleCount {
                samples[i] = Int16(bitPattern: UInt16(raw[2 * i]) | (UInt16(raw[2 * i + 1]) << 8))
            }
        }
        samples.withUnsafeBufferPointer { buf in
            accumulateStats(samples: buf.baseAddress!, count: buf.count)
        }
    }

    func startRecording() {
        lock.lock()
        recordedPCMData.removeAll(keepingCapacity: true)
        pendingChunkBuffer.removeAll(keepingCapacity: true)
        turnMaxAbsSample = 0
        frameSumSquares = 0
        frameSampleCount = 0
        frameDbValues.removeAll(keepingCapacity: true)
        statSampleCount = 0

        // Prepend rolling pre-roll buffer to prevent clipped first syllable
        preRollBytesInTurn = 0
        var immediatePreRollChunk: Data? = nil
        if !preRollRingBuffer.isEmpty {
            preRollBytesInTurn = preRollRingBuffer.count
            recordedPCMData.append(preRollRingBuffer)
            immediatePreRollChunk = preRollRingBuffer
            // Pre-roll bytes bypass the live accumulation below (they were captured while
            // idle), so their stats are folded in once here - a ≤400ms scan, off the key-up
            // path entirely.
            accumulateStats(data: preRollRingBuffer)
            preRollRingBuffer.removeAll(keepingCapacity: true)
        }

        chunkCount = 0
        recordingStartTime = CFAbsoluteTimeGetCurrent()
        lastMeterUpdateTime = 0
        isRecording = true
        lock.unlock()

        // Immediately dispatch pre-roll audio to WebSocket so speech model receives head-start
        // audio - split into streaming-target-sized frames rather than one oversized payload
        // (the whole pre-roll still goes out right now; only the framing changes).
        if let chunk = immediatePreRollChunk {
            var offset = chunk.startIndex
            while offset < chunk.endIndex {
                let end = chunk.index(offset, offsetBy: streamingChunkTargetBytes, limitedBy: chunk.endIndex) ?? chunk.endIndex
                onAudioChunk?(chunk.subdata(in: offset..<end))
                offset = end
            }
        }
    }

    func stopRecording(gracePeriodMs: Int, maxTrailMs: Int, silenceThresholdDb: Double) -> (pcmData: Data, duration: Double, chunkCount: Int, capturedBytes: Int, peakDb: Double?, speechFrames: Int) {
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
        audioProcessingQueue.sync {}

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

        // 5. Append the acoustic lookahead silence flush (SILENCE_FLUSH_MS; default 700ms =
        // 22,400 bytes @ 16kHz 16-bit mono). This satisfies the lookahead window speech
        // encoders need to finalize trailing words; appended AFTER stat accumulation stopped,
        // so the silence gate never sees it regardless of duration.
        let silenceData = Data(count: silenceFlushBytes)
        if !silenceData.isEmpty {
            recordedPCMData.append(silenceData)
        }

        let data = recordedPCMData
        let duration = stopRequestTime - recordingStartTime
        let chunks = chunkCount

        // 6. Silence-gate stats from the running accumulators - no rescan of the clip. The
        // silence flush above was appended AFTER accumulation stopped, so it can never mask
        // genuine silence; nil peak means zero real (pre-roll + key-held) samples, which
        // callers treat as "not silent", matching the old too-short-clip behavior.
        let peakDb: Double? = statSampleCount > 0 ? 20 * log10(max(Double(turnMaxAbsSample), 1.0) / 32768.0) : nil
        var speechFrames = 0
        for db in frameDbValues where db > silenceThresholdDb { speechFrames += 1 }
        lock.unlock()

        // 7. Fire chunk callbacks outside the lock. Ordering preserved: trailing real audio first, then silence.
        if let trailing = trailingChunk {
            onAudioChunk?(trailing)
        }
        if !silenceData.isEmpty {
            onAudioChunk?(silenceData)
        }

        Logger.endMeter()
        return (data, duration, chunks, capturedBytes, peakDb, speechFrames)
    }

    func stopEngine() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
    }
}
