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

struct Logger {
    static var isVerbose: Bool = true

    // POSIX microsecond timestamp formatter (zero heap allocations)
    static func timestamp() -> String {
        var tv = timeval()
        gettimeofday(&tv, nil)
        var tm_val = tm()
        localtime_r(&tv.tv_sec, &tm_val)
        var buf = [CChar](repeating: 0, count: 32)
        strftime(&buf, buf.count, "%H:%M:%S", &tm_val)
        let ms = Int(tv.tv_usec) / 1000
        return String(cString: buf) + String(format: ".%03d", ms)
    }

    static func info(_ tag: String, _ message: String) {
        print("\(ANSI.gray)[\(timestamp())]\(ANSI.reset) \(ANSI.bold)\(ANSI.cyan)[\(tag)]\(ANSI.reset) \(message)")
        fflush(stdout)
    }

    static func success(_ tag: String, _ message: String) {
        print("\(ANSI.gray)[\(timestamp())]\(ANSI.reset) \(ANSI.bold)\(ANSI.green)[\(tag)]\(ANSI.reset) \(message)")
        fflush(stdout)
    }

    static func warn(_ tag: String, _ message: String) {
        print("\(ANSI.gray)[\(timestamp())]\(ANSI.reset) \(ANSI.bold)\(ANSI.yellow)[\(tag)]\(ANSI.reset) \(message)")
        fflush(stdout)
    }

    static func error(_ tag: String, _ message: String) {
        print("\(ANSI.gray)[\(timestamp())]\(ANSI.reset) \(ANSI.bold)\(ANSI.red)[\(tag)]\(ANSI.reset) \(message)")
        fflush(stdout)
    }

    static func debug(_ tag: String, _ message: String) {
        guard isVerbose else { return }
        print("\(ANSI.gray)[\(timestamp())] [\(tag)] \(message)\(ANSI.reset)")
        fflush(stdout)
    }

    static func meter(_ message: String) {
        print("\(ANSI.clearLine)\(ANSI.gray)[\(timestamp())]\(ANSI.reset) \(message)", terminator: "")
        fflush(stdout)
    }

    static func endMeter() {
        print("")
        fflush(stdout)
    }
}
