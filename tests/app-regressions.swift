extension HotkeyManager {
    func fixturePress(_ pressed: Bool) {
        lastStateChangeTime = 0
        updateKeyState(pressed: pressed)
    }
}
let toggleFixture = HotkeyManager(binding: .fKey(0x69), mode: "toggle")
var starts = 0
var stops = 0
toggleFixture.onKeyDown = { starts += 1 }
toggleFixture.onKeyUp = { stops += 1 }
toggleFixture.fixturePress(true)
toggleFixture.fixturePress(true)
check(starts == 1 && stops == 0, "toggle ignores held-key repeats")
toggleFixture.resetToggle()
toggleFixture.fixturePress(false)
toggleFixture.fixturePress(true)
check(starts == 2 && stops == 0, "toggle starts immediately after external interruption")
toggleFixture.fixturePress(false)
toggleFixture.fixturePress(true)
check(stops == 1, "toggle still finishes on next physical press")

extension AudioCaptureEngine {
    func fixtureConversionFailure() {
        audioProcessingQueue.sync {
            lock.lock()
            isRecording = true
            turnInterrupted = false
            lock.unlock()
            discardFailedBuffer()
            check(turnInterrupted, "single conversion failure invalidates captured audio")
            isRecording = false
        }
    }
    func fixtureInterruptedCapture() {
        audioProcessingQueue.sync {
            lock.lock()
            isRecording = true
            turnInterrupted = true
            recordingStartTime = ProcessInfo.processInfo.systemUptime - 1
            recordedPCMData = Data(count: 32000)
            lock.unlock()
        }
    }
}
extension JustSpeakApp {
    func fixtureInterruptedTurn() {
        audioCapture.fixtureInterruptedCapture()
        isProcessing = true
        runTurnPipeline(keyUpTime: ProcessInfo.processInfo.systemUptime)
        check(turnSettled && !isProcessing, "interrupted capture settles and releases busy state")
        check(pendingRestRequest == nil && restAttemptStart == nil, "interrupted capture never enters REST fallback")
        history?.close()
    }
}
AudioCaptureEngine().fixtureConversionFailure()
let historyFixtureURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
var appFixtureConfig = Config()
appFixtureConfig.showHUD = false
appFixtureConfig.soundFeedback = false
appFixtureConfig.enableLiveWebSocket = false
appFixtureConfig.learnCorrections = false
appFixtureConfig.postRollMs = 0
appFixtureConfig.micIdleTimeoutSec = 0
appFixtureConfig.historyEnabled = true
appFixtureConfig.historyDbPath = historyFixtureURL.path
let interruptedApp = JustSpeakApp(config: appFixtureConfig)
interruptedApp.fixtureInterruptedTurn()
var fixtureDB: OpaquePointer?
check(sqlite3_open_v2(historyFixtureURL.path, &fixtureDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, "history fixture readable")
var fixtureStatement: OpaquePointer?
let fixtureSQL = "SELECT COUNT(*) FROM transcriptions WHERE transport='microphone' AND outcome='error' AND text IS NULL AND total_ms >= 0 AND capture_finalize_ms >= 0 AND event_queue_ms = 0"
check(sqlite3_prepare_v2(fixtureDB, fixtureSQL, -1, &fixtureStatement, nil) == SQLITE_OK, "history metrics schema and insert align")
check(sqlite3_step(fixtureStatement) == SQLITE_ROW && sqlite3_column_int(fixtureStatement, 0) == 1, "interrupted history keeps timing and never claims delivered text")
sqlite3_finalize(fixtureStatement)
sqlite3_close(fixtureDB)
try? FileManager.default.removeItem(at: historyFixtureURL)

// An immediate dispatcher models main winning the race against the pipeline worker.
extension AudioCaptureEngine {
    func fixtureRejectedCapture(silent: Bool) {
        audioProcessingQueue.sync {
            lock.lock()
            isRecording = true
            turnInterrupted = false
            recordingStartTime = ProcessInfo.processInfo.systemUptime - (silent ? 1 : 0.01)
            recordedPCMData = Data(count: silent ? 32000 : 320)
            statSampleCount = silent ? 16000 : 0
            turnMaxAbsSample = 0
            frameDbValues = silent ? [-120] : []
            lock.unlock()
        }
    }
}
extension JustSpeakApp {
    func fixtureRejectedTurn(silent: Bool) {
        audioCapture.fixtureRejectedCapture(silent: silent)
        isProcessing = true
        var callbacks = 0
        scheduleRejectedTurnUI = { action in
            callbacks += 1
            self.processingLock.lock()
            let busy = self.isProcessing
            self.processingLock.unlock()
            check(!busy, "rejected turn clears busy before main cleanup can run")
            action()
        }
        runTurnPipeline(keyUpTime: ProcessInfo.processInfo.systemUptime)
        check(callbacks == 1 && micIdleWorkItem != nil, "rejected turn arms microphone idle release")
        check(pendingRestRequest == nil, "rejected turn avoids transcription")
        micIdleWorkItem?.cancel()
        micIdleWorkItem = nil
    }
}
var rejectedConfig = appFixtureConfig
rejectedConfig.historyEnabled = false
rejectedConfig.micIdleTimeoutSec = 300
JustSpeakApp(config: rejectedConfig).fixtureRejectedTurn(silent: false)
JustSpeakApp(config: rejectedConfig).fixtureRejectedTurn(silent: true)
