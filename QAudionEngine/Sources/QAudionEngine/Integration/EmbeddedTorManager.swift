import Foundation
import os

#if canImport(Tor)
import Tor

/// Embedded Tor manager for iOS — replaces the external Orbot dependency.
///
/// Runs Tor in-process via the `iCepa/Tor.swift` framework (XCFramework
/// wrapping the Tor C library). Exposes a SOCKS5 port on 127.0.0.1 that
/// `TorObfsTransport` uses to route .onion signaling traffic.
///
/// **Lifecycle:**
///   - `start()` — idempotent; bootstraps Tor once and returns the SOCKS5 port.
///   - `stop()` — releases the tor thread; safe to call multiple times.
///
/// **Mirrors:**
///   - Android: `TorBridge.kt` + `TorSupervisor.kt`
///   - Desktop:  `TorManager.ts` (child-process tor)
public actor EmbeddedTorManager {

    // MARK: - Types

    public enum TorError: Error {
        case bootstrapTimeout
        case controlPortError(String)
        case notAvailable
    }

    // MARK: - Singleton

    public static let shared = EmbeddedTorManager()

    // MARK: - State

    private var thread: TORThread?
    private var controller: TORController?
    private var state: State = .idle

    private enum State {
        case idle
        case starting
        case running(port: UInt16)
        case failed(Error)
    }

    private static let log = Logger(subsystem: "com.bcrypto.qaudion", category: "EmbeddedTorManager")

    // MARK: - Init

    private init() {}

    // MARK: - Public API

    /// Start embedded Tor and return the SOCKS5 port (127.0.0.1:<port>).
    /// Idempotent — returns the cached port if already running.
    public func start(timeoutSeconds: Int = 90) async throws -> UInt16 {
        switch state {
        case .running(let port):
            return port
        case .starting:
            return try await waitForRunning(timeoutSeconds: timeoutSeconds)
        case .failed:
            state = .idle
            return try await start(timeoutSeconds: timeoutSeconds)
        case .idle:
            state = .starting
        }

        do {
            let port = try await bootstrap(timeoutSeconds: timeoutSeconds)
            state = .running(port: port)
            return port
        } catch {
            state = .failed(error)
            throw error
        }
    }

    /// Stop Tor and release resources.
    public func stop() {
        controller?.disconnect()
        controller = nil
        thread = nil
        state = .idle
        Self.log.info("stop: embedded Tor stopped")
    }

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    public var activeSocksPort: UInt16? {
        if case .running(let p) = state { return p }
        return nil
    }

    // MARK: - Bootstrap

    private func bootstrap(timeoutSeconds: Int) async throws -> UInt16 {
        // Tor data directory.
        let torDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("tor-data", isDirectory: true)
        try FileManager.default.createDirectory(at: torDir, withIntermediateDirectories: true)

        // GeoIP files from the Tor.framework bundle.
        let geoipPath  = frameworkResource("geoip")
        let geoip6Path = frameworkResource("geoip6")

        let assignedPort = UInt16.random(in: 49_152...65_535)
        let config = TORConfiguration()
        config.cookieAuthentication = true
        config.dataDirectory = torDir
        if let p = geoipPath  { config.geoipFile  = URL(fileURLWithPath: p) }
        if let p = geoip6Path { config.geoip6File = URL(fileURLWithPath: p) }
        config.options = [
            "SocksPort": "\(assignedPort)",
            "StrictNodes": "0",
            "Log": "notice stderr",
        ]
        let controlSocketUrl = torDir.appendingPathComponent("control.socket")
        config.controlSocket = controlSocketUrl

        let torThread = TORThread(configuration: config)
        torThread.start()
        self.thread = torThread
        Self.log.info("bootstrap: tor thread started, SOCKS5 port=\(assignedPort)")

        // Allow Tor to initialise the control socket.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let ctrl = TORController(socketURL: controlSocketUrl)
        self.controller = ctrl

        // Race bootstrap against timeout.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.connectAndWaitBootstrap(ctrl, torDir: torDir) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                throw TorError.bootstrapTimeout
            }
            try await group.next()!
            group.cancelAll()
        }

        Self.log.info("bootstrap: Tor ready at 127.0.0.1:\(assignedPort)")
        return assignedPort
    }

    private func connectAndWaitBootstrap(_ ctrl: TORController, torDir: URL) async throws {
        // Retry control socket connect — tor may still be initialising.
        var connected = false
        var lastErr: Error = TorError.controlPortError("control socket not ready after 20 attempts")
        for attempt in 0..<20 {
            do {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    do { try ctrl.connect(); c.resume() }
                    catch { c.resume(throwing: error) }
                }
                connected = true
                break
            } catch {
                lastErr = error
                Self.log.debug("control connect attempt \(attempt + 1): \(error)")
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        guard connected else { throw lastErr }

        // Authenticate with cookie.
        let cookieUrl = torDir.appendingPathComponent("control_auth_cookie")
        if FileManager.default.fileExists(atPath: cookieUrl.path),
           let cookie = try? Data(contentsOf: cookieUrl) {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                ctrl.authenticate(with: cookie) { ok, err in
                    if ok { c.resume() }
                    else { c.resume(throwing: err ?? TorError.controlPortError("auth failed")) }
                }
            }
        } else {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                ctrl.authenticate(with: Data()) { ok, err in
                    if ok { c.resume() }
                    else { c.resume(throwing: err ?? TorError.controlPortError("null auth failed")) }
                }
            }
        }

        Self.log.debug("control authenticated — polling bootstrap progress")

        // Poll until 100% bootstrap.
        var progress = 0
        while progress < 100 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let pct: Int = await withCheckedContinuation { cont in
                ctrl.getInfoForKeys(["status/bootstrap-phase"]) { resp in
                    let phase = resp["status/bootstrap-phase"] ?? ""
                    // Tor format: "PROGRESS=80 TAG=loading_descriptors SUMMARY=..."
                    let parsed = Self.parseBootstrapProgress(from: phase)
                    Self.log.debug("bootstrap \(parsed)%")
                    cont.resume(returning: parsed)
                }
            }
            // Only advance — never regress the reported progress.
            if pct > progress { progress = pct }
        }
    }

    // MARK: - Helpers

    /// Parse "PROGRESS=<n> ..." Tor bootstrap-phase string → 0-100.
    private static func parseBootstrapProgress(from phase: String) -> Int {
        guard let prefixRange = phase.range(of: "PROGRESS=") else { return 0 }
        let rest = phase[prefixRange.upperBound...]
        let numStr: Substring
        if let spaceIdx = rest.firstIndex(of: " ") {
            numStr = rest[rest.startIndex..<spaceIdx]
        } else {
            numStr = rest
        }
        return Int(numStr) ?? 0
    }

    private func waitForRunning(timeoutSeconds: Int) async throws -> UInt16 {
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        while Date() < deadline {
            if case .running(let p) = state { return p }
            if case .failed(let e) = state { throw e }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw TorError.bootstrapTimeout
    }

    private func frameworkResource(_ name: String) -> String? {
        for bundle in Bundle.allFrameworks where bundle.bundleIdentifier?.contains("Tor") == true {
            if let p = bundle.path(forResource: name, ofType: nil) { return p }
            if let p = bundle.path(forResource: name, ofType: "dat") { return p }
        }
        return nil
    }
}

#else

// ─── Stub when Tor.swift is not linked ───────────────────────────────────────

/// Stub EmbeddedTorManager used when Tor.framework is not available.
/// All operations fail gracefully so callers fall back to external Orbot.
public actor EmbeddedTorManager {
    public static let shared = EmbeddedTorManager()
    private init() {}

    public enum TorError: Error {
        case bootstrapTimeout
        case controlPortError(String)
        case notAvailable
    }

    public func start(timeoutSeconds: Int = 90) async throws -> UInt16 {
        throw TorError.notAvailable
    }
    public func stop() {}
    public var isRunning: Bool { false }
    public var activeSocksPort: UInt16? { nil }
}

#endif
