import Foundation
import Network
import Combine

/// NetworkMonitor: Real-time network reachability and interface supervisor using Apple's Network.framework.
/// Detects Wi-Fi / Ethernet drops, router reboots, and interface transitions with zero CPU polling.
@MainActor
public final class NetworkMonitor: ObservableObject {
    public static let shared = NetworkMonitor()

    @Published public private(set) var isReachable: Bool = true
    @Published public private(set) var isWifi: Bool = false
    @Published public private(set) var isWired: Bool = false
    @Published public private(set) var isExpensive: Bool = false

    public var onReachabilityChanged: (@Sendable (Bool) -> Void)?

    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "com.vortex.networkmonitor", qos: .utility)
    private var lastReportedState: Bool?

    private init() {
        self.monitor = NWPathMonitor()
        self.monitor.pathUpdateHandler = { [weak self] path in
            let reachable = (path.status == .satisfied)
            let isWifi = path.usesInterfaceType(.wifi)
            let isWired = path.usesInterfaceType(.wiredEthernet)
            let isExpensive = path.isExpensive

            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let stateChanged = (self.lastReportedState != reachable)
                self.lastReportedState = reachable

                self.isReachable = reachable
                self.isWifi = isWifi
                self.isWired = isWired
                self.isExpensive = isExpensive

                if stateChanged {
                    self.onReachabilityChanged?(reachable)
                }
            }
        }
        self.monitor.start(queue: monitorQueue)
    }

    deinit {
        monitor.cancel()
    }

    /// Fast synchronous reachability check using a socket probe to common DNS servers
    nonisolated public static func quickInternetCheck(timeout: TimeInterval = 2.0) -> Bool {
        let hosts = [("1.1.1.1", 53), ("8.8.8.8", 53)]
        for (host, port) in hosts {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            if inet_pton(AF_INET, host, &addr.sin_addr) <= 0 { continue }

            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else { continue }
            defer { close(sock) }

            // Set socket non-blocking
            let flags = fcntl(sock, F_GETFL, 0)
            _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

            let res = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            if res == 0 { return true }
            if errno == EINPROGRESS {
                var pollFd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
                let pollRes = poll(&pollFd, 1, Int32(timeout * 1000))
                if pollRes > 0 && (pollFd.revents & Int16(POLLOUT)) != 0 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &len)
                    if err == 0 { return true }
                }
            }
        }
        return false
    }
}
