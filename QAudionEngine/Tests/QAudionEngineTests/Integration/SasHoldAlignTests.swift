import XCTest
import CryptoKit
@testable import QAudionEngine

/// SAS hold alignment round (post-v5), the iOS side of R-SAS-WORDS, R-HELD-REKEY (caller-side deferral)
/// and R-VERIFIED-MARK. "Held" = a 1:1 call whose peer identity key is unresolved (no pin, no server
/// key) with media held pending the SAS; the "candidate round" is the first round of the call whose
/// signature verified against the bundle key while unresolved.
final class SasHoldAlignTests: XCTestCase {

    private typealias F = V5TestFixtures

    private let peer = "peer-0001"
    private let keyA = F.signer(seed: 71)
    private let keyB = F.signer(seed: 72)

    private let k1 = Data(repeating: 0x11, count: 32)
    private let k2 = Data(repeating: 0x22, count: 32)
    private let h1 = Data(repeating: 0xA1, count: 32)
    private let h2 = Data(repeating: 0xA2, count: 32)

    private func signedOffer(
        signer: (priv: Curve25519.Signing.PrivateKey, pubRaw: Data), round: Int
    ) throws -> AndroidHandshakeBundle {
        let unsigned = AndroidHandshakeBundle(
            kind: .offer, callId: F.callId,
            pqcPublicKey: Data(repeating: 0xA1, count: 1568).base64EncodedString(),
            x25519PublicKey: Data(repeating: 0xA2, count: 32).base64EncodedString(),
            rekeyNonce: F.rekeyNonce.base64EncodedString(), rekeyRound: round)
        let t = try XCTUnwrap(QAudionCallIntegration.offerTranscript(
            from: unsigned, callId: F.callId, signerKeyRaw: signer.pubRaw,
            dtlsFingerprint: F.fingerprint("offerer")))
        let sig = try signer.priv.signature(for: t)
        return AndroidHandshakeBundle(
            kind: .offer, callId: F.callId,
            pqcPublicKey: unsigned.pqcPublicKey, x25519PublicKey: unsigned.x25519PublicKey,
            signerIdentityKey: signer.pubRaw.base64EncodedString(),
            sigV5: sig.base64EncodedString(),
            dtlsFingerprint: F.fingerprintText("offerer"),
            rekeyNonce: unsigned.rekeyNonce, rekeyRound: round)
    }

    private func verdict(_ integ: QAudionCallIntegration, _ b: AndroidHandshakeBundle) -> HandshakeSigningPolicy.Verdict {
        integ.evaluateInbound(
            bundle: b, callId: F.callId, peerId: peer, peerDeviceId: nil, expectedOfferBinding: nil).verdict
    }

    private func words(_ key: Data, _ hash: Data) throws -> [String] {
        try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: hash).words
    }

    // MARK: - R-SAS-WORDS

    /// An honest same-key rekey before the confirmation installs a later session key, but the words of
    /// the held call stay the candidate round's: the other platforms show the first round's words, so
    /// the two users can still compare them.
    func testHeldCallKeepsTheCandidateRoundsWordsAcrossASameKeyRekey() throws {
        let integ = QAudionCallIntegration()
        XCTAssertEqual(verdict(integ, try signedOffer(signer: keyA, round: 1)), .abort(code: "identity_unresolved"))
        integ.recordKeyRound(callId: F.callId, key: k1, round: 1, transcriptHash: h1)
        XCTAssertEqual(verdict(integ, try signedOffer(signer: keyA, round: 2)), .abort(code: "identity_unresolved"))
        integ.recordKeyRound(callId: F.callId, key: k2, round: 2, transcriptHash: h2)

        let material = try XCTUnwrap(integ.candidateSasMaterial(callId: F.callId.uppercased()))
        XCTAssertEqual(material.round, 1)
        XCTAssertEqual(material.sessionKey, k1)
        XCTAssertEqual(material.transcriptHash, h1)
        XCTAssertEqual(try words(material.sessionKey, material.transcriptHash), try words(k1, h1))
        XCTAssertNotEqual(
            try words(material.sessionKey, material.transcriptHash), try words(k2, h2),
            "the live round's words differ: showing them would be the iOS/desktop mismatch")
    }

    /// The candidate's material is written once, for the candidate round only.
    func testCandidateMaterialIsWrittenOnceAndOnlyForTheCandidateRound() throws {
        let integ = QAudionCallIntegration()
        _ = verdict(integ, try signedOffer(signer: keyA, round: 1))
        // a later round (not the candidate) arriving first, then the candidate, then a replay of it
        integ.recordKeyRound(callId: F.callId, key: k2, round: 2, transcriptHash: h2)
        XCTAssertNil(integ.candidateSasMaterial(callId: F.callId), "round 2 is not the candidate")
        integ.recordKeyRound(callId: F.callId, key: k1, round: 1, transcriptHash: h1)
        integ.recordKeyRound(callId: F.callId, key: k2, round: 1, transcriptHash: h2)
        XCTAssertEqual(integ.candidateSasMaterial(callId: F.callId)?.sessionKey, k1)
        XCTAssertEqual(integ.candidateSasMaterial(callId: F.callId)?.transcriptHash, h1)
    }

    /// A call whose identity resolved (pin or server key) has no candidate: its live words apply.
    func testAuthenticatedCallHasNoCandidateMaterial() throws {
        let integ = QAudionCallIntegration()
        let server = keyA.pubRaw
        integ.resolveServerPeerKey = { _ in server }
        _ = verdict(integ, try signedOffer(signer: keyA, round: 1))
        integ.recordKeyRound(callId: F.callId, key: k1, round: 1, transcriptHash: h1)
        XCTAssertNil(integ.candidateSasMaterial(callId: F.callId))
    }

    /// A round the candidate's key cannot vouch for puts the call in conflict: the candidate's words then
    /// vouch for nothing (the live words are shown and the confirmation is refused).
    func testConflictedCallFallsBackToTheLiveWords() throws {
        let integ = QAudionCallIntegration()
        _ = verdict(integ, try signedOffer(signer: keyA, round: 1))
        integ.recordKeyRound(callId: F.callId, key: k1, round: 1, transcriptHash: h1)
        XCTAssertNotNil(integ.candidateSasMaterial(callId: F.callId))
        _ = verdict(integ, try signedOffer(signer: keyB, round: 2))
        integ.recordKeyRound(callId: F.callId, key: k2, round: 2, transcriptHash: h2)
        XCTAssertNil(integ.candidateSasMaterial(callId: F.callId))
        XCTAssertEqual(integ.sasSignerAdoption(callId: F.callId, sessionKey: k2), .refused)
    }

    /// The confirmation is checked against the candidate round's words: whatever later same-key session
    /// key is live, the key adopted is the candidate round's signer.
    func testConfirmationFollowsTheCandidateRoundNotTheLiveOne() throws {
        let integ = QAudionCallIntegration()
        _ = verdict(integ, try signedOffer(signer: keyA, round: 1))
        integ.recordKeyRound(callId: F.callId, key: k1, round: 1, transcriptHash: h1)
        // a live round 3 whose verdict was never noted (it would have nothing to adopt on its own)
        let k3 = Data(repeating: 0x33, count: 32)
        integ.recordKeyRound(callId: F.callId, key: k3, round: 3, transcriptHash: Data(repeating: 0xA3, count: 32))
        XCTAssertNil(integ.signerKeyAwaitingSas(callId: F.callId, sessionKey: k3))
        XCTAssertEqual(integ.sasSignerAdoption(callId: F.callId, sessionKey: k3), .adopt(keyA.pubRaw))
    }

    /// After the confirmation the words stay the same ones the user compared (the verified mark of the
    /// call keeps matching), and everything is forgotten when the call's state is cleared.
    func testWordsStayAfterTheConfirmationAndAreForgottenWithTheCall() throws {
        let integ = QAudionCallIntegration()
        _ = verdict(integ, try signedOffer(signer: keyA, round: 1))
        integ.recordKeyRound(callId: F.callId, key: k1, round: 1, transcriptHash: h1)
        integ.confirmSasSigner(callId: F.callId, key: keyA.pubRaw)
        XCTAssertEqual(integ.candidateSasMaterial(callId: F.callId)?.sessionKey, k1)
        XCTAssertNil(integ.candidateSasMaterial(callId: "another-call"))
        integ.sasPins.clear(callId: F.callId)
        XCTAssertNil(integ.candidateSasMaterial(callId: F.callId))
    }

    func testMalformedMaterialIsIgnored() {
        let book = CallScopedSasPinBook()
        book.noteUnresolved(callId: "c1", round: 1, signerKey: keyA.pubRaw)
        book.recordCandidateMaterial(callId: "c1", round: 1, sessionKey: Data(repeating: 1, count: 31), transcriptHash: h1)
        book.recordCandidateMaterial(callId: "c1", round: 1, sessionKey: k1, transcriptHash: Data(repeating: 1, count: 31))
        book.recordCandidateMaterial(callId: "", round: 1, sessionKey: k1, transcriptHash: h1)
        XCTAssertNil(book.candidateSasMaterial(callId: "c1"))
    }

    // MARK: - R-HELD-REKEY (caller side)

    func testAHeldCallerDoesNotStartARekeyAndRunsItOnceTheHoldIsReleased() async {
        let integ = QAudionCallIntegration()
        integ.configureAsActiveCallerForTesting()
        integ.markHeld(callId: F.callId)
        XCTAssertTrue(integ.isMediaHeld(callId: F.callId.uppercased()))

        let started = await integ.performPqcReKey(callId: F.callId, peerId: peer)
        XCTAssertFalse(started, "the caller does not start rekeys while the call is held")

        XCTAssertTrue(integ.releaseHold(callId: F.callId), "the skipped rekey is reported so the app can run it now")
        XCTAssertFalse(integ.isMediaHeld(callId: F.callId))
        XCTAssertFalse(integ.releaseHold(callId: F.callId), "reported once")
    }

    /// Nothing was deferred when no rekey was due: releasing a hold must not invent one.
    func testReleasingAHoldWithNoSkippedRekeyReportsNothing() {
        let integ = QAudionCallIntegration()
        integ.configureAsActiveCallerForTesting()
        integ.markHeld(callId: F.callId)
        XCTAssertFalse(integ.releaseHold(callId: F.callId))
    }

    /// The callee never starts rekeys (R-REKEY-INIT), so nothing is ever deferred on its side.
    func testAHeldCalleeDefersNothing() async {
        let integ = QAudionCallIntegration()   // never sent an offer: not the caller
        integ.markHeld(callId: F.callId)
        let started = await integ.performPqcReKey(callId: F.callId, peerId: peer)
        XCTAssertFalse(started)
        XCTAssertFalse(integ.releaseHold(callId: F.callId))
    }

    func testTheRekeyRolePolicyDeniesAHeldCaller() {
        XCTAssertTrue(RekeyRolePolicy.mayInitiateRekey(isCaller: true, isActive: true, hasPendingAttempt: false, isHeld: false))
        XCTAssertFalse(RekeyRolePolicy.mayInitiateRekey(isCaller: true, isActive: true, hasPendingAttempt: false, isHeld: true))
    }

    /// A rekey round received while held (the peer started it before it saw the hold) and signed by the
    /// candidate key is installed and the call stays held: no conflict; an honest same-key rekey stays
    /// adoptable. Any other key puts the call in conflict.
    func testARekeyReceivedWhileHeldIsKeptHeldAndAnotherKeyIsAConflict() throws {
        let integ = QAudionCallIntegration()
        XCTAssertEqual(verdict(integ, try signedOffer(signer: keyA, round: 1)), .abort(code: "identity_unresolved"))
        XCTAssertEqual(verdict(integ, try signedOffer(signer: keyA, round: 2)), .abort(code: "identity_unresolved"))
        XCTAssertFalse(integ.sasPins.isConflicted(callId: F.callId))
        XCTAssertEqual(verdict(integ, try signedOffer(signer: keyB, round: 3)), .abort(code: "identity_unresolved"))
        XCTAssertTrue(integ.sasPins.isConflicted(callId: F.callId))
    }

    // MARK: - R-VERIFIED-MARK

    private let selfId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private let peerId = "11111111-2222-3333-4444-555555555555"

    private func makeStore() -> ContactsStore {
        ContactsStore.testKeyOverride = Data(repeating: 0x2b, count: 32)
        let suite = "test.sasmark.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        // Freshly generated, well-formed suite name: UserDefaults(suiteName:) never returns nil for it.
        // swiftlint:disable:next force_unwrapping
        return ContactsStore(defaults: UserDefaults(suiteName: suite)!)
    }

    override func tearDown() {
        ContactsStore.testKeyOverride = nil
        super.tearDown()
    }

    private func contact(_ id: String, verified: Bool = false) -> ContactsStore.StoredContact {
        ContactsStore.StoredContact(
            userId: id, displayName: "Alice", phoneHash: "ph", avatarUrl: nil, lastSeen: nil, isVerified: verified)
    }

    func testOnlyACommittedPinMarksTheContact() {
        typealias P = SasSignerPinPolicy.Decision
        XCTAssertTrue(SasPinVerification.shouldMark(decision: P.pin, durableWriteCommitted: true))
        XCTAssertTrue(SasPinVerification.shouldMark(decision: P.alreadyPinned, durableWriteCommitted: true))
        XCTAssertFalse(SasPinVerification.shouldMark(decision: P.pin, durableWriteCommitted: false),
                       "a failed Keychain write commits nothing")
        XCTAssertFalse(SasPinVerification.shouldMark(decision: P.conflict, durableWriteCommitted: false),
                       "a different existing pin: the confirmation never marks")
        XCTAssertFalse(SasPinVerification.shouldMark(decision: P.conflict, durableWriteCommitted: true))
    }

    func testMarkVerifiedSetsTheVerifiedMarkThroughTheExistingVerificationPath() throws {
        let store = makeStore()
        store.save([contact(peerId)])
        XCTAssertFalse(store.load()[0].isVerified)

        let ok = SasPinVerification.markVerified(
            store: store, peerUserId: peerId, selfUserId: selfId, selfIdentityKey: keyB.pubRaw,
            confirmedKey: keyA.pubRaw, nowMs: 1_234)
        XCTAssertTrue(ok)
        let stored = try XCTUnwrap(store.load().first)
        XCTAssertTrue(stored.isVerified, "the contact list and the group badge read this")
        XCTAssertEqual(stored.verificationMethod, "anti-replay")
        XCTAssertEqual(stored.verifiedAtMs, 1_234)
        XCTAssertEqual(stored.displayName, "Alice", "everything else is untouched")
        let expected = SasPinVerification.fingerprintHex(
            selfUserId: selfId, selfIdentityKey: keyB.pubRaw, peerUserId: peerId, peerIdentityKey: keyA.pubRaw)
        XCTAssertEqual(stored.verifiedFingerprintHex, expected)
        XCTAssertEqual(expected?.count, 60)
    }

    func testMarkVerifiedWritesNothingForAnUnknownContactOrBadInput() {
        let store = makeStore()
        store.save([contact(peerId)])
        XCTAssertFalse(SasPinVerification.markVerified(
            store: store, peerUserId: "ffffffff-ffff-ffff-ffff-ffffffffffff", selfUserId: selfId,
            selfIdentityKey: keyB.pubRaw, confirmedKey: keyA.pubRaw, nowMs: 1))
        XCTAssertFalse(SasPinVerification.markVerified(
            store: store, peerUserId: peerId, selfUserId: "not-a-uuid",
            selfIdentityKey: keyB.pubRaw, confirmedKey: keyA.pubRaw, nowMs: 1))
        XCTAssertFalse(SasPinVerification.markVerified(
            store: store, peerUserId: peerId, selfUserId: selfId,
            selfIdentityKey: keyB.pubRaw, confirmedKey: Data(repeating: 1, count: 31), nowMs: 1))
        XCTAssertFalse(store.load()[0].isVerified)
    }

    /// The trust card with no server key: the contact is verified by SAS against the pin whose safety
    /// number is the recorded one; a rotated (different) pin, a contact verified another way, or an
    /// unverified contact never inherits the mark.
    func testTrustCardResolvesTheSasVerifiedPinWithoutAServerKey() throws {
        let store = makeStore()
        store.save([contact(peerId)])
        SasPinVerification.markVerified(
            store: store, peerUserId: peerId, selfUserId: selfId, selfIdentityKey: keyB.pubRaw,
            confirmedKey: keyA.pubRaw, nowMs: 5)
        let verified = store.load().first
        let other = F.signer(seed: 73).pubRaw

        let hit = SasPinVerification.verifiedPinnedKey(
            contact: verified, selfUserId: selfId, selfIdentityKey: keyB.pubRaw, peerUserId: peerId,
            pinnedKeys: [other, keyA.pubRaw])
        XCTAssertEqual(hit?.key, keyA.pubRaw)

        XCTAssertNil(SasPinVerification.verifiedPinnedKey(
            contact: verified, selfUserId: selfId, selfIdentityKey: keyB.pubRaw, peerUserId: peerId,
            pinnedKeys: [other]), "a rotated pin does not inherit the mark")
        XCTAssertNil(SasPinVerification.verifiedPinnedKey(
            contact: contact(peerId), selfUserId: selfId, selfIdentityKey: keyB.pubRaw, peerUserId: peerId,
            pinnedKeys: [keyA.pubRaw]), "an unverified contact stays unverified")
        let qr = contact(peerId).withVerification(
            fingerprintHex: hit?.fingerprintHex ?? "", atMs: 1, method: "qr")
        XCTAssertNil(SasPinVerification.verifiedPinnedKey(
            contact: qr, selfUserId: selfId, selfIdentityKey: keyB.pubRaw, peerUserId: peerId,
            pinnedKeys: [keyA.pubRaw]), "only a SAS verification is shown as SAS-verified")
        XCTAssertNil(SasPinVerification.verifiedPinnedKey(
            contact: nil, selfUserId: selfId, selfIdentityKey: keyB.pubRaw, peerUserId: peerId,
            pinnedKeys: [keyA.pubRaw]))
    }

    // MARK: - app wiring (AppState cannot be driven here: CallKit, live provider, WebSocket)

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

    private func appStateText() throws -> String { try sourceText("QAudionApp/AppState.swift") }

    /// The verdict sites that hold a call's media (the OFFER-verify leg and the ACCEPT-verify leg) must
    /// register the hold with the integration BEFORE telling the app, or the caller keeps rekeying while
    /// held (R-HELD-REKEY). The behavioural tests above drive `markHeld` directly, so this pins the wiring.
    func testBothVerdictSitesRegisterTheHoldBeforeNotifyingTheApp() throws {
        let src = try sourceText("QAudionEngine/Sources/QAudionEngine/Integration/QAudionCallIntegration.swift")
        let wiring = "markHeld(callId: callId)\n                onHandshakeIdentityUnverified?(callId, code)"
        XCTAssertEqual(src.components(separatedBy: wiring).count - 1, 2,
                       "both the OFFER and the ACCEPT verdict site register the hold, then notify the app")
        XCTAssertEqual(src.components(separatedBy: "onHandshakeIdentityUnverified?(callId, code)").count - 1, 2,
                       "no other site raises the hold without registering it")
    }

    func testTheAppMarksOnlyOnACommittedPinShowsCandidateWordsAndReleasesTheHold() throws {
        let app = try appStateText()
        // the mark is behind the committed-pin rule, after the refused / conflict early returns
        let markCall = "markContactVerifiedBySas(peerUserId: peer, confirmedKey: hit.key)"
        XCTAssertEqual(app.components(separatedBy: markCall).count - 1, 1)
        let guardText = "if SasPinVerification.shouldMark(decision: decision, durableWriteCommitted: durableWriteCommitted) {"
        let guardRange = try XCTUnwrap(app.range(of: guardText))
        let markRange = try XCTUnwrap(app.range(of: markCall))
        XCTAssertLessThan(guardRange.lowerBound, markRange.lowerBound, "the mark sits behind the committed-pin guard")
        // inside the adoption function itself: the `.refused` return (a conflict between rounds) and the
        // return of a differing stored pin both come before the mark
        let fnStart = try XCTUnwrap(app.range(of: "func adoptSasConfirmedSignerKeyIfUnresolved() -> SasSignerAdoption {"))
        let fnEnd = try XCTUnwrap(app.range(of: "private func markContactVerifiedBySas("))
        let body = String(app[fnStart.upperBound..<fnEnd.lowerBound])
        let markAt = try XCTUnwrap(body.range(of: markCall))
        let refusedAt = try XCTUnwrap(body.range(of: "return .refused"))
        let conflictAt = try XCTUnwrap(body.range(of: "RTLog.warn(\"call\", \"saspin adopt=0 conflict=1\")"))
        XCTAssertLessThan(refusedAt.lowerBound, markAt.lowerBound, "a refused confirmation returns before it can mark")
        XCTAssertLessThan(conflictAt.lowerBound, markAt.lowerBound, "a conflicting pin returns before it can mark")
        // R-SAS-WORDS
        XCTAssertTrue(app.contains("let candidate = candidateSasMaterial(forCallId: owner)"))
        XCTAssertTrue(app.contains("let key = candidate?.sessionKey ?? liveKey"))
        // R-HELD-REKEY: the confirmation releases the hold and runs a skipped rekey
        XCTAssertTrue(app.contains("integration.releaseHold(callId: activeCallId)"))
        XCTAssertTrue(app.contains("reKeyScheduler.forceReKey(reason: \"hold-released\")"))
    }

    // MARK: - R-HELD-TELEMETRY (already conformant on iOS; pinned here)

    /// A call that ends while still held reports `identity_unresolved`, whoever hangs up: a local
    /// hangup and a remote one (whose reason does not carry a close reason) both end in
    /// `AppState.endCall`, which reads the hold code of the call being torn down.
    func testAHeldCallEndsWithIdentityUnresolvedWhoeverHangsUp() throws {
        // a remote hangup that carries no close reason (an ordinary peer hangup) is not a fatal reason
        XCTAssertNil(CallCloseReason.accepted("user_hangup"))
        XCTAssertEqual(
            CallCloseReason.forEnd(fatalReason: nil, heldIdentityCode: "identity_unresolved"), .identityUnresolved)
        let app = try appStateText()
        XCTAssertTrue(app.contains("heldIdentityCode = identityHoldCodeByCallId[gatedCallId]"))
        XCTAssertTrue(app.contains("fatalReason: pendingFatalCloseReason, heldIdentityCode: heldIdentityCode)"))
        XCTAssertTrue(app.contains("self.endCall(notifyPeerInBand: false)"), "the remote hangup ends through endCall")
        // the hold code is recorded by the handler wired to the integration's hold callback
        XCTAssertTrue(app.contains("identityHoldCodeByCallId[cid] = code"))
    }
}
