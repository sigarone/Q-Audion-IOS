import XCTest
import CryptoKit
@testable import QAudionEngine

/// The SAS commitment of transcript v6 (SASCOMMIT design, R-COMMIT-* rules): primitives, the REVEAL
/// wire format, the callee and caller state machines, the per-call book, the policy rules, the
/// integration entry points that can be driven without a PeerConnection, and the wiring pinned on the
/// source text where AppState cannot be driven here (CallKit, live provider, WebSocket). The shared KAT
/// vectors and sequences live in `HandshakeTranscriptV6Tests` and `SasCommitSequenceTests`.
final class SasCommitTests: XCTestCase {

    private let callId = "11111111-2222-3333-4444-555555555555"
    private let nonce = Data((0..<32).map { UInt8($0 &+ 1) })
    private let ownHash = Data(repeating: 0xA5, count: 32)
    private let otherHash = Data(repeating: 0x5A, count: 32)

    private func commit(_ n: Data? = nil, id: String? = nil) -> Data {
        SasCommit.commit(callId: id ?? callId, nonce: n ?? nonce)!
    }

    private func reveal(_ binding: Data? = nil, _ n: Data? = nil, id: String? = nil) -> String {
        SasReveal.serialize(callId: id ?? callId, acceptBinding: binding ?? ownHash, nonce: n ?? nonce)!
    }

    private func sentCallee(at ms: Int = 0) -> SasCommitCallee {
        var callee = SasCommitCallee(callId: callId, storedCommit: commit())
        callee.setAcceptHash(ownHash)
        callee.acceptSent(nowMs: ms)
        return callee
    }

    // MARK: - R-COMMIT-FIELD: the commitment

    func testCommitIsSha256OfLabelLpCallIdAndNonce() {
        var input = Data("qaudion-sas-commit-v6".utf8)
        XCTAssertEqual(input.count, 21)
        let id = Data(callId.utf8)
        input.append(contentsOf: [UInt8(id.count >> 8), UInt8(id.count & 0xFF)])
        input.append(id)
        input.append(nonce)
        XCTAssertEqual(commit(), Data(SHA256.hash(data: input)))
        XCTAssertEqual(commit().count, 32)
    }

    func testCommitRefusesAWrongNonceLength() {
        for n in [0, 16, 31, 33, 64] {
            XCTAssertNil(SasCommit.commit(callId: callId, nonce: Data(repeating: 1, count: n)))
        }
    }

    func testTheCommitmentBindsTheCallIdAndTheNonce() {
        var flipped = nonce
        flipped[31] ^= 0x01
        XCTAssertNotEqual(commit(), commit(flipped))
        XCTAssertNotEqual(commit(), commit(id: callId + "x"))
    }

    func testNewNonceIs32RandomBytesAndNeverRepeats() throws {
        let a = try XCTUnwrap(SasCommit.newNonce())
        let b = try XCTUnwrap(SasCommit.newNonce())
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
    }

    func testCanonicalBase64IsStrict() throws {
        let good = Data(repeating: 7, count: 32).base64EncodedString()
        XCTAssertNotNil(SasCommit.decodeCanonicalBase64(good, expectedLength: 32))
        XCTAssertNil(SasCommit.decodeCanonicalBase64(good, expectedLength: 31), "wrong length")
        XCTAssertNil(SasCommit.decodeCanonicalBase64(String(good.dropLast()), expectedLength: 32), "no padding")
        XCTAssertNil(SasCommit.decodeCanonicalBase64(good + " ", expectedLength: 32), "trailing space")
        XCTAssertNil(SasCommit.decodeCanonicalBase64("", expectedLength: 32))
        let urlSafe = Data(repeating: 0xFB, count: 32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        XCTAssertNil(SasCommit.decodeCanonicalBase64(urlSafe, expectedLength: 32), "URL-safe alphabet")
        // non-zero trailing bits: the last base64 character of a 32-byte value carries 2 spare bits
        var chars = Array(good)
        chars[chars.count - 2] = chars[chars.count - 2] == "A" ? "B" : "A"
        let noncanonical = String(chars)
        if let decoded = Data(base64Encoded: noncanonical), decoded.base64EncodedString() != noncanonical {
            XCTAssertNil(SasCommit.decodeCanonicalBase64(noncanonical, expectedLength: 32), "non-zero trailing bits")
        }
    }

    // MARK: - R-COMMIT-FIELD / R-COMMIT-FIRST-ROUND: policy

    func testCommitFieldRulesByRoundAndKind() {
        let good = commit().base64EncodedString()
        func code(_ isOffer: Bool, _ round: Int?, _ text: String?) -> String? {
            HandshakeSigningPolicy.sasCommitMalformedCode(isOffer: isOffer, round: round, sasCommitB64: text)
        }
        XCTAssertNil(code(true, 1, good))
        XCTAssertEqual(code(true, 1, nil), "commit_missing")
        XCTAssertEqual(code(true, 1, ""), "commit_malformed", "a JSON null arrives as the empty string")
        XCTAssertEqual(code(true, 1, Data(repeating: 1, count: 31).base64EncodedString()), "commit_malformed")
        XCTAssertEqual(code(true, 1, String(good.dropLast())), "commit_malformed")
        XCTAssertNil(code(true, 2, nil))
        XCTAssertNil(code(true, UInt32.max.asInt, nil))
        XCTAssertEqual(code(true, 2, good), "commit_unexpected")
        XCTAssertEqual(code(true, 2, ""), "commit_unexpected", "even a null on a rekey OFFER")
        XCTAssertNil(code(false, 1, nil), "an ACCEPT carries none")
        XCTAssertEqual(code(false, 1, good), "commit_unexpected")
        XCTAssertEqual(code(false, 3, ""), "commit_unexpected")
        XCTAssertNil(code(true, nil, nil), "a missing round is the transcript builder's malformed case")
        XCTAssertNil(code(true, 0, nil))
    }

    func testTheFirstOfferOfACallMustBeRoundOne() {
        XCTAssertNil(HandshakeSigningPolicy.firstRoundMalformedCode(isFirstOfferOfCall: true, round: 1))
        XCTAssertEqual(HandshakeSigningPolicy.firstRoundMalformedCode(isFirstOfferOfCall: true, round: 2), "first_round_not_1")
        XCTAssertEqual(HandshakeSigningPolicy.firstRoundMalformedCode(isFirstOfferOfCall: true, round: 0), "first_round_not_1")
        XCTAssertEqual(HandshakeSigningPolicy.firstRoundMalformedCode(isFirstOfferOfCall: true, round: nil), "first_round_not_1")
        XCTAssertNil(HandshakeSigningPolicy.firstRoundMalformedCode(isFirstOfferOfCall: false, round: 5), "later OFFERs are rekeys")
    }

    /// WIRE_SPEC §3.7.4 pending OFFER: an OFFER that overtook `call_incoming` is judged as a first OFFER on
    /// arrival (round 1 and a valid commitment), else dropped.
    func testAPendingOfferIsCheckedAsAFirstOfferWhenItArrives() {
        let good = commit().base64EncodedString()
        XCTAssertNil(HandshakeSigningPolicy.pendingOfferMalformedCode(round: 1, sasCommitB64: good))
        XCTAssertEqual(HandshakeSigningPolicy.pendingOfferMalformedCode(round: 2, sasCommitB64: nil), "first_round_not_1")
        XCTAssertEqual(HandshakeSigningPolicy.pendingOfferMalformedCode(round: 2, sasCommitB64: good), "first_round_not_1")
        XCTAssertEqual(HandshakeSigningPolicy.pendingOfferMalformedCode(round: nil, sasCommitB64: good), "first_round_not_1")
        XCTAssertEqual(HandshakeSigningPolicy.pendingOfferMalformedCode(round: 1, sasCommitB64: nil), "commit_missing")
        XCTAssertEqual(HandshakeSigningPolicy.pendingOfferMalformedCode(round: 1, sasCommitB64: ""), "commit_malformed")
        XCTAssertEqual(HandshakeSigningPolicy.pendingOfferMalformedCode(
            round: 1, sasCommitB64: Data(repeating: 1, count: 31).base64EncodedString()), "commit_malformed")
    }

    /// The pre-ring slot in AppState: the arrival check runs BEFORE the OFFER is held, the slot keeps one
    /// OFFER per peer (the newest) and a held OFFER is replayed only for the call whose id it carries.
    func testThePendingOfferSlotChecksOnArrivalKeepsOnePerPeerAndMatchesTheCallId() throws {
        let app = try sourceText("QAudionApp/AppState.swift")
        let route = try XCTUnwrap(app.range(of: "private func routeInboundAndroidOffer(parsed: AndroidHandshakeEnvelope.Parsed, senderId: String) {"))
        let body = String(app[route.upperBound...].prefix(6_000))
        let checkAt = try XCTUnwrap(body.range(of: "HandshakeSigningPolicy.pendingOfferMalformedCode("))
        let holdAt = try XCTUnwrap(body.range(of: "bufferOfferReplay(senderId: senderId, callId: parsed.callId)"))
        XCTAssertLessThan(checkAt.lowerBound, holdAt.lowerBound, "an invalid pending OFFER is never held")
        XCTAssertTrue(app.contains("pendingOfferReplays.removeAll { $0.senderId == senderId }"), "one pending OFFER per peer")
        XCTAssertTrue(app.contains("&& (wanted == nil || $0.callId == nil || $0.callId == wanted)"), "applied only to its own call")
        XCTAssertTrue(app.contains("self.drainPendingOfferReplays(for: senderId, callId: callIdStr.isEmpty ? nil : callIdStr)"))
        XCTAssertTrue(app.contains("drainPendingOfferReplays(for: callerId, callId: callId.uuidString)"))
    }

    /// R-COMMIT-BIND: with a rekey attempt in flight, an ACCEPT that echoes round 1 is never the rekey's
    /// answer; any other combination is unchanged.
    func testARound1AcceptWhileARekeyIsInFlightIsStray() throws {
        XCTAssertTrue(QAudionCallIntegration.isStrayRound1Accept(isReKeyAccept: true, echoedRound: 1))
        XCTAssertFalse(QAudionCallIntegration.isStrayRound1Accept(isReKeyAccept: true, echoedRound: 2))
        XCTAssertFalse(QAudionCallIntegration.isStrayRound1Accept(isReKeyAccept: true, echoedRound: nil))
        XCTAssertFalse(QAudionCallIntegration.isStrayRound1Accept(isReKeyAccept: false, echoedRound: 1), "the ordinary round-1 path")
        let src = try integrationText()
        let acceptCase = try XCTUnwrap(src.range(of: "case .accept:\n            // Originator side"))
        let tail = String(src[acceptCase.upperBound...])
        let strayAt = try XCTUnwrap(tail.range(of: "Self.isStrayRound1Accept(isReKeyAccept: isReKeyAccept, echoedRound: bundle.rekeyRound)"))
        let verifyAt = try XCTUnwrap(tail.range(of: "let acceptCheck = evaluateInbound("))
        XCTAssertLessThan(strayAt.lowerBound, verifyAt.lowerBound, "dropped before it is verified")
    }

    // MARK: - integration: the callee ends malformed OFFERs without an ACCEPT

    private func offerBundle(round: Int, commit: String?) -> AndroidHandshakeBundle {
        AndroidHandshakeBundle(
            kind: .offer, callId: callId,
            pqcPublicKey: Data(repeating: 0xA1, count: 1568).base64EncodedString(),
            x25519PublicKey: Data(repeating: 0xA2, count: 32).base64EncodedString(),
            sasCommit: commit,
            rekeyNonce: V6TestFixtures.rekeyNonce.base64EncodedString(), rekeyRound: round)
    }

    private func receive(_ bundle: AndroidHandshakeBundle) async -> (code: String?, fatals: [String], sent: Int) {
        let integ = QAudionCallIntegration()
        var fatals: [String] = []
        var sent = 0
        integ.onHandshakeFatal = { _, reason in fatals.append(reason) }
        var code: String?
        do {
            try await integ.onAndroidBundleReceived(
                bundle: bundle, callId: callId, callerId: "peer-1", sendOpaqueRaw: { _ in sent += 1 })
        } catch IntegrationError.handshakeAborted(let c) {
            code = c
        } catch {
            code = "other"
        }
        return (code, fatals, sent)
    }

    /// callee-first-offer-round-2: ends `handshake_malformed`, no ACCEPT. Fails without the first-round
    /// rule in the `.offer` case.
    func testAFirstOfferWithRoundTwoEndsTheCallWithoutAnAccept() async {
        let r = await receive(offerBundle(round: 2, commit: nil))
        XCTAssertEqual(r.code, "first_round_not_1")
        XCTAssertEqual(r.fatals, ["handshake_malformed"])
        XCTAssertEqual(r.sent, 0)
    }

    /// callee-missing-commit: a round-1 OFFER without `sasCommit` ends the call, no ACCEPT.
    func testARoundOneOfferWithoutACommitmentEndsTheCallWithoutAnAccept() async {
        let r = await receive(offerBundle(round: 1, commit: nil))
        XCTAssertEqual(r.code, "commit_missing")
        XCTAssertEqual(r.fatals, ["handshake_malformed"])
        XCTAssertEqual(r.sent, 0)
    }

    func testARoundOneOfferWithAMalformedCommitmentEndsTheCallWithoutAnAccept() async {
        let r = await receive(offerBundle(round: 1, commit: "AAAA"))
        XCTAssertEqual(r.code, "commit_malformed")
        XCTAssertEqual(r.fatals, ["handshake_malformed"])
        XCTAssertEqual(r.sent, 0)
    }

    /// callee-rekey-offer-with-commit: a rekey OFFER that carries the key is malformed (after round 1).
    func testARekeyOfferCarryingACommitmentIsMalformed() async {
        let integ = QAudionCallIntegration()
        integ.sasCommit.beginCallee(callId: callId, commit: commit())
        var fatals: [String] = []
        integ.onHandshakeFatal = { _, reason in fatals.append(reason) }
        let verdict = integ.evaluateInbound(
            bundle: offerBundle(round: 2, commit: commit().base64EncodedString()), callId: callId,
            peerId: "peer-1", peerDeviceId: nil, expectedOfferBinding: nil).verdict
        XCTAssertEqual(verdict, .malformed(code: "commit_unexpected"))
        _ = fatals
    }

    func testAnAcceptCarryingACommitmentIsMalformed() {
        let integ = QAudionCallIntegration()
        let accept = AndroidHandshakeBundle(
            kind: .accept, callId: callId, pqcPublicKey: "", x25519PublicKey: "",
            ciphertext: AndroidHandshakeBundle.Ciphertext(
                pqc: Data(repeating: 0xB1, count: 1568).base64EncodedString(),
                x25519: Data(repeating: 0xB2, count: 32).base64EncodedString()),
            sasCommit: commit().base64EncodedString(),
            rekeyNonce: V6TestFixtures.rekeyNonce.base64EncodedString(), rekeyRound: 1)
        let verdict = integ.evaluateInbound(
            bundle: accept, callId: callId, peerId: "peer-1", peerDeviceId: nil,
            expectedOfferBinding: Data(repeating: 1, count: 32)).verdict
        XCTAssertEqual(verdict, .malformed(code: "commit_unexpected"))
    }

    // MARK: - R-COMMIT-REVEAL: wire format

    func testRevealIsCallIdTagAnd88CanonicalCharacters() throws {
        let wire = reveal()
        XCTAssertTrue(wire.hasPrefix(callId + "|SASREVEAL:"))
        let b64 = String(wire.dropFirst(callId.count + 1 + 10))
        XCTAssertEqual(b64.count, 88)
        let payload = try XCTUnwrap(SasCommit.decodeCanonicalBase64(b64, expectedLength: 64))
        XCTAssertEqual(payload.prefix(32), ownHash)
        XCTAssertEqual(payload.suffix(32), nonce)
        XCTAssertNil(SasReveal.serialize(callId: callId, acceptBinding: Data(count: 31), nonce: nonce))
        XCTAssertNil(SasReveal.serialize(callId: callId, acceptBinding: ownHash, nonce: Data(count: 33)))
    }

    func testRevealParseClassifiesEveryShape() throws {
        let wire = reveal()
        XCTAssertEqual(SasReveal.parse(data: wire, expectedCallId: callId), .payload(acceptBinding: ownHash, nonce: nonce))
        XCTAssertEqual(SasReveal.parse(data: wire, expectedCallId: callId.uppercased()),
                       .payload(acceptBinding: ownHash, nonce: nonce), "callId compared case-insensitively")
        XCTAssertEqual(SasReveal.parse(data: wire, expectedCallId: "another-call"), .notAReveal)
        XCTAssertEqual(SasReveal.parse(data: wire.replacingOccurrences(of: "SASREVEAL:", with: "sasreveal:"),
                                       expectedCallId: callId), .notAReveal)
        XCTAssertEqual(SasReveal.parse(data: "no pipe here", expectedCallId: callId), .notAReveal)
        XCTAssertEqual(SasReveal.parse(data: wire + " ", expectedCallId: callId), .malformed)
        XCTAssertEqual(SasReveal.parse(data: String(wire.dropLast()), expectedCallId: callId), .malformed)
        let long = callId + "|SASREVEAL:" + String(repeating: "A", count: 200)
        XCTAssertEqual(SasReveal.parse(data: long, expectedCallId: callId), .malformed, "data longer than 200 characters")
    }

    // MARK: - R-COMMIT-CHECK: the callee state machine

    func testAValidRevealOpensTheCommitment() {
        var callee = sentCallee()
        XCTAssertTrue(callee.isWaitingForReveal)
        XCTAssertEqual(callee.receiveReveal(data: reveal(), nowMs: 100), .sasReady)
        XCTAssertFalse(callee.isWaitingForReveal)
        XCTAssertEqual(callee.verifiedNonce, nonce)
    }

    /// Step 2: nothing is held, nothing is created for a REVEAL that arrives before this device sent its
    /// ACCEPT: it is dropped, and it does not verify later either (there is no early-REVEAL hold).
    func testARevealBeforeTheAcceptWasSentIsDroppedAndNeverHeld() {
        var callee = SasCommitCallee(callId: callId, storedCommit: commit())
        callee.setAcceptHash(ownHash)
        XCTAssertEqual(callee.receiveReveal(data: reveal(), nowMs: 10), .dropped)
        XCTAssertTrue(callee.acceptSent(nowMs: 2_000))
        XCTAssertNil(callee.verifiedNonce, "the early REVEAL was not kept")
        XCTAssertEqual(callee.tick(nowMs: 7_000), .end(reason: "sas_reveal_timeout"))
    }

    func testARevealWithoutACommitmentContextIsDropped() {
        let book = SasCommitBook()
        XCTAssertEqual(book.calleeOnReveal(callId: callId, data: reveal(), nowMs: 0), .dropped)
        XCTAssertFalse(book.isCallee(callId: callId), "no state is created by a stray REVEAL")
        XCTAssertFalse(book.isCaller(callId: callId))
        XCTAssertNil(book.words(callId: callId))
    }

    func testWrongNonceMalformedAndSecondDifferentRevealEndTheCall() {
        var flipped = nonce
        flipped[0] ^= 0x80
        var a = sentCallee()
        XCTAssertEqual(a.receiveReveal(data: reveal(nil, flipped), nowMs: 100), .end(reason: "sas_commit_mismatch"))
        var b = sentCallee()
        XCTAssertEqual(b.receiveReveal(data: String(reveal().dropLast()), nowMs: 100), .end(reason: "sas_commit_mismatch"))
        var c = sentCallee()
        XCTAssertEqual(c.receiveReveal(data: reveal(), nowMs: 100), .sasReady)
        XCTAssertEqual(c.receiveReveal(data: reveal(), nowMs: 200), .dropped, "byte-identical duplicate")
        XCTAssertEqual(c.receiveReveal(data: reveal(nil, flipped), nowMs: 300), .end(reason: "sas_commit_mismatch"))
        // an ended call ignores everything afterwards
        XCTAssertEqual(c.receiveReveal(data: reveal(), nowMs: 400), .dropped)
    }

    func testTheRevealTimerStartsAtTheFirstSendAndIsNotRestartedByRetransmissions() {
        var callee = SasCommitCallee(callId: callId, storedCommit: commit())
        callee.setAcceptHash(ownHash)
        XCTAssertTrue(callee.acceptSent(nowMs: 0))
        XCTAssertFalse(callee.acceptSent(nowMs: 2_500), "a retransmission does not restart the timer")
        XCTAssertEqual(callee.tick(nowMs: 4_999), .none)
        XCTAssertEqual(callee.tick(nowMs: 5_000), .end(reason: "sas_reveal_timeout"))
    }

    func testTheTimerNeverFiresOnceTheRevealVerifiedOrBeforeTheAcceptWasSent() {
        var verified = sentCallee()
        XCTAssertEqual(verified.receiveReveal(data: reveal(), nowMs: 10), .sasReady)
        XCTAssertEqual(verified.timerFired(), .none)
        XCTAssertEqual(verified.tick(nowMs: 60_000), .none)
        var unsent = SasCommitCallee(callId: callId, storedCommit: commit())
        unsent.setAcceptHash(ownHash)
        XCTAssertEqual(unsent.timerFired(), .none, "a held ACCEPT has no timer")
    }

    func testTheAnsweredCommitmentIsFrozenOnceTheAcceptIsSent() {
        var callee = sentCallee()
        callee.setAcceptHash(otherHash)   // a later ACCEPT must not replace the frozen one
        XCTAssertEqual(callee.acceptHash, ownHash)
    }

    // MARK: - R-COMMIT-SIBLING

    func testARevealNamingAnotherAcceptMakesThisDeviceLeaveLocally() {
        var callee = sentCallee()
        XCTAssertEqual(callee.receiveReveal(data: reveal(otherHash), nowMs: 100), .leaveLocally)
        XCTAssertFalse(callee.acceptsKeyConfirmation)
        XCTAssertTrue(callee.leftLocally)
        XCTAssertEqual(callee.timerFired(), .none, "its timers are stopped")
        XCTAssertEqual(callee.receiveReveal(data: reveal(), nowMs: 200), .dropped)
    }

    // MARK: - R-COMMIT-BIND / R-COMMIT-NONCE: the caller

    func testTheCallerBindsTheFirstAcceptAndNeverUsesAnother() throws {
        var caller = try XCTUnwrap(SasCommitCaller(callId: callId, nonce: nonce))
        XCTAssertEqual(caller.commit, commit())
        XCTAssertNil(caller.revealWire(), "never before binding")
        XCTAssertNil(caller.sasNonce, "the nonce is not released before binding")
        XCTAssertEqual(caller.onAccept(acceptHash: ownHash), .bindAndReveal)
        XCTAssertEqual(caller.revealWire(), reveal())
        XCTAssertEqual(caller.onAccept(acceptHash: otherHash), .drop, "a different round-1 ACCEPT after binding")
        XCTAssertEqual(caller.revealsSent, 1)
        XCTAssertEqual(caller.revealWire(), reveal(), "still the REVEAL of the first one")
    }

    func testADuplicateOfTheBoundAcceptResendsTheIdenticalRevealFourTimesAtMost() throws {
        var caller = try XCTUnwrap(SasCommitCaller(callId: callId, nonce: nonce))
        XCTAssertEqual(caller.onAccept(acceptHash: ownHash), .bindAndReveal)
        for _ in 0..<4 {
            XCTAssertEqual(caller.onAccept(acceptHash: ownHash), .resendReveal)
            XCTAssertEqual(caller.revealWire(), reveal())
        }
        XCTAssertEqual(caller.onAccept(acceptHash: ownHash), .drop, "at most 4 re-sends per call")
        XCTAssertEqual(caller.onReauth(), .drop, "the WS re-auth shares the budget")
        XCTAssertEqual(caller.revealsSent, 5)
    }

    func testAWsReauthResendsWithinTheSameBudget() throws {
        var caller = try XCTUnwrap(SasCommitCaller(callId: callId, nonce: nonce))
        XCTAssertEqual(caller.onReauth(), .drop, "nothing to re-send before binding")
        XCTAssertEqual(caller.onAccept(acceptHash: ownHash), .bindAndReveal)
        XCTAssertEqual(caller.onReauth(), .resendReveal)
        XCTAssertEqual(caller.revealWire(), reveal())
    }

    func testAnEndedCallZeroisesTheNonceAndNeverRevealsAgain() throws {
        var caller = try XCTUnwrap(SasCommitCaller(callId: callId, nonce: nonce))
        XCTAssertEqual(caller.onAccept(acceptHash: ownHash), .bindAndReveal)
        caller.end()
        XCTAssertNil(caller.revealWire())
        XCTAssertNil(caller.sasNonce)
        XCTAssertEqual(caller.onAccept(acceptHash: ownHash), .drop)
        // and a call that ended before binding never reveals for a late ACCEPT
        var early = try XCTUnwrap(SasCommitCaller(callId: callId, nonce: nonce))
        early.end()
        XCTAssertEqual(early.onAccept(acceptHash: ownHash), .drop)
        XCTAssertEqual(early.revealsSent, 0)
    }

    func testACallerNeverProcessesAReveal() throws {
        let book = SasCommitBook()
        _ = book.beginCaller(callId: callId, nonce: nonce)
        XCTAssertEqual(book.calleeOnReveal(callId: callId, data: reveal(), nowMs: 0), .dropped)
        let caller = try XCTUnwrap(SasCommitCaller(callId: callId, nonce: nonce))
        XCTAssertEqual(caller.onReveal(), .drop)
    }

    /// The bind is atomic: with many distinct ACCEPTs racing, exactly one binds and exactly one REVEAL
    /// is produced (fails if the bind is not one critical section, the iOS non-actor race of the design).
    func testConcurrentAcceptsBindExactlyOnce() {
        let book = SasCommitBook()
        _ = book.beginCaller(callId: callId, nonce: nonce)
        let lock = NSLock()
        var binds = 0
        var wires = Set<String>()
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            let (decision, wire) = book.callerOnAccept(callId: callId, acceptHash: Data(repeating: UInt8(i), count: 32))
            if decision == .bindAndReveal {
                lock.lock(); binds += 1; if let wire { wires.insert(wire) }; lock.unlock()
            }
        }
        XCTAssertEqual(binds, 1)
        XCTAssertEqual(wires.count, 1)
    }

    func testTheNonceIsDrawnOncePerCallAndDiffersBetweenCalls() throws {
        let book = SasCommitBook()
        let first = try XCTUnwrap(book.beginCaller(callId: callId))
        XCTAssertEqual(book.beginCaller(callId: callId.uppercased()), first, "never regenerated for the same call")
        XCTAssertEqual(book.callerCommit(callId: callId), first)
        let other = try XCTUnwrap(book.beginCaller(callId: "another-call"))
        XCTAssertNotEqual(first, other, "a redial is a new call with a new nonce")
        XCTAssertEqual(first.count, 32)
        book.clear(callId: callId)
        XCTAssertNil(book.callerCommit(callId: callId))
        let afterClear = try XCTUnwrap(book.beginCaller(callId: callId))
        XCTAssertNotEqual(afterClear, first, "a cleared call never reuses its nonce")
    }

    // MARK: - R-COMMIT-SAS: the words of the book

    func testTheCallersWordsAppearOnlyAfterBindingAndTheCalleesAfterAVerifiedReveal() throws {
        let key = Data(repeating: 0x42, count: 32)
        let expected = try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: ownHash, sasNonce: nonce).words

        let callerBook = SasCommitBook()
        _ = callerBook.beginCaller(callId: callId, nonce: nonce)
        callerBook.recordRound1(callId: callId, sessionKey: key, acceptHash: ownHash)
        XCTAssertNil(callerBook.words(callId: callId), "no bound ACCEPT: no words")
        let bound = SasCommitBook()
        _ = bound.beginCaller(callId: callId, nonce: nonce)
        _ = bound.callerOnAccept(callId: callId, acceptHash: ownHash)
        bound.recordRound1(callId: callId, sessionKey: key, acceptHash: ownHash)
        XCTAssertEqual(bound.words(callId: callId), expected)

        let calleeBook = SasCommitBook()
        XCTAssertTrue(calleeBook.beginCallee(callId: callId, commit: commit()))
        XCTAssertFalse(calleeBook.beginCallee(callId: callId, commit: commit(Data(repeating: 9, count: 32))),
                       "the first stored commitment wins")
        calleeBook.calleeSetAccept(callId: callId, acceptHash: ownHash)
        calleeBook.recordRound1(callId: callId, sessionKey: key, acceptHash: ownHash)
        XCTAssertNil(calleeBook.words(callId: callId), "the callee has no words before the REVEAL")
        XCTAssertTrue(calleeBook.calleeAcceptSent(callId: callId, nowMs: 0))
        XCTAssertTrue(calleeBook.isWaitingForReveal(callId: callId))
        XCTAssertEqual(calleeBook.calleeOnReveal(callId: callId, data: reveal(), nowMs: 50), .sasReady)
        XCTAssertEqual(calleeBook.words(callId: callId), expected, "caller and callee derive the same words")
        XCTAssertFalse(calleeBook.isWaitingForReveal(callId: callId))
    }

    func testARevealThatArrivesBeforeTheRoundOneMaterialStillYieldsTheWords() throws {
        let key = Data(repeating: 0x43, count: 32)
        let book = SasCommitBook()
        _ = book.beginCallee(callId: callId, commit: commit())
        book.calleeSetAccept(callId: callId, acceptHash: ownHash)
        _ = book.calleeAcceptSent(callId: callId, nowMs: 0)
        XCTAssertEqual(book.calleeOnReveal(callId: callId, data: reveal(), nowMs: 10), .sasReady)
        XCTAssertNil(book.words(callId: callId), "the session key is not installed yet")
        book.recordRound1(callId: callId, sessionKey: key, acceptHash: ownHash)
        XCTAssertEqual(book.words(callId: callId),
                       try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: ownHash, sasNonce: nonce).words)
    }

    // MARK: - Source wiring (AppState and the integration cannot be driven here)

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

    private func integrationText() throws -> String {
        try sourceText("QAudionEngine/Sources/QAudionEngine/Integration/QAudionCallIntegration.swift")
    }

    /// R-COMMIT-REVEAL: the caller's REVEAL is awaited BEFORE its round-1 KCMAC is armed, inside the
    /// ACCEPT-processing path (not from a later callback).
    func testTheRevealIsSentBeforeTheCallersKcmac() throws {
        let src = try integrationText()
        let acceptCase = try XCTUnwrap(src.range(of: "case .accept:\n            // Originator side"))
        let tail = String(src[acceptCase.upperBound...])
        let revealAt = try XCTUnwrap(tail.range(of: "await sendSasReveal(wire, callId: callId, resend: false)"))
        let kcmacAt = try XCTUnwrap(tail.range(of: "onKcMacReady?(KcMacReadyEvent("))
        XCTAssertLessThan(revealAt.lowerBound, kcmacAt.lowerBound)
        // and the bind happens before the REVEAL, before any session work
        let bindAt = try XCTUnwrap(tail.range(of: "sasCommit.callerOnAccept("))
        XCTAssertLessThan(bindAt.lowerBound, revealAt.lowerBound)
        let decapAt = try XCTUnwrap(tail.range(of: "try pqc.decapsulate("))
        XCTAssertLessThan(bindAt.lowerBound, decapAt.lowerBound, "the bind precedes the crypto work and every suspension")
    }

    /// R-COMMIT-SCOPE: only the round-1 OFFER carries a commitment; the rekey OFFER passes none.
    func testOnlyRoundOneDrawsACommitmentAndTheRekeyOfferCarriesNone() throws {
        let src = try integrationText()
        XCTAssertEqual(src.components(separatedBy: "sasCommit.beginCaller(callId: callId)").count - 1, 1)
        XCTAssertTrue(src.contains("rekeyNonce: thisRoundNonce, rekeyRound: thisRound, rekeyNextPeriodMs: nextPeriodMs,\n                sasCommit: nil)"))
        XCTAssertTrue(src.contains("rekeyNonce: rekeyNonceRound1, rekeyRound: 1, rekeyNextPeriodMs: nil,\n            sasCommit: sasCommitRound1)"))
    }

    /// R-COMMIT-CHECK / D1: the AppState handler checks the sender first, only a callee that sent its
    /// ACCEPT processes the REVEAL, and the sibling exit sends no hangup of any kind.
    func testTheAppHandlesTheRevealWithTheSenderCheckAndTheSiblingExitIsSilent() throws {
        let app = try sourceText("QAudionApp/AppState.swift")
        let start = try XCTUnwrap(app.range(of: "private func handleInboundSasReveal(callId: String, raw: String, senderId: String) {"))
        let end = try XCTUnwrap(app.range(of: "private func leaveCallAsSiblingDevice(callId: String) {"))
        let handler = String(app[start.upperBound..<end.lowerBound])
        let senderAt = try XCTUnwrap(handler.range(of: "guard callContactId == senderId"))
        let calleeAt = try XCTUnwrap(handler.range(of: "integration.isSasCallee(callId: callId)"))
        XCTAssertLessThan(senderAt.lowerBound, calleeAt.lowerBound)
        XCTAssertTrue(handler.contains("responderCallIntegration"), "only the responder leg processes a REVEAL")
        XCTAssertTrue(handler.contains("handleHandshakeFatal(callId: callId, reason: reason)"), "a mismatch/timeout ends the call")

        let leaveStart = try XCTUnwrap(app.range(of: "private func leaveCallAsSiblingDevice(callId: String) {"))
        let leaveEnd = try XCTUnwrap(app.range(of: "private func handleUndecodableHandshakeBundle("))
        let leave = String(app[leaveStart.upperBound..<leaveEnd.lowerBound])
        for forbidden in ["sendHangup", "sendCallHangupForId", "sendControlHangup", "echoHangupToServer", "pendingFatalCloseReason"] {
            XCTAssertFalse(leave.contains(forbidden), "the sibling exit must not use \(forbidden)")
        }
        let unbindAt = try XCTUnwrap(leave.range(of: "impl.unbindActiveCallId(matching: cid)"))
        let endAt = try XCTUnwrap(leave.range(of: "endCall(notifyPeerInBand: false)"))
        XCTAssertLessThan(unbindAt.lowerBound, endAt.lowerBound, "unbound first so endCall's hangup paths send nothing")
    }

    /// D1: the callee's own round-1 `kc_mac` is held until the REVEAL verified, and a device that left
    /// stops judging MACs.
    func testTheCalleesKcmacIsHeldUntilTheRevealAndALoserIgnoresMacs() throws {
        let app = try sourceText("QAudionApp/AppState.swift")
        XCTAssertTrue(app.contains("kcPendingOwnMac[key] = (wire: wire, peerId: peerId)"))
        XCTAssertTrue(app.contains("if let pending = kcPendingOwnMac.removeValue(forKey: key), let provider = liveProvider {"))
        XCTAssertTrue(app.contains("!integration.acceptsKeyConfirmation(callId: callId)"))
        XCTAssertTrue(app.contains("kcPendingOwnMac[callId] = nil"), "the held MAC is wiped with the ring state")
    }

    /// R-COMMIT-REASONS: telemetry codes and labels for the two new reasons.
    func testTheTwoReasonsHaveTelemetryCodesAndLabelsInEveryLanguage() throws {
        let app = try sourceText("QAudionApp/AppState.swift")
        XCTAssertTrue(app.contains("case SasCommit.reasonMismatch: code = 4"))
        XCTAssertTrue(app.contains("case SasCommit.reasonTimeout: code = 5"))
        XCTAssertEqual(CallCloseReason.accepted("sas_commit_mismatch"), .sasCommitMismatch)
        XCTAssertEqual(CallCloseReason.accepted("sas_reveal_timeout"), .sasRevealTimeout)
        XCTAssertEqual(SasCommit.reasonMismatch, "sas_commit_mismatch")
        XCTAssertEqual(SasCommit.reasonTimeout, "sas_reveal_timeout")
        // the history labels exist in it, en, de, es, fr, pt-BR
        let catalog = try sourceText("QAudionApp/Localizable.xcstrings")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(catalog.utf8)) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: Any])
        for key in ["call_history.close.sas_commit_mismatch", "call_history.close.sas_reveal_timeout", "sas.waiting_for_code"] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let loc = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            for lang in ["it", "en", "de", "es", "fr", "pt-BR"] {
                XCTAssertNotNil(loc[lang], "\(key) is translated into \(lang)")
            }
        }
    }

    // MARK: - R-COMMIT-V6: nothing of v5 survives

    func testNoV5HandshakeSymbolOrLabelSurvivesInTheSources() throws {
        let files = [
            "QAudionEngine/Sources/QAudionEngine/Crypto/HandshakeTranscript.swift",
            "QAudionEngine/Sources/QAudionEngine/Crypto/HandshakeSigningPolicy.swift",
            "QAudionEngine/Sources/QAudionEngine/Crypto/HkdfLabels.swift",
            "QAudionEngine/Sources/QAudionEngine/Crypto/ComputeSasUseCase.swift",
            "QAudionEngine/Sources/QAudionEngine/Integration/AndroidHandshakeBundle.swift",
            "QAudionEngine/Sources/QAudionEngine/Integration/QAudionCallIntegration.swift",
            "QAudionApp/AppState.swift",
        ]
        for file in files {
            let text = try sourceText(file)
            XCTAssertFalse(text.contains("qaudion-handshake-sig-v5"), "\(file): v5 domain")
            XCTAssertFalse(text.contains("q-audion-sas-transcript"), "\(file): retired SAS label")
            XCTAssertFalse(text.contains("public let sigV5"), "\(file): sigV5 field")
            XCTAssertFalse(text.contains("sigV5B64"), "\(file): sigV5 parameter")
            XCTAssertFalse(text.contains("sasTranscriptBindV1"), "\(file): retired label constant")
        }
        let transcript = try sourceText("QAudionEngine/Sources/QAudionEngine/Crypto/HandshakeTranscript.swift")
        XCTAssertTrue(transcript.contains("Data(\"qaudion-handshake-sig-v6\".utf8)"))
    }

    /// The domain of both transcripts is the v6 one, 24 bytes, not length-prefixed.
    func testTheTranscriptDomainIsV6() throws {
        let offer = V6TestFixtures.offerTranscript(signerKey: V6TestFixtures.signer(seed: 3).pubRaw)
        XCTAssertEqual(offer.prefix(24), Data("qaudion-handshake-sig-v6".utf8))
        XCTAssertEqual(offer[24], 0x01)
        let accept = V6TestFixtures.acceptTranscript(signerKey: V6TestFixtures.signer(seed: 4).pubRaw, offer: offer)
        XCTAssertEqual(accept.prefix(24), Data("qaudion-handshake-sig-v6".utf8))
        XCTAssertEqual(accept[24], 0x02)
    }

    /// R-COMMIT-UNCHANGED: the session key does not depend on any nonce: its derivation takes none, and
    /// the SAS words of two different nonces share one session key.
    func testTheSessionKeyDoesNotDependOnTheNonce() {
        let pqc = Data(repeating: 1, count: 32), x = Data(repeating: 2, count: 32)
        let key = QAudionCallIntegration.deriveTranscriptBoundSessionKey(
            pqcSharedSecret: pqc, x25519Shared: x, psk: nil, transcriptHash: ownHash)
        XCTAssertEqual(key, QAudionCallIntegration.deriveTranscriptBoundSessionKey(
            pqcSharedSecret: pqc, x25519Shared: x, psk: nil, transcriptHash: ownHash))
    }

    // MARK: - R-COMMIT-LOG: nothing secret reaches a log

    func testNoCommitmentLogLineCarriesSecretMaterial() throws {
        for file in ["QAudionEngine/Sources/QAudionEngine/Integration/QAudionCallIntegration.swift", "QAudionApp/AppState.swift"] {
            let text = try sourceText(file)
            for line in text.split(separator: "\n") where line.contains("sas_commit") || line.contains("sascommit") || line.contains("SASREVEAL") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("print(") || trimmed.hasPrefix("RTLog.") else { continue }
                for secret in ["nonce", "Nonce", "acceptHash", "acceptBinding", "words", "commitRaw", "sasCommit.base64", "base64EncodedString"] {
                    XCTAssertFalse(trimmed.contains(secret), "\(file): a log line mentions \(secret): \(trimmed)")
                }
            }
        }
        let primitives = try sourceText("QAudionEngine/Sources/QAudionEngine/Crypto/SasCommit.swift")
        XCTAssertFalse(primitives.contains("print("), "the primitives never log")
        XCTAssertFalse(primitives.contains("RTLog"), "the primitives never log")
    }

    // MARK: - WIRE_SPEC lock

    /// The spec copy and the lock agree: the committed WIRE_SPEC.md hashes to the EXPECTED value of the
    /// drift-lock workflow, and it is the v6 spec.
    func testTheWireSpecMatchesTheLockHash() throws {
        let spec = try sourceText("WIRE_SPEC.md")
        let lock = try sourceText(".github/workflows/wire-spec-lock.yml")
        let hash = SHA256.hash(data: Data(spec.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(lock.contains("EXPECTED=" + hash), "wire-spec-lock.yml EXPECTED must be the hash of WIRE_SPEC.md")
        XCTAssertTrue(spec.contains("### 3.7 Signed transcript v6"))
        XCTAssertTrue(spec.contains("#### 3.7.4 SAS commitment and REVEAL"))
    }
}

private extension UInt32 {
    var asInt: Int { Int(self) }
}
