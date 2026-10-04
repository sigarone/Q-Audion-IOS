import XCTest
@testable import QAudionEngine

/// The K-round rules the first iOS pass left out (WIRE_SPEC §3.7.1 R-KCMAC-ATOMIC, R-REKEY-ACCEPT-WAIT,
/// R-ACCEPT-RESEND; spec 79f72a25): the proof of arrival of a rekey ACCEPT, one step at a time on the per-call state, the
/// held-set purge, the offerer taking only the ACCEPT of the round in flight, and the acceptor re-sending the exact bytes of
/// its ACCEPTs after a socket re-authentication. What needs a live provider (AppState) is pinned on the source text.
final class KcMacKRoundFixTests: XCTestCase {

    private let callId = "11111111-2222-3333-4444-555555555555"
    private let hashA = Data(repeating: 0xA1, count: 32)
    private let appPath = "QAudionApp/AppState.swift"
    private let integrationPath = "QAudionEngine/Sources/QAudionEngine/Integration/QAudionCallIntegration.swift"

    private func commit(_ n: UInt8) -> Data {
        // swiftlint:disable:next force_unwrapping
        SasCommit.commit(callId: callId, nonce: Data(repeating: n, count: 32))!
    }

    /// Records what the transport was handed, safe to read after concurrent tasks finished.
    private final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }

    private func pendingRound(_ number: Int, initiator: Bool = true) -> KcMacRoundBook.PendingRound {
        KcMacRoundBook.PendingRound(
            round: number,
            context: KcMacRound(
                kcKey: KeyConfirmation.deriveKcKey(sessionKey: Data("round-\(number)".utf8) + Data(repeating: 0x5A, count: 32)),
                transcript: Data("transcript-round-\(number)".utf8),
                isInitiator: initiator))
    }

    private func peerPayload(_ round: KcMacRoundBook.PendingRound) -> String {
        (Data([round.peerRole]) + round.expectedPeerMac).base64EncodedString()
    }

    private func stranger(_ seed: UInt8) -> String {
        (Data([0x01]) + Data(repeating: seed, count: 32)).base64EncodedString()
    }

    // MARK: - R-KCMAC-ATOMIC: one step at a time, whichever runs first wins

    /// A round decided first never fails: the expiry that follows finds nothing pending.
    func testAnExpiryAfterTheDecisionChangesNothing() {
        var book = KcMacRoundBook()
        let r2 = pendingRound(2)
        _ = book.arm(r2, nowMs: 0)
        XCTAssertEqual(book.receive(payload: peerPayload(r2), nowMs: 1), .decided(.verified(round: 2)))
        XCTAssertFalse(book.expire(round: 2), "decided first: the window's end is no failure")
        XCTAssertTrue(book.isDecided(round: 2))
    }

    /// A round that failed first is not decided afterwards: its MAC is no longer attributed, it is only held.
    func testADecisionAfterTheExpiryDoesNotHappen() {
        var book = KcMacRoundBook()
        let r2 = pendingRound(2)
        _ = book.arm(r2, nowMs: 0)
        XCTAssertTrue(book.expire(round: 2), "the window ended while it was pending")
        XCTAssertEqual(book.receive(payload: peerPayload(r2), nowMs: 1), .held, "never judged, never verified")
        XCTAssertFalse(book.isDecided(round: 2))
    }

    /// The arming is one step: when a held MAC is offered again the round is already pending, so a MAC that overtook
    /// the arming is decided by it and is not left to wait for the next arming.
    func testAnArmingDecidesTheRoundFromAMacThatOvertookIt() {
        var book = KcMacRoundBook()
        let r2 = pendingRound(2)
        XCTAssertEqual(book.receive(payload: peerPayload(r2), nowMs: 0), .held)
        let armed = book.arm(r2, nowMs: 100)
        XCTAssertEqual(armed.verdicts, [.verified(round: 2)])
        XCTAssertTrue(book.isDecided(round: 2))
        XCTAssertEqual(book.heldCount, 0)
    }

    // MARK: - the held set: stale entries are dropped before a new MAC is held

    /// 4 stale and 4 fresh held MACs: a new MAC drops the stale ones first and is held; the limit of 8 then applies to
    /// the fresh entries that remain.
    func testStaleHeldMacsAreDroppedBeforeANewOneIsHeldAndTheLimitCountsTheFreshOnes() {
        var book = KcMacRoundBook()
        for seed in 1...4 { XCTAssertEqual(book.receive(payload: stranger(UInt8(seed)), nowMs: 0), .held) }
        for seed in 5...8 { XCTAssertEqual(book.receive(payload: stranger(UInt8(seed)), nowMs: 20_000), .held) }
        XCTAssertEqual(book.heldCount, 8)
        // 31 s: the first four are stale (30 s or more); the ninth MAC takes a slot, four fresh ones stay.
        XCTAssertEqual(book.receive(payload: stranger(9), nowMs: 31_000), .held)
        XCTAssertEqual(book.heldCount, 5)
        for seed in 10...12 { XCTAssertEqual(book.receive(payload: stranger(UInt8(seed)), nowMs: 31_000), .held) }
        XCTAssertEqual(book.heldCount, 8)
        XCTAssertEqual(book.receive(payload: stranger(13), nowMs: 31_000), .heldDropped, "eight fresh entries: full")
    }

    // MARK: - R-ACCEPT-RESEND: the proof of arrival of a rekey ACCEPT is the peer's MAC of that round

    func testTheDecidedRoundsAreTheProofOfArrival() {
        var book = KcMacRoundBook()
        let r2 = pendingRound(2)
        let r3 = pendingRound(3)
        _ = book.arm(r2, nowMs: 0)
        _ = book.arm(r3, nowMs: 1)
        XCTAssertFalse(book.isDecided(round: 2))
        XCTAssertEqual(book.receive(payload: peerPayload(r3), nowMs: 2), .decided(.verified(round: 3)))
        XCTAssertTrue(book.isDecided(round: 3))
        XCTAssertFalse(book.isDecided(round: 2), "a superseded round is decided only by its own MAC")
    }

    func testARekeyAcceptIsDueForResendUntilItsRoundIsDecided() async throws {
        let integ = QAudionCallIntegration()
        let wire = Wire()
        try await integ.emitJsonAccept(callId: callId, wire: "ACCEPT-R2", sendOpaqueRaw: { wire.add($0) },
                                       isRound1: false, calleeToken: nil, acceptRound: 2)
        try await integ.emitJsonAccept(callId: callId, wire: "ACCEPT-R3", sendOpaqueRaw: { wire.add($0) },
                                       isRound1: false, calleeToken: nil, acceptRound: 3)
        var decided: Set<Int> = []
        XCTAssertEqual(integ.acceptsDueForResend(callId: callId, roundDecided: { decided.contains($0) }).map { $0.round }, [2, 3])
        decided.insert(2)
        XCTAssertEqual(integ.acceptsDueForResend(callId: callId.uppercased(), roundDecided: { decided.contains($0) }).map { $0.round }, [3])
        decided.insert(3)
        XCTAssertTrue(integ.acceptsDueForResend(callId: callId, roundDecided: { decided.contains($0) }).isEmpty)
    }

    /// An ACCEPT that was never handed to the transport (nothing sent, or held while ringing) is never re-sent.
    func testAnAcceptThatWasNeverSentIsNeverDue() async throws {
        let integ = QAudionCallIntegration()
        let token = try XCTUnwrap(integ.sasCommit.beginCalleeOwned(callId: callId, commit: commit(1), acceptHash: hashA))
        XCTAssertTrue(integ.acceptsDueForResend(callId: callId, roundDecided: { _ in false }).isEmpty, "nothing sent yet")
        integ.shouldHoldResponderAccept = { _ in true }
        try await integ.emitJsonAccept(callId: callId, wire: "ACCEPT-1", sendOpaqueRaw: { _ in XCTFail("held, not sent") },
                                       isRound1: true, calleeToken: token, acceptRound: 1)
        XCTAssertTrue(integ.sasCommit.isWaitingForReveal(callId: callId), "the callee context exists")
        XCTAssertTrue(integ.acceptsDueForResend(callId: callId, roundDecided: { _ in false }).isEmpty,
                      "a round-1 ACCEPT held while ringing is not re-sent")
    }

    /// Released from the hold, the ACCEPT is recorded at the hand-over and is due until the REVEAL verified.
    func testTheRoundOneAcceptIsDueFromItsReleaseUntilTheRevealVerified() async throws {
        let integ = QAudionCallIntegration()
        let wire = Wire()
        integ.setResponderSenderForTesting { wire.add($0) }
        let token = try XCTUnwrap(integ.sasCommit.beginCalleeOwned(callId: callId, commit: commit(1), acceptHash: hashA))
        integ.shouldHoldResponderAccept = { _ in true }
        try await integ.emitJsonAccept(callId: callId, wire: "ACCEPT-1", sendOpaqueRaw: { wire.add($0) },
                                       isRound1: true, calleeToken: token, acceptRound: 1)
        XCTAssertTrue(wire.all.isEmpty)
        integ.shouldHoldResponderAccept = { _ in false }
        let released = await integ.releaseHeldAccept(callId: callId)
        XCTAssertTrue(released)
        XCTAssertEqual(wire.all, ["ACCEPT-1"])
        XCTAssertEqual(integ.acceptsDueForResend(callId: callId, roundDecided: { _ in true }),
                       [QAudionCallIntegration.SentAccept(round: 1, wire: "ACCEPT-1")],
                       "round 1 is not decided by a MAC: only the REVEAL is its proof")

        // The caller's REVEAL names this ACCEPT and opens the commitment: the proof of arrival.
        integ.sasCommit.recordRound1(callId: callId, sessionKey: Data(repeating: 7, count: 32), acceptHash: hashA)
        let reveal = try XCTUnwrap(SasReveal.serialize(callId: callId, acceptBinding: hashA, nonce: Data(repeating: 1, count: 32)))
        XCTAssertEqual(integ.sasCommit.calleeOnReveal(callId: callId, data: reveal, nowMs: 10), .sasReady)
        XCTAssertTrue(integ.acceptsDueForResend(callId: callId, roundDecided: { _ in false }).isEmpty)
    }

    /// The bytes that go out again are the bytes first handed to the transport, round by round, in order.
    func testTheResendHandsTheExactFirstBytesToTheTransportInRoundOrder() async throws {
        let integ = QAudionCallIntegration()
        let wire = Wire()
        integ.setResponderSenderForTesting { wire.add($0) }
        try await integ.emitJsonAccept(callId: callId, wire: "ACCEPT-R3", sendOpaqueRaw: { _ in }, isRound1: false,
                                       calleeToken: nil, acceptRound: 3)
        try await integ.emitJsonAccept(callId: callId, wire: "ACCEPT-R2", sendOpaqueRaw: { _ in }, isRound1: false,
                                       calleeToken: nil, acceptRound: 2)
        let due = integ.acceptsDueForResend(callId: callId, roundDecided: { _ in false })
        XCTAssertEqual(due.map { $0.round }, [2, 3], "oldest round first")
        await integ.resendAcceptsAfterReauth(due, callId: callId)
        XCTAssertEqual(wire.all, ["ACCEPT-R2", "ACCEPT-R3"])
        await integ.resendAcceptsAfterReauth([], callId: callId)
        XCTAssertEqual(wire.all.count, 2, "nothing due, nothing sent")
    }

    /// A cached-ACCEPT replay of an OFFER duplicate hands over the same bytes: nothing new is recorded.
    func testAReplayOfTheCachedAcceptRecordsTheSameBytes() async throws {
        let integ = QAudionCallIntegration()
        try await integ.emitJsonAccept(callId: callId, wire: "ACCEPT-R2", sendOpaqueRaw: { _ in }, isRound1: false,
                                       calleeToken: nil, acceptRound: 2)
        try await integ.emitJsonAccept(callId: callId, wire: "ACCEPT-R2", sendOpaqueRaw: { _ in }, isRound1: false,
                                       calleeToken: nil, acceptRound: 2)
        XCTAssertEqual(integ.acceptsDueForResend(callId: callId, roundDecided: { _ in false }),
                       [QAudionCallIntegration.SentAccept(round: 2, wire: "ACCEPT-R2")])
    }

    func testTheSentAcceptsAreForgottenWhenTheCallIsWiped() async throws {
        let integ = QAudionCallIntegration()
        try await integ.emitJsonAccept(callId: callId, wire: "ACCEPT-R2", sendOpaqueRaw: { _ in }, isRound1: false,
                                       calleeToken: nil, acceptRound: 2)
        integ.wipeSasCommitState(callId: callId)
        XCTAssertTrue(integ.acceptsDueForResend(callId: callId, roundDecided: { _ in false }).isEmpty)
    }

    // MARK: - R-REKEY-ACCEPT-WAIT: the offerer takes only the ACCEPT of the round in flight

    func testOnlyTheRoundInFlightTakesAnAccept() {
        // no attempt in flight: the round-1 rules decide, not this one
        XCTAssertFalse(QAudionCallIntegration.isStaleRekeyAccept(attemptRound: nil, echoedRound: 2))
        XCTAssertFalse(QAudionCallIntegration.isStaleRekeyAccept(attemptRound: nil, echoedRound: nil))
        // round 3 in flight
        XCTAssertFalse(QAudionCallIntegration.isStaleRekeyAccept(attemptRound: 3, echoedRound: 3))
        XCTAssertTrue(QAudionCallIntegration.isStaleRekeyAccept(attemptRound: 3, echoedRound: 2),
                      "the late ACCEPT of an abandoned round")
        XCTAssertTrue(QAudionCallIntegration.isStaleRekeyAccept(attemptRound: 3, echoedRound: 4))
        XCTAssertTrue(QAudionCallIntegration.isStaleRekeyAccept(attemptRound: 3, echoedRound: nil))
    }

    // MARK: - wiring

    private func sourceText(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw XCTSkip("\(relativePath) not found")
    }

    private func code(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func slice(_ text: String, from start: String, to end: String) throws -> String {
        let a = try XCTUnwrap(text.range(of: start), "start marker: \(start)")
        let tail = text[a.upperBound...]
        let b = try XCTUnwrap(tail.range(of: end), "end marker: \(end)")
        return String(tail[..<b.lowerBound])
    }

    /// The ACCEPT handler drops an ACCEPT of another round before it verifies anything, and the attempt carries the
    /// round its OFFER signed.
    func testTheAcceptHandlerDropsAnAcceptOfAnotherRoundBeforeVerifyingIt() throws {
        let integration = try sourceText(integrationPath)
        let handler = code(try slice(integration, from: "case .accept:", to: "// 1. ML-KEM-1024 decapsulate with our local PQC priv."))
        let staleAt = try XCTUnwrap(handler.range(of: "if Self.isStaleRekeyAccept(attemptRound: rekeyAttempt?.round, echoedRound: bundle.rekeyRound) {"))
        let verifyAt = try XCTUnwrap(handler.range(of: "let acceptCheck = evaluateInbound("))
        XCTAssertLessThan(staleAt.lowerBound, verifyAt.lowerBound, "before verification, binding and any identity side effect")
        let after = String(handler[staleAt.lowerBound...].prefix(400))
        XCTAssertTrue(after.contains("dropped\") return }"), "dropped, nothing else happens")
        XCTAssertTrue(code(integration).contains("PendingReKeyAttempt(id: attemptId, round: Int(thisRound), localKeys: localKeys)"))
    }

    /// The ACCEPT is recorded at the hand-over, before the write, in the direct path and in the release path.
    func testTheAcceptIsRecordedAtTheHandOverBeforeTheWrite() throws {
        let integration = try sourceText(integrationPath)
        let emit = code(try slice(integration, from: "acceptRound: Int? = nil) async throws {",
                                  to: "/// R-ACCEPT-RESEND: remember the exact bytes"))
        let recordAt = try XCTUnwrap(emit.range(of: "recordSentAccept(callId: cid, round: acceptRound, wire: wire)"))
        let sendAt = try XCTUnwrap(emit.range(of: "try await sendOpaqueRaw(wire)"))
        XCTAssertLessThan(recordAt.lowerBound, sendAt.lowerBound)
        let hold = try XCTUnwrap(emit.range(of: "if shouldHoldResponderAccept?(cid) == true {"))
        XCTAssertLessThan(hold.lowerBound, recordAt.lowerBound, "a held ACCEPT is not recorded")
        let release = code(try slice(integration, from: "public func releaseHeldAccept(callId: String) async -> Bool {",
                                     to: "/// Drops a held ACCEPT without sending it"))
        let releaseRecord = try XCTUnwrap(release.range(of: "recordSentAccept(callId: cid, round: acceptRound, wire: wire)"))
        let releaseSend = try XCTUnwrap(release.range(of: "try await sender(wire)"))
        XCTAssertLessThan(releaseRecord.lowerBound, releaseSend.lowerBound)
        let offer = code(integration)
        XCTAssertEqual(offer.components(separatedBy: "acceptRound: Int(round)").count - 1, 2,
                       "both ACCEPT emissions of an OFFER name their signed round")
    }

    /// One event, one unit of budget: the ACCEPTs join the same event as the REVEAL and the MACs and leave first.
    func testTheAcceptsLeaveInTheOneReauthEventBeforeTheRevealAndTheMacs() throws {
        let app = try sourceText(appPath)
        let handler = code(try slice(
            app, from: "private func handleSocketReauthForConfirmation() {",
            to: "/// W-KCMAC — verify an inbound `KCMAC:` piggy-back"))
        XCTAssertEqual(handler.components(separatedBy: "takeResendEvent(").count - 1, 1, "one budget unit per event")
        XCTAssertTrue(handler.contains("integration.acceptsDueForResend(callId: cid) { round in call?.book.isDecided(round: round) ?? false }"))
        XCTAssertTrue(handler.contains("guard due.any || !olderWires.isEmpty || !acceptsDue.isEmpty else { return }"))
        let budgetAt = try XCTUnwrap(handler.range(of: "guard integration.takeResendEvent(callId: cid) else {"))
        let dueAt = try XCTUnwrap(handler.range(of: "let acceptsDue = "))
        XCTAssertLessThan(dueAt.lowerBound, budgetAt.lowerBound, "decided before the budget is touched")
        let acceptAt = try XCTUnwrap(handler.range(of: "await integration.resendAcceptsAfterReauth(acceptsDue, callId: cid)"))
        let revealAt = try XCTUnwrap(handler.range(of: "await integration.resendRevealAfterReauth(callId: cid)"))
        let macAt = try XCTUnwrap(handler.range(of: "try? await provider.callingApi.sendOpaqueMessageString(recipientId: peerToSend, payload: wireToSend)"))
        XCTAssertLessThan(acceptAt.lowerBound, revealAt.lowerBound)
        XCTAssertLessThan(acceptAt.lowerBound, macAt.lowerBound, "each ACCEPT before the MAC of its round")
        XCTAssertTrue(handler.contains("accepts=\\(acceptsDue.count)"))
    }

    /// R-KCMAC-ATOMIC: the expiry of one round's window is one main-actor step: the test and the failure together.
    func testTheExpiryOfARoundIsOneMainActorStep() throws {
        let app = try sourceText(appPath)
        let deadline = code(try slice(
            app, from: "state.deadlineTask = Task { [weak self] in",
            to: "// MACs the peer sent before this round was armed"))
        XCTAssertEqual(deadline.components(separatedBy: "MainActor.run").count - 1, 1,
                       "the read of the remaining time and the failure are not two hops")
        let testAt = try XCTUnwrap(deadline.range(of: "let left = self.kcWaitRemainingMs(callId: event.callId, state: cur)"))
        let failAt = try XCTUnwrap(deadline.range(of: "self.failKeyConfirmation(callId: event.callId, state: cur, expired: true)"))
        XCTAssertLessThan(testAt.lowerBound, failAt.lowerBound)
        XCTAssertTrue(deadline.contains("guard left <= 0 else { return left }"))
    }
}
