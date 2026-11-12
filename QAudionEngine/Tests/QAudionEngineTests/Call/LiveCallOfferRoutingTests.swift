import XCTest
@testable import QAudionEngine

/// An OFFER of another call arriving while a call is live must leave the live call as it is.
final class LiveCallOfferRoutingTests: XCTestCase {

    private let liveId = "aaaaaaaa-1111-2222-3333-444444444444"
    private let otherId = "bbbbbbbb-1111-2222-3333-444444444444"

    private func offer(callId: String, round: Int = 1) -> AndroidHandshakeBundle {
        AndroidHandshakeBundle(
            kind: .offer, callId: callId,
            pqcPublicKey: Data(repeating: 0xA1, count: 1568).base64EncodedString(),
            x25519PublicKey: Data(repeating: 0xA2, count: 32).base64EncodedString(),
            sasCommit: nil,
            rekeyNonce: V6TestFixtures.rekeyNonce.base64EncodedString(), rekeyRound: round)
    }

    private struct Seen {
        var processing: [String] = []
        var fatals: [String] = []
        var sent = 0
        var keyInstalls = 0
        var relayReady = 0
    }

    private func receive(_ integ: QAudionCallIntegration, _ bundle: AndroidHandshakeBundle, callId: String) async -> Seen {
        var seen = Seen()
        integ.sendCallProcessing = { cid, _ in seen.processing.append(cid) }
        integ.onHandshakeFatal = { _, reason in seen.fatals.append(reason) }
        integ.onPqcSessionKeyEstablished = { _ in seen.keyInstalls += 1 }
        integ.onRelaySessionReady = { _, _, _ in seen.relayReady += 1 }
        _ = try? await integ.onAndroidBundleReceived(
            bundle: bundle, callId: callId, callerId: "peer-1", capsBind: CapsBind.analyze(bundle: bundle),
            sendOpaqueRaw: { _ in seen.sent += 1 })
        return seen
    }

    func testPolicy() {
        XCTAssertTrue(QAudionCallIntegration.isOfferForOtherLiveCall(
            offerCallId: otherId, sessionCallIds: [liveId], isLive: true))
        XCTAssertFalse(QAudionCallIntegration.isOfferForOtherLiveCall(
            offerCallId: liveId.uppercased(), sessionCallIds: [liveId], isLive: true), "the live call's own OFFER")
        XCTAssertFalse(QAudionCallIntegration.isOfferForOtherLiveCall(
            offerCallId: otherId, sessionCallIds: [liveId], isLive: false), "no live call")
        XCTAssertFalse(QAudionCallIntegration.isOfferForOtherLiveCall(
            offerCallId: otherId, sessionCallIds: [], isLive: true), "no session held")
    }

    /// A round-1 OFFER of another call, with a call live: nothing happens for it, the live call keeps its session.
    func testRoundOneOfferOfAnotherCallLeavesTheLiveCallAlone() async {
        let integ = QAudionCallIntegration()
        integ.configureLiveCallForTesting(callId: liveId)
        let seen = await receive(integ, offer(callId: otherId), callId: otherId)
        XCTAssertTrue(seen.processing.isEmpty, "the OFFER was not taken up")
        XCTAssertTrue(seen.fatals.isEmpty)
        XCTAssertEqual(seen.sent, 0)
        XCTAssertEqual(seen.keyInstalls, 0)
        XCTAssertEqual(seen.relayReady, 0)
        XCTAssertTrue(integ.hasProcessedOffer(callId: liveId))
        XCTAssertFalse(integ.hasProcessedOffer(callId: otherId))
    }

    /// Any other round of another call is dropped the same way, without ending the live call.
    func testRoundTwoOfferOfAnotherCallDoesNotEndTheLiveCall() async {
        let integ = QAudionCallIntegration()
        integ.configureLiveCallForTesting(callId: liveId)
        let seen = await receive(integ, offer(callId: otherId, round: 2), callId: otherId)
        XCTAssertTrue(seen.fatals.isEmpty)
        XCTAssertTrue(seen.processing.isEmpty)
        XCTAssertTrue(integ.hasProcessedOffer(callId: liveId))
    }

    /// Controls: the live call's own OFFER and an OFFER with no live call are taken up as before.
    func testOwnOfferAndOfferWithoutLiveCallAreTakenUp() async {
        let live = QAudionCallIntegration()
        live.configureLiveCallForTesting(callId: liveId)
        let own = await receive(live, offer(callId: liveId, round: 2), callId: liveId)
        XCTAssertEqual(own.processing, [liveId])

        let idle = QAudionCallIntegration()
        let first = await receive(idle, offer(callId: otherId), callId: otherId)
        XCTAssertEqual(first.processing, [otherId])
    }

    // MARK: - routing before any state, and one call per integration

    private func offerWithCaps(callId: String, round: Int = 1) -> AndroidHandshakeBundle {
        AndroidHandshakeBundle(
            kind: .offer, callId: callId,
            pqcPublicKey: Data(repeating: 0xA1, count: 1568).base64EncodedString(),
            x25519PublicKey: Data(repeating: 0xA2, count: 32).base64EncodedString(),
            capabilities: .init(ratchetV3: nil, ratchetV4: false, srtpDirKeyV1: false, innerAudioAadV1: false),
            sasCommit: nil,
            rekeyNonce: V6TestFixtures.rekeyNonce.base64EncodedString(), rekeyRound: round)
    }

    /// (1) A dropped OFFER of another call leaves the live call's negotiated capabilities, and so its outer mode, as they were.
    func testDroppedOfferLeavesTheLiveCallsCapabilitiesAndOuterModeAlone() async {
        let integ = QAudionCallIntegration()
        integ.configureLiveCallForTesting(callId: liveId)
        integ.setPeerCapabilitiesForTesting(srtpDirKey: true, ratchetV4: true, innerAudioAad: true)
        let outerBefore = integ.negotiatedSrtpDirKey
        let before = integ.peerCapabilitiesForTesting
        _ = await receive(integ, offerWithCaps(callId: otherId), callId: otherId)
        let after = integ.peerCapabilitiesForTesting
        XCTAssertEqual(after.srtpDirKey, before.srtpDirKey)
        XCTAssertEqual(after.seen, before.seen)
        XCTAssertEqual(after.ratchetV4, before.ratchetV4)
        XCTAssertEqual(after.innerAudioAad, before.innerAudioAad)
        XCTAssertTrue(after.srtpDirKey, "the bit the dropped OFFER did not advertise is still set")
        XCTAssertEqual(integ.negotiatedSrtpDirKey, outerBefore)
    }

    /// The same holds for an OFFER dropped while the call is only ringing (bound, no session yet).
    func testOfferDroppedWhileRingingLeavesCapabilitiesAlone() async {
        let integ = QAudionCallIntegration()
        integ.bindOfferCallForTesting(callId: liveId)
        integ.setPeerCapabilitiesForTesting(srtpDirKey: true, ratchetV4: true, innerAudioAad: false)
        let before = integ.peerCapabilitiesForTesting
        let seen = await receive(integ, offerWithCaps(callId: otherId), callId: otherId)
        XCTAssertTrue(seen.processing.isEmpty)
        XCTAssertEqual(integ.peerCapabilitiesForTesting.srtpDirKey, before.srtpDirKey)
        XCTAssertEqual(integ.peerCapabilitiesForTesting.ratchetV4, before.ratchetV4)
        XCTAssertEqual(integ.boundOfferCallIdForTesting, liveId)
    }

    /// (2) Two OFFERs for different calls racing through the routing decision: exactly one passes, the other is refused.
    func testOnlyOneOfTwoInterleavedOffersIsTakenUp() {
        for _ in 0..<200 {
            let integ = QAudionCallIntegration()
            let box = RouteBox()
            let ids = [liveId, otherId]
            DispatchQueue.concurrentPerform(iterations: 2) { i in
                let r = integ.routeOffer(callId: ids[i])
                box.add(r)
            }
            XCTAssertEqual(box.routes.filter { $0 == .claimed }.count, 1)
            XCTAssertEqual(box.routes.filter { $0 == .other }.count, 1)
        }
    }

    /// While X rings (no session yet, not active), the OFFER of Y that queued behind it is refused, and X's own OFFER still passes.
    func testSecondCallIsRefusedWhileTheFirstRings() {
        let integ = QAudionCallIntegration()
        XCTAssertEqual(integ.routeOffer(callId: liveId), .claimed)
        XCTAssertEqual(integ.routeOffer(callId: otherId), .other)
        XCTAssertEqual(integ.routeOffer(callId: liveId.uppercased()), .alreadyBound)
        XCTAssertEqual(integ.boundOfferCallIdForTesting, liveId)
    }

    /// The first OFFER that ends without establishing anything gives the binding back; one that holds a session keeps it.
    func testBindingIsReleasedOnlyWhenNothingWasEstablished() {
        let integ = QAudionCallIntegration()
        XCTAssertEqual(integ.routeOffer(callId: liveId), .claimed)
        integ.releaseOfferClaimForTesting(callId: liveId)
        XCTAssertNil(integ.boundOfferCallIdForTesting)
        XCTAssertEqual(integ.routeOffer(callId: otherId), .claimed, "a real call is not refused on account of a failed one")

        let held = QAudionCallIntegration()
        held.configureLiveCallForTesting(callId: liveId)
        XCTAssertEqual(held.routeOffer(callId: liveId), .claimed)
        held.releaseOfferClaimForTesting(callId: liveId)
        XCTAssertEqual(held.boundOfferCallIdForTesting, liveId)
    }

    /// (3) The same callId keeps working once bound: a replacement of an unanswered round 1 (A2) and a rekey.
    func testSameCallIdOffersAreStillTakenUpAfterTheBinding() async {
        let integ = QAudionCallIntegration()
        integ.bindOfferCallForTesting(callId: liveId)
        let replacement = await receive(integ, offer(callId: liveId, round: 1), callId: liveId)
        XCTAssertEqual(replacement.processing, [liveId], "the A2 replacement of an unanswered round 1 is routed on")
        let rekey = await receive(integ, offer(callId: liveId, round: 2), callId: liveId)
        XCTAssertEqual(rekey.processing, [liveId])
        XCTAssertEqual(integ.routeOffer(callId: liveId), .alreadyBound)
    }

    /// Wiring: the routing decision runs before the first write of any peer capability, and the capability bits of an
    /// OFFER are written only where the OFFER is accepted (inside the `.offer` case, with its fingerprint).
    func testRoutingPrecedesEveryCapabilityWrite() throws {
        var dir = URL(fileURLWithPath: #filePath)
        var src: String?
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let c = dir.appendingPathComponent("QAudionEngine/Sources/QAudionEngine/Integration/QAudionCallIntegration.swift")
            if FileManager.default.fileExists(atPath: c.path) { src = try String(contentsOf: c, encoding: .utf8); break }
        }
        let text = try XCTUnwrap(src, "source not found")
        let entry = try XCTUnwrap(text.range(of: "public func onAndroidBundleReceived("))
        let body = String(text[entry.upperBound...])
        let routeAt = try XCTUnwrap(body.range(of: "switch routeOffer(callId: callId)"))
        let writeAt = try XCTUnwrap(body.range(of: "applyPeerCapabilities(bundle: bundle, srtpDirKeyAdvertised: peerSrtpDirKeyAdvertised)"))
        XCTAssertLessThan(routeAt.lowerBound, writeAt.lowerBound)
        let offerCase = try XCTUnwrap(body.range(of: "case .offer:"))
        let acceptedAt = try XCTUnwrap(body.range(of: "applyPeerCapabilitiesLocked(bundle: bundle"))
        XCTAssertLessThan(writeAt.lowerBound, offerCase.lowerBound, "no capability write of an OFFER before its case")
        XCTAssertLessThan(offerCase.lowerBound, acceptedAt.lowerBound)
    }
    // MARK: - ACCEPT of another call

    private func accept(callId: String, round: Int?) -> AndroidHandshakeBundle {
        AndroidHandshakeBundle(
            kind: .accept, callId: callId,
            ciphertext: .init(pqc: Data(repeating: 0xB1, count: 1568).base64EncodedString(),
                              x25519: Data(repeating: 0xB2, count: 32).base64EncodedString()),
            capabilities: .init(ratchetV3: nil, ratchetV4: false, srtpDirKeyV1: false, innerAudioAadV1: false),
            rekeyRound: round)
    }

    private final class ResumeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [Data?] = []
        func add(_ v: Data?) { lock.lock(); calls.append(v); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
    }

    /// An ACCEPT of another call writes no capability and does not consume the live rekey; the honest ACCEPT afterwards
    /// still takes the waiting round and is processed.
    func testForeignAcceptLeavesCapabilitiesAndTheWaitingRekeyAlone() async throws {
        let integ = QAudionCallIntegration()
        integ.configureLiveCallForTesting(callId: liveId)
        integ.stashSentOfferForTesting(callId: liveId)
        integ.setPeerCapabilitiesForTesting(srtpDirKey: true, ratchetV4: true, innerAudioAad: true)
        let resumed = ResumeBox()
        let attemptId = try integ.installWaitingReKeyAttemptForTesting(round: 2) { resumed.add($0) }
        let before = integ.peerCapabilitiesForTesting

        _ = try? await integ.onAndroidBundleReceived(
            bundle: accept(callId: otherId, round: 2), callId: otherId, callerId: "peer-1",
            capsBind: CapsBind.analyze(bundle: accept(callId: otherId, round: 2)), sendOpaqueRaw: { _ in })

        let after = integ.peerCapabilitiesForTesting
        XCTAssertEqual(after.srtpDirKey, before.srtpDirKey)
        XCTAssertEqual(after.ratchetV4, before.ratchetV4)
        XCTAssertEqual(after.innerAudioAad, before.innerAudioAad)
        let pending = try XCTUnwrap(integ.reKeyAttemptForTesting, "the live rekey is still there")
        XCTAssertEqual(pending.id, attemptId)
        XCTAssertFalse(pending.acceptReached)
        XCTAssertEqual(resumed.count, 0)

        // The honest ACCEPT of the call takes the waiting round: it is processed and the attempt is resolved once.
        let honest = accept(callId: liveId, round: 2)
        _ = try? await integ.onAndroidBundleReceived(
            bundle: honest, callId: liveId, callerId: "peer-1", capsBind: CapsBind.analyze(bundle: honest), sendOpaqueRaw: { _ in })
        XCTAssertEqual(resumed.count, 1, "the honest ACCEPT reached the round and resolved it")
    }

    /// An ACCEPT with no OFFER of its call behind it writes nothing, whatever else is held.
    func testAcceptWithoutAnOwnOfferWritesNoCapability() async {
        let integ = QAudionCallIntegration()
        let bundle = accept(callId: otherId, round: 1)
        _ = try? await integ.onAndroidBundleReceived(
            bundle: bundle, callId: otherId, callerId: "peer-1", capsBind: CapsBind.analyze(bundle: bundle), sendOpaqueRaw: { _ in })
        XCTAssertFalse(integ.peerCapabilitiesForTesting.seen)
    }

    /// Wiring: the sent-OFFER transcript is checked before a waiting rekey is taken.
    func testTranscriptIsCheckedBeforeTheWaitingRekeyIsTaken() throws {
        var dir = URL(fileURLWithPath: #filePath)
        var src: String?
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let c = dir.appendingPathComponent("QAudionEngine/Sources/QAudionEngine/Integration/QAudionCallIntegration.swift")
            if FileManager.default.fileExists(atPath: c.path) { src = try String(contentsOf: c, encoding: .utf8); break }
        }
        let text = try XCTUnwrap(src, "source not found")
        let acceptCase = try XCTUnwrap(text.range(of: "case .accept:
            // Originator side"))
        let tail = String(text[acceptCase.upperBound...])
        let guardAt = try XCTUnwrap(tail.range(of: "but no sent-OFFER transcript is stashed"))
        let takeAt = try XCTUnwrap(tail.range(of: "takeWaitingReKeyAttempt(round: waitingRekeyRound)"))
        XCTAssertLessThan(guardAt.lowerBound, takeAt.lowerBound)
    }
}

private final class RouteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [QAudionCallIntegration.OfferRoute] = []
    func add(_ r: QAudionCallIntegration.OfferRoute) { lock.lock(); stored.append(r); lock.unlock() }
    var routes: [QAudionCallIntegration.OfferRoute] { lock.lock(); defer { lock.unlock() }; return stored }
}
