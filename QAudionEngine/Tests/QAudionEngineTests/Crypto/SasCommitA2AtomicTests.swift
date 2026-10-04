import XCTest
@testable import QAudionEngine

/// A2 (WIRE_SPEC 3.7.4, pending OFFER) made atomic: the replacement of an unanswered round-1 OFFER is ONE
/// compare-and-remove in the SAS book, the ACCEPT is marked sent under the same guard, and every later step of an
/// OFFER's processing (the ACCEPT hold or send, the session install) is checked against the serial of the callee
/// context that OFFER created. Also the round-1 fail-closed behaviour when no SAS book is reachable.
final class SasCommitA2AtomicTests: XCTestCase {

    private let callId = "11111111-2222-3333-4444-555555555555"
    private let hashA = Data(repeating: 0xA1, count: 32)
    private let hashB = Data(repeating: 0xB2, count: 32)

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

    // MARK: - the book: compare-and-remove, serials, mark-sent

    func testSupersedeIfUnsentWipesAnUnsentContextAndEverythingRecordedForIt() {
        let book = SasCommitBook()
        let token = book.beginCalleeOwned(callId: callId, commit: commit(1), acceptHash: hashA)
        XCTAssertNotNil(token)
        book.recordRound1(callId: callId, sessionKey: Data(repeating: 7, count: 32), acceptHash: hashA)
        XCTAssertNotNil(book.round1SessionKey(callId: callId))
        XCTAssertTrue(book.calleeSupersedeIfUnsent(callId: callId.uppercased()))
        XCTAssertFalse(book.isCallee(callId: callId))
        XCTAssertNil(book.round1SessionKey(callId: callId), "the replaced round's material goes with it")
        XCTAssertFalse(book.calleeSupersedeIfUnsent(callId: callId), "nothing left to remove")
    }

    func testSupersedeIfUnsentIsRefusedOnceTheAcceptIsMarkedSent() throws {
        let book = SasCommitBook()
        let token = try XCTUnwrap(book.beginCalleeOwned(callId: callId, commit: commit(1), acceptHash: hashA))
        XCTAssertEqual(book.calleeMarkAcceptSent(callId: callId, token: token, nowMs: 5), .first)
        XCTAssertFalse(book.calleeSupersedeIfUnsent(callId: callId), "the answered commitment is frozen")
        XCTAssertTrue(book.isCallee(callId: callId), "nothing was touched")
        XCTAssertTrue(book.calleeIsCurrent(callId: callId, token: token))
    }

    func testAStaleContextCannotMarkItsAcceptSentOnTheContextThatReplacedIt() throws {
        let book = SasCommitBook()
        let tokenA = try XCTUnwrap(book.beginCalleeOwned(callId: callId, commit: commit(1), acceptHash: hashA))
        XCTAssertTrue(book.calleeSupersedeIfUnsent(callId: callId))
        let tokenB = try XCTUnwrap(book.beginCalleeOwned(callId: callId, commit: commit(2), acceptHash: hashB))
        XCTAssertNotEqual(tokenA, tokenB, "serials never repeat")
        XCTAssertEqual(book.calleeMarkAcceptSent(callId: callId, token: tokenA, nowMs: 5), .stale,
                       "the replaced OFFER's ACCEPT is not sent")
        XCTAssertTrue(book.calleeCanBeSuperseded(callId: callId),
                      "and it did not freeze the replacing OFFER's context")
        XCTAssertFalse(book.calleeIsCurrent(callId: callId, token: tokenA))
        XCTAssertTrue(book.calleeIsCurrent(callId: callId, token: tokenB))
        XCTAssertEqual(book.calleeMarkAcceptSent(callId: callId, token: tokenB, nowMs: 6), .first)
    }

    func testMarkAcceptSentIsFirstOnceThenNotFirst() throws {
        let book = SasCommitBook()
        let token = try XCTUnwrap(book.beginCalleeOwned(callId: callId, commit: commit(1), acceptHash: hashA))
        XCTAssertEqual(book.calleeMarkAcceptSent(callId: callId, token: token, nowMs: 1), .first)
        XCTAssertEqual(book.calleeMarkAcceptSent(callId: callId, token: token, nowMs: 2), .notFirst,
                       "a retransmission or a cached replay never restarts the REVEAL timer")
        XCTAssertEqual(book.calleeMarkAcceptSent(callId: callId, token: token &+ 99, nowMs: 3), .stale)
        XCTAssertEqual(book.calleeMarkAcceptSent(callId: "another-call", token: token, nowMs: 3), .stale)
    }

    /// A context that never got its ACCEPT hash cannot mark a send, and a refusal is not "sent before": nothing is sent.
    func testAContextThatRefusesToMarkASendIsNotTreatedAsAlreadySent() throws {
        let book = SasCommitBook()
        XCTAssertTrue(book.beginCallee(callId: callId, commit: commit(1)))   // no ACCEPT hash stored
        let token = try XCTUnwrap(book.calleeCurrentToken(callId: callId))
        XCTAssertEqual(book.calleeMarkAcceptSent(callId: callId, token: token, nowMs: 1), .stale)
        XCTAssertTrue(book.calleeCanBeSuperseded(callId: callId), "and it stays unanswered")
    }

    func testAContextClearedWithTheCallIsStale() throws {
        let book = SasCommitBook()
        let token = try XCTUnwrap(book.beginCalleeOwned(callId: callId, commit: commit(1), acceptHash: hashA))
        XCTAssertEqual(book.calleeCurrentToken(callId: callId), token)
        book.clear(callId: callId)
        XCTAssertNil(book.calleeCurrentToken(callId: callId))
        XCTAssertFalse(book.calleeIsCurrent(callId: callId, token: token))
        XCTAssertEqual(book.calleeMarkAcceptSent(callId: callId, token: token, nowMs: 1), .stale)
    }

    func testBeginCalleeOwnedRefusesASecondContextAndMalformedArguments() {
        let book = SasCommitBook()
        XCTAssertNotNil(book.beginCalleeOwned(callId: callId, commit: commit(1), acceptHash: hashA))
        XCTAssertNil(book.beginCalleeOwned(callId: callId, commit: commit(2), acceptHash: hashB),
                     "the first context of a call owns its commitment")
        let other = SasCommitBook()
        XCTAssertNil(other.beginCalleeOwned(callId: "", commit: commit(1), acceptHash: hashA))
        XCTAssertNil(other.beginCalleeOwned(callId: callId, commit: Data(repeating: 1, count: 31), acceptHash: hashA))
        XCTAssertNil(other.beginCalleeOwned(callId: callId, commit: commit(1), acceptHash: Data(repeating: 1, count: 31)))
        XCTAssertFalse(other.isCallee(callId: callId), "a refused begin leaves no context")
    }

    func testTheOwnedContextHoldsItsAcceptHashFromTheStart() throws {
        let book = SasCommitBook()
        let token = try XCTUnwrap(book.beginCalleeOwned(callId: callId, commit: commit(1), acceptHash: hashA))
        // a callee context without a stored ACCEPT hash can never be marked sent: the owned one can, at once
        XCTAssertEqual(book.calleeMarkAcceptSent(callId: callId, token: token, nowMs: 1), .first)
        XCTAssertTrue(book.isWaitingForReveal(callId: callId))
    }

    /// The race itself, replayed many times with the two operations really running in parallel: whichever takes the
    /// book's lock first decides, so exactly one of "the ACCEPT is marked sent" and "the context is replaced" wins.
    func testTheAcceptAndTheReplacementNeverBothWin() throws {
        for round in 0..<400 {
            let book = SasCommitBook()
            let token = try XCTUnwrap(book.beginCalleeOwned(callId: callId, commit: commit(1), acceptHash: hashA))
            let outcome = Wire()
            let cid = callId
            let queue = DispatchQueue.global(qos: .userInitiated)
            let group = DispatchGroup()
            queue.async(group: group) {
                if book.calleeMarkAcceptSent(callId: cid, token: token, nowMs: 1) == .first { outcome.add("sent") }
            }
            queue.async(group: group) {
                if book.calleeSupersedeIfUnsent(callId: cid) { outcome.add("replaced") }
            }
            group.wait()
            XCTAssertEqual(outcome.all.count, 1, "exactly one winner (round \(round)): \(outcome.all)")
            if outcome.all == ["sent"] {
                XCTAssertTrue(book.calleeIsCurrent(callId: callId, token: token))
            } else {
                XCTAssertFalse(book.isCallee(callId: callId))
            }
        }
    }

    // MARK: - the integration: held ACCEPT, release, replacement

    private func heldIntegration(wire: Wire) -> QAudionCallIntegration {
        let integ = QAudionCallIntegration()
        integ.shouldHoldResponderAccept = { _ in true }
        integ.setResponderSenderForTesting { wire.add($0) }
        return integ
    }

    func testTheHeldAcceptOfAReplacedOfferIsNeverReleasedAndTheReplacingOneIs() async throws {
        let wire = Wire()
        let integ = heldIntegration(wire: wire)
        let tokenA = try XCTUnwrap(integ.sasCommit.beginCalleeOwned(callId: callId, commit: commit(1), acceptHash: hashA))
        try await integ.emitJsonAccept(callId: callId, wire: "ACCEPT-A", sendOpaqueRaw: { _ in XCTFail("held, not sent") },
                                       isRound1: true, calleeToken: tokenA)
        XCTAssertTrue(integ.supersedeUnansweredRound1IfUnsent(callId: callId), "unanswered: replaced")

        let tokenB = try XCTUnwrap(integ.sasCommit.beginCalleeOwned(callId: callId, commit: commit(2), acceptHash: hashB))
        try await integ.emitJsonAccept(callId: callId, wire: "ACCEPT-B", sendOpaqueRaw: { _ in XCTFail("held, not sent") },
                                       isRound1: true, calleeToken: tokenB)
        // The replaced OFFER's processing finishes late: it must neither hold nor send its ACCEPT, and must not
        // displace the replacing OFFER's held one.
        try await integ.emitJsonAccept(callId: callId, wire: "ACCEPT-A-LATE", sendOpaqueRaw: { _ in XCTFail("stale") },
                                       isRound1: true, calleeToken: tokenA)

        integ.shouldHoldResponderAccept = { _ in false }
        let released = await integ.releaseHeldAccept(callId: callId)
        XCTAssertTrue(released)
        XCTAssertEqual(wire.all, ["ACCEPT-B"], "only the replacing OFFER's ACCEPT leaves")
        XCTAssertFalse(integ.sasCommit.calleeCanBeSuperseded(callId: callId), "its ACCEPT is out: frozen")
    }

    func testTheReleaseWinsWhenTheHumanAnsweredFirstAndTheReplacementIsRefused() async throws {
        let wire = Wire()
        let integ = heldIntegration(wire: wire)
        let tokenA = try XCTUnwrap(integ.sasCommit.beginCalleeOwned(callId: callId, commit: commit(1), acceptHash: hashA))
        try await integ.emitJsonAccept(callId: callId, wire: "ACCEPT-A", sendOpaqueRaw: { _ in XCTFail("held") },
                                       isRound1: true, calleeToken: tokenA)
        integ.shouldHoldResponderAccept = { _ in false }
        let released = await integ.releaseHeldAccept(callId: callId)
        XCTAssertTrue(released)
        XCTAssertEqual(wire.all, ["ACCEPT-A"])
        XCTAssertFalse(integ.supersedeUnansweredRound1IfUnsent(callId: callId),
                       "the ACCEPT is out: a different round-1 OFFER is a stale round")
        XCTAssertTrue(integ.sasCommit.calleeIsCurrent(callId: callId, token: tokenA), "the answered context stays")
        XCTAssertTrue(integ.sasCommit.isWaitingForReveal(callId: callId))
    }

    func testAReleaseAfterTheReplacementSendsNothing() async throws {
        let wire = Wire()
        let integ = heldIntegration(wire: wire)
        let tokenA = try XCTUnwrap(integ.sasCommit.beginCalleeOwned(callId: callId, commit: commit(1), acceptHash: hashA))
        try await integ.emitJsonAccept(callId: callId, wire: "ACCEPT-A", sendOpaqueRaw: { _ in XCTFail("held") },
                                       isRound1: true, calleeToken: tokenA)
        XCTAssertTrue(integ.supersedeUnansweredRound1IfUnsent(callId: callId))
        integ.shouldHoldResponderAccept = { _ in false }
        let released = await integ.releaseHeldAccept(callId: callId)
        XCTAssertFalse(released)
        XCTAssertTrue(wire.all.isEmpty, "the replaced round's ACCEPT never leaves")
    }

    /// A held ACCEPT of a replaced OFFER that is still in the slot when the human answers (the release popped it just
    /// before the replacement wiped the slot) is dropped by the release itself, never sent, and it does not freeze
    /// the context of the OFFER that replaced it.
    func testAStaleHeldAcceptHandedToTheReleaseIsDroppedByTheRelease() async throws {
        let wire = Wire()
        let integ = heldIntegration(wire: wire)
        let tokenA = try XCTUnwrap(integ.sasCommit.beginCalleeOwned(callId: callId, commit: commit(1), acceptHash: hashA))
        XCTAssertTrue(integ.supersedeUnansweredRound1IfUnsent(callId: callId))
        let tokenB = try XCTUnwrap(integ.sasCommit.beginCalleeOwned(callId: callId, commit: commit(2), acceptHash: hashB))
        integ.storeHeldAcceptForTesting(callId: callId, wire: "ACCEPT-A-STALE", calleeToken: tokenA)

        let released = await integ.releaseHeldAccept(callId: callId)
        XCTAssertFalse(released)
        XCTAssertTrue(wire.all.isEmpty, "the replaced OFFER's ACCEPT is dropped by the release")
        XCTAssertTrue(integ.sasCommit.calleeCanBeSuperseded(callId: callId), "B's context is not frozen by A's ACCEPT")
        XCTAssertTrue(integ.sasCommit.calleeIsCurrent(callId: callId, token: tokenB))
    }

    /// The same race through the integration: the human answers (`releaseHeldAccept`) while a newer OFFER replaces
    /// the round. Exactly one wins; the ACCEPT left if and only if the replacement was refused.
    func testReleaseAndReplacementRaceThroughTheIntegration() async throws {
        for round in 0..<200 {
            let wire = Wire()
            let integ = heldIntegration(wire: wire)
            let tokenA = try XCTUnwrap(integ.sasCommit.beginCalleeOwned(callId: callId, commit: commit(1), acceptHash: hashA))
            try await integ.emitJsonAccept(callId: callId, wire: "ACCEPT-A", sendOpaqueRaw: { _ in XCTFail("held") },
                                           isRound1: true, calleeToken: tokenA)
            integ.shouldHoldResponderAccept = { _ in false }
            let cid = callId
            let (released, replaced) = await withTaskGroup(of: (Int, Bool).self) { group -> (Bool, Bool) in
                group.addTask { (0, await integ.releaseHeldAccept(callId: cid)) }
                group.addTask { (1, integ.supersedeUnansweredRound1IfUnsent(callId: cid)) }
                var r = false
                var s = false
                for await (tag, value) in group {
                    if tag == 0 { r = value } else { s = value }
                }
                return (r, s)
            }
            XCTAssertNotEqual(released, replaced, "exactly one winner (round \(round))")
            XCTAssertEqual(wire.all, released ? ["ACCEPT-A"] : [], "the ACCEPT left iff the replacement lost (round \(round))")
        }
    }

    /// Without the hold the ACCEPT is marked sent and handed to the transport directly: a stale context's ACCEPT is
    /// not, and it must not freeze the context of the OFFER that replaced it.
    func testAStaleAcceptIsNotSentWhenTheHoldIsOffAndDoesNotFreezeTheReplacingContext() async throws {
        let integ = QAudionCallIntegration()
        let wire = Wire()
        let tokenA = try XCTUnwrap(integ.sasCommit.beginCalleeOwned(callId: callId, commit: commit(1), acceptHash: hashA))
        XCTAssertTrue(integ.supersedeUnansweredRound1IfUnsent(callId: callId))
        let tokenB = try XCTUnwrap(integ.sasCommit.beginCalleeOwned(callId: callId, commit: commit(2), acceptHash: hashB))

        try await integ.emitJsonAccept(callId: callId, wire: "ACCEPT-A", sendOpaqueRaw: { wire.add($0) },
                                       isRound1: true, calleeToken: tokenA)
        XCTAssertTrue(wire.all.isEmpty, "the replaced OFFER's ACCEPT never reaches the transport")
        XCTAssertTrue(integ.sasCommit.calleeCanBeSuperseded(callId: callId), "B is still unanswered")

        try await integ.emitJsonAccept(callId: callId, wire: "ACCEPT-B", sendOpaqueRaw: { wire.add($0) },
                                       isRound1: true, calleeToken: tokenB)
        XCTAssertEqual(wire.all, ["ACCEPT-B"])
        XCTAssertFalse(integ.sasCommit.calleeCanBeSuperseded(callId: callId))
        XCTAssertTrue(integ.sasCommit.isWaitingForReveal(callId: callId), "the REVEAL wait starts at the first send")
    }

    func testARoundOneAcceptWithoutAContextIsNotSentAndARekeyAcceptIs() async throws {
        let integ = QAudionCallIntegration()
        let wire = Wire()
        // a cached-ACCEPT replay after the call's context is gone (no token)
        try await integ.emitJsonAccept(callId: callId, wire: "CACHED", sendOpaqueRaw: { wire.add($0) },
                                       isRound1: true, calleeToken: nil)
        XCTAssertTrue(wire.all.isEmpty)
        // a rekey round's ACCEPT has no commitment context and goes out as before
        try await integ.emitJsonAccept(callId: callId, wire: "REKEY", sendOpaqueRaw: { wire.add($0) },
                                       isRound1: false, calleeToken: nil)
        XCTAssertEqual(wire.all, ["REKEY"])
    }

    func testARetransmittedAcceptIsSentButNeverRestartsTheFreeze() async throws {
        let integ = QAudionCallIntegration()
        let wire = Wire()
        let token = try XCTUnwrap(integ.sasCommit.beginCalleeOwned(callId: callId, commit: commit(1), acceptHash: hashA))
        try await integ.emitJsonAccept(callId: callId, wire: "ACCEPT", sendOpaqueRaw: { wire.add($0) },
                                       isRound1: true, calleeToken: token)
        try await integ.emitJsonAccept(callId: callId, wire: "ACCEPT", sendOpaqueRaw: { wire.add($0) },
                                       isRound1: true, calleeToken: integ.sasCommit.calleeCurrentToken(callId: callId))
        XCTAssertEqual(wire.all, ["ACCEPT", "ACCEPT"], "a replay of the cached ACCEPT is still sent")
    }

    // MARK: - the offer intake wiring

    private func integrationText() throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(
                "QAudionEngine/Sources/QAudionEngine/Integration/QAudionCallIntegration.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw XCTSkip("QAudionCallIntegration.swift not found")
    }

    /// Whole-line comments dropped, whitespace collapsed: a pin written against this survives re-wrapping.
    private func code(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The check-then-act is gone: the replacement is the guarded compare-and-remove (a refusal drops the OFFER), the
    /// context is begun with its serial, the ACCEPT goes through the guarded send, the session install runs under the
    /// install lock after the token check, and the engine is no longer initialised with `try?`.
    func testTheOfferIntakeUsesTheAtomicReplacementTheTokenAndTheInstallGuard() throws {
        let src = code(try integrationText())
        XCTAssertFalse(src.contains("supersedeUnansweredRound1(callId:"), "the unconditional wipe is gone")
        XCTAssertTrue(src.contains("guard supersedeUnansweredRound1IfUnsent(callId: callId) else {"))
        XCTAssertFalse(src.contains("try? engine.initialize()"), "no error of the engine is swallowed")
        XCTAssertFalse(src.contains("sasCommit.beginCallee(callId: callId, commit: commitRaw)"), "the context is begun with its serial")
        XCTAssertTrue(src.contains("sasCommit.beginCalleeOwned( callId: callId, commit: commitRaw, acceptHash: acceptBinding)"))

        let begin = try XCTUnwrap(src.range(of: "sasCommit.beginCalleeOwned("))
        let emit = try XCTUnwrap(src.range(of: "try await emitJsonAccept(callId: callId, wire: wire, sendOpaqueRaw: sendOpaqueRaw, isRound1: !isReKeyRound, calleeToken: calleeToken, acceptRound: Int(round))"))
        let guarded = try XCTUnwrap(src.range(of: "let installed: Bool = try offerInstallLock.withLock {"))
        let tokenCheck = try XCTUnwrap(src.range(of: "if let calleeToken, !sasCommit.calleeIsCurrent(callId: callId, token: calleeToken) { return false }"))
        let initSession = try XCTUnwrap(src.range(of: "try engine.initSession(sharedSecret: combined, adaptivePadding: true,"))
        let ready = try XCTUnwrap(src.range(of: "onKcMacReady?(KcMacReadyEvent("))
        XCTAssertLessThan(begin.lowerBound, emit.lowerBound)
        XCTAssertLessThan(emit.lowerBound, guarded.lowerBound)
        XCTAssertLessThan(guarded.lowerBound, tokenCheck.lowerBound)
        XCTAssertLessThan(tokenCheck.lowerBound, initSession.lowerBound, "the token is checked before the session is installed")
        XCTAssertLessThan(initSession.lowerBound, ready.lowerBound)
        let afterGuard = String(src[guarded.upperBound...].prefix(40_000))
        let closeAt = try XCTUnwrap(afterGuard.range(of: "} if !installed {"))
        XCTAssertTrue(afterGuard[..<closeAt.lowerBound].contains("onKcMacReady?(KcMacReadyEvent("),
                      "the callbacks run inside the guarded block")
        XCTAssertFalse(afterGuard[..<closeAt.lowerBound].contains("await "), "no suspension inside the guarded block")
    }

    /// The cached ACCEPT of a duplicate OFFER and the serial it belongs to are read together under the install lock, and
    /// the transcript-hash marker is stored only after this OFFER owns the call's commitment.
    func testTheReplayReadsWireAndSerialTogetherAndTheMarkerFollowsTheOwnership() throws {
        let src = code(try integrationText())
        XCTAssertTrue(src.contains("let replay: (wire: String, token: UInt64?)? = offerInstallLock.withLock { guard let cached = lock.withLock({ acceptWireByOfferFingerprint[offerDedupKey] }) else { return nil } return (cached, round == 1 ? sasCommit.calleeCurrentToken(callId: callId) : nil) }"))
        XCTAssertFalse(src.contains("wire: cached"), "no cached wire is replayed with a serial read separately")
        let owned = try XCTUnwrap(src.range(of: "calleeToken = ownedToken"))
        let marker = try XCTUnwrap(src.range(of: "HandshakeTranscriptHashStore.shared.set(acceptBinding, forCallId: callId)"))
        let emit = try XCTUnwrap(src.range(of: "try await emitJsonAccept(callId: callId, wire: wire, sendOpaqueRaw: sendOpaqueRaw, isRound1: !isReKeyRound"))
        XCTAssertLessThan(owned.lowerBound, marker.lowerBound, "an OFFER dropped for not owning the commitment leaves the marker alone")
        XCTAssertLessThan(marker.lowerBound, emit.lowerBound, "stored before any callback announces the key")
    }

    /// An ACCEPT is marked sent (atomically, with the token) before it is handed to the transport, on both the direct
    /// and the held-release path, and the hold is stored under the install lock.
    func testEveryAcceptSendIsMarkedBeforeTheTransportAndTheHoldIsStoredUnderTheLock() throws {
        let src = code(try integrationText())
        let emitStart = try XCTUnwrap(src.range(of: "func emitJsonAccept("))
        let emitBody = String(src[emitStart.upperBound...].prefix(3_000))
        let markAt = try XCTUnwrap(emitBody.range(of: "markRound1AcceptSent(callId: callId, token: calleeToken)"))
        let sendAt = try XCTUnwrap(emitBody.range(of: "try await sendOpaqueRaw(wire)"))
        XCTAssertLessThan(markAt.lowerBound, sendAt.lowerBound)
        XCTAssertTrue(emitBody.contains("offerInstallLock.withLock"), "the hold is stored under the install lock")

        let relStart = try XCTUnwrap(src.range(of: "public func releaseHeldAccept(callId: String) async -> Bool {"))
        let relBody = String(src[relStart.upperBound...].prefix(2_500))
        let relMark = try XCTUnwrap(relBody.range(of: "markRound1AcceptSent(callId: cid, token: calleeToken)"))
        let relSend = try XCTUnwrap(relBody.range(of: "try await sender(wire)"))
        XCTAssertLessThan(relMark.lowerBound, relSend.lowerBound)
        XCTAssertFalse(src.contains("noteResponderAcceptSent("), "the unguarded marker is gone")
    }

    // MARK: - round 1 with no SAS book reachable

    func testARoundOneWaitWithoutABookKeepsTheLongestWaitOfItsRole() {
        typealias W = KcMacWindow
        // initiator: 30 s from arming, not the 15 s base window
        XCTAssertGreaterThan(W.remainingMsWithoutBook(isRound1: true, isInitiator: true, armedAtMs: 1_000, nowMs: 1_000 + 29_900), 0)
        XCTAssertEqual(W.remainingMsWithoutBook(isRound1: true, isInitiator: true, armedAtMs: 1_000, nowMs: 1_000 + 30_000), 0)
        // callee: the pre-REVEAL backstop, also 30 s from arming
        XCTAssertGreaterThan(W.remainingMsWithoutBook(isRound1: true, isInitiator: false, armedAtMs: 1_000, nowMs: 1_000 + 29_900), 0)
        XCTAssertEqual(W.remainingMsWithoutBook(isRound1: true, isInitiator: false, armedAtMs: 1_000, nowMs: 1_000 + 30_000), 0)
        // a later round: the offerer keeps the base window, the acceptor of the rekey round waits 30 s (K2)
        XCTAssertGreaterThan(W.remainingMsWithoutBook(isRound1: false, isInitiator: true, armedAtMs: 0, nowMs: 14_900), 0)
        XCTAssertEqual(W.remainingMsWithoutBook(isRound1: false, isInitiator: true, armedAtMs: 0, nowMs: 15_000), 0)
        XCTAssertGreaterThan(W.remainingMsWithoutBook(isRound1: false, isInitiator: false, armedAtMs: 0, nowMs: 29_900), 0)
        XCTAssertEqual(W.remainingMsWithoutBook(isRound1: false, isInitiator: false, armedAtMs: 0, nowMs: 30_000), 0)
    }

    func testTheWaitWithoutABookIsNeverShorterThanTheWaitWithOne() {
        typealias W = KcMacWindow
        for initiator in [true, false] {
            for nowMs in stride(from: 0, through: 40_000, by: 2_500) {
                let withoutBook = W.remainingMsWithoutBook(isRound1: true, isInitiator: initiator, armedAtMs: 0, nowMs: nowMs)
                let handed: Int? = initiator ? 0 : nil
                let verified: Int? = initiator ? nil : 0
                let withBook = W.remainingMs(isRound1: true, isInitiator: initiator, armedAtMs: 0, nowMs: nowMs,
                                             revealHandedAtMs: handed, revealVerifiedAtMs: verified)
                XCTAssertGreaterThanOrEqual(withoutBook, withBook, "initiator=\(initiator) now=\(nowMs)")
            }
        }
    }

    func testTheDeviceRuleWithoutABookDropsOnlyForALiveRoundOneInitiatorState() {
        typealias B = SasCommitBook
        XCTAssertEqual(B.callerKcMacSenderVerdictWithoutBook(roundOneInitiatorStateAlive: true), .dropSilently,
                       "the caller's book is gone while its state is alive: nothing vouches for the sender")
        XCTAssertEqual(B.callerKcMacSenderVerdictWithoutBook(roundOneInitiatorStateAlive: false), .notApplicable,
                       "a callee has no caller book by design: the rule does not apply")
    }

    func testTheAppFailsClosedWhenTheCallersBookIsGone() throws {
        var dir = URL(fileURLWithPath: #filePath)
        var app: String?
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent("QAudionApp/AppState.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                app = try String(contentsOf: candidate, encoding: .utf8)
                break
            }
        }
        guard let appText = app else { throw XCTSkip("AppState.swift not found") }
        let src = code(appText)
        XCTAssertTrue(src.contains("SasCommitBook.callerKcMacSenderVerdictWithoutBook( roundOneInitiatorStateAlive: aliveState?.isInitiator == true && aliveState?.isRound1 == true)"))
        XCTAssertTrue(src.contains("KcMacWindow.remainingMsWithoutBook( isRound1: state.isRound1, isInitiator: state.isInitiator, armedAtMs: state.armedAtMs, nowMs: nowMs)"))
        XCTAssertFalse(src.contains("isRound1: false, isInitiator: state.isInitiator, armedAtMs: state.armedAtMs, nowMs: nowMs, revealHandedAtMs: nil"),
                       "the shorter fallback window is gone")
    }
}
