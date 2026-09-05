// These tests use an in-memory provider. They never read or write the system clipboard.
final class ClipboardFixture {
    let lock = NSLock()
    var revision = 1
    var reads = 0
    var payload: String? = "original"
    var blocked = false
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func version() -> Int { lock.lock(); defer { lock.unlock() }; return revision }
    func read() -> String? {
        lock.lock()
        reads += 1
        let shouldBlock = blocked
        let value = payload
        lock.unlock()
        if shouldBlock { entered.signal(); release.wait() }
        return value
    }
}
func clipboardReady(_ prep: ClipboardPreparation<String>, timeout: Double = 1) -> Bool {
    let done = DispatchSemaphore(value: 0)
    var ready = false
    prep.awaitPrepared(timeout: timeout) { value in
        ready = value; done.signal()
    }
    _ = done.wait(timeout: .now() + timeout + 1)
    return ready
}
let clipboardFixture = ClipboardFixture()
let clipboardPrep = ClipboardPreparation(version: { clipboardFixture.version() }, read: { clipboardFixture.read() })
clipboardPrep.prepare()
check(clipboardReady(clipboardPrep), "clipboard snapshot prepares asynchronously")
check(clipboardPrep.take()?.contents == "original", "snapshot preserves exact contents")
check(clipboardPrep.take() == nil, "snapshot consumed once")
clipboardFixture.lock.lock(); clipboardFixture.payload = ""; clipboardFixture.lock.unlock()
clipboardPrep.prepare()
check(clipboardReady(clipboardPrep), "empty clipboard is a valid snapshot")
check(clipboardPrep.take()?.contents == "", "empty clipboard can be restored")
clipboardPrep.prepare()
check(clipboardReady(clipboardPrep), "prepare snapshot before external copy")
clipboardFixture.lock.lock(); clipboardFixture.revision += 1; clipboardFixture.lock.unlock()
check(clipboardPrep.take() == nil, "new user copy invalidates prepared snapshot")
check(clipboardReady(clipboardPrep), "await refreshes a missing snapshot")
clipboardFixture.lock.lock(); clipboardFixture.revision += 1; clipboardFixture.lock.unlock()
check(clipboardReady(clipboardPrep), "await refreshes a stale snapshot")
check(clipboardPrep.take()?.version == clipboardFixture.version(), "refresh uses current clipboard version")
clipboardFixture.lock.lock(); clipboardFixture.payload = nil; clipboardFixture.lock.unlock()
clipboardPrep.prepare()
check(!clipboardReady(clipboardPrep, timeout: 0.03), "failed representation read is unavailable")
check(clipboardPrep.take() == nil, "failed provider cannot become empty snapshot")
clipboardFixture.lock.lock(); clipboardFixture.payload = "original"; clipboardFixture.blocked = true; clipboardFixture.lock.unlock()
clipboardPrep.prepare()
check(clipboardFixture.entered.wait(timeout: .now() + 1) == .success, "blocked provider started")
let clipboardWaitStart = ProcessInfo.processInfo.systemUptime
check(!clipboardReady(clipboardPrep, timeout: 0.03), "provider stall has bounded asynchronous wait")
check(ProcessInfo.processInfo.systemUptime - clipboardWaitStart < 0.5, "timeout does not wait for blocked provider")
clipboardFixture.lock.lock(); let initialReads = clipboardFixture.reads; clipboardFixture.lock.unlock()
for _ in 0..<10000 { clipboardPrep.prepare() }
clipboardFixture.lock.lock(); clipboardFixture.blocked = false; clipboardFixture.lock.unlock()
clipboardFixture.release.signal()
check(clipboardReady(clipboardPrep), "latest coalesced request becomes ready")
clipboardFixture.lock.lock(); let extraReads = clipboardFixture.reads - initialReads; clipboardFixture.lock.unlock()
check(extraReads == 1, "rapid preparations coalesce to one pending provider read")
check(clipboardPrep.take()?.contents == "original", "latest snapshot remains usable")
clipboardFixture.lock.lock(); clipboardFixture.blocked = true; clipboardFixture.lock.unlock()
clipboardPrep.prepare()
check(clipboardFixture.entered.wait(timeout: .now() + 1) == .success, "discard test provider started")
let discardedDone = DispatchSemaphore(value: 0)
var discardedReady = true
clipboardPrep.awaitPrepared(timeout: 1) { value in
    discardedReady = value; discardedDone.signal()
}
clipboardPrep.discard()
check(discardedDone.wait(timeout: .now() + 1) == .success && !discardedReady, "discard resolves waiters without provider completion")
clipboardFixture.release.signal()
check(clipboardPrep.take() == nil, "discard cannot expose obsolete contents")
let changingFixture = ClipboardFixture()
changingFixture.blocked = true
let changingPrep = ClipboardPreparation(version: { changingFixture.version() }, read: { changingFixture.read() })
changingPrep.prepare()
check(changingFixture.entered.wait(timeout: .now() + 1) == .success, "changing provider started")
let changingDone = DispatchSemaphore(value: 0)
var changingReady = false
changingPrep.awaitPrepared(timeout: 1) { value in
    changingReady = value; changingDone.signal()
}
changingFixture.lock.lock()
changingFixture.revision = 2
changingFixture.payload = "new copy"
changingFixture.blocked = false
changingFixture.lock.unlock()
changingFixture.release.signal()
check(changingDone.wait(timeout: .now() + 2) == .success && changingReady, "copy during materialization refreshes within wait")
check(changingPrep.take()?.contents == "new copy", "concurrent copy uses new contents rather than partial snapshot")
