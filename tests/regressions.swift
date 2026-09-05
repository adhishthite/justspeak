var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fatalError("FAIL: \(label)") }
    checks += 1
}
func pairs(_ input: [CorrectionWatcher.Pair]) -> [String] { input.map { $0.wrong + "=>" + $0.right } }

check(pairs(CorrectionWatcher.extractCorrections(pasted: "cloud", field: "Claude", vocabSet: [])) == ["cloud=>Claude"], "proper noun correction")
check(CorrectionWatcher.extractCorrections(pasted: "cloud", field: "Cloud", vocabSet: []).isEmpty, "case-only changes rejected")
check(CorrectionWatcher.extractCorrections(pasted: "the", field: "The", vocabSet: []).isEmpty, "stopword rejected")
check(CorrectionWatcher.extractCorrections(pasted: String(repeating: "word ", count: 513), field: "word", vocabSet: []).isEmpty, "long paste budget")

var seed: UInt64 = 0x51A7
func next(_ limit: Int) -> Int {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Int((seed >> 32) % UInt64(limit))
}
let vocabulary = ["cloud", "Claude", "code", "Code", "report", "Priya", "priya", "the", "...", "Next.js", "next.js", "部署", "मराठी"]
for _ in 0..<300 {
    let n = 1 + next(12)
    let pasted = (0..<n).map { _ in vocabulary[next(vocabulary.count)] }.joined(separator: " ")
    let field = (0..<(1 + next(40))).map { _ in vocabulary[next(vocabulary.count)] }.joined(separator: " ")
    let expected = LegacyCorrectionWatcher.extractCorrections(pasted: pasted, field: field, vocabSet: ["claude"]).map { $0.wrong + "=>" + $0.right }
    check(pairs(CorrectionWatcher.extractCorrections(pasted: pasted, field: field, vocabSet: ["claude"])) == expected, "rolling window retains gates and tie behavior")
}

// A deliberately blocked terminal must not block producers or grow their queue without limit.
let writerEntered = DispatchSemaphore(value: 0)
let releaseWriter = DispatchSemaphore(value: 0)
let logLock = NSLock()
var written: [String] = []
let writer = BoundedLogWriter { text in
    if text == "block" { writerEntered.signal(); releaseWriter.wait() }
    logLock.lock(); written.append(text); logLock.unlock()
}
writer.submit("block")
check(writerEntered.wait(timeout: .now() + 1) == .success, "log sink entered")
let enqueueStart = ProcessInfo.processInfo.systemUptime
for i in 0..<10000 { writer.submit("meter \(i)", meter: true) }
for _ in 0..<1000 { writer.submit("diagnostic") }
check(ProcessInfo.processInfo.systemUptime - enqueueStart < 1, "logging producers do not wait for sink")
releaseWriter.signal()
writer.flush(timeout: 2)
logLock.lock(); let logged = written; logLock.unlock()
check(logged.count <= 131, "bounded log queue")
check(logged.contains("meter 9999"), "latest meter retained")
Logger.isVerbose = false
var formatted = false
func expensiveMessage() -> String { formatted = true; return "unexpected" }
Logger.meter(expensiveMessage())
check(!formatted, "normal mode skips meter formatting")

let retryScope = CancellableRequest()
let retryFired = DispatchSemaphore(value: 0)
retryScope.schedule(after: 0.02) { retryFired.signal() }
retryScope.cancel()
check(retryFired.wait(timeout: .now() + 0.08) == .timedOut, "cancelled retry cannot start")

extension GeminiLiveClient {
    func fixtureOpen() {
        lock.lock()
        turnID &+= 1
        turnOpen = true
        readyState = true
        turnHasAudioGap = false
        hasFiredTurnCompletion = false
        currentTurnText = ""
        committedTranscript = ""
        interimTranscript = ""
        lock.unlock()
    }
    func fixtureMessage(_ fields: [String: Any], oldConnection: Bool = false) {
        let bytes = try! JSONSerialization.data(withJSONObject: ["serverContent": fields])
        lock.lock(); let epoch = connectionID; lock.unlock()
        handleIncomingMessage(.data(bytes), epoch: oldConnection ? epoch &- 1 : epoch)
    }
    func fixtureCompletion(_ completion: @escaping (Result<(text: String, firstTokenMs: Double, totalMs: Double), Error>) -> Void) {
        lock.lock()
        isCommitting = true
        turnCommitTime = ProcessInfo.processInfo.systemUptime
        turnCompletion = completion
        lock.unlock()
    }
    func fixtureMeteredUsage() {
        lock.lock(); lastSeenPromptTokens = 20; lastSeenResponseTokens = 3; lock.unlock()
    }
    func fixtureSetupComplete() {
        let bytes = try! JSONSerialization.data(withJSONObject: ["setupComplete": [:]])
        handleIncomingMessage(.data(bytes), epoch: connectionID)
    }
    func fixtureIdleRotation() { connect(onlyWhenIdle: true, expectedConnection: connectionID) }
    func fixtureText() -> String { lock.lock(); defer { lock.unlock() }; return currentTurnText }
    func fixtureGap() { lock.lock(); turnHasAudioGap = true; lock.unlock() }
    func fixtureBeginCommit(_ completion: @escaping (Result<(text: String, firstTokenMs: Double, totalMs: Double), Error>) -> Void) {
        beginCommit(turn: turnID, completion: completion)
    }
}
let live = GeminiLiveClient(apiKey: "")
live.fixtureOpen()
live.fixtureMessage(["inputTranscription": ["text": "First segment."], "turnComplete": true])
check(live.fixtureText() == "First segment.", "pre-commit completion preserves text")
live.fixtureMessage(["interimInputTranscription": ["text": "Second segment"]])
var completions = 0
var resultText = ""
live.fixtureMeteredUsage()
live.fixtureCompletion { result in
    completions += 1
    if case .success(let value) = result { resultText = value.text }
}
live.fixtureMessage(["inputTranscription": ["text": "Second segment."], "turnComplete": true])
check(resultText == "First segment. Second segment.", "segments preserved")
live.fixtureSetupComplete()
check(live.lastTurnUsage?.inputTokens == 20 && live.lastTurnUsage?.outputTokens == 3, "settled usage survives replacement setup")
live.fixtureMessage(["inputTranscription": ["text": "Late text"], "turnComplete": true])
check(completions == 1 && live.fixtureText().isEmpty, "completion exactly once; late closed-turn text ignored")
live.fixtureOpen()
live.fixtureMessage(["inputTranscription": ["text": "Old connection"]], oldConnection: true)
check(live.fixtureText().isEmpty, "old connection ignored")
live.fixtureGap()
check(!live.canCommitTurn, "partial stream ineligible")
var rejected = false
live.fixtureBeginCommit { if case .failure = $0 { rejected = true } }
check(rejected, "partial stream fails before commit")
let rotation = GeminiLiveClient(apiKey: "synthetic-test-value")
rotation.fixtureOpen()
rotation.fixtureIdleRotation()
check(rotation.isReady && rotation.canCommitTurn, "healthy active turn defers idle rotation without opening a connection")
print("PASS: \(checks) regression checks. No API, mic, clipboard, or app startup.")
