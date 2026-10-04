import XCTest
@testable import QAudionEngine

/// The K-round close (WIRE_SPEC §3.7 R-REKEY-ACCEPT-WAIT and R-ACCEPT-RESEND; spec 45177562), on the iOS offerer and
/// acceptor:
///
/// 1. an ACCEPT that reached the offerer in time is processed to completion: the round stops waiting when the ACCEPT
///    reaches the offerer, so the deadline can no longer abandon it, whichever of the two steps runs first wins, and the
///    ACCEPT's verification may end after the deadline;
/// 2. every ACCEPT the offerer receives once round 1 is bound is sorted in one place: a byte-identical copy of the bound
///    round-1 ACCEPT re-sends the REVEAL (one event of the budget of 4) in every state of the call, a rekey round that is
///    waiting included; every other copy or late ACCEPT is dropped silently without touching a waiting round;
/// 3. the acceptor re-sends a rekey ACCEPT only for a round that is still in PENDING, and forgets the ACCEPT of a round it
///    refused, never armed, abandoned, decided or whose window ended.
///
/// The offerer's handler is driven here with ACCEPTs that are dropped before any verification (nothing needs a signer or
/// a real ciphertext); what needs the live app is pinned on the source text.
final class KcMacKCloseTests: XCTestCase {

    private let callId = "11111111-2222-3333-4444-555555555555"
    private let appPath = "QAudionApp/AppState.swift"
    private let integrationPath = "QAudionEngine/Sources/QAudionEngine/Integration/QAudionCallIntegration.swift"

    /// What the awaiting `performPqcReKey` was resumed with, safe to read after concurrent tasks finished.
    private final class Resolutions: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Data?] = []
        func add(_ value: Data?) { lock.withLock { items.append(value) } }
        var all: [Data?] { lock.withLock { items } }
    }

    /// What the transport was handed.
    private final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }

    private func acceptBundle(round: Int, seed: UInt8) -> AndroidHandshakeBundle {
        AndroidHandshakeBundle(
            kind: .accept, callId: callId,
            ciphertext: AndroidHandshakeBundle.Ciphertext(
                pqc: Data(repeating: seed, count: 1568).base64EncodedString(),
                x25519: Data(repeating: seed &+ 1, count: 32).base64EncodedString()),
            rekeyRound: round)
    }

    /// Deliver `bundle` to `integ` as the call peer's ACCEPT; returns what the call reported as fatal.
    private func deliver(_ bundle: AndroidHandshakeBundle, to integ: QAudionCallIntegration) async throws -> [String] {
        var fatals: [String] = []
        integ.onHandshakeFatal = { _, reason in fatals.append(reason) }
        try await integ.onAndroidBundleReceived(
            bundle: bundle, callId: callId, callerId: "peer-1", sendOpaqueRaw: { _ in })
        return fatals
    }

    // MARK: - (1) reach and expiry are two steps on the call's state: the one that runs first wins

    /// The ACCEPT reached first: the round stops waiting, the deadline that follows does nothing, and the round is
    /// resolved only when the ACCEPT's processing ends. (Before this rule the deadline abandoned the round and the
    /// ACCEPT, still being verified, was dropped at the old `stillLive` check.)
    func testAnAcceptThatReachedInTimeIsNotAbandonedByTheDeadline() throws {
        let integ = QAudionCallIntegration()
        let resolutions = Resolutions()
        let id = try integ.installWaitingReKeyAttemptForTesting(round: 2) { resolutions.add($0) }

        let taken = integ.takeWaitingReKeyAttempt(round: 2)
        XCTAssertEqual(taken?.id, id, "the first ACCEPT for the waiting round takes it")
        XCTAssertEqual(integ.reKeyAttemptForTesting?.acceptReached, true, "it no longer waits")

        XCTAssertFalse(integ.expireReKeyWait(attemptId: id), "the ACCEPT reached first: the deadline abandons nothing")
        XCTAssertTrue(resolutions.all.isEmpty, "the round is still the ACCEPT's to finish")
        XCTAssertEqual(integ.reKeyAttemptForTesting?.id, id, "and it is still in place, for that processing to resolve")

        // The processing ends after the deadline, with the key: the round is installed.
        let key = Data(repeating: 9, count: 32)
        integ.resolveReKeyAttempt(id: id, with: key)
        XCTAssertEqual(resolutions.all, [key])
        XCTAssertNil(integ.reKeyAttemptForTesting)
    }

    /// The deadline ran first: the round is abandoned (no key, the call goes on), and an ACCEPT that arrives afterwards
    /// finds no waiting round.
    func testTheDeadlineThatRanFirstAbandonsTheRoundAndALaterAcceptCannotTakeIt() throws {
        let integ = QAudionCallIntegration()
        let resolutions = Resolutions()
        let id = try integ.installWaitingReKeyAttemptForTesting(round: 2) { resolutions.add($0) }

        XCTAssertTrue(integ.expireReKeyWait(attemptId: id))
        XCTAssertEqual(resolutions.all, [nil], "abandoned: the awaiting rekey gets no key")
        XCTAssertNil(integ.reKeyAttemptForTesting)
        XCTAssertNil(integ.takeWaitingReKeyAttempt(round: 2), "a late ACCEPT is dropped")
        XCTAssertFalse(integ.expireReKeyWait(attemptId: id), "the expiry itself runs once")
        XCTAssertEqual(resolutions.all.count, 1)
    }

    /// One ACCEPT per round: the first one to reach takes the round, a second one (identical or not) cannot.
    func testASecondAcceptForARoundWhoseAcceptReachedCannotTakeIt() throws {
        let integ = QAudionCallIntegration()
        let resolutions = Resolutions()
        _ = try integ.installWaitingReKeyAttemptForTesting(round: 3) { resolutions.add($0) }
        XCTAssertNotNil(integ.takeWaitingReKeyAttempt(round: 3))
        XCTAssertNil(integ.takeWaitingReKeyAttempt(round: 3), "the round no longer waits")
        XCTAssertTrue(resolutions.all.isEmpty, "a refused second ACCEPT resolves nothing")
    }

    /// Only the round that waits can be taken; any other round leaves it waiting.
    func testOnlyTheWaitingRoundCanBeTaken() throws {
        let integ = QAudionCallIntegration()
        let id = try integ.installWaitingReKeyAttemptForTesting(round: 3) { _ in }
        XCTAssertNil(integ.takeWaitingReKeyAttempt(round: 2), "the late ACCEPT of an abandoned round")
        XCTAssertNil(integ.takeWaitingReKeyAttempt(round: 4))
        XCTAssertEqual(integ.reKeyAttemptForTesting?.id, id)
        XCTAssertEqual(integ.reKeyAttemptForTesting?.acceptReached, false, "still waiting, untouched")
    }

    /// The awaiting rekey is resumed exactly once, whoever resolves it.
    func testTheAttemptIsResolvedOnce() throws {
        let integ = QAudionCallIntegration()
        let resolutions = Resolutions()
        let id = try integ.installWaitingReKeyAttemptForTesting(round: 2) { resolutions.add($0) }
        _ = integ.takeWaitingReKeyAttempt(round: 2)
        integ.resolveReKeyAttempt(id: id, with: nil)
        integ.resolveReKeyAttempt(id: id, with: Data(repeating: 1, count: 32))
        XCTAssertFalse(integ.expireReKeyWait(attemptId: id))
        XCTAssertEqual(resolutions.all, [nil], "a refusal, once")
    }

    // MARK: - (2) the handler sorts every ACCEPT in one place and never touches a waiting round for a copy or a late one

    /// The late ACCEPT of an earlier round (the acceptor's re-send, a server replay, a late arrival), identical or not,
    /// is dropped silently while the next round waits: no close reason, no throw, the waiting round untouched.
    func testALateAcceptOfAnEarlierRoundIsDroppedWithoutTouchingTheWaitingRound() async throws {
        let integ = QAudionCallIntegration()
        let resolutions = Resolutions()
        let id = try integ.installWaitingReKeyAttemptForTesting(round: 3) { resolutions.add($0) }
        let late = acceptBundle(round: 2, seed: 0x31)
        for _ in 0..<2 {   // the ACCEPT and a byte-identical copy of it
            let fatals = try await deliver(late, to: integ)
            XCTAssertTrue(fatals.isEmpty, "no close reason")
        }
        let other = try await deliver(acceptBundle(round: 2, seed: 0x32), to: integ)
        XCTAssertTrue(other.isEmpty)
        XCTAssertEqual(integ.reKeyAttemptForTesting?.id, id)
        XCTAssertEqual(integ.reKeyAttemptForTesting?.acceptReached, false, "still waiting")
        XCTAssertTrue(resolutions.all.isEmpty, "not resolved, not failed")
    }

    /// A second ACCEPT for the round whose ACCEPT already reached (still being processed) is dropped silently: the round
    /// is not touched, cleared or resolved by it.
    func testASecondAcceptForARoundBeingProcessedIsDroppedSilently() async throws {
        let integ = QAudionCallIntegration()
        let resolutions = Resolutions()
        let id = try integ.installWaitingReKeyAttemptForTesting(round: 3) { resolutions.add($0) }
        _ = integ.takeWaitingReKeyAttempt(round: 3)   // the first ACCEPT reached and is being processed
        let fatals = try await deliver(acceptBundle(round: 3, seed: 0x41), to: integ)
        XCTAssertTrue(fatals.isEmpty)
        XCTAssertEqual(integ.reKeyAttemptForTesting?.id, id)
        XCTAssertEqual(integ.reKeyAttemptForTesting?.acceptReached, true)
        XCTAssertTrue(resolutions.all.isEmpty, "the first ACCEPT's processing resolves it, not this one")
    }

    /// A rekey ACCEPT with no round waiting (the round was abandoned, or none was started) is dropped silently.
    func testARekeyAcceptWithNoRoundWaitingIsDroppedSilently() async throws {
        let integ = QAudionCallIntegration()
        let fatals = try await deliver(acceptBundle(round: 2, seed: 0x51), to: integ)
        XCTAssertTrue(fatals.isEmpty)
        XCTAssertNil(integ.reKeyAttemptForTesting)
    }

    /// Case 1, the pre-existing defect: a byte-identical copy of the BOUND round-1 ACCEPT that arrives while a rekey
    /// round waits is answered by the identical REVEAL (one event of the budget), and nothing else happens. It used to be
    /// dropped by the `!isReKeyAccept` gate without re-sending anything.
    func testACopyOfTheBoundRound1AcceptWhileARekeyRoundWaitsResendsTheRevealAndTouchesNothingElse() async throws {
        let integ = QAudionCallIntegration()
        let wire = Wire()
        integ.setResponderSenderForTesting { wire.add($0) }
        let pqcCt = Data(repeating: 0xC1, count: 1568), eph = Data(repeating: 0xC2, count: 32)
        let hash = Data(repeating: 0xA1, count: 32), nonce = Data(repeating: 0x42, count: 32)
        XCTAssertTrue(integ.bindProcessedRound1AcceptForTesting(
            callId: callId, pqcCt: pqcCt, x25519Eph: eph, acceptHash: hash, nonce: nonce))
        let resolutions = Resolutions()
        let id = try integ.installWaitingReKeyAttemptForTesting(round: 2) { resolutions.add($0) }

        let copy = AndroidHandshakeBundle(
            kind: .accept, callId: callId,
            ciphertext: AndroidHandshakeBundle.Ciphertext(pqc: pqcCt.base64EncodedString(), x25519: eph.base64EncodedString()),
            rekeyRound: 1)
        let fatals = try await deliver(copy, to: integ)

        let reveal = try XCTUnwrap(SasReveal.serialize(callId: callId, acceptBinding: hash, nonce: nonce))
        XCTAssertEqual(wire.all, [reveal], "the identical REVEAL went again")
        XCTAssertEqual(integ.sasCommit.resendEventsUsed(callId: callId), 1, "one event of the budget of 4")
        XCTAssertTrue(fatals.isEmpty)
        XCTAssertEqual(integ.reKeyAttemptForTesting?.id, id, "the waiting round is untouched")
        XCTAssertEqual(integ.reKeyAttemptForTesting?.acceptReached, false)
        XCTAssertTrue(resolutions.all.isEmpty)
    }

    /// The same copy in every other state of the call: no rekey at all, and no key of round 1 left (they are released
    /// once round 1 is installed): the REVEAL still goes again. Once the budget of 4 is spent the copy is still dropped.
    func testACopyOfTheBoundRound1AcceptIsAnsweredInEveryStateOfTheCallUntilTheBudgetIsSpent() async throws {
        let integ = QAudionCallIntegration()
        let wire = Wire()
        integ.setResponderSenderForTesting { wire.add($0) }
        let pqcCt = Data(repeating: 0xD1, count: 1568), eph = Data(repeating: 0xD2, count: 32)
        let hash = Data(repeating: 0xA2, count: 32), nonce = Data(repeating: 0x43, count: 32)
        XCTAssertTrue(integ.bindProcessedRound1AcceptForTesting(
            callId: callId, pqcCt: pqcCt, x25519Eph: eph, acceptHash: hash, nonce: nonce))
        let copy = AndroidHandshakeBundle(
            kind: .accept, callId: callId,
            ciphertext: AndroidHandshakeBundle.Ciphertext(pqc: pqcCt.base64EncodedString(), x25519: eph.base64EncodedString()),
            rekeyRound: 1)
        for _ in 0..<ConfirmTimeout.maxResendEvents {
            _ = try await deliver(copy, to: integ)
        }
        XCTAssertEqual(wire.all.count, ConfirmTimeout.maxResendEvents, "no rekey, no stashed keys: still answered")
        _ = try await deliver(copy, to: integ)
        XCTAssertEqual(wire.all.count, ConfirmTimeout.maxResendEvents, "a spent budget re-sends nothing")
        XCTAssertEqual(integ.sasCommit.resendEventsUsed(callId: callId), ConfirmTimeout.maxResendEvents)
    }

    // MARK: - (3) the acceptor forgets the ACCEPT of a round that is not (or no longer) pending

    /// The test is membership in PENDING, whatever else is stored: a round that was never armed (or refused) is not
    /// listed, so it adds no message to a re-send event and never spends a unit of the budget.
    func testTheAcceptOfARoundThatIsNotPendingIsNeverListed() async throws {
        let integ = QAudionCallIntegration()
        try await integ.emitJsonAccept(callId: callId, wire: "ACCEPT-R2", sendOpaqueRaw: { _ in },
                                       isRound1: false, calleeToken: nil, acceptRound: 2)
        XCTAssertEqual(integ.acceptsDueForResend(callId: callId, roundPending: { _ in true }).map { $0.round }, [2],
                       "armed and undecided: due")
        XCTAssertTrue(integ.acceptsDueForResend(callId: callId, roundPending: { _ in false }).isEmpty,
                      "never armed, refused, abandoned, decided or expired: not due, even though the bytes are stored")
    }

    func testForgettingARekeyAcceptDropsItsBytes() async throws {
        let integ = QAudionCallIntegration()
        try await integ.emitJsonAccept(callId: callId, wire: "ACCEPT-R2", sendOpaqueRaw: { _ in },
                                       isRound1: false, calleeToken: nil, acceptRound: 2)
        try await integ.emitJsonAccept(callId: callId, wire: "ACCEPT-R3", sendOpaqueRaw: { _ in },
                                       isRound1: false, calleeToken: nil, acceptRound: 3)
        integ.forgetSentAccept(callId: callId.uppercased(), round: 2)
        XCTAssertEqual(integ.acceptsDueForResend(callId: callId, roundPending: { _ in true }).map { $0.round }, [3])
        integ.forgetSentAccept(callId: callId, round: 3)
        integ.forgetSentAccept(callId: callId, round: 3)   // a no-op
        XCTAssertTrue(integ.acceptsDueForResend(callId: callId, roundPending: { _ in true }).isEmpty)
    }

    /// Round 1 is never forgotten this way: its proof of arrival is the REVEAL, not a MAC.
    func testTheRoundOneAcceptIsNeverForgottenByTheRekeyRule() async throws {
        let integ = QAudionCallIntegration()
        integ.setResponderSenderForTesting { _ in }
        let commit = try XCTUnwrap(SasCommit.commit(callId: callId, nonce: Data(repeating: 1, count: 32)))
        let token = try XCTUnwrap(integ.sasCommit.beginCalleeOwned(
            callId: callId, commit: commit, acceptHash: Data(repeating: 0xA1, count: 32)))
        try await integ.emitJsonAccept(callId: callId, wire: "ACCEPT-1", sendOpaqueRaw: { _ in },
                                       isRound1: true, calleeToken: token, acceptRound: 1)
        integ.forgetSentAccept(callId: callId, round: 1)
        XCTAssertEqual(integ.acceptsDueForResend(callId: callId, roundPending: { _ in false }).map { $0.round }, [1])
    }

    // MARK: - wiring (what needs the live app, or a signed handshake, is pinned on the source text)

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

    /// Comments dropped, whitespace squeezed: a pin survives re-wrapping and re-commenting.
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

    /// The ACCEPT handler: the copy of the bound round-1 ACCEPT is answered before any key lookup and without the
    /// rekey gate, the round is TAKEN before anything is verified, every way out of the processing resolves the taken
    /// attempt, and the old after-the-deadline drop is gone.
    func testTheAcceptHandlerSortsInOnePlaceAndTakesTheRoundBeforeVerifying() throws {
        let integration = try sourceText(integrationPath)
        let marker = "// 1. ML-KEM-1024 decapsulate with our local PQC priv."
        let handler = code(try slice(integration, from: "case .accept:", to: marker))
        let rest = code(try slice(integration, from: marker, to: "JSON caller ACCEPT-received path."))

        let waitingAt = try XCTUnwrap(handler.range(of: "let waitingRekeyRound: Int? = lock.withLock {"))
        let caseOneAt = try XCTUnwrap(handler.range(of: "if lock.withLock({ boundRound1AcceptKeyByCall[normalizedIdForDedup] == acceptDedupKey }) {"))
        let keysAt = try XCTUnwrap(handler.range(of: "guard let local = localKeys else {"))
        let takeAt = try XCTUnwrap(handler.range(of: "guard let taken = takeWaitingReKeyAttempt(round: waitingRekeyRound) else {"))
        let verifyAt = try XCTUnwrap(handler.range(of: "let acceptCheck = evaluateInbound("))
        XCTAssertLessThan(waitingAt.lowerBound, caseOneAt.lowerBound, "reach is read before anything else")
        XCTAssertLessThan(caseOneAt.lowerBound, keysAt.lowerBound, "the REVEAL answer holds in every state of the call, keys or none")
        XCTAssertLessThan(caseOneAt.lowerBound, takeAt.lowerBound)
        XCTAssertLessThan(takeAt.lowerBound, verifyAt.lowerBound, "the round is taken before the ACCEPT is verified")

        // case 1: no rekey gate, nothing but the REVEAL happens
        let caseOne = String(handler[caseOneAt.lowerBound...].prefix(600))
        XCTAssertTrue(caseOne.contains("sasCommit.callerRevealForDuplicateAccept(callId: callId)"))
        XCTAssertTrue(caseOne.contains("await sendSasReveal(wire, callId: callId, resend: true)"))
        XCTAssertFalse(handler.contains("!isReKeyAccept, isBoundAccept"), "the rekey gate that dropped a copy without a REVEAL is gone")

        // every way out of the processing resolves the taken attempt: with nil by default, with the key at the end
        XCTAssertTrue(handler.contains("var takenAttemptResolved = false defer { if let rekeyAttempt, !takenAttemptResolved { resolveReKeyAttempt(id: rekeyAttempt.id, with: nil) } }"))
        XCTAssertTrue(rest.contains("if let rekeyAttempt { takenAttemptResolved = true resolveReKeyAttempt(id: rekeyAttempt.id, with: combined) }"))

        // the old check that dropped an ACCEPT after the deadline had cleared the attempt is only a teardown guard now
        XCTAssertFalse(integration.contains("already resolved/timed out"))
        XCTAssertTrue(rest.contains("let stillLive = lock.withLock { pendingReKeyAttempt?.id == rekeyAttempt?.id }"))
    }

    /// The deadline and the send failure of `performPqcReKey` go through the one step that checks the round still waits.
    func testTheDeadlineOfTheRekeyAbandonsOnlyARoundThatStillWaits() throws {
        let integration = try sourceText(integrationPath)
        let rekey = code(try slice(integration, from: "public func performPqcReKey(", to: "public func onCapabilityMessageReceived("))
        XCTAssertEqual(rekey.components(separatedBy: "self.expireReKeyWait(attemptId: attemptId)").count - 1, 2,
                       "the send failure and the deadline")
        XCTAssertFalse(rekey.contains("self.pendingReKeyAttempt = nil"), "no path clears the attempt behind the step's back")
        let expire = code(try slice(integration, from: "func expireReKeyWait(attemptId: UUID) -> Bool {", to: "/// The end of the processing of the ACCEPT"))
        XCTAssertTrue(expire.contains("attempt.id == attemptId, !attempt.acceptReached"))
        let take = code(try slice(integration, from: "func takeWaitingReKeyAttempt(round: Int) -> PendingReKeyAttempt? {", to: "/// R-REKEY-ACCEPT-WAIT, expiry:"))
        XCTAssertTrue(take.contains("!attempt.acceptReached, attempt.round == round"))
        XCTAssertTrue(take.contains("attempt.acceptReached = true"))
    }

    /// A rekey round that ends after its ACCEPT was handed over without arming its KCMAC round is forgotten, and a
    /// verified peer MAC (the proof of arrival) forgets it too; the app asks for PENDING membership.
    func testTheRefusedRoundIsForgottenAndTheAppAsksForPendingMembership() throws {
        let integration = try sourceText(integrationPath)
        let offer = code(try slice(integration, from: "case .offer:", to: "case .accept:"))
        let emitAt = try XCTUnwrap(offer.range(of: "try await emitJsonAccept(callId: callId, wire: wire, sendOpaqueRaw: sendOpaqueRaw, isRound1: !isReKeyRound, calleeToken: calleeToken, acceptRound: Int(round))"))
        let deferAt = try XCTUnwrap(offer.range(of: "var rekeyRoundArmed = false defer { if isReKeyRound, !rekeyRoundArmed { forgetSentAccept(callId: callId, round: Int(round)) } }"))
        let armAt = try XCTUnwrap(offer.range(of: "rekeyRoundArmed = true onKcMacReady?(KcMacReadyEvent("))
        XCTAssertLessThan(emitAt.lowerBound, deferAt.lowerBound, "after the ACCEPT was handed over, not on the early drops")
        XCTAssertLessThan(deferAt.lowerBound, armAt.lowerBound)

        let app = code(try sourceText(appPath))
        XCTAssertTrue(app.contains("integration.acceptsDueForResend(callId: cid) { round in call?.book.isPending(round: round) ?? false }"))
        XCTAssertFalse(app.contains("call?.book.isDecided(round: round) ?? false"), "decided is not the test any more")
        XCTAssertTrue(app.contains("if round >= 2 { sasIntegration(forCallId: key)?.forgetSentAccept(callId: key, round: round) }"))
    }
}
