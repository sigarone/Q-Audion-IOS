import XCTest
@testable import QAudionEngine

/// Delivery of the answering side's `restart_ice_request` and the offering side's handling of a peer request
/// (flag `calls.ice_fastswitch`). The plan and the decisions are pure; the runner is driven with a fake clock and a
/// fake socket. The wiring in the call controller is pinned by `FastSwitchWiringTests` and by the scans below.
final class RestartRequestDeliveryTests: XCTestCase {

    // MARK: - Plan

    private typealias Plan = RestartRequestPlan

    func testNothingIsWrittenWithoutAnAuthenticatedSocket() {
        var plan = Plan(startedAt: 0)
        XCTAssertEqual(plan.step(now: 0, liveGeneration: nil), .wait)
        XCTAssertEqual(plan.step(now: 5, liveGeneration: nil), .wait)
        XCTAssertEqual(plan.writes, 0)
    }

    func testTheFirstWriteHappensOnTheFirstAuthenticatedSocketWithoutAResendLabel() {
        var plan = Plan(startedAt: 0)
        XCTAssertEqual(plan.step(now: 3, liveGeneration: 7), .write(resend: nil))
    }

    func testARefusedWriteIsNotCountedAndNotConfirmed() {
        var plan = Plan(startedAt: 0)
        XCTAssertEqual(plan.step(now: 0, liveGeneration: 1), .write(resend: nil))
        plan.recordWrite(now: 0, generation: nil)
        XCTAssertEqual(plan.writes, 0)
        XCTAssertEqual(plan.step(now: 5, liveGeneration: 1), .write(resend: nil), "still has to be written")
    }

    func testTheRequestIsDeliveredOnlyWhenTheSameSocketIsStillLiveAfterTheConfirmWindow() {
        var plan = Plan(startedAt: 0)
        plan.recordWrite(now: 0, generation: 1)
        XCTAssertEqual(plan.step(now: 1.4, liveGeneration: 1), .wait)
        XCTAssertEqual(plan.step(now: 1.5, liveGeneration: 1), .delivered)
    }

    func testASocketThatDiesInsideTheConfirmWindowIsResentOnTheNextOneAsReconnect() {
        var plan = Plan(startedAt: 0)
        plan.recordWrite(now: 0, generation: 1)
        XCTAssertEqual(plan.step(now: 0.5, liveGeneration: nil), .wait)
        XCTAssertEqual(plan.step(now: 2.0, liveGeneration: nil), .wait, "a dead socket never confirms")
        XCTAssertEqual(plan.step(now: 3.0, liveGeneration: 2), .write(resend: .reconnect))
    }

    func testAReplacedSocketWithNoGapIsResentAsWsgen() {
        var plan = Plan(startedAt: 0)
        plan.recordWrite(now: 0, generation: 1)
        XCTAssertEqual(plan.step(now: 0.5, liveGeneration: 2), .write(resend: .wsgen))
    }

    func testAtMostTwelveWrites() {
        var plan = Plan(startedAt: 0)
        var now: TimeInterval = 0
        var gen = 0
        for expected in 1...Plan.maxWrites {
            gen += 1
            guard case .write = plan.step(now: now, liveGeneration: gen) else { return XCTFail("write \(expected)") }
            plan.recordWrite(now: now, generation: gen)
            now += 1.0
        }
        XCTAssertEqual(plan.writes, Plan.maxWrites)
        XCTAssertEqual(plan.step(now: now, liveGeneration: gen + 1), .giveUp)
    }

    func testTheBudgetIsThirtySeconds() {
        var plan = Plan(startedAt: 100)
        XCTAssertEqual(plan.step(now: 129.9, liveGeneration: nil), .wait)
        XCTAssertEqual(plan.step(now: 130, liveGeneration: nil), .giveUp)
        XCTAssertEqual(Plan.budgetSec, 30)
        XCTAssertEqual(Plan.confirmAfterSec, 1.5)
        XCTAssertEqual(Plan.maxWrites, 12)
    }

    // MARK: - Runner with a fake clock and socket

    private final class World: @unchecked Sendable {
        private let lock = NSLock()
        private var t: TimeInterval = 1000
        private var _writes: [(at: TimeInterval, gen: Int)] = []
        private var _logs: [String] = []
        /// Generation of the authenticated socket at time `t`, nil: none.
        var genAt: @Sendable (TimeInterval) -> Int?
        init(genAt: @escaping @Sendable (TimeInterval) -> Int?) { self.genAt = genAt }

        var now: TimeInterval { lock.withLock { t } }
        var writes: [(at: TimeInterval, gen: Int)] { lock.withLock { _writes } }
        var logs: [String] { lock.withLock { _logs } }

        func advance(_ s: TimeInterval) { lock.withLock { t += s } }

        func makeDelivery() -> RestartRequestDelivery {
            RestartRequestDelivery(environment: RestartRequestDelivery.Environment(
                write: { [self] in
                    let now = self.now
                    guard let g = self.genAt(now) else { return nil }
                    self.lock.withLock { self._writes.append((now, g)) }
                    return g
                },
                liveGeneration: { [self] in self.genAt(self.now) },
                ensureReady: { [self] _ in self.genAt(self.now) != nil },
                now: { [self] in self.now },
                sleep: { [self] s in
                    self.advance(s)
                    await Task.yield()
                },
                log: { [self] line in self.lock.withLock { self._logs.append(line) } }))
        }

        func waitForLog(containing needle: String) async {
            for _ in 0..<5000 {
                if logs.contains(where: { $0.contains(needle) }) { return }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
    }

    func testRequestOnADeadThenNewSocketIsNotCountedDeliveredAndIsResent() async {
        // gen 1 live for 0.6 s, a gap, gen 2 from 3 s on.
        let world = World { t in
            if t < 1000.6 { return 1 }
            if t < 1003 { return nil }
            return 2
        }
        let delivery = world.makeDelivery()
        let first = await delivery.start()
        XCTAssertTrue(first)
        await world.waitForLog(containing: "delivered=1")
        let writes = world.writes
        XCTAssertEqual(writes.map { $0.gen }, [1, 2], "written again on the next authenticated socket")
        XCTAssertGreaterThanOrEqual(writes[1].at, 1003)
        XCTAssertTrue(world.logs.contains("restart_ice fast=1 role=responder n=2 resend=1 reason=reconnect"))
        XCTAssertTrue(world.logs.contains("restart_ice fast=1 role=responder n=2 delivered=1"))
    }

    func testNothingIsWrittenWhileTheSocketIsNotAuthenticated() async {
        let world = World { t in t < 1003 ? nil : 1 }
        let delivery = world.makeDelivery()
        let first = await delivery.start()
        XCTAssertFalse(first, "no authenticated socket at start: nothing written")
        XCTAssertTrue(world.writes.isEmpty)
        await world.waitForLog(containing: "delivered=1")
        XCTAssertEqual(world.writes.count, 1)
        XCTAssertGreaterThanOrEqual(world.writes[0].at, 1003)
    }

    func testAWriteTheSocketRefusesIsNotAnAcceptedWrite() async {
        // liveGeneration says up, write refuses (stale): nothing may count as written.
        let refusals = ManagedRefusals()
        let world = World { _ in 1 }
        let delivery = RestartRequestDelivery(environment: RestartRequestDelivery.Environment(
            write: { refusals.next() ? nil : world.genAt(world.now) },
            liveGeneration: { 1 },
            ensureReady: { _ in true },
            now: { world.now },
            sleep: { s in world.advance(s); await Task.yield() },
            log: { _ in }))
        let first = await delivery.start()
        XCTAssertFalse(first)
        XCTAssertGreaterThan(refusals.calls, 0)
        delivery.cancel()
    }

    private final class ManagedRefusals: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0
        func next() -> Bool { lock.withLock { calls += 1; return calls <= 2 } }
    }

    func testTheBoundsHoldInTheRunner() async {
        // A new generation every second: never confirmed, so the writes stop at the cap.
        let world = World { t in Int((t - 1000).rounded(.down)) + 1 }
        let delivery = world.makeDelivery()
        _ = await delivery.start()
        await world.waitForLog(containing: "giveup=1")
        XCTAssertEqual(world.writes.count, RestartRequestPlan.maxWrites)
        XCTAssertTrue(world.logs.contains("restart_ice fast=1 role=responder n=12 giveup=1"))

        // No socket for the whole budget: nothing written, given up after 30 s.
        let dead = World { _ in nil }
        let d2 = dead.makeDelivery()
        _ = await d2.start()
        await dead.waitForLog(containing: "giveup=1")
        XCTAssertTrue(dead.writes.isEmpty)
        XCTAssertGreaterThanOrEqual(dead.now - 1000, RestartRequestPlan.budgetSec)
    }

    func testThePeerOffersArrivalEndsTheDelivery() async {
        let world = World { t in Int((t - 1000).rounded(.down)) + 1 }
        let delivery = world.makeDelivery()
        _ = await delivery.start()
        delivery.peerOfferArrived()
        for _ in 0..<50 { await Task.yield() }
        let n = world.writes.count
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(world.writes.count, n, "no write after the peer's offer arrived")
        XCTAssertTrue(world.logs.contains("restart_ice fast=1 role=responder delivered=1"))
    }

    // MARK: - Offering side: peer request

    private typealias D = FastSwitchDecisions

    private func peerAction(flagOn: Bool = true, initiator: Bool = true, reason: String = D.peerRequestReason,
                            iceDown: Bool = false, unanswered: Bool = false) -> D.PeerRequestAction {
        D.peerRequestAction(flagOn: flagOn, initiator: initiator, reason: reason,
                            iceNotConnected: iceDown, hasUnansweredOffer: unanswered)
    }

    func testAPeerRequestAfterAnUnansweredOfferResendsThatOffer() {
        XCTAssertEqual(peerAction(unanswered: true), .resendInflight)
        XCTAssertEqual(peerAction(iceDown: true, unanswered: true), .resendInflight)
    }

    func testAPeerRequestWhileIceIsDownIsNotDebounced() {
        XCTAssertEqual(peerAction(iceDown: true), .bypassGates)
        XCTAssertEqual(peerAction(), .normal, "ICE up and nothing in flight: the debounce and the gate apply")
    }

    func testCachedServersAreUsedForABypassedPeerRequestOnly() {
        XCTAssertTrue(D.usesCachedServersForRestart(flagOn: true, reason: D.peerRequestReason, peerRequestBypass: true))
        XCTAssertFalse(D.usesCachedServersForRestart(flagOn: true, reason: D.peerRequestReason))
        XCTAssertFalse(D.usesCachedServersForRestart(flagOn: true, reason: D.peerRequestReason,
                                                     forceProbe: true, peerRequestBypass: true))
        XCTAssertFalse(D.usesCachedServersForRestart(flagOn: false, reason: D.peerRequestReason, peerRequestBypass: true))
    }

    func testFlagOffKeepsTheOldBehaviour() {
        XCTAssertEqual(peerAction(flagOn: false, iceDown: true, unanswered: true), .normal)
        XCTAssertFalse(D.requestStillSentInsideGate(flagOn: false, initiator: false,
                                                    reason: D.interfaceChangeReason, peerUsesRequest: true))
        XCTAssertEqual(peerAction(initiator: false, iceDown: true, unanswered: true), .normal, "answering side")
        XCTAssertEqual(peerAction(reason: "watchdog", iceDown: true, unanswered: true), .normal, "other reasons")
    }

    func testAnInterfaceChangeInsideTheGateStillSendsTheRequest() {
        XCTAssertTrue(D.requestStillSentInsideGate(flagOn: true, initiator: false,
                                                   reason: D.interfaceChangeReason, peerUsesRequest: true))
        XCTAssertFalse(D.requestStillSentInsideGate(flagOn: true, initiator: true,
                                                    reason: D.interfaceChangeReason, peerUsesRequest: true))
        XCTAssertFalse(D.requestStillSentInsideGate(flagOn: true, initiator: false,
                                                    reason: D.interfaceChangeReason, peerUsesRequest: false))
    }

    // MARK: - Wiring in the controller (source scan; the controller needs WebRTC)

    private func controllerSource(file: StaticString = #filePath) -> String {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(
                "QAudionEngine/Sources/QAudionEngine/WebRTC/QAudionWebRtcCallController.swift")
            if let text = try? String(contentsOf: candidate, encoding: .utf8) {
                return text.replacingOccurrences(of: "\r\n", with: "\n")
            }
        }
        XCTFail("controller source not found")
        return ""
    }

    func testTheControllerResendsTheSameOfferAndBypassesTheGateOnlyThroughTheDecision() {
        let ctl = controllerSource()
        XCTAssertTrue(ctl.contains("let peerAction = FastSwitchDecisions.peerRequestAction(") ||
                      ctl.contains("var peerAction = FastSwitchDecisions.peerRequestAction("))
        XCTAssertTrue(ctl.contains("if peerAction != .normal {\n                lastIceRestartAt = now"))
        XCTAssertTrue(ctl.contains("if peerAction == .resendInflight, let offer = inflightOffer"))
        XCTAssertTrue(ctl.contains("sdp: offer.sdp, capabilities: offer.capabilities"))
        XCTAssertEqual(ctl.components(separatedBy: "createOffer(audioOnly: true, iceRestart: true)").count - 1, 1)
        XCTAssertTrue(ctl.contains("trig=\\(FastSwitchDecisions.peerRequestTrigLabel) resend=1"))
    }

    func testTheCalleeRequestUsesTheDeliveryOnlyWithTheFlagOn() {
        let ctl = controllerSource()
        XCTAssertTrue(ctl.contains("if fastSwitchOn {\n                // Written only on an authenticated socket"))
        XCTAssertTrue(ctl.contains("reqSent = await restartRequestDelivery().start()"))
        XCTAssertTrue(ctl.contains("reqSent = await callingApi.sendRestartIceRequest(recipientId: rid)"),
                      "flag off keeps the previous send")
        XCTAssertTrue(ctl.contains("restartRequestDelivery().peerOfferArrived()"))
    }
}
