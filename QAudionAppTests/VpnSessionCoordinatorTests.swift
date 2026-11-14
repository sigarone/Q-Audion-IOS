import XCTest
@testable import QAudionApp

/// The VPN session bookkeeping against a fake system tunnel: a connect waits for a closing session, the wait is
/// bounded, status events of a superseded session are ignored, and a connect that never reports ends at its deadline
/// with the tunnel stopped. Times are a few milliseconds, so every test runs in well under a second.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-ci.yml`.
@MainActor
final class VpnSessionCoordinatorTests: XCTestCase {

    /// A system tunnel whose status the test controls. `closeAfter` makes `stopTunnel` behave like the real thing:
    /// `.disconnecting` first, `.disconnected` after the delay; nil leaves the status alone (a stuck session).
    @MainActor
    private final class FakeTunnel: VpnTunnelControlling {
        var tunnelStatus: VpnTunnelStatus
        var stopCalls = 0
        var closeAfter: TimeInterval? = 0.03

        init(status: VpnTunnelStatus = .disconnected) {
            tunnelStatus = status
        }

        func stopTunnel() {
            stopCalls += 1
            guard let delay = closeAfter else { return }
            tunnelStatus = .disconnecting
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.tunnelStatus = .disconnected
            }
        }
    }

    private var deadlineCalls = 0

    private func makeCoordinator(
        _ tunnel: FakeTunnel,
        stopTimeout: TimeInterval = 1,
        connectDeadline: TimeInterval = 5
    ) -> VpnSessionCoordinator {
        deadlineCalls = 0
        return VpnSessionCoordinator(
            timing: VpnSessionTiming(pollInterval: 0.005, stopTimeout: stopTimeout, connectDeadline: connectDeadline),
            tunnel: { tunnel },
            onDeadline: { [unowned self] in self.deadlineCalls += 1 }
        )
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - Connect waits for the closing session

    func test_connectWaitsForAnInFlightDisconnect() async {
        let tunnel = FakeTunnel(status: .connected)
        let coordinator = makeCoordinator(tunnel)

        coordinator.beginDisconnect()
        XCTAssertEqual(tunnel.stopCalls, 1)
        XCTAssertEqual(tunnel.tunnelStatus, .disconnecting, "the system is still closing the old session")

        let gen = coordinator.beginConnect()
        let ready = await coordinator.ensureStopped(for: gen)

        XCTAssertTrue(ready)
        XCTAssertEqual(tunnel.tunnelStatus, .disconnected, "the start must not run before the old session is down")
        XCTAssertEqual(tunnel.stopCalls, 1, "the leftover session is stopped once, not again")
    }

    func test_connectStopsALeftoverSessionItDidNotStart() async {
        let tunnel = FakeTunnel(status: .connected)
        let coordinator = makeCoordinator(tunnel)

        let gen = coordinator.beginConnect()
        let ready = await coordinator.ensureStopped(for: gen)

        XCTAssertTrue(ready)
        XCTAssertEqual(tunnel.stopCalls, 1)
        XCTAssertEqual(tunnel.tunnelStatus, .disconnected)
    }

    func test_connectOnADownTunnelDoesNotWaitOrStop() async {
        let tunnel = FakeTunnel(status: .disconnected)
        let coordinator = makeCoordinator(tunnel)

        let gen = coordinator.beginConnect()
        let ready = await coordinator.ensureStopped(for: gen)

        XCTAssertTrue(ready)
        XCTAssertEqual(tunnel.stopCalls, 0)
    }

    func test_theWaitForTheTunnelToGoDownIsBounded() async {
        let tunnel = FakeTunnel(status: .disconnecting)
        tunnel.closeAfter = nil
        let coordinator = makeCoordinator(tunnel, stopTimeout: 0.05)

        let gen = coordinator.beginConnect()
        let ready = await coordinator.ensureStopped(for: gen)

        XCTAssertFalse(ready, "a session that never closes ends the wait with a failure, not a hang")
        XCTAssertTrue(coordinator.isCurrent(gen), "the attempt itself is still the current one, so the owner can report it")
    }

    func test_aWaitingConnectIsSupersededByANewerAttempt() async {
        let tunnel = FakeTunnel(status: .disconnecting)
        tunnel.closeAfter = nil
        let coordinator = makeCoordinator(tunnel)

        let first = coordinator.beginConnect()
        let waiting = Task { await coordinator.ensureStopped(for: first) }
        await pause(0.02)
        _ = coordinator.beginConnect()
        tunnel.tunnelStatus = .disconnected

        let ready = await waiting.value
        XCTAssertFalse(ready, "the older attempt must not go on to start the tunnel")
    }

    // MARK: - Superseded sessions

    func test_aLateDisconnectedFromTheOldSessionIsIgnored() {
        let tunnel = FakeTunnel(status: .connected)
        let coordinator = makeCoordinator(tunnel)

        let first = coordinator.beginConnect()
        coordinator.tunnelStarted(for: first)
        coordinator.beginDisconnect()
        let second = coordinator.beginConnect()

        // The old session reports that it closed while the new attempt is still preparing.
        XCTAssertNil(coordinator.handleStatus(.disconnected))
        XCTAssertTrue(coordinator.isCurrent(second))

        coordinator.tunnelStarted(for: second)
        XCTAssertEqual(coordinator.handleStatus(.connected), .connected)
    }

    func test_eventsAreIgnoredBeforeTheTunnelStartIsRequested() {
        let coordinator = makeCoordinator(FakeTunnel())
        _ = coordinator.beginConnect()

        XCTAssertNil(coordinator.handleStatus(.disconnected))
        XCTAssertNil(coordinator.handleStatus(.connected))
    }

    func test_aDisconnectedEventOfTheCurrentSessionIsReportedOnce() {
        let coordinator = makeCoordinator(FakeTunnel())
        let gen = coordinator.beginConnect()
        coordinator.tunnelStarted(for: gen)

        XCTAssertNil(coordinator.handleStatus(.connecting))
        XCTAssertEqual(coordinator.handleStatus(.disconnected), .disconnected)
        XCTAssertNil(coordinator.handleStatus(.disconnected), "the session is over; a repeat is not an event")
    }

    func test_anInvalidConfigurationOfTheCurrentSessionIsReported() {
        let coordinator = makeCoordinator(FakeTunnel())
        let gen = coordinator.beginConnect()
        coordinator.tunnelStarted(for: gen)

        XCTAssertEqual(coordinator.handleStatus(.invalid), .invalid)
    }

    // MARK: - Connect deadline

    func test_theDeadlineStopsTheTunnelAndReportsOnce() async {
        let tunnel = FakeTunnel(status: .connecting)
        let coordinator = makeCoordinator(tunnel, connectDeadline: 0.05)

        let gen = coordinator.beginConnect()
        coordinator.tunnelStarted(for: gen)
        await pause(0.2)

        XCTAssertEqual(deadlineCalls, 1)
        XCTAssertEqual(tunnel.stopCalls, 1, "the tunnel that never reported is stopped")
        XCTAssertFalse(coordinator.isCurrent(gen))
        XCTAssertNil(coordinator.handleStatus(.disconnected), "the stop it caused is not an event of a live session")
    }

    func test_theDeadlineAlsoCoversAnAttemptThatNeverStartedTheTunnel() async {
        let tunnel = FakeTunnel(status: .disconnected)
        let coordinator = makeCoordinator(tunnel, connectDeadline: 0.05)

        let gen = coordinator.beginConnect()
        await pause(0.2)

        XCTAssertEqual(deadlineCalls, 1, "a hang before the start must not leave the UI on connecting either")
        XCTAssertFalse(coordinator.isCurrent(gen), "the stalled attempt is superseded and ends without starting")
    }

    func test_connectedCancelsTheDeadline() async {
        let tunnel = FakeTunnel(status: .connecting)
        let coordinator = makeCoordinator(tunnel, connectDeadline: 0.05)

        let gen = coordinator.beginConnect()
        coordinator.tunnelStarted(for: gen)
        XCTAssertEqual(coordinator.handleStatus(.connected), .connected)
        await pause(0.2)

        XCTAssertEqual(deadlineCalls, 0)
        XCTAssertEqual(tunnel.stopCalls, 0)
        XCTAssertTrue(coordinator.isCurrent(gen))
    }

    func test_aPausedDeadlineDoesNotRunUntilItIsArmedAgain() async {
        let tunnel = FakeTunnel(status: .disconnected)
        let coordinator = makeCoordinator(tunnel, connectDeadline: 0.08)

        let gen = coordinator.beginConnect()
        coordinator.pauseDeadline(for: gen)
        await pause(0.2)
        XCTAssertEqual(deadlineCalls, 0, "no deadline while the system prompt waits on the user")

        coordinator.armDeadline(for: gen)
        await pause(0.03)
        XCTAssertEqual(deadlineCalls, 0, "the deadline starts over with its full length")
        await pause(0.2)
        XCTAssertEqual(deadlineCalls, 1)
    }

    // MARK: - Cancel while connecting

    func test_cancelWhileConnectingSupersedesStopsAndDisarmsTheDeadline() async {
        let tunnel = FakeTunnel(status: .connecting)
        let coordinator = makeCoordinator(tunnel, connectDeadline: 0.05)

        let gen = coordinator.beginConnect()
        coordinator.tunnelStarted(for: gen)
        coordinator.beginDisconnect()
        await pause(0.2)

        XCTAssertFalse(coordinator.isCurrent(gen), "the cancelled attempt must stop at its next check")
        XCTAssertEqual(tunnel.stopCalls, 1)
        XCTAssertEqual(deadlineCalls, 0, "a cancelled attempt does not later report a timeout")
        XCTAssertNil(coordinator.handleStatus(.disconnected))
    }

    func test_cancelBeforeTheTunnelStartSupersedesWithoutWaiting() async {
        let tunnel = FakeTunnel(status: .disconnected)
        let coordinator = makeCoordinator(tunnel)

        let gen = coordinator.beginConnect()
        coordinator.beginDisconnect()

        XCTAssertFalse(coordinator.isCurrent(gen))
        let next = coordinator.beginConnect()
        let ready = await coordinator.ensureStopped(for: next)
        XCTAssertTrue(ready)
    }
}
