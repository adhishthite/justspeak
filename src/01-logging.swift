// MARK: - ANSI Color Styling & High-Performance Logging

enum ANSI {
    static let reset = "\u{001B}[0m"
    static let bold = "\u{001B}[1m"
    static let dim = "\u{001B}[2m"
    static let red = "\u{001B}[31m"
    static let green = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let blue = "\u{001B}[34m"
    static let magenta = "\u{001B}[35m"
    static let cyan = "\u{001B}[36m"
    static let white = "\u{001B}[37m"
    static let gray = "\u{001B}[90m"
    static let clearLine = "\u{001B}[2K\r"
}

final class BoundedLogWriter {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.justspeak.log", qos: .utility)
    private var lines: [String] = []
    private var latestMeter: String?
    private var draining = false
    private var dropped = 0
    private let write: (String) -> Void

    init(
        write: @escaping (String) -> Void = {
            Swift.print($0, terminator: ""); fflush(stdout)
        }
    ) {
        self.write = write
    }

    func submit(_ text: String, meter: Bool = false, endMeter: Bool = false) {
        let bounded = String(text.prefix(8192))
        lock.lock()
        if endMeter { latestMeter = nil }
        if meter {
            latestMeter = bounded
        } else if lines.count < 128 {
            lines.append(bounded)
        } else {
            dropped += 1
        }
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            let next: String?
            if !lines.isEmpty {
                next = lines.removeFirst()
            } else if let meter = latestMeter {
                next = meter
                latestMeter = nil
            } else if dropped > 0 {
                next = "\n[LOG] Dropped \(dropped) messages while output was busy.\n"
                dropped = 0
            } else {
                next = nil
                draining = false
            }
            lock.unlock()
            guard let next = next else { return }
            write(next)
        }
    }

    func flush(timeout: TimeInterval = 0.2) {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }
}

struct Logger {
    static var isVerbose = true
    private static let writer = BoundedLogWriter()

    static func timestamp() -> String {
        var tv = timeval()
        gettimeofday(&tv, nil)
        var tm = tm()
        localtime_r(&tv.tv_sec, &tm)
        var buf = [CChar](repeating: 0, count: 32)
        strftime(&buf, buf.count, "%H:%M:%S", &tm)
        return String(cString: buf) + String(format: ".%03d", Int(tv.tv_usec) / 1000)
    }

    static func raw(_ message: String) { writer.submit(message + "\n") }
    static func flush() { writer.flush() }

    static func info(_ tag: String, _ message: String) {
        raw("\(ANSI.gray)[\(timestamp())]\(ANSI.reset) \(ANSI.bold)\(ANSI.cyan)[\(tag)]\(ANSI.reset) \(message)")
    }
    static func success(_ tag: String, _ message: String) {
        raw("\(ANSI.gray)[\(timestamp())]\(ANSI.reset) \(ANSI.bold)\(ANSI.green)[\(tag)]\(ANSI.reset) \(message)")
    }
    static func warn(_ tag: String, _ message: String) {
        raw("\(ANSI.gray)[\(timestamp())]\(ANSI.reset) \(ANSI.bold)\(ANSI.yellow)[\(tag)]\(ANSI.reset) \(message)")
    }
    static func error(_ tag: String, _ message: String) {
        raw("\(ANSI.gray)[\(timestamp())]\(ANSI.reset) \(ANSI.bold)\(ANSI.red)[\(tag)]\(ANSI.reset) \(message)")
    }
    static func debug(_ tag: String, _ message: @autoclosure () -> String) {
        guard isVerbose else { return }
        raw("\(ANSI.gray)[\(timestamp())] [\(tag)] \(message())\(ANSI.reset)")
    }
    static func meter(_ message: @autoclosure () -> String) {
        guard isVerbose else { return }
        writer.submit("\(ANSI.clearLine)\(ANSI.gray)[\(timestamp())]\(ANSI.reset) \(message())", meter: true)
    }
    static func endMeter() { writer.submit("\n", endMeter: true) }
}
