// MARK: - Gemini Live WebSocket Client (TEXT Modality + Manual Activity Detection + Auto-Reconnect)

final class GeminiLiveClient: NSObject, URLSessionWebSocketDelegate {
    private let apiKey: String
    private let model: String
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession!

    private let lock = NSLock()
    private var connectedState = false
    private var readyState = false
    private var connectionID: UInt64 = 0
    private var turnID: UInt64 = 0
    private var turnOpen = false
    private var turnHasAudioGap = false
    private var rotateWhenIdle = false
    private var reconnectEnabled = true
    private let sendQueue = DispatchQueue(label: "com.justspeak.send", qos: .userInitiated)
    private var turnWrites = DispatchGroup()
    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return connectedState }
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return readyState }
    var canCommitTurn: Bool {
        lock.lock(); defer { lock.unlock() }
        return readyState && turnOpen && !turnHasAudioGap
    }

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
    private var completedUsage: (inputTokens: Int, outputTokens: Int)?

    /// API-reported usage for the current/most recent turn, or nil if the server reported
    /// nothing new this turn (caller falls back to a duration-based estimate).
    var lastTurnUsage: (inputTokens: Int, outputTokens: Int)? {
        lock.lock()
        defer { lock.unlock() }
        if hasFiredTurnCompletion { return completedUsage }
        return usageSnapshot()
    }

    private func usageSnapshot() -> (inputTokens: Int, outputTokens: Int)? {
        let dp = lastSeenPromptTokens - turnBaselinePromptTokens
        let dr = lastSeenResponseTokens - turnBaselineResponseTokens
        guard dp > 0 || dr > 0 else { return nil }
        return (max(0, dp), max(0, dr))
    }
    // Which settlement rule ended the last turn - the mechanism WS_ENDPOINT_ALIGNED changes,
    // recorded per turn in history. Under `lock`; read via lastSettlePath after completion
    // (same pattern as lastTurnUsage).
    private var settlePathValue: String?
    var lastSettlePath: String? {
        lock.lock()
        defer { lock.unlock() }
        return settlePathValue
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
    private let endpointAligned: Bool

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
    // Settlement and deadlines use monotonic time; keep the existing scheduling allowance.
    private static let settleTimerCushion: Double = 0.01
    private let settleQueue = DispatchQueue(label: "com.justspeak.settle")
    private var settleWorkItem: DispatchWorkItem?  // reschedulable: initial-wait-without-tokens, then quiet-window checks
    private var settleMaxWorkItem: DispatchWorkItem?  // fixed hard ceiling check
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempts: Int = 0

    init(
        apiKey: String,
        model: String = "gemini-3.5-transcribe-live",
        smartTranscription: Bool = true,
        languageCodes: [String] = ["en-IN", "mr-IN"],
        customVocabulary: [String] = [],
        vadMode: String = "manual",
        vadSilenceMs: Int = 1500,
        endpointAligned: Bool = false
    ) {
        self.apiKey = apiKey
        self.model = model
        self.smartTranscription = smartTranscription
        self.languageCodes = languageCodes
        self.customVocabulary = customVocabulary
        self.vadMode = vadMode
        self.vadSilenceMs = vadSilenceMs
        self.endpointAligned = endpointAligned
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 10.0
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func connect(onlyWhenIdle: Bool = false, expectedConnection: UInt64? = nil) {
        guard !apiKey.isEmpty else { return }

        let wsUrlString = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        guard let url = URL(string: wsUrlString) else {
            Logger.error("WS", "Invalid WebSocket URL.")
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let task = urlSession.webSocketTask(with: request)
        lock.lock()
        if let expected = expectedConnection, expected != connectionID || !reconnectEnabled {
            lock.unlock(); task.cancel(with: .goingAway, reason: nil); return
        }
        if onlyWhenIdle && turnOpen && readyState {
            rotateWhenIdle = true
            lock.unlock(); task.cancel(with: .goingAway, reason: nil); return
        }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectEnabled = true
        connectionID &+= 1
        let epoch = connectionID
        let old = webSocketTask
        self.webSocketTask = task
        readyState = false
        connectedState = false
        if turnOpen { turnHasAudioGap = true }
        rotateWhenIdle = false
        lock.unlock()
        old?.cancel(with: .goingAway, reason: nil)
        task.resume()

        Logger.info("WS", "Connecting to Gemini Live WebSockets (\(model))...")
        sendSetupMessage(task: task, epoch: epoch)
        listenForMessages(task: task, epoch: epoch)
    }

    private func sendSetupMessage(task: URLSessionWebSocketTask, epoch: UInt64) {
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
                "inputAudioTranscription": transcriptionConfig,
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
                        "silenceDurationMs": vadSilenceMs,
                    ],
                    "turnCoverage": "TURN_INCLUDES_ALL_INPUT",
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
                        ],
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
                    ],
                ]
            ]
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: setupPayload),
            let jsonString = String(data: jsonData, encoding: .utf8)
        else {
            Logger.error("WS", "Failed to serialize setup message.")
            return
        }

        task.send(.string(jsonString)) { [weak self] error in
            if let error = error { self?.connectionFailed(epoch: epoch, error: error) }
        }
    }

    private func connectionFailed(epoch: UInt64, error: Error) {
        lock.lock()
        guard epoch == connectionID else { lock.unlock(); return }
        readyState = false
        connectedState = false
        if turnOpen { turnHasAudioGap = true }
        let completion = hasFiredTurnCompletion ? nil : turnCompletion
        turnCompletion = nil
        if completion != nil { hasFiredTurnCompletion = true; isCommitting = false }
        lock.unlock()
        completion?(.failure(error))
        scheduleReconnect(epoch: epoch)
    }

    private func listenForMessages(task: URLSessionWebSocketTask, epoch: UInt64) {
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                self.handleIncomingMessage(message, epoch: epoch)
                self.lock.lock()
                let current = self.connectionID == epoch
                self.lock.unlock()
                if current { self.listenForMessages(task: task, epoch: epoch) }
            case .failure(let error): self.connectionFailed(epoch: epoch, error: error)
            }
        }
    }

    private func handleIncomingMessage(_ message: URLSessionWebSocketTask.Message, epoch: UInt64) {
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
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
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
        var messageTurn: UInt64 = 0

        lock.lock()

        guard epoch == connectionID else { lock.unlock(); return }

        messageTurn = turnID

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
            self.connectedState = true
            self.readyState = true
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
            rotateWhenIdle = true
            shouldScheduleReconnect = !turnOpen
        }
        // 3. Server content (transcription streaming)
        else if turnOpen, let serverContent = json["serverContent"] as? [String: Any] {
            var updatedText: String? = nil
            var isUserSpeech = false
            var isFinalTranscription = false

            // PRIORITY 1: Finalized inputTranscription (e.g. gemini-3.5-transcribe-live) -
            // closes the current speech segment; earlier segments must be preserved.
            if let inputTrans = serverContent["inputTranscription"] as? [String: Any],
                let text = inputTrans["text"] as? String, !text.isEmpty
            {
                applyFinalTranscription(text)
                updatedText = mergedTranscript()
                isUserSpeech = true
                isFinalTranscription = true
            }
            // PRIORITY 2: Progressive Interim Transcription - rewrites only the live segment.
            else if let interim = serverContent["interimInputTranscription"] as? [String: Any],
                let text = interim["text"] as? String, !text.isEmpty
            {
                applyInterimTranscription(text)
                updatedText = mergedTranscript()
                isUserSpeech = true
            }
            // PRIORITY 3: Alternative inputAudioTranscription (finalized form)
            else if let inputAudio = serverContent["inputAudioTranscription"] as? [String: Any],
                let text = inputAudio["text"] as? String, !text.isEmpty
            {
                applyFinalTranscription(text)
                updatedText = mergedTranscript()
                isUserSpeech = true
                isFinalTranscription = true
            }
            // PRIORITY 4: Multimodal text delta from modelTurn (raw append, no segmentation)
            else if let modelTurn = serverContent["modelTurn"] as? [String: Any],
                let parts = modelTurn["parts"] as? [[String: Any]]
            {
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
                let text = outputTranscription["text"] as? String, !text.isEmpty
            {
                committedTranscript += text
                updatedText = mergedTranscript()
            }

            if let newText = updatedText {
                let now = ProcessInfo.processInfo.systemUptime
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

            if (isTurnComplete || isGenComplete) && isCommitting && !turnHasAudioGap && !currentTurnText.isEmpty && !hasFiredTurnCompletion {
                turnOpen = false
                shouldScheduleReconnect = rotateWhenIdle
                completedUsage = usageSnapshot()
                hasFiredTurnCompletion = true
                isCommitting = false
                settlePathValue = "server_turn_complete"
                settleWorkItem?.cancel()
                settleWorkItem = nil
                settleMaxWorkItem?.cancel()
                settleMaxWorkItem = nil

                let totalLatencyMs = (ProcessInfo.processInfo.systemUptime - turnCommitTime) * 1000.0
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
            _ = msg
            connectionFailed(epoch: epoch, error: NSError(domain: "JustSpeak", code: -3, userInfo: [NSLocalizedDescriptionKey: "Live API rejected the request."]))
        }
        if didCompleteSetup {
            Logger.success("WS", "Gemini Live session established & ready for streaming.")
        }
        if shouldScheduleReconnect {
            Logger.warn("WS", "Server sent goAway signal. Preemptively scheduling reconnect...")
            self.scheduleReconnect(epoch: epoch, onlyWhenIdle: true)
        }
        // Callbacks fire before any terminal write: stdout is unbuffered and a slow consumer
        // must never delay the HUD update or the turn's completion. The completion is invoked
        // directly - its only consumer immediately hops onto the app's sessionQueue, so the
        // old DispatchQueue.global() bounce added a scheduling hop for nothing.
        if let update = liveTextUpdate {
            onLiveTextUpdate?(update.textCopy)
            Logger.meter(
                "\(ANSI.bold)\(ANSI.cyan)\(update.label)\(ANSI.reset) [\(String(format: "%.0f", update.elapsedMs))ms]: \(ANSI.bold)\(update.fullText.replacingOccurrences(of: "\n", with: " "))\(ANSI.reset)"
            )
        }
        if let fire = turnCompletionFire {
            fire.completion?(.success((text: fire.text, firstTokenMs: fire.firstTokenMs, totalMs: fire.totalMs)))
            Logger.endMeter()
        }
        // A post-commit token arrived: (re)schedule the quiet-window settle check, never
        // earlier than minPostCommitWait after commit. Scheduling happens off-lock; the
        // pointer swap that replaces the previous pending item is its own short lock scope.
        if let elapsedSinceCommit = quietRescheduleElapsedSinceCommit {
            lock.lock()
            let expectedTurn = messageTurn
            let shouldSchedule = turnID == messageTurn && isCommitting && !hasFiredTurnCompletion
            lock.unlock()
            guard shouldSchedule else { return }
            let delay: Double
            if quietRescheduleIsFinal {
                delay = Self.settleFinalGrace + Self.settleTimerCushion
            } else {
                let quiet = usesManualActivity ? Self.settleInterimQuietManual : Self.settleQuietWindow
                delay = max(quiet, Self.settleMinPostCommitWait - elapsedSinceCommit) + Self.settleTimerCushion
            }
            let item = DispatchWorkItem { [weak self] in self?.attemptSettle(turn: expectedTurn) }
            lock.lock()
            guard turnID == expectedTurn, isCommitting, !hasFiredTurnCompletion else { lock.unlock(); return }
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
    private func attemptSettle(turn: UInt64) {
        lock.lock()
        guard turn == turnID, isCommitting, !hasFiredTurnCompletion else {
            lock.unlock()
            return
        }

        if turnHasAudioGap {
            let epoch = connectionID
            lock.unlock()
            connectionFailed(
                epoch: epoch,
                error: NSError(
                    domain: "JustSpeak", code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "Live connection missed part of the recording."]))
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsedCommit = now - turnCommitTime
        let text = currentTurnText
        let postCommitTokenTime = lastPostCommitTokenTime
        let postCommitFinalTime = lastPostCommitFinalTime

        var settleWithText = false
        var firedRule = ""
        if let finalTime = postCommitFinalTime {
            // An authoritative final transcription landed: settle after only a short grace
            // (long enough for a trailing segment's final to displace this timer), with no
            // minimum-wait floor - waiting longer adds latency, not accuracy.
            settleWithText = !text.isEmpty && (now - finalTime) >= Self.settleFinalGrace
            firedRule = "final_grace"
        } else if let postTime = postCommitTokenTime {
            // Only speculative interims so far. In manual-activity mode a final is expected,
            // so wait longer before pasting speculation; otherwise use the tight quiet window.
            let quietWindow = usesManualActivity ? Self.settleInterimQuietManual : Self.settleQuietWindow
            let quietSincePostToken = now - postTime
            settleWithText = elapsedCommit >= Self.settleMinPostCommitWait && !text.isEmpty && quietSincePostToken >= quietWindow
            firedRule = "quiet_window"
        } else if !text.isEmpty && elapsedCommit >= Self.settleInitialWaitWithoutTokens {
            settleWithText = true
            firedRule = "initial_wait"
        }

        let timedOut = !settleWithText && elapsedCommit >= Self.settleMaxWait
        guard settleWithText || timedOut else {
            lock.unlock()
            return
        }

        completedUsage = usageSnapshot()
        hasFiredTurnCompletion = true
        isCommitting = false
        turnOpen = false
        settlePathValue = timedOut ? "timeout" : firedRule
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

        // A heuristic finish has no server boundary. Retire its socket before another turn
        // can accept delayed words from this one.
        connect()

        // Completion before the terminal write, and directly on settleQueue - the consumer
        // re-dispatches onto sessionQueue itself, so the extra global-queue hop bought nothing.
        if !text.isEmpty {
            cb?(.success((text: text, firstTokenMs: firstToken, totalMs: totalLatencyMs)))
        } else {
            cb?(.failure(NSError(domain: "JustSpeak", code: -2, userInfo: [NSLocalizedDescriptionKey: "No speech recognized before timeout."])))
        }
        Logger.endMeter()
    }

    func startNewTurn() {
        lock.lock()
        let abandoned = turnOpen
        lock.unlock()
        if abandoned { abandonTurn() }
        lock.lock()
        turnID &+= 1
        turnOpen = true
        turnHasAudioGap = !readyState
        turnWrites = DispatchGroup()
        self.settleWorkItem?.cancel()
        self.settleWorkItem = nil
        self.settleMaxWorkItem?.cancel()
        self.settleMaxWorkItem = nil
        self.isCommitting = false
        self.settlePathValue = nil
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
        self.completedUsage = nil
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
                let startStr = String(data: startJson, encoding: .utf8)
            {
                sendTurnMessage(startStr)
            }
        }
    }

    // Base64's alphabet (A-Za-z0-9+/=) needs no JSON escaping, so the fixed-shape
    // envelope is built once and the payload is spliced in directly, skipping
    // JSONSerialization on the hot per-chunk (~150ms) path.
    private static let audioChunkJSONPrefix = "{\"realtimeInput\":{\"audio\":{\"mimeType\":\"audio/pcm;rate=16000\",\"data\":\""
    private static let audioChunkJSONSuffix = "\"}}}"

    private func sendTurnMessage(_ text: String) {
        lock.lock()
        guard readyState, turnOpen, let task = webSocketTask else {
            if turnOpen { turnHasAudioGap = true }
            lock.unlock()
            return
        }
        let epoch = connectionID
        let turn = turnID
        let writes = turnWrites
        writes.enter()
        lock.unlock()
        sendQueue.async { [weak self] in
            guard let self = self else { writes.leave(); return }
            self.lock.lock()
            let current = epoch == self.connectionID && turn == self.turnID && self.turnOpen
            self.lock.unlock()
            guard current else { writes.leave(); return }
            task.send(.string(text)) { [weak self] error in
                if let self = self, let error = error {
                    self.lock.lock()
                    let current = self.turnID == turn && self.connectionID == epoch
                    self.lock.unlock()
                    if current { self.connectionFailed(epoch: epoch, error: error) }
                }
                writes.leave()
            }
        }
    }

    func sendAudioChunk(_ pcmChunk: Data) {
        sendTurnMessage(Self.audioChunkJSONPrefix + pcmChunk.base64EncodedString() + Self.audioChunkJSONSuffix)
    }

    func commitTurn(completion: @escaping (Result<(text: String, firstTokenMs: Double, totalMs: Double), Error>) -> Void) {
        lock.lock()
        let writes = turnWrites
        let expectedTurn = turnID
        lock.unlock()
        writes.notify(queue: sendQueue) { [weak self] in
            self?.beginCommit(turn: expectedTurn, completion: completion)
        }
    }

    private func beginCommit(turn expectedTurn: UInt64, completion: @escaping (Result<(text: String, firstTokenMs: Double, totalMs: Double), Error>) -> Void) {
        lock.lock()
        guard expectedTurn == turnID, turnOpen, readyState, !turnHasAudioGap else {
            lock.unlock()
            completion(.failure(NSError(domain: "JustSpeak", code: -4, userInfo: [NSLocalizedDescriptionKey: "Live connection missed part of the recording."])))
            return
        }
        self.turnCommitTime = ProcessInfo.processInfo.systemUptime
        self.isCommitting = true
        self.lastPostCommitTokenTime = nil
        self.lastPostCommitFinalTime = nil
        self.turnCompletion = completion
        self.hasFiredTurnCompletion = false
        lock.unlock()

        // End-of-turn signaling. Legacy (shipped) behavior sends all three of audioStreamEnd,
        // activityEnd and clientContent.turnComplete. The dedicated transcribe docs show only
        // ONE terminator per VAD mode (manual -> activityEnd; auto/tuned -> audioStreamEnd)
        // and never clientContent.turnComplete - WS_ENDPOINT_ALIGNED opts into that shape for
        // A/B testing. Conversational models are never aligned: clientContent.turnComplete is
        // what triggers their generation.
        let aligned = endpointAligned && model.contains("transcribe")

        // 1. audioStreamEnd flushes the audio encoder pipeline (aligned manual mode omits it:
        // the docs' manual recipe ends with activityEnd alone).
        if !(aligned && usesManualActivity) {
            let endAudioPayload: [String: Any] = [
                "realtimeInput": [
                    "audioStreamEnd": true
                ]
            ]
            if let endAudioJson = try? JSONSerialization.data(withJSONObject: endAudioPayload),
                let endAudioStr = String(data: endAudioJson, encoding: .utf8)
            {
                sendTurnMessage(endAudioStr)
            }
        }

        // 2. Dispatch manual activityEnd: the key release IS the end of speech whenever
        // server VAD is disabled (in legacy mode after audioStreamEnd, so all buffered audio
        // lands inside the activity window)
        if usesManualActivity {
            let endPayload: [String: Any] = [
                "realtimeInput": [
                    "activityEnd": [:]
                ]
            ]
            if let endJson = try? JSONSerialization.data(withJSONObject: endPayload),
                let endStr = String(data: endJson, encoding: .utf8)
            {
                sendTurnMessage(endStr)
            }
        }

        // 3. Dispatch turnComplete signal to finalize transcript (legacy only). NOTE for the
        // A/B: the server may currently be echoing turnComplete back, which settles the turn
        // immediately in handleIncomingMessage - aligned mode shifts settlement onto the
        // attemptSettle timers, so compare latency in BOTH directions before adopting.
        if !aligned {
            let commitPayload: [String: Any] = [
                "clientContent": [
                    "turnComplete": true
                ]
            ]

            guard let jsonData = try? JSONSerialization.data(withJSONObject: commitPayload),
                let jsonString = String(data: jsonData, encoding: .utf8)
            else {
                completion(.failure(NSError(domain: "JustSpeak", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize commit payload."])))
                return
            }

            sendTurnMessage(jsonString)
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
            let initialItem = DispatchWorkItem { [weak self] in self?.attemptSettle(turn: expectedTurn) }
            let maxItem = DispatchWorkItem { [weak self] in self?.attemptSettle(turn: expectedTurn) }

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

    private func scheduleReconnect(epoch: UInt64, onlyWhenIdle: Bool = false) {
        lock.lock()
        guard epoch == connectionID, reconnectEnabled, reconnectWorkItem == nil else {
            lock.unlock(); return
        }
        reconnectAttempts += 1
        let delay = min(10.0, pow(2.0, Double(min(reconnectAttempts, 4))))
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let current = self.connectionID == epoch && self.reconnectEnabled
            self.reconnectWorkItem = nil
            self.lock.unlock()
            if current { self.connect(onlyWhenIdle: onlyWhenIdle, expectedConnection: epoch) }
        }
        reconnectWorkItem = item
        lock.unlock()
        settleQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func abandonTurn() {
        lock.lock()
        let needsRotation = turnOpen
        turnOpen = false
        turnCompletion = nil
        isCommitting = false
        hasFiredTurnCompletion = true
        settleWorkItem?.cancel()
        settleMaxWorkItem?.cancel()
        lock.unlock()
        if needsRotation { connect() }
    }

    func disconnect() {
        lock.lock()
        connectionID &+= 1
        reconnectEnabled = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        settleWorkItem?.cancel()
        settleWorkItem = nil
        settleMaxWorkItem?.cancel()
        settleMaxWorkItem = nil
        let task = webSocketTask
        webSocketTask = nil
        connectedState = false
        readyState = false
        if turnOpen { turnHasAudioGap = true }
        let completion = turnCompletion
        turnCompletion = nil
        isCommitting = false
        lock.unlock()
        task?.cancel(with: .normalClosure, reason: nil)
        completion?(.failure(NSError(domain: "JustSpeak", code: -4, userInfo: [NSLocalizedDescriptionKey: "Live connection closed."])))
    }
}
