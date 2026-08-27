// MARK: - Network Reachability Monitor

// Connectivity truth for the key-down offline gate: dictating while offline should be
// refused in 0ms with a clear message, not discovered ~10s later when both the WS and
// REST routes time out. NWPathMonitor callbacks arrive on their own queue; state is
// snapshotted under the lock and logging happens outside it.
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.justspeak.netpath", qos: .utility)
    private let lock = NSLock()
    // Optimistic until the first path update lands - a slow monitor must never block a
    // dictation on a healthy network.
    private var online = true

    var isOnline: Bool {
        lock.lock()
        let value = online
        lock.unlock()
        return value
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let nowOnline = (path.status == .satisfied)
            self.lock.lock()
            let wasOnline = self.online
            self.online = nowOnline
            self.lock.unlock()
            guard wasOnline != nowOnline else { return }
            if nowOnline {
                Logger.success("NET", "Internet connection restored.")
            } else {
                Logger.warn("NET", "Internet connection lost - dictation will refuse until it returns.")
            }
        }
        monitor.start(queue: queue)
    }
}
