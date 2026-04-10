import Foundation
import Network

/// ICE-lite agent for P2P connection establishment.
///
/// Gathers local (host) and server-reflexive (srflx) candidates via STUN,
/// then performs connectivity checks against remote candidates to find the
/// best P2P path. Prefers direct P2P over relay.
public final class IceAgent: @unchecked Sendable {

    // MARK: - Types

    public struct IceCandidate: Sendable, Equatable {
        public let ip: String
        public let port: UInt16
        public let type: CandidateType
        public let priority: UInt32

        public init(ip: String, port: UInt16, type: CandidateType, priority: UInt32) {
            self.ip = ip
            self.port = port
            self.type = type
            self.priority = priority
        }
    }

    public enum CandidateType: String, Sendable {
        case host   // Local interface address
        case srflx  // Server-reflexive (STUN)
        case relay  // TURN relay (not implemented)
    }

    public enum IceState: String, Sendable {
        case new
        case gathering
        case checking
        case connected
        case failed
    }

    // MARK: - Properties

    private let stunClient = StunClient()
    private let lock = NSLock()
    private var _state: IceState = .new
    private var localCandidates: [IceCandidate] = []

    /// The default local port used for UDP binding.
    private let localPort: UInt16

    public var state: IceState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    public init(localPort: UInt16 = 0) {
        self.localPort = localPort
    }

    // MARK: - Candidate gathering

    /// Gather local host candidates and STUN server-reflexive candidates.
    public func gatherCandidates() async -> [IceCandidate] {
        setState(.gathering)

        var candidates: [IceCandidate] = []

        // 1. Host candidates from local network interfaces
        let hostCandidates = getLocalAddresses()
        for (ip, port) in hostCandidates {
            candidates.append(IceCandidate(
                ip: ip,
                port: port,
                type: .host,
                priority: calculatePriority(type: .host)
            ))
        }

        // 2. Server-reflexive candidates via STUN
        if let stunResult = await stunClient.discoverFromAnyServer() {
            let srflxCandidate = IceCandidate(
                ip: stunResult.publicIP,
                port: stunResult.publicPort,
                type: .srflx,
                priority: calculatePriority(type: .srflx)
            )
            // Avoid duplicates (e.g. when not behind NAT)
            if !candidates.contains(where: { $0.ip == srflxCandidate.ip && $0.port == srflxCandidate.port }) {
                candidates.append(srflxCandidate)
            }
        }

        // Sort by priority descending (host > srflx > relay)
        candidates.sort { $0.priority > $1.priority }

        lock.lock()
        localCandidates = candidates
        lock.unlock()

        return candidates
    }

    /// Return the previously gathered local candidates.
    public func getLocalCandidates() -> [IceCandidate] {
        lock.lock(); defer { lock.unlock() }
        return localCandidates
    }

    // MARK: - Connectivity checks

    /// Perform connectivity checks against remote candidates.
    /// Tests each candidate with a UDP probe and returns the first reachable one.
    public func checkConnectivity(remoteCandidates: [IceCandidate]) async -> IceCandidate? {
        guard !remoteCandidates.isEmpty else {
            setState(.failed)
            return nil
        }

        setState(.checking)

        // Sort remote candidates by priority descending
        let sorted = remoteCandidates.sorted { $0.priority > $1.priority }

        for candidate in sorted {
            if await probeCandidate(candidate) {
                setState(.connected)
                return candidate
            }
        }

        setState(.failed)
        return nil
    }

    // MARK: - Private helpers

    /// Get local IPv4 addresses from network interfaces.
    private func getLocalAddresses() -> [(String, UInt16)] {
        var addresses: [(String, UInt16)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return addresses }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = ptr {
            let flags = Int32(addr.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            if isUp && !isLoopback, let sa = addr.pointee.ifa_addr {
                if sa.pointee.sa_family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &hostname, socklen_t(hostname.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: hostname)
                        // Skip link-local 169.254.x.x
                        if !ip.hasPrefix("169.254.") {
                            addresses.append((ip, localPort))
                        }
                    }
                }
            }
            ptr = addr.pointee.ifa_next
        }

        return addresses
    }

    /// Send a small UDP probe to the candidate and wait for any response or timeout.
    private func probeCandidate(_ candidate: IceCandidate) async -> Bool {
        await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(candidate.ip),
                port: NWEndpoint.Port(rawValue: candidate.port)!
            )
            let connection = NWConnection(to: endpoint, using: .udp)

            var resolved = false
            let probeLock = NSLock()

            // 2-second timeout per candidate
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                probeLock.lock()
                guard !resolved else { probeLock.unlock(); return }
                resolved = true
                probeLock.unlock()
                connection.cancel()
                continuation.resume(returning: false)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Send a 4-byte probe ("QICE")
                    let probe = Data("QICE".utf8)
                    connection.send(content: probe, completion: .contentProcessed { error in
                        probeLock.lock()
                        guard !resolved else { probeLock.unlock(); return }
                        if error != nil {
                            resolved = true
                            probeLock.unlock()
                            connection.cancel()
                            continuation.resume(returning: false)
                            return
                        }
                        probeLock.unlock()
                        // Wait for any response
                        connection.receiveMessage { content, _, _, _ in
                            probeLock.lock()
                            guard !resolved else { probeLock.unlock(); return }
                            resolved = true
                            probeLock.unlock()
                            connection.cancel()
                            continuation.resume(returning: content != nil)
                        }
                    })
                case .failed:
                    probeLock.lock()
                    guard !resolved else { probeLock.unlock(); return }
                    resolved = true
                    probeLock.unlock()
                    connection.cancel()
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: .global())
        }
    }

    /// Priority calculation following ICE RFC 8445 formula (simplified).
    /// type preference: host=126, srflx=100, relay=0
    /// Higher priority means preferred path.
    private func calculatePriority(type: CandidateType) -> UInt32 {
        let typePreference: UInt32
        switch type {
        case .host:  typePreference = 126
        case .srflx: typePreference = 100
        case .relay: typePreference = 0
        }
        // priority = (2^24) * type_preference + (2^8) * local_preference + component_id
        // local_preference=65535 (single interface), component_id=1 (RTP)
        return (typePreference << 24) | (65535 << 8) | 1
    }

    private func setState(_ newState: IceState) {
        lock.lock(); _state = newState; lock.unlock()
    }
}
