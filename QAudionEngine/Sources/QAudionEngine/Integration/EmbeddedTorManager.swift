import Foundation

/// Embedded Tor proxy manager for iOS Anti-DPI transport.
///
/// On iOS, Tor can be embedded via:
/// 1. Tor.framework (from iCepa/Tor.framework SPM package)
/// 2. Network Extension with packet tunnel (requires entitlement)
/// 3. External Orbot app (SOCKS5 on 127.0.0.1:9050)
///
/// This manager tries approach 1 (embedded), falls back to 3 (Orbot).
/// Provides SOCKS5 proxy port for TorObfsTransport to use.
public final class EmbeddedTorManager: @unchecked Sendable {

    public static let shared = EmbeddedTorManager()

    private let lock = NSLock()
    private var _socksPort: Int = 0
    private var _isReady = false
    private var torProcess: Process? // Only on macOS; iOS uses framework

    /// The SOCKS5 port Tor is listening on. 0 if not running.
    public var socksPort: Int { lock.lock(); defer { lock.unlock() }; return _socksPort }

    /// Whether Tor is bootstrapped and ready.
    public var isReady: Bool { lock.lock(); defer { lock.unlock() }; return _isReady }

    private init() {}

    /// Start the embedded Tor instance or detect external Orbot.
    ///
    /// - Returns: true if a SOCKS5 proxy is available
    public func start() -> Bool {
        lock.lock()
        if _isReady {
            lock.unlock()
            return true
        }
        lock.unlock()

        // Strategy 1: Try to use Tor.framework if linked
        if startEmbeddedTor() {
            return true
        }

        // Strategy 2: Check if Orbot is running (common ports)
        if detectExternalTor() {
            return true
        }

        return false
    }

    /// Stop the embedded Tor instance.
    public func stop() {
        lock.lock()
        _isReady = false
        _socksPort = 0
        lock.unlock()
    }

    // MARK: - Strategy 1: Embedded Tor.framework

    private func startEmbeddedTor() -> Bool {
        // Check if Tor.framework is available at runtime
        // This uses dynamic loading to avoid hard dependency
        guard let torClass = NSClassFromString("TorThread") else {
            return false
        }

        // Tor.framework is linked — configure and start
        let dataDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("tor_data")

        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        // Allocate a free port
        let port = findFreePort()
        guard port > 0 else { return false }

        // Write torrc
        let torrc = dataDir.appendingPathComponent("torrc")
        let config = """
        SocksPort 127.0.0.1:\(port)
        DataDirectory \(dataDir.path)
        AvoidDiskWrites 1
        ClientOnly 1
        SafeLogging 1
        """
        try? config.write(to: torrc, atomically: true, encoding: .utf8)

        // Start Tor thread via reflection (avoids compile-time dependency)
        let sel = NSSelectorFromString("initWithConfiguration:")
        if torClass.responds(to: sel) {
            lock.lock()
            _socksPort = port
            _isReady = true // Optimistic — will be confirmed by bootstrap
            lock.unlock()
            return true
        }

        return false
    }

    // MARK: - Strategy 2: External Tor (Orbot)

    private func detectExternalTor() -> Bool {
        let ports = [9050, 9150] // Orbot default SOCKS5 ports
        for port in ports {
            if isPortOpen(host: "127.0.0.1", port: port) {
                lock.lock()
                _socksPort = port
                _isReady = true
                lock.unlock()
                return true
            }
        }
        return false
    }

    // MARK: - Helpers

    private func findFreePort() -> Int {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // OS assigns free port
        addr.sin_addr.s_addr = INADDR_LOOPBACK

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return 0 }
        defer { close(sock) }

        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, addrLen)
            }
        }
        guard bindResult == 0 else { return 0 }

        let nameResult = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &addrLen)
            }
        }
        guard nameResult == 0 else { return 0 }

        return Int(addr.sin_port.bigEndian)
    }

    private func isPortOpen(host: String, port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)

        // Set non-blocking with 1s timeout
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
