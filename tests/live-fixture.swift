let chunkMs = Int(CommandLine.arguments[1])!
let flushMs = Int(CommandLine.arguments[2])!
let aligned = CommandLine.arguments[3] == "true"
let client = GeminiLiveClient(apiKey: ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? "", languageCodes: ["en-US", "mr-IN"], endpointAligned: aligned)
let setupStart = DispatchTime.now().uptimeNanoseconds
client.connect()
while !client.isReady && Double(DispatchTime.now().uptimeNanoseconds - setupStart) / 1e9 < 12 { Thread.sleep(forTimeInterval: 0.025) }
guard client.isReady else { print("RESULT handshake_failed=true"); exit(2) }
print("RESULT handshake_ready=true")
let pcm = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[4]))
guard pcm.count > 32000 else { print("RESULT invalid_audio=true"); exit(4) }
for repetition in 1...3 {
    client.startNewTurn()
    client.sendAudioChunk(Data(count: 12800))
    let start = DispatchTime.now().uptimeNanoseconds
    let chunks = stride(from: 0, to: pcm.count, by: chunkMs * 32)
    for offset in chunks {
        let end = min(pcm.count, offset + chunkMs * 32)
        let target = Double(end) / 32000
        let remaining = target - Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
        client.sendAudioChunk(pcm.subdata(in: offset..<end))
    }
    let release = DispatchTime.now().uptimeNanoseconds
    if flushMs > 0 { client.sendAudioChunk(Data(count: flushMs * 32)) }
    let sem = DispatchSemaphore(value: 0)
    client.commitTurn { result in
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - release) / 1e6
        var row: [String: Any] = [
            "chunk_ms": chunkMs, "flush_ms": flushMs, "aligned": aligned, "repetition": repetition, "audio_end_to_settle_ms": elapsed, "settle_path": client.lastSettlePath ?? "unknown",
        ]
        switch result {
        case .success(let payload):
            row["text"] = payload.text
            row["client_commit_ms"] = payload.totalMs
            row["send_drain_ms"] = elapsed - payload.totalMs
        case .failure(let error): row["error_code"] = (error as NSError).code
        }
        let json = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        print("RESULT " + String(data: json, encoding: .utf8)!)
        sem.signal()
    }
    if sem.wait(timeout: .now() + 5) == .timedOut { print("RESULT completion_deadline_exceeded=true"); exit(3) }
    Thread.sleep(forTimeInterval: 0.3)
}
exit(0)
