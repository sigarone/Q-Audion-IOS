// VpnSessionCoordinator.swift — Q-Audion iOS
//
// Session bookkeeping for the VPN connect / disconnect flow, kept free of any
// system framework so it compiles in every build and can be unit tested with a
// fake tunnel (VpnSessionCoordinatorTests). `VpnService` (VPN builds only) owns
// one instance and adapts the system manager to `VpnTunnelControlling`.
//
// What it guarantees:
//   - every connect attempt and every disconnect starts a new generation, and
//     status events that belong to an older generation are ignored;
//   - a connect waits (bounded) until the system tunnel is down, so a start can
//     never overlap a session that is still closing;
//   - a connect attempt has an overall deadline; when it expires the tunnel is
//     stopped and the owner is told, so the UI can never stay on "connecting".
//
// Logging goes through `RTLog` (tag "vpn"); only fixed words, generation
// numbers and status names are written: no keys, addresses or host names.

import Foundation

/// The system tunnel status as the coordinator sees it (1:1 with the OS status).
enum VpnTunnelStatus: Equatable {
    case invalid
    case disconnected
    case connecting
    case connected
    case reasserting
    case disconnecting

    /// True when no session is running or closing.
    var isDown: Bool { self == .disconnected || self == .invalid }
}

/// The part of the system manager the coordinator needs.
@MainActor
protocol VpnTunnelControlling: AnyObject {
    var tunnelStatus: VpnTunnelStatus { get }
    func stopTunnel()
}

struct VpnSessionTiming {
    /// How often the status is read while waiting for the tunnel to go down.
    var pollInterval: TimeInterval = 0.1
    /// Upper bound of the wait for the system to report the tunnel as down.
    var stopTimeout: TimeInterval = 8
    /// Upper bound of a whole connect attempt, from the tap to "connected".
    var connectDeadline: TimeInterval = 30
}

@MainActor
final class VpnSessionCoordinator {

    /// What the owner must do after a status event of the current session.
    enum Event: Equatable {
        case connected
        case disconnected
        case invalid
    }

    private(set) var generation = 0
    /// Generation whose tunnel start was requested; status events count only for it.
    private var startedGeneration: Int?
    private var deadlineTask: Task<Void, Never>?
    private var stopTask: Task<Bool, Never>?

    private let tunnel: @MainActor () -> VpnTunnelControlling?
    private let timing: VpnSessionTiming
    private let onDeadline: @MainActor () -> Void

    /// - Parameters:
    ///   - tunnel: the current system tunnel (the manager can be replaced while loading preferences).
    ///   - onDeadline: called once when the connect deadline of the current attempt expires,
    ///     after the tunnel has been asked to stop.
    init(
        timing: VpnSessionTiming = VpnSessionTiming(),
        tunnel: @escaping @MainActor () -> VpnTunnelControlling?,
        onDeadline: @escaping @MainActor () -> Void
    ) {
        self.timing = timing
        self.tunnel = tunnel
        self.onDeadline = onDeadline
    }

    func isCurrent(_ gen: Int) -> Bool { gen == generation }

    // MARK: - Connect

    /// Starts a new attempt: supersedes whatever came before and arms the deadline.
    func beginConnect() -> Int {
        generation += 1
        startedGeneration = nil
        cancelDeadline()
        let gen = generation
        RTLog.info("vpn", "connect begin gen=\(gen)")
        armDeadline(for: gen)
        return gen
    }

    /// (Re)starts the connect deadline for `gen` with its full length. The owner
    /// pauses it around a step that can wait on the user (the system's first-use
    /// permission prompt) and arms it again afterwards.
    func armDeadline(for gen: Int) {
        guard isCurrent(gen) else { return }
        cancelDeadline()
        let deadline = timing.connectDeadline
        deadlineTask = Task { [weak self] in
            guard (try? await Task.sleep(nanoseconds: Self.nanos(deadline))) != nil else { return }
            self?.deadlineExpired(gen)
        }
    }

    /// Stops the connect deadline until `armDeadline` is called again.
    func pauseDeadline(for gen: Int) {
        guard isCurrent(gen) else { return }
        cancelDeadline()
    }

    /// Waits until the system tunnel is down, stopping a leftover session first.
    /// - Returns: true when the tunnel is down and `gen` is still the current attempt;
    ///   false when the wait timed out or the attempt was superseded meanwhile.
    func ensureStopped(for gen: Int) async -> Bool {
        if let pending = stopTask {
            _ = await pending.value
            stopTask = nil
        }
        guard isCurrent(gen) else { return false }
        guard let current = tunnel() else { return true }
        if !current.tunnelStatus.isDown {
            if current.tunnelStatus != .disconnecting {
                RTLog.info("vpn", "connect: stopping a leftover session, status=\(current.tunnelStatus)")
                current.stopTunnel()
            }
            let down = await waitUntilDown()
            guard isCurrent(gen) else { return false }
            if !down { RTLog.warn("vpn", "connect: previous session did not close in time") }
            return down
        }
        return true
    }

    /// Records that the system was asked to start the tunnel for `gen`.
    func tunnelStarted(for gen: Int) {
        guard isCurrent(gen) else { return }
        startedGeneration = gen
        RTLog.info("vpn", "tunnel start requested gen=\(gen)")
    }

    /// Ends an attempt that failed before the tunnel came up (no deadline needed any more).
    func abort(_ gen: Int) {
        guard isCurrent(gen) else { return }
        startedGeneration = nil
        cancelDeadline()
    }

    // MARK: - Status events

    /// Filters a system status change. Returns nil when it must be ignored: it
    /// belongs to a superseded session, or it is an intermediate status.
    func handleStatus(_ status: VpnTunnelStatus) -> Event? {
        guard startedGeneration == generation else {
            RTLog.debug("vpn", "status \(status) ignored (superseded session)")
            return nil
        }
        switch status {
        case .connected:
            cancelDeadline()
            RTLog.info("vpn", "status connected gen=\(generation)")
            return .connected
        case .disconnected:
            cancelDeadline()
            startedGeneration = nil
            RTLog.info("vpn", "status disconnected gen=\(generation)")
            return .disconnected
        case .invalid:
            cancelDeadline()
            startedGeneration = nil
            RTLog.warn("vpn", "status invalid gen=\(generation)")
            return .invalid
        case .connecting, .reasserting, .disconnecting:
            return nil
        }
    }

    // MARK: - Disconnect / cancel

    /// Stops the tunnel and supersedes the current attempt or session. Returns
    /// at once; the wait for the system to report "down" runs in the background
    /// and a later `ensureStopped` joins it.
    func beginDisconnect() {
        let wasStarted = startedGeneration != nil
        generation += 1
        startedGeneration = nil
        cancelDeadline()
        RTLog.info("vpn", "disconnect begin gen=\(generation)")
        stopAndWatch(force: wasStarted)
    }

    // MARK: - Private

    private func deadlineExpired(_ gen: Int) {
        guard isCurrent(gen) else { return }
        RTLog.warn("vpn", "connect deadline expired gen=\(gen)")
        generation += 1
        let wasStarted = startedGeneration != nil
        startedGeneration = nil
        deadlineTask = nil
        stopAndWatch(force: wasStarted)
        onDeadline()
    }

    private func stopAndWatch(force: Bool) {
        guard let current = tunnel() else { return }
        let wasDown = current.tunnelStatus.isDown
        current.stopTunnel()
        guard force || !wasDown else { return }
        stopTask = Task { [weak self] () -> Bool in
            guard let self else { return false }
            let down = await self.waitUntilDown()
            RTLog.info("vpn", down ? "disconnect completed" : "disconnect wait timed out")
            return down
        }
    }

    private func waitUntilDown() async -> Bool {
        let end = Date().addingTimeInterval(timing.stopTimeout)
        while true {
            if tunnel()?.tunnelStatus.isDown ?? true { return true }
            if Date() >= end { return false }
            guard (try? await Task.sleep(nanoseconds: Self.nanos(timing.pollInterval))) != nil else { return false }
        }
    }

    private func cancelDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
    }

    private static func nanos(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }
}
