func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
for size in [1000, 5000, 20000] {
    let pasted = (0..<50).map { "term\($0)" }.joined(separator: " ")
    let field = (0..<(size - 50)).map { "context\($0)" }.joined(separator: " ") + " " + pasted
    var before: [Double] = []
    var after: [Double] = []
    for _ in 0..<3 {
        var start = ProcessInfo.processInfo.systemUptime
        let old = LegacyCorrectionWatcher.extractCorrections(pasted: pasted, field: field, vocabSet: [])
        before.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        start = ProcessInfo.processInfo.systemUptime
        let new = CorrectionWatcher.extractCorrections(pasted: pasted, field: field, vocabSet: [])
        after.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        assert(old.isEmpty && new.isEmpty)
    }
    print("BENCH correction field_words=\(size) paste_words=50 before_ms=\(median(before)) after_ms=\(median(after)) speedup=\(median(before) / median(after))")
}
let sink: (String) -> Void = { _ in Thread.sleep(forTimeInterval: 0.05) }
var start = ProcessInfo.processInfo.systemUptime
for _ in 0..<10 { sink("diagnostic") }
let blockedMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
let writer = BoundedLogWriter(write: sink)
start = ProcessInfo.processInfo.systemUptime
for _ in 0..<10 { writer.submit("diagnostic") }
let producerMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
writer.flush(timeout: 2)
print("BENCH logging controlled_sink=50ms writes=10 synchronous_producer_ms=\(blockedMs) queued_producer_ms=\(producerMs)")
