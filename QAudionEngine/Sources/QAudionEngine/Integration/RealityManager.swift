import Foundation
import os

#if canImport(Reality)
import Reality
#if canImport(Darwin)
import Darwin
#endif

/// Embedded Reality (VLESS+REALITY over xray-core, via github.com/xtls/libxray)
/// client for iOS — the primary censorship-bypass transport per
/// bcrypto-server's docs/CENSORSHIP_RESISTANT_TRANSPORT_DESIGN.md §4/§4.4.
/// Tor stays exactly as-is for its own separate purposes (design doc §7) —
/// this is an ADDITIVE second backend, not a replacement.
///
/// Wraps the RealityCore Go module (`../../RealityCore`, built to
/// `Reality.xcframework` by `scripts/build-reality-xcframework.sh`) — a thin
/// binding over `github.com/xtls/libxray`. `start()` returns the local
/// loopback SOCKS5 port the tunnel is listening on;
/// `BCryptoWebSocketClient.connect(viaSocksPort:)` is the intended consumer,
/// same shape `TorObfsTransport.connectViaSocks(port:)` already uses for Tor.
///
/// **Mirrors:** `EmbeddedTorManager`'s actor/singleton/`start()-throws-port`
/// shape exactly — a second, independent backend that does not touch Tor's
/// code path (TorObfsTransport / EmbeddedTorManager are untouched).
public actor RealityManager {

    // MARK: - Types

    public enum RealityError: Error {
        case startFailed(String)
        case notAvailable
    }

    /// Server-issued parameters needed to dial the Reality front.
    /// `serverName`/`publicKey` describe the disguise-target deployment the
    /// SERVER picked (design doc §4.2/§10.3) — NOT hardcoded here, and NOT
    /// something this app decides; fetch from the server the same way
    /// `RelayCredentialsProvider` already fetches `onionAddress`.
    public struct Params: Sendable {
        public let serverAddress: String
        public let serverPort: Int
        public let uuid: String
        public let publicKey: String
        public let shortId: String
        public let serverName: String
        public let flow: String
        public let fingerprint: String

        public init(
            serverAddress: String,
            serverPort: Int = 443,
            uuid: String,
            publicKey: String,
            shortId: String = "",
            serverName: String,
            flow: String = "xtls-rprx-vision",
            fingerprint: String = "chrome"
        ) {
            self.serverAddress = serverAddress
            self.serverPort = serverPort
            self.uuid = uuid
            self.publicKey = publicKey
            self.shortId = shortId
            self.serverName = serverName
            self.flow = flow
            self.fingerprint = fingerprint
        }
    }

    // MARK: - Singleton

    public static let shared = RealityManager()

    // MARK: - State

    private var state: State = .idle

    private enum State {
        case idle
        case running(port: UInt16)
    }

    /// The params the tunnel was last (re)started with — needed by the
    /// health watcher to rebuild the SAME tunnel without its caller having
    /// to hold onto them. Mirrors Android RealityManager.kt's `lastConfig`.
    private var lastParams: Params?

    /// W-REALITYHEALTH (2026-09-06) — separate from the tunnel's own
    /// lifecycle so a self-heal restart (`restartInPlace`) does not cancel
    /// the very Task it is running in. Cancelled/recreated only by `stop()`
    /// and `startHealthWatch()`, never by `start()`'s state transition.
    private var healthTask: Task<Void, Never>?

    private static let log = Logger(subsystem: "com.bcrypto.qaudion", category: "RealityManager")

    private init() {}

    // MARK: - Public API

    /// Start the embedded Reality tunnel and return the local SOCKS5 port.
    /// Idempotent — returns the cached port if already running (call
    /// `stop()` first to restart with different params).
    ///
    /// `async`: `RealityStart` is a synchronous, blocking FFI call into the
    /// gomobile-bound Go runtime (xray-core's inbound-listener startup —
    /// expected to be fast, but not zero-cost). Running it directly inside
    /// an actor-isolated method would block this actor's serial executor for
    /// its whole duration, stalling any concurrent `isRunning`/
    /// `activeSocksPort` read. `runBlocking` below hops it onto a background
    /// queue and resumes back into actor isolation only to mutate `state`.
    public func start(params: Params) async throws -> UInt16 {
        if case .running(let port) = state { return port }
        lastParams = params

        // Client config has no geoip/geosite-based routing rule (single
        // outbound, no rules[] block — see RealityCore/reality.go
        // startParams.DataDir comment), so any writable per-app-instance
        // directory works even though it's never populated with .dat files.
        // force-unwrap safe: FileManager.urls(for:in:) for
        // .applicationSupportDirectory in .userDomainMask is documented to
        // always return exactly one URL on Apple platforms.
        let dataDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
            // swiftlint:disable:next force_unwrapping
        ).first!.appendingPathComponent("reality-data", isDirectory: true)
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        // Same ephemeral-port pattern EmbeddedTorManager uses for its SocksPort.
        let localPort = UInt16.random(in: 49_152...65_535)

        let payload: [String: Any] = [
            "serverAddress": params.serverAddress,
            "serverPort": params.serverPort,
            "uuid": params.uuid,
            "flow": params.flow,
            "publicKey": params.publicKey,
            "shortId": params.shortId,
            "serverName": params.serverName,
            "fingerprint": params.fingerprint,
            "localSocksPort": Int(localPort),
            "dataDir": dataDir.path,
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: jsonData, encoding: .utf8) else {
            throw RealityError.startFailed("failed to encode start params")
        }

        // RealityStart returns the bound port (>0) on success, 0 on failure —
        // gomobile's (T, error) convention generates an NSError**-out-param C
        // signature Swift does not auto-bridge to `throws` for plain C
        // functions (verified against the actual generated header while
        // writing RealityCore/reality.go); LastError() carries the reason.
        let bound = await Self.runBlocking { RealityStart(json) }
        guard bound > 0 else {
            throw RealityError.startFailed(RealityLastError())
        }

        state = .running(port: UInt16(bound))
        Self.log.info("start: Reality tunnel up on 127.0.0.1:\(bound)")
        startHealthWatch()
        return UInt16(bound)
    }

    /// Stop the tunnel. Safe to call when not running.
    public func stop() async {
        healthTask?.cancel()
        healthTask = nil
        guard case .running = state else { return }
        let ok = await Self.runBlocking { RealityStop() }
        if !ok {
            Self.log.warning("stop: RealityStop() failed: \(RealityLastError())")
        }
        state = .idle
    }

    // MARK: - Health watch (W-REALITYHEALTH, 2026-09-06)

    /// Live device evidence (Android, same Reality/xray-core transport):
    /// after hours idle, the underlying xray-core outbound session goes
    /// stale (server/NAT idle timeout on a long-lived tunnel) while the
    /// local SOCKS listener keeps running and accepting new connections —
    /// it just can't carry them any more. `isRunning`/`RealityIsRunning()`
    /// only reports whether the Go listener goroutine is alive, exactly
    /// like Android's `State.Ready` — neither means the tunnel can still
    /// reach anything. On Android this produced 1374 identical
    /// `SSLHandshakeException: connection closed` failures over 7+ hours
    /// that NEVER self-recovered, because nothing ever re-checked a tunnel
    /// once it came up. iOS shares the exact same one-shot-activation shape
    /// (`AppState.activateRealityFallback` guards on `transportIsReality`
    /// and never re-enters once true) and had NO probe of any kind, not
    /// even once at startup — worse than Android before this fix. This
    /// periodically re-proves the tunnel the same way Android's
    /// `RealityManager.probeReachable` does: a raw SOCKS5 CONNECT to the
    /// app's own server, through the local listener, expecting reply code
    /// 0x00.
    private func startHealthWatch() {
        healthTask?.cancel()
        // CLAUDE.md §13 — a Task closure with a while/guard/if body this deep
        // is exactly the shape that has timed out the Swift 6 type-checker
        // elsewhere in this repo (see ChatDetailScreen.swift's
        // handleVoiceNoteStart/startVoiceNoteAsync split). Keep the closure
        // itself trivial; the real loop lives in a plain method below.
        healthTask = Task { [weak self] in
            await self?.runHealthLoop()
        }
    }

    private func runHealthLoop() async {
        var consecutiveFailures = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.healthCheckIntervalNs)
            if Task.isCancelled { return }
            let recovered = await healthCheckTick(consecutiveFailures: consecutiveFailures)
            consecutiveFailures = recovered
        }
    }

    /// One probe-and-react cycle. Returns the failure count for the NEXT
    /// cycle (0 after a pass or a restart, incremented after a fail).
    /// Actor-isolated (reads `state`/`lastParams` directly, no `await` on
    /// `self` needed) — lifted out of `runHealthLoop`'s while-loop for the
    /// same type-checker-budget reason `startHealthWatch` lifted the Task
    /// body out of `start()`.
    private func healthCheckTick(consecutiveFailures: Int) async -> Int {
        guard case .running(let port) = state else { return consecutiveFailures }
        let carries = await Self.runBlocking {
            Self.probeSocks5Sync(
                socksPort: port,
                host: Self.healthCheckHost,
                port: Self.healthCheckPort,
                timeoutSec: Self.probeTimeoutSec
            )
        }
        if carries {
            if consecutiveFailures > 0 {
                let n = consecutiveFailures
                Self.log.info("health: probe recovered after \(n) failure(s)")
            }
            return 0
        }
        let failures = consecutiveFailures + 1
        let threshold = Self.healthFailureThreshold
        Self.log.warning("health: probe failed (\(failures)/\(threshold) consecutive)")
        if failures >= Self.healthFailureThreshold {
            Self.log.warning("health: tunnel unresponsive for \(failures) consecutive checks — restarting")
            await restartInPlace()
            return 0
        }
        return failures
    }

    /// Tears down and rebuilds the xray-core engine with `lastParams`,
    /// WITHOUT touching `healthTask` — called FROM `healthTask`'s own Task,
    /// so it must not cancel the Task it is currently running in (that is
    /// exactly what `stop()` would do). A failed restart leaves `.idle` for
    /// callers to observe via `isRunning`; the health loop keeps running
    /// either way so a later network recovery gets another chance next
    /// cycle.
    private func restartInPlace() async {
        guard let params = lastParams else { return }
        let stopOk = await Self.runBlocking { RealityStop() }
        if !stopOk {
            Self.log.warning("health: restart's RealityStop() failed: \(RealityLastError())")
        }
        state = .idle

        let dataDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
            // swiftlint:disable:next force_unwrapping
        ).first!.appendingPathComponent("reality-data", isDirectory: true)
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let localPort = UInt16.random(in: 49_152...65_535)
        let payload: [String: Any] = [
            "serverAddress": params.serverAddress,
            "serverPort": params.serverPort,
            "uuid": params.uuid,
            "flow": params.flow,
            "publicKey": params.publicKey,
            "shortId": params.shortId,
            "serverName": params.serverName,
            "fingerprint": params.fingerprint,
            "localSocksPort": Int(localPort),
            "dataDir": dataDir.path,
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: jsonData, encoding: .utf8) else {
            Self.log.warning("health: restart failed to encode start params")
            return
        }
        let bound = await Self.runBlocking { RealityStart(json) }
        guard bound > 0 else {
            Self.log.warning("health: restart failed: \(RealityLastError())")
            return
        }
        state = .running(port: UInt16(bound))
        Self.log.info("health: tunnel restarted OK on 127.0.0.1:\(bound)")
    }

    /// Raw SOCKS5 handshake + CONNECT to `host:port` through the local
    /// listener on `socksPort`, run synchronously off-actor via
    /// `runBlocking` (same reason `RealityStart`/`RealityStop` are: this
    /// must not stall the actor's serial executor). POSIX sockets, not
    /// `URLSession`/`Network.framework`: this has to speak the SOCKS5 wire
    /// protocol to the PROXY itself, not go through the app's HTTP stack,
    /// and a byte-for-byte port of the exact same probe Android
    /// `RealityManager.probeReachable` runs keeps both platforms' health
    /// checks provably equivalent. Nothing about `host`/`port` is ever
    /// actually reached beyond the CONNECT — the socket is opened and
    /// dropped, same as the Android probe's own doc comment.
    private static func probeSocks5Sync(socksPort: UInt16, host: String, port: Int, timeoutSec: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var tv = timeval(tv_sec: timeoutSec, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(socksPort).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { return false }

        // Greeting: version 5, one method, "no authentication".
        let greeting: [UInt8] = [0x05, 0x01, 0x00]
        guard write(fd, greeting, greeting.count) == greeting.count else { return false }
        var greetReply = [UInt8](repeating: 0, count: 2)
        guard read(fd, &greetReply, 2) == 2, greetReply[0] == 0x05, greetReply[1] == 0x00 else { return false }

        // CONNECT, address type 3 (domain name).
        guard let hostBytes = host.data(using: .ascii), hostBytes.count <= 255 else { return false }
        var req: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(hostBytes.count)]
        req.append(contentsOf: hostBytes)
        req.append(UInt8((port >> 8) & 0xFF))
        req.append(UInt8(port & 0xFF))
        guard write(fd, req, req.count) == req.count else { return false }
        var head = [UInt8](repeating: 0, count: 4)
        guard read(fd, &head, 4) == 4 else { return false }
        // head[1] is the reply code: 0x00 is the only success.
        return head[0] == 0x05 && head[1] == 0x00
    }

    private static let healthCheckIntervalNs: UInt64 = 5 * 60 * 1_000_000_000
    private static let healthFailureThreshold = 2
    private static let healthCheckHost = "voip.bcrypto.com"
    private static let healthCheckPort = 443
    private static let probeTimeoutSec = 6

    /// Runs a synchronous, blocking closure off this actor's executor (see
    /// `start()`'s doc comment) and resumes the calling actor-isolated
    /// context with its result.
    private static func runBlocking<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: body())
            }
        }
    }

    public var isRunning: Bool {
        RealityIsRunning()
    }

    public var activeSocksPort: UInt16? {
        if case .running(let p) = state { return p }
        return nil
    }

    /// Bundled xray-core version — diagnostics only.
    public var version: String {
        RealityVersion()
    }
}

#else

// ─── Stub when Reality.xcframework is not linked ─────────────────────────────
//
// Same maturity level as EmbeddedTorManager's `#else` branch today: the
// RealityCore Go module and scripts/build-reality-xcframework.sh exist, but
// Reality.xcframework is NOT YET wired as a QAudionEngine dependency (see the
// TODO next to CQaudionCryptoCore/WebRTC in QAudionEngine/Package.swift) — it
// needs a real CI/macOS build to produce the artifact and confirm the SPM
// wiring doesn't regress engine-tests.yml before that's safe to add. Until
// then this stub keeps every call site compiling; `start()` always throws
// `.notAvailable`, exactly like EmbeddedTorManager's stub does for Tor.
public actor RealityManager {

    public enum RealityError: Error {
        case startFailed(String)
        case notAvailable
    }

    public struct Params: Sendable {
        public let serverAddress: String
        public let serverPort: Int
        public let uuid: String
        public let publicKey: String
        public let shortId: String
        public let serverName: String
        public let flow: String
        public let fingerprint: String

        public init(
            serverAddress: String,
            serverPort: Int = 443,
            uuid: String,
            publicKey: String,
            shortId: String = "",
            serverName: String,
            flow: String = "xtls-rprx-vision",
            fingerprint: String = "chrome"
        ) {
            self.serverAddress = serverAddress
            self.serverPort = serverPort
            self.uuid = uuid
            self.publicKey = publicKey
            self.shortId = shortId
            self.serverName = serverName
            self.flow = flow
            self.fingerprint = fingerprint
        }
    }

    public static let shared = RealityManager()
    private init() {}

    public func start(params: Params) async throws -> UInt16 {
        throw RealityError.notAvailable
    }
    public func stop() async {}
    public var isRunning: Bool { false }
    public var activeSocksPort: UInt16? { nil }
    public var version: String { "" }
}

#endif
