import Foundation
import os

#if canImport(Reality)
import Reality

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

        // Client config has no geoip/geosite-based routing rule (single
        // outbound, no rules[] block — see RealityCore/reality.go
        // startParams.DataDir comment), so any writable per-app-instance
        // directory works even though it's never populated with .dat files.
        let dataDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
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
        return UInt16(bound)
    }

    /// Stop the tunnel. Safe to call when not running.
    public func stop() async {
        guard case .running = state else { return }
        let ok = await Self.runBlocking { RealityStop() }
        if !ok {
            Self.log.warning("stop: RealityStop() failed: \(RealityLastError())")
        }
        state = .idle
    }

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
