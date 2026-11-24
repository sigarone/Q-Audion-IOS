import XCTest
import CryptoKit
@testable import QAudionEngine

/// The identity shield: the decision table, the record of a key, the contact level, the post-quantum shield and "Massima sicurezza",
/// the state of a call's identity verdict (one test per hole H1 to H8), the confirmation policy (G1, G11), the proof of
/// possession and the adoption guards (G12, G13).
///
/// Pure value logic, so these run in the engine target that CI compiles on every push.
final class IdentityShieldTests: XCTestCase {

    // MARK: Fixtures

    private func newKey() -> Data { Curve25519.Signing.PrivateKey().publicKey.rawRepresentation }

    private let selfId = "11111111-1111-1111-1111-111111111111"
    private let peerId = "22222222-2222-2222-2222-222222222222"
    private let selfKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
    private let callId = "aabbccdd-0000-0000-0000-000000000001"

    private func fingerprint(of key: Data) -> String {
        guard let fp = SasPinVerification.fingerprintHex(
            selfUserId: selfId, selfIdentityKey: selfKey, peerUserId: peerId, peerIdentityKey: key) else {
            XCTFail("fingerprint")
            return ""
        }
        return fp
    }

    private func tagRecord(for key: Data) -> IdentityVerificationRecord {
        IdentityVerificationRecord(bindingTag: SasBinding.identityTag(forPinnedKey: key), verifiedFingerprintHex: nil)
    }

    private func shield(
        known: Bool = true, code: String? = nil, released: Bool = false, hasKey: Bool = true,
        lost: Bool = false, record: KeyVerification = .none
    ) -> IdentityShield {
        IdentityShieldRules.callShield(
            verdictKnown: known, abortCode: code, releasedBySas: released,
            hasAuthKey: hasKey, authLost: lost, record: record)
    }

    // MARK: Decision table (first match wins)

    func testNoVerdictYetIsPendingWhateverElseIsTrue() {
        XCTAssertEqual(.pending, shield(known: false, record: .forKey))
        XCTAssertEqual(.pending, shield(known: false, code: "sig_invalid", lost: true))
    }

    func testALaterRoundUnderAnotherKeyIsChanged() {
        XCTAssertEqual(.changed, shield(lost: true, record: .forKey))
    }

    func testMismatchForgedSignatureAndDowngradeAreChangedEvenAfterRelease() {
        for code in ["identity_key_mismatch", "sig_invalid", "ratchet_v5_downgrade"] {
            XCTAssertEqual(.changed, shield(code: code, released: false, hasKey: false), code)
            XCTAssertEqual(.changed, shield(code: code, released: true, hasKey: false), code)
        }
    }

    func testAnUnknownAbortCodeIsRedNeverGreen() {
        XCTAssertEqual(.changed, shield(code: "something_new", released: true))
    }

    func testUnresolvedIsPurpleUntilAnAdoptedKeyReleasedItThenGreen() {
        XCTAssertEqual(.toVerify, shield(code: "identity_unresolved", released: false, hasKey: false))
        XCTAssertEqual(.verified, shield(code: "identity_unresolved", released: true, hasKey: false))
    }

    func testACallWithoutAnIdentityKeyIsPurpleNeverGreen() {
        XCTAssertEqual(.toVerify, shield(hasKey: false, record: .forKey))
    }

    func testRecordForTheCallKeyIsGreenAnotherKeyOnTheSameDeviceIsRedNoneIsPurple() {
        XCTAssertEqual(.verified, shield(record: .forKey))
        XCTAssertEqual(.changed, shield(record: .otherKeySameDevice))
        XCTAssertEqual(.toVerify, shield(record: .none))
    }

    func testTheStateOfACallIsReadOnlyForTheCallItBelongsTo() {
        let k = newKey()
        let auth = CallIdentityAuth.authenticated(callId: callId, key: k)
        XCTAssertEqual(.verified, IdentityShieldRules.callShield(auth: auth, callId: callId, record: .forKey))
        XCTAssertEqual(.verified, IdentityShieldRules.callShield(auth: auth, callId: callId.uppercased(), record: .forKey))
        XCTAssertEqual(.pending, IdentityShieldRules.callShield(auth: auth, callId: "other-call", record: .forKey),
                       "a value tagged with another call counts as no verdict yet")
        XCTAssertEqual(.pending, IdentityShieldRules.callShield(auth: .pending, callId: callId, record: .forKey))
        XCTAssertEqual(.changed, IdentityShieldRules.callShield(auth: .lost(callId: callId), callId: callId, record: .forKey))
        XCTAssertEqual(.toVerify, IdentityShieldRules.callShield(auth: .noIdentity(callId: callId), callId: callId, record: .forKey))
        XCTAssertEqual(.changed, IdentityShieldRules.callShield(
            auth: .held(callId: callId, code: "sig_invalid", releasedAdopted: true, signerKey: k), callId: callId, record: .none))
    }

    // MARK: H1 / H2: a published key that is not the verified one

    /// The call is authenticated by K2 (published, sigV6 verified under it) while this device is pinned to the verified K1: the
    /// record test is about the BUNDLE key, so the shield is red, never green.
    func testH2_authenticatedRepinFromPublished_isOtherKeySameDevice_andRed() {
        let k1 = newKey(), k2 = newKey()
        let record = tagRecord(for: k1)
        let verification = IdentityShieldRules.keyVerification(
            authKey: k2, devicePin: k1, record: record,
            selfUserId: selfId, selfIdentityKey: selfKey, peerUserId: peerId)
        XCTAssertEqual(.otherKeySameDevice, verification)
        XCTAssertEqual(.changed, IdentityShieldRules.callShield(
            auth: .authenticated(callId: callId, key: k2), callId: callId, record: verification))
    }

    // MARK: H3: confirming records the key the call authenticated

    func testH3_confirmingNeverBindsTheWordsOfAK2CallToThePinK1() {
        let k1 = newKey(), k2 = newKey()
        let auth = CallIdentityAuth.authenticated(callId: callId, key: k2)
        XCTAssertFalse(SasConfirmPolicy.mayRecord(auth: auth, callId: callId, pinnedKey: k1, adoptedSignerKey: nil))
        XCTAssertTrue(SasConfirmPolicy.mayRecord(auth: auth, callId: callId, pinnedKey: k2, adoptedSignerKey: nil))
        XCTAssertFalse(SasConfirmPolicy.mayRecord(auth: auth, callId: callId, pinnedKey: nil, adoptedSignerKey: nil))
        XCTAssertEqual(.recordForAuthenticatedKey(key: k2), SasConfirmPolicy.action(auth: auth, callId: callId, candidate: nil),
                       "the key to record is the one of the call, whatever the pin says")
    }

    // MARK: H4: a confirmation records nothing unless a signature of this call vouches for a key

    func testH4_pendingAndNoIdentityReleaseOnlyAndRecordNothing() {
        for auth in [CallIdentityAuth.pending, .noIdentity(callId: callId)] {
            XCTAssertEqual(.releaseOnly, SasConfirmPolicy.action(auth: auth, callId: callId, candidate: nil), "\(auth)")
            XCTAssertFalse(SasConfirmPolicy.mayRecord(auth: auth, callId: callId, pinnedKey: newKey(), adoptedSignerKey: newKey()))
        }
        XCTAssertEqual(.refuse, SasConfirmPolicy.action(
            auth: .authenticated(callId: "another", key: newKey()), callId: callId, candidate: nil),
            "a verdict of another call is never confirmed here")
    }

    /// Q7: a held call that became Lost must still be releasable (no-brick): the confirmation releases the media, writes nothing,
    /// and the shield stays red.
    func testQ7_aLostCallReleasesTheMediaAndWritesNothing() {
        let signer = newKey()
        var state = CallIdentityReducer.apply(
            report(.held(code: "identity_unresolved", signerKey: signer, bundleSigValid: false, bundleKeyPublishedForDevice: false), round: 1),
            to: .pending)
        state = CallIdentityReducer.apply(report(.authenticated(key: newKey()), round: 2), to: state)
        XCTAssertEqual(.lost(callId: callId), state)
        XCTAssertEqual(.releaseOnly, SasConfirmPolicy.action(auth: state, callId: callId, candidate: nil))
        XCTAssertFalse(SasConfirmPolicy.mayRecord(auth: state, callId: callId, pinnedKey: signer, adoptedSignerKey: signer))
        XCTAssertEqual(.changed, IdentityShieldRules.callShield(auth: state, callId: callId, record: .forKey))
        // the verdict of another call is still never confirmed here
        XCTAssertEqual(.refuse, SasConfirmPolicy.action(auth: .lost(callId: "another"), callId: callId, candidate: nil))
    }

    /// Q6: the protection line of a previous call never reaches this call.
    func testQ6_aStalePq2HOfAPreviousCallDoesNotMakeMassimaGreenBeforeThisCallsLevelArrives() {
        let stale = CallPqProtection(levelToken: "PQ2", auth: "H", pin: "", callId: "previous-call")
        XCTAssertNil(IdentityShieldRules.protection(stale, forCall: callId))
        XCTAssertFalse(IdentityShieldRules.massimaSicurezza(
            shield: .verified, protection: IdentityShieldRules.protection(stale, forCall: callId)))
        XCTAssertEqual(.grey, IdentityShieldRules.pqcShield(IdentityShieldRules.protection(stale, forCall: callId)))
        let mine = CallPqProtection(levelToken: "PQ2", auth: "H", pin: "", callId: callId.uppercased())
        XCTAssertEqual(mine, IdentityShieldRules.protection(mine, forCall: callId))
        XCTAssertTrue(IdentityShieldRules.massimaSicurezza(shield: .verified, protection: IdentityShieldRules.protection(mine, forCall: callId)))
        XCTAssertNil(IdentityShieldRules.protection(mine, forCall: ""))
        XCTAssertNil(IdentityShieldRules.protection(nil, forCall: callId))
    }

    func testH4_aHoldNoSignatureVouchesForIsReleaseOnlyAndRecordsNothing() {
        let signer = newKey()
        for code in ["sig_invalid", "ratchet_v5_downgrade", "identity_key_mismatch", "anything_else"] {
            let auth = CallIdentityAuth.held(callId: callId, code: code, releasedAdopted: false, signerKey: signer)
            XCTAssertEqual(.releaseOnly, SasConfirmPolicy.action(auth: auth, callId: callId, candidate: nil), code)
            XCTAssertFalse(SasConfirmPolicy.mayRecord(auth: auth, callId: callId, pinnedKey: signer, adoptedSignerKey: signer), code)
        }
    }

    // MARK: H5: a rekey verified under another key is Lost, never "unknown"

    private func report(_ kind: IdentityVerdictReport.Kind, round: Int, call: String? = nil, device: String? = "dev-1") -> IdentityVerdictReport {
        IdentityVerdictReport(callId: call ?? callId, peerId: peerId, deviceId: device, round: round, kind: kind)
    }

    func testH5_aRekeyUnderAnotherKeyMakesTheAuthenticatedCallLost() {
        let k1 = newKey(), k2 = newKey()
        var state = CallIdentityReducer.apply(report(.authenticated(key: k1), round: 1), to: .pending)
        XCTAssertEqual(.authenticated(callId: callId, key: k1), state)
        state = CallIdentityReducer.apply(report(.authenticated(key: k1), round: 2), to: state)
        XCTAssertEqual(.authenticated(callId: callId, key: k1), state, "the same key again changes nothing")
        state = CallIdentityReducer.apply(report(.authenticated(key: k2), round: 3), to: state)
        XCTAssertEqual(.lost(callId: callId), state)
        XCTAssertEqual(.changed, IdentityShieldRules.callShield(auth: state, callId: callId, record: .forKey))
        // terminal for the call
        state = CallIdentityReducer.apply(report(.authenticated(key: k1), round: 4), to: state)
        XCTAssertEqual(.lost(callId: callId), state)
    }

    func testH5_fromTheMomentOfTheHoldARekeyUnderAnotherKeyIsLost() {
        let signer = newKey(), other = newKey()
        var state = CallIdentityReducer.apply(
            report(.held(code: "identity_unresolved", signerKey: signer, bundleSigValid: false, bundleKeyPublishedForDevice: false), round: 1),
            to: .pending)
        XCTAssertEqual(.held(callId: callId, code: "identity_unresolved", releasedAdopted: false, signerKey: signer), state)
        // the same signer again: still the hold
        let again = CallIdentityReducer.apply(
            report(.held(code: "identity_unresolved", signerKey: signer, bundleSigValid: false, bundleKeyPublishedForDevice: false), round: 2), to: state)
        XCTAssertEqual(state, again)
        // a verified round under another key, before any pin write finished
        state = CallIdentityReducer.apply(report(.authenticated(key: other), round: 2), to: state)
        XCTAssertEqual(.lost(callId: callId), state)
    }

    func testH5_afterASasPinReleaseARoundOfAnotherKeyIsLostAndAnAbortRoundToo() {
        let signer = newKey(), other = newKey()
        let held = CallIdentityAuth.held(callId: callId, code: "identity_unresolved", releasedAdopted: false, signerKey: signer)
        let released = CallIdentityReducer.markReleasedAdopted(held, callId: callId, signerKey: signer)
        XCTAssertEqual(.held(callId: callId, code: "identity_unresolved", releasedAdopted: true, signerKey: signer), released)
        XCTAssertEqual(.verified, IdentityShieldRules.callShield(auth: released, callId: callId, record: .none))
        XCTAssertEqual(.lost(callId: callId), CallIdentityReducer.apply(report(.authenticated(key: other), round: 2), to: released))
        XCTAssertEqual(.lost(callId: callId), CallIdentityReducer.apply(
            report(.held(code: "identity_unresolved", signerKey: other, bundleSigValid: false, bundleKeyPublishedForDevice: false), round: 2),
            to: released))
        XCTAssertEqual(.lost(callId: callId), CallIdentityReducer.apply(
            report(.held(code: "sig_invalid", signerKey: signer, bundleSigValid: false, bundleKeyPublishedForDevice: false), round: 2),
            to: released), "an unverified later round while the call stands on an adopted key is red, not ignored")
    }

    func testAReportOfAnotherCallChangesNothingWhateverItsRound() {
        let k = newKey()
        let current = CallIdentityAuth.authenticated(callId: callId, key: k)
        XCTAssertEqual(current, CallIdentityReducer.apply(report(.authenticated(key: newKey()), round: 2, call: "other"), to: current))
        XCTAssertEqual(current, CallIdentityReducer.apply(report(.authenticated(key: newKey()), round: 1, call: "OTHER"), to: current))
        // a call starts from pending: its own first report is taken
        XCTAssertEqual(.authenticated(callId: "other", key: k),
                       CallIdentityReducer.apply(report(.authenticated(key: k), round: 1, call: "OTHER"), to: .pending))
    }

    /// F2: the proof Task of an ENDED call answers after the next call's round 1.
    func test_review_aLateProofOfAnEndedCallDoesNotReplaceTheLiveCall() {
        let live = CallIdentityAuth.authenticated(callId: callId, key: newKey())
        let lateProof = report(.held(code: "identity_key_mismatch", signerKey: newKey(), bundleSigValid: true,
                                     bundleKeyPublishedForDevice: true), round: 1, call: "c1-ended")
        XCTAssertEqual(live, CallIdentityReducer.apply(lateProof, to: live))
    }

    /// F3: A2 replacement of an unanswered round-1 OFFER by one of ANOTHER signer (the words now come from the replacement).
    func test_review_anA2ReplacementByAnotherSignerLeavesNoAdoptableKeyOfTheReplacedOffer() throws {
        let k2 = newKey(), k3 = newKey(), mm = "identity_key_mismatch"
        var s = CallIdentityReducer.apply(
            report(.held(code: mm, signerKey: k2, bundleSigValid: false, bundleKeyPublishedForDevice: false), round: 1), to: .pending)
        // The app resets the call's state when the unanswered OFFER is replaced (discardUnansweredRound1AppState), BEFORE the
        // replacing round is reported: that round meets .pending.
        s = .pending
        s = CallIdentityReducer.apply(
            report(.held(code: mm, signerKey: k3, bundleSigValid: false, bundleKeyPublishedForDevice: false), round: 1), to: s)
        XCTAssertEqual(.held(callId: callId, code: mm, releasedAdopted: false, signerKey: k3), s, "the replacement is the session now")
        let late = report(.held(code: mm, signerKey: k2, bundleSigValid: true, bundleKeyPublishedForDevice: true), round: 1)
        s = CallIdentityReducer.apply(late, to: s)
        let c = try XCTUnwrap(CallIdentityReducer.candidate(from: late))
        XCTAssertNotEqual(.adoptHeldRotation(c), SasConfirmPolicy.action(auth: s, callId: callId, candidate: c))
    }

    /// The contact-level marker is recorded for every verdict that shows a changed key, whatever call it belongs to.
    func testChangeMarker_recordsTheChangedKeyForAnyCall() {
        let signer = newKey(), k1 = newKey(), k2 = newKey()
        let mismatch = report(.held(code: "identity_key_mismatch", signerKey: signer, bundleSigValid: false, bundleKeyPublishedForDevice: false),
                              round: 1, call: "a-call-that-is-not-active")
        XCTAssertEqual(.key(signer), ChangeMarker.keyToRecord(report: mismatch, devicePin: nil))
        XCTAssertEqual(.key(k2), ChangeMarker.keyToRecord(report: report(.authenticated(key: k2), round: 1, call: "other"), devicePin: k1))
        // any round: a rekey round verified under another key than the pin marks the contact, and the call is lost (red)
        let rekey = report(.authenticated(key: k2), round: 2)
        XCTAssertEqual(.key(k2), ChangeMarker.keyToRecord(report: rekey, devicePin: k1))
        let state = CallIdentityReducer.apply(rekey, to: CallIdentityReducer.apply(report(.authenticated(key: k1), round: 1), to: .pending))
        XCTAssertEqual(.lost(callId: callId), state)
        XCTAssertEqual(.changed, IdentityShieldRules.callShield(auth: state, callId: callId, record: .forKey))
        let contact = IdentityShieldRules.contactShield(
            pinnedKeys: [k1], record: tagRecord(for: k1), selfUserId: selfId, selfIdentityKey: selfKey, peerUserId: peerId, pendingChange: true)
        XCTAssertEqual(.changed, contact)
        XCTAssertEqual(.key(signer), ChangeMarker.keyToRecord(report: report(.held(code: "identity_key_mismatch", signerKey: signer, bundleSigValid: false, bundleKeyPublishedForDevice: false), round: 3), devicePin: k1))
        XCTAssertEqual(.unknown, ChangeMarker.keyToRecord(report: report(.held(code: "identity_key_mismatch", signerKey: nil, bundleSigValid: false, bundleKeyPublishedForDevice: false), round: 2), devicePin: k1))
        XCTAssertNil(ChangeMarker.keyToRecord(report: report(.authenticated(key: k1), round: 1), devicePin: k1))
        XCTAssertNil(ChangeMarker.keyToRecord(report: report(.authenticated(key: k2), round: 1), devicePin: nil))
        XCTAssertNil(ChangeMarker.keyToRecord(report: report(.held(code: "sig_invalid", signerKey: signer, bundleSigValid: false, bundleKeyPublishedForDevice: false), round: 1), devicePin: k1))
    }

    /// A late genuine round-1 OFFER never turns an attacker's hold green.
    func test_review_aLateRound1OfferNeverTurnsAHoldGreen() {
        let ka = newKey(), k1 = newKey()
        var s = CallIdentityReducer.apply(report(.held(code: "identity_key_mismatch", signerKey: ka,
            bundleSigValid: false, bundleKeyPublishedForDevice: false), round: 1), to: .pending)
        s = CallIdentityReducer.apply(report(.authenticated(key: k1), round: 1), to: s)
        XCTAssertEqual(.lost(callId: callId), s)
        XCTAssertEqual(.changed, IdentityShieldRules.callShield(auth: s, callId: callId, record: .forKey))
    }

    /// F3: a replacement that differs only by the round (same signer, other signature) is another session too: the report carries a
    /// session tag and a proof of the earlier tag is not the proof of the later one.
    func testF3_theSessionTagSeparatesTwoOffersOfTheSameSigner() {
        let k = newKey()
        let a = IdentityVerdictReport(callId: callId, peerId: peerId, deviceId: "dev-1", round: 1,
                                      kind: .held(code: "identity_key_mismatch", signerKey: k, bundleSigValid: true, bundleKeyPublishedForDevice: true),
                                      sessionTag: "sig-A")
        let b = IdentityVerdictReport(callId: callId, peerId: peerId, deviceId: "dev-1", round: 1,
                                      kind: .held(code: "identity_key_mismatch", signerKey: k, bundleSigValid: false, bundleKeyPublishedForDevice: false),
                                      sessionTag: "sig-B")
        XCTAssertTrue(a.isProofReport)
        XCTAssertFalse(b.isProofReport)
        XCTAssertNotEqual(a.sessionTag, b.sessionTag)
        XCTAssertEqual("", report(.authenticated(key: k), round: 1).sessionTag)
    }

    /// F4: a pin verified by safety number or in person (no in-call binding) is never replaced silently by a published key.
    func test_review_aSafetyNumberVerifiedPinIsNotReplacedSilentlyAndTheCallIsRed() {
        let k1 = newKey(), k2 = newKey()
        let byNumber = IdentityVerificationRecord(bindingTag: nil, verifiedFingerprintHex: fingerprint(of: k1))
        XCTAssertTrue(RepinGate.refusesSilentRepin(priorPin: k1, newKey: k2, record: byNumber,
                                                   selfUserId: selfId, selfIdentityKey: selfKey, peerUserId: peerId))
        // the in-call confirmation counts too
        XCTAssertTrue(RepinGate.refusesSilentRepin(priorPin: k1, newKey: k2, record: tagRecord(for: k1),
                                                   selfUserId: selfId, selfIdentityKey: selfKey, peerUserId: peerId))
        // nothing verified, or the same key: the silent re-pin stays allowed
        XCTAssertFalse(RepinGate.refusesSilentRepin(priorPin: k1, newKey: k2, record: .empty,
                                                    selfUserId: selfId, selfIdentityKey: selfKey, peerUserId: peerId))
        XCTAssertFalse(RepinGate.refusesSilentRepin(priorPin: k1, newKey: k1, record: byNumber,
                                                    selfUserId: selfId, selfIdentityKey: selfKey, peerUserId: peerId))
        // the pin stays K1, the call is authenticated by K2: red (H2)
        let v = IdentityShieldRules.keyVerification(authKey: k2, devicePin: k1, record: byNumber,
                                                    selfUserId: selfId, selfIdentityKey: selfKey, peerUserId: peerId)
        XCTAssertEqual(.otherKeySameDevice, v)
        XCTAssertEqual(.changed, IdentityShieldRules.callShield(
            auth: .authenticated(callId: callId, key: k2), callId: callId, record: v))
    }

    // MARK: H6: another verified device must not turn a new device red or green

    func testH6_aVerifiedDeviceDoesNotTurnANewDeviceRedOrGreen() {
        let kA = newKey(), kB = newKey()
        // the user verified key A (device A); the call comes from device B with key B and B has no pin of its own
        let verification = IdentityShieldRules.keyVerification(
            authKey: kB, devicePin: nil, record: tagRecord(for: kA),
            selfUserId: selfId, selfIdentityKey: selfKey, peerUserId: peerId)
        XCTAssertEqual(KeyVerification.none, verification)
        XCTAssertEqual(.toVerify, IdentityShieldRules.callShield(
            auth: .authenticated(callId: callId, key: kB), callId: callId, record: verification))
        // B pinned to its own key, never verified: neither
        XCTAssertEqual(KeyVerification.none, IdentityShieldRules.keyVerification(
            authKey: kB, devicePin: kB, record: tagRecord(for: kA),
            selfUserId: selfId, selfIdentityKey: selfKey, peerUserId: peerId))
    }

    // MARK: H7: the record is found by the key, whichever way it was written

    func testH7_theVerificationIsMatchedByTheKeyNotByWhereItWasWritten() {
        let k = newKey()
        // the in-call confirmation (identity tag) and the safety-number verification (fingerprint) both apply to exactly their key
        XCTAssertEqual(.forKey, IdentityShieldRules.keyVerification(
            authKey: k, devicePin: nil, record: tagRecord(for: k),
            selfUserId: selfId, selfIdentityKey: selfKey, peerUserId: peerId))
        let byNumber = IdentityVerificationRecord(bindingTag: nil, verifiedFingerprintHex: fingerprint(of: k))
        XCTAssertEqual(.forKey, IdentityShieldRules.keyVerification(
            authKey: k, devicePin: nil, record: byNumber,
            selfUserId: selfId, selfIdentityKey: selfKey, peerUserId: peerId))
        // the safety number needs this account's identity: without it that half never applies
        XCTAssertEqual(KeyVerification.none, IdentityShieldRules.keyVerification(
            authKey: k, devicePin: nil, record: byNumber, selfUserId: nil, selfIdentityKey: nil, peerUserId: peerId))
        // an absent record never applies
        XCTAssertEqual(KeyVerification.none, IdentityShieldRules.keyVerification(
            authKey: k, devicePin: k, record: .empty, selfUserId: selfId, selfIdentityKey: selfKey, peerUserId: peerId))
        // a malformed key never applies
        XCTAssertFalse(tagRecord(for: k).applies(to: Data([1, 2, 3]), selfUserId: selfId, selfIdentityKey: selfKey, peerUserId: peerId))
    }

    // MARK: H8: a mismatch confirmed by the words adopts nothing the call did not prove

    func testH8_mismatchWithoutProofIsReleaseOnlyAndWithProofAdoptsTheBundleKeyOnly() {
        let bundleKey = newKey(), serverKey = newKey()
        let held = CallIdentityAuth.held(callId: callId, code: "identity_key_mismatch", releasedAdopted: false, signerKey: bundleKey)
        XCTAssertEqual(.releaseOnly, SasConfirmPolicy.action(auth: held, callId: callId, candidate: nil))
        // a candidate for ANOTHER key (the server-fetched one) never applies to the held bundle key
        let wrongKey = IdentityRotationCandidate(callId: callId, peerId: peerId, deviceId: "dev-1", key: serverKey)
        XCTAssertEqual(.releaseOnly, SasConfirmPolicy.action(auth: held, callId: callId, candidate: wrongKey))
        // a candidate of another call never applies
        let wrongCall = IdentityRotationCandidate(callId: "other", peerId: peerId, deviceId: "dev-1", key: bundleKey)
        XCTAssertEqual(.releaseOnly, SasConfirmPolicy.action(auth: held, callId: callId, candidate: wrongCall))
        let proven = IdentityRotationCandidate(callId: callId, peerId: peerId, deviceId: "dev-1", key: bundleKey)
        XCTAssertEqual(.adoptHeldRotation(proven), SasConfirmPolicy.action(auth: held, callId: callId, candidate: proven))
    }

    // MARK: G1: the adoption guards, in order

    private func guardOutcome(
        key: Data, pin: Data?, candidate: IdentityRotationCandidate?, published: Bool = true,
        selfUser: String? = nil, selfKeyAvailable: Bool = true, peer: String? = nil, call: String? = nil, device: String? = "dev-1"
    ) -> SasPinOutcome? {
        RotationAdoption.guardOutcome(
            peerUserId: peer ?? peerId, selfUserId: selfUser ?? selfId, key: key,
            selfIdentityKeyAvailable: selfKeyAvailable, deviceId: device, pinnedKeyForDevice: pin,
            candidate: candidate, callId: call ?? callId, keyPublishedNow: published)
    }

    func testG1_allGuardsPassOnlyForTheCandidateOfThisCallAndAPublishedKey() {
        let k1 = newKey(), k2 = newKey()
        let good = IdentityRotationCandidate(callId: callId, peerId: peerId, deviceId: "dev-1", key: k2)
        XCTAssertNil(guardOutcome(key: k2, pin: k1, candidate: good), "every guard passed: the pin may be written")
        // 1. malformed peer / key
        XCTAssertEqual(.unavailable, guardOutcome(key: Data([1, 2, 3]), pin: k1, candidate: good))
        XCTAssertEqual(.unavailable, guardOutcome(key: k2, pin: k1, candidate: good, peer: ""))
        XCTAssertEqual(.unavailable, guardOutcome(key: Ed25519IdentityKeyPolicy.smallOrderPoints[0], pin: k1, candidate: good))
        // 2. own id unknown, or equal to the peer
        XCTAssertEqual(.unavailable, RotationAdoption.guardOutcome(
            peerUserId: peerId, selfUserId: nil, key: k2, selfIdentityKeyAvailable: true, deviceId: "dev-1",
            pinnedKeyForDevice: k1, candidate: good, callId: callId, keyPublishedNow: true))
        XCTAssertEqual(.unavailable, guardOutcome(key: k2, pin: k1, candidate: good, selfUser: peerId))
        // 3. own identity key missing
        XCTAssertEqual(.unavailable, guardOutcome(key: k2, pin: k1, candidate: good, selfKeyAvailable: false))
        // 4. no pin for the device
        XCTAssertEqual(.unavailable, guardOutcome(key: k2, pin: nil, candidate: good))
        // 5. already the pin
        XCTAssertEqual(.alreadyPinned, guardOutcome(key: k2, pin: k2, candidate: nil))
    }

    func testG13_aStaleOrForeignMarkerNeverAdopts() {
        let k1 = newKey(), k2 = newKey(), k3 = newKey()
        let good = IdentityRotationCandidate(callId: callId, peerId: peerId, deviceId: "dev-1", key: k2)
        // no candidate at all
        XCTAssertEqual(.conflict, guardOutcome(key: k2, pin: k1, candidate: nil))
        // a candidate written by the handshake of ANOTHER call (stale)
        let stale = IdentityRotationCandidate(callId: "old-call", peerId: peerId, deviceId: "dev-1", key: k2)
        XCTAssertEqual(.conflict, guardOutcome(key: k2, pin: k1, candidate: stale))
        // a candidate for another key / peer / device
        XCTAssertEqual(.conflict, guardOutcome(key: k3, pin: k1, candidate: good))
        XCTAssertEqual(.conflict, guardOutcome(key: k2, pin: k1, candidate: IdentityRotationCandidate(callId: callId, peerId: "x", deviceId: "dev-1", key: k2)))
        XCTAssertEqual(.conflict, guardOutcome(key: k2, pin: k1, candidate: IdentityRotationCandidate(callId: callId, peerId: peerId, deviceId: "dev-2", key: k2)))
        // an empty call id never matches anything
        XCTAssertEqual(.conflict, guardOutcome(key: k2, pin: k1, candidate: good, call: ""))
        // a case-variant call id is the same call
        XCTAssertNil(guardOutcome(key: k2, pin: k1, candidate: good, call: callId.uppercased()))
        // 7. the key is not in the server-published set right now
        XCTAssertEqual(.conflict, guardOutcome(key: k2, pin: k1, candidate: good, published: false))
    }

    // MARK: G12 / G13: proof of possession on a mismatch

    func testG12_bothProofsAreNeededAndTheOfflineOrUnknownDeviceNeverCounts() {
        let key = newKey(), other = newKey()
        func proof(sig: Bool = true, v5: Bool = true, pinnedV5: Bool = false, device: Bool = true, fetch: MismatchProof.DeviceFetch) -> (bundleSigValid: Bool, bundleKeyPublishedForDevice: Bool) {
            MismatchProof.evaluate(bundleKey: key, sigVerifiedUnderBundleKey: sig, advertisedRatchetV5: v5,
                                   ratchetV5CapablePinned: pinnedV5, deviceIdKnown: device, fetch: fetch)
        }
        let ok = proof(fetch: .key(key))
        XCTAssertTrue(ok.bundleSigValid)
        XCTAssertTrue(ok.bundleKeyPublishedForDevice)
        // offline / timeout / 404 / cache: the fetch gave nothing for the device
        XCTAssertFalse(proof(fetch: .unavailable).bundleKeyPublishedForDevice)
        // a fetch that returned ANOTHER key: the bundle key is not the published one
        XCTAssertFalse(proof(fetch: .key(other)).bundleKeyPublishedForDevice)
        // an unknown device id: even a fetched key proves nothing for the device
        XCTAssertFalse(proof(device: false, fetch: .key(key)).bundleKeyPublishedForDevice)
        // a key that is not 32 bytes
        XCTAssertFalse(proof(fetch: .key(Data([1, 2]))).bundleKeyPublishedForDevice)
        // the signature did not verify under the bundle key
        XCTAssertFalse(proof(sig: false, fetch: .key(key)).bundleSigValid)
    }

    func testG13_aDowngradingBundleIsNeverAdoptable() {
        let key = newKey()
        let down = MismatchProof.evaluate(bundleKey: key, sigVerifiedUnderBundleKey: true, advertisedRatchetV5: false,
                                          ratchetV5CapablePinned: true, deviceIdKnown: true, fetch: .key(key))
        XCTAssertFalse(down.bundleSigValid)
        let first = MismatchProof.evaluate(bundleKey: key, sigVerifiedUnderBundleKey: true, advertisedRatchetV5: false,
                                           ratchetV5CapablePinned: false, deviceIdKnown: true, fetch: .key(key))
        XCTAssertTrue(first.bundleSigValid, "a peer that never proved ratchetV5 is not a downgrade")
    }

    func testG12_theCandidateExistsOnlyForAProvenFirstRoundMismatch() {
        let key = newKey()
        func held(_ code: String, sig: Bool, published: Bool, round: Int = 1, signer: Data? = nil) -> IdentityVerdictReport {
            report(.held(code: code, signerKey: signer ?? key, bundleSigValid: sig, bundleKeyPublishedForDevice: published), round: round)
        }
        XCTAssertEqual(IdentityRotationCandidate(callId: callId, peerId: peerId, deviceId: "dev-1", key: key),
                       CallIdentityReducer.candidate(from: held("identity_key_mismatch", sig: true, published: true)))
        XCTAssertNil(CallIdentityReducer.candidate(from: held("identity_key_mismatch", sig: true, published: false)))
        XCTAssertNil(CallIdentityReducer.candidate(from: held("identity_key_mismatch", sig: false, published: true)))
        XCTAssertNil(CallIdentityReducer.candidate(from: held("sig_invalid", sig: true, published: true)))
        XCTAssertNil(CallIdentityReducer.candidate(from: held("ratchet_v5_downgrade", sig: true, published: true)))
        XCTAssertNil(CallIdentityReducer.candidate(from: held("identity_unresolved", sig: true, published: true)))
        XCTAssertNil(CallIdentityReducer.candidate(from: held("identity_key_mismatch", sig: true, published: true, round: 2)),
                     "only the handshake round that raised the hold can create it")
        XCTAssertNil(CallIdentityReducer.candidate(from: report(.authenticated(key: key), round: 1)))
        XCTAssertNil(CallIdentityReducer.candidate(from: held("identity_key_mismatch", sig: true, published: true, signer: Data([1]))))
    }

    func testG12_theProofReportOfTheSameRoundDoesNotChangeTheHoldItself() {
        let key = newKey()
        let first = report(.held(code: "identity_key_mismatch", signerKey: key, bundleSigValid: false, bundleKeyPublishedForDevice: false), round: 1)
        let proof = report(.held(code: "identity_key_mismatch", signerKey: key, bundleSigValid: true, bundleKeyPublishedForDevice: true), round: 1)
        let state = CallIdentityReducer.apply(first, to: .pending)
        XCTAssertEqual(state, CallIdentityReducer.apply(proof, to: state))
        XCTAssertNil(CallIdentityReducer.candidate(from: first), "the immediate report carries no proof: a confirmation is release-only")
        XCTAssertNotNil(CallIdentityReducer.candidate(from: proof))
    }

    // MARK: G12 / G13: compare-and-set after an asynchronous adoption

    func testCompareAndSet_aRotationIsAdoptedOnlyWhileTheCallIsStillTheHoldOfThatKey() {
        let key = newKey(), other = newKey()
        let candidate = IdentityRotationCandidate(callId: callId, peerId: peerId, deviceId: "dev-1", key: key)
        let held = CallIdentityAuth.held(callId: callId, code: "identity_key_mismatch", releasedAdopted: false, signerKey: key)
        XCTAssertEqual(.authenticated(callId: callId, key: key), CallIdentityReducer.adoptedRotation(held, candidate: candidate))
        // a Lost published while the adoption was awaited stays Lost
        let lost = CallIdentityAuth.lost(callId: callId)
        XCTAssertEqual(lost, CallIdentityReducer.adoptedRotation(lost, candidate: candidate))
        // the hold of another key, of another call, or another code is not this adoption
        XCTAssertEqual(
            CallIdentityAuth.held(callId: callId, code: "identity_key_mismatch", releasedAdopted: false, signerKey: other),
            CallIdentityReducer.adoptedRotation(
                .held(callId: callId, code: "identity_key_mismatch", releasedAdopted: false, signerKey: other), candidate: candidate))
        let otherCall = CallIdentityAuth.held(callId: "other", code: "identity_key_mismatch", releasedAdopted: false, signerKey: key)
        XCTAssertEqual(otherCall, CallIdentityReducer.adoptedRotation(otherCall, candidate: candidate))
        let sigInvalid = CallIdentityAuth.held(callId: callId, code: "sig_invalid", releasedAdopted: false, signerKey: key)
        XCTAssertEqual(sigInvalid, CallIdentityReducer.adoptedRotation(sigInvalid, candidate: candidate))
        // and a green shield follows only the adopted call
        XCTAssertEqual(.verified, IdentityShieldRules.callShield(
            auth: CallIdentityReducer.adoptedRotation(held, candidate: candidate), callId: callId, record: .forKey))
    }

    func testCompareAndSet_theReleasedMarkNeedsTheSameHoldAndTheSameKey() {
        let key = newKey(), other = newKey()
        let held = CallIdentityAuth.held(callId: callId, code: "identity_unresolved", releasedAdopted: false, signerKey: key)
        XCTAssertEqual(held, CallIdentityReducer.markReleasedAdopted(held, callId: callId, signerKey: other))
        XCTAssertEqual(held, CallIdentityReducer.markReleasedAdopted(held, callId: "other", signerKey: key))
        let lost = CallIdentityAuth.lost(callId: callId)
        XCTAssertEqual(lost, CallIdentityReducer.markReleasedAdopted(lost, callId: callId, signerKey: key))
        let mismatch = CallIdentityAuth.held(callId: callId, code: "identity_key_mismatch", releasedAdopted: false, signerKey: key)
        XCTAssertEqual(mismatch, CallIdentityReducer.markReleasedAdopted(mismatch, callId: callId, signerKey: key),
                       "only an identity_unresolved hold is released by an adopted signer key")
    }

    func testTheUnresolvedHoldRecordsOnlyForAnAdoptedSignerKeyEqualToTheHeldOne() {
        let signer = newKey(), other = newKey()
        let held = CallIdentityAuth.held(callId: callId, code: "identity_unresolved", releasedAdopted: false, signerKey: signer)
        XCTAssertEqual(.adoptUnresolvedSigner, SasConfirmPolicy.action(auth: held, callId: callId, candidate: nil))
        XCTAssertTrue(SasConfirmPolicy.mayRecord(auth: held, callId: callId, pinnedKey: nil, adoptedSignerKey: signer))
        XCTAssertFalse(SasConfirmPolicy.mayRecord(auth: held, callId: callId, pinnedKey: nil, adoptedSignerKey: other))
        XCTAssertFalse(SasConfirmPolicy.mayRecord(auth: held, callId: callId, pinnedKey: signer, adoptedSignerKey: nil))
    }

    // MARK: Contact level

    private func contact(
        pins: [Data], record: IdentityVerificationRecord, pending: Bool = false
    ) -> IdentityShield {
        IdentityShieldRules.contactShield(
            pinnedKeys: pins, record: record, selfUserId: selfId, selfIdentityKey: selfKey, peerUserId: peerId, pendingChange: pending)
    }

    func testContactShield_noPinIsPendingAndOnlyEveryVerifiedPinIsVerified() {
        let a = newKey(), b = newKey()
        XCTAssertEqual(.pending, contact(pins: [], record: tagRecord(for: a)))
        XCTAssertEqual(.pending, contact(pins: [Data([1, 2])], record: tagRecord(for: a)), "a malformed pin is no pin")
        XCTAssertEqual(.verified, contact(pins: [a], record: tagRecord(for: a)))
        XCTAssertEqual(.toVerify, contact(pins: [a], record: .empty))
        // a device pinned later and never verified must not hide behind a verified one
        XCTAssertEqual(.toVerify, contact(pins: [a, b], record: tagRecord(for: a)))
        // the safety-number verification of a key counts like the in-call one
        let byNumber = IdentityVerificationRecord(bindingTag: nil, verifiedFingerprintHex: fingerprint(of: a))
        XCTAssertEqual(.verified, contact(pins: [a], record: byNumber))
    }

    func testContactShield_aRecordedChangeIsRedOnlyOverAVerifiedKey() {
        let a = newKey(), b = newKey()
        XCTAssertEqual(.changed, contact(pins: [a], record: tagRecord(for: a), pending: true))
        XCTAssertEqual(.changed, contact(pins: [a, b], record: tagRecord(for: a), pending: true))
        XCTAssertEqual(.toVerify, contact(pins: [a], record: .empty, pending: true), "a change over a key nobody verified stays to verify")
        // after a rotation the verification is for the OLD key: the new pin is not verified
        XCTAssertEqual(.toVerify, contact(pins: [b], record: tagRecord(for: a), pending: false))
    }

    // MARK: Post-quantum shield and Massima sicurezza

    private func pq(_ level: String, _ auth: String = "C", _ pin: String = "") -> CallPqProtection {
        CallPqProtection(levelToken: level, auth: auth, pin: pin)
    }

    func testPqcShield_unknownIsGreyTwoLayersAreGreenReducedAndNoneAreAmberAnAnomalyIsAmber() {
        XCTAssertEqual(.grey, IdentityShieldRules.pqcShield(nil))
        XCTAssertEqual(.green, IdentityShieldRules.pqcShield(pq("PQ2", "H")))
        XCTAssertEqual(.green, IdentityShieldRules.pqcShield(pq("PQ2", "C")))
        XCTAssertEqual(.green, IdentityShieldRules.pqcShield(pq("PQ2S")))
        XCTAssertEqual(.amber, IdentityShieldRules.pqcShield(pq("PQ1")))
        XCTAssertEqual(.amber, IdentityShieldRules.pqcShield(pq("CL")))
        for level in ["PQ2", "PQ2S", "PQ1", "CL"] {
            XCTAssertEqual(.amber, IdentityShieldRules.pqcShield(pq(level, "H", "anomaly")), level)
        }
    }

    func testMassimaSicurezza_onlyVerifiedPq2WithAVerifiedHybridSignatureAndNoAnomaly() {
        XCTAssertTrue(IdentityShieldRules.massimaSicurezza(shield: .verified, protection: pq("PQ2", "H")))
        XCTAssertFalse(IdentityShieldRules.massimaSicurezza(shield: .verified, protection: pq("PQ2S", "H")))
        XCTAssertFalse(IdentityShieldRules.massimaSicurezza(shield: .verified, protection: pq("PQ2", "C")))
        XCTAssertFalse(IdentityShieldRules.massimaSicurezza(shield: .verified, protection: pq("PQ2", "H", "anomaly")))
        XCTAssertFalse(IdentityShieldRules.massimaSicurezza(shield: .verified, protection: pq("PQ1", "H")))
        XCTAssertFalse(IdentityShieldRules.massimaSicurezza(shield: .verified, protection: nil))
        for s in [IdentityShield.toVerify, .changed, .pending] {
            XCTAssertFalse(IdentityShieldRules.massimaSicurezza(shield: s, protection: pq("PQ2", "H")), "\(s)")
        }
    }

    /// "Massima sicurezza" is a function of the identity shield and the protection line of the call and of nothing else: the whole
    /// domain of both inputs gives the cryptographic condition, whatever the state of the contact's voice is, so a voice state
    /// can neither add nor remove the badge.
    func testMassimaSicurezza_dependsOnTheCryptographicInputsOnly() {
        let levels = ["PQ2", "PQ2S", "PQ1", "CL", ""]
        let auths = ["H", "C", ""]
        let pins = ["", "anomaly", "ok"]
        var protections: [CallPqProtection?] = [nil]
        for l in levels { for a in auths { for p in pins { protections.append(pq(l, a, p)) } } }
        var shown = 0
        for shield in [IdentityShield.pending, .verified, .toVerify, .changed] {
            for protection in protections {
                let crypto = shield == .verified && protection?.levelToken == "PQ2" && protection?.auth == "H" && protection?.pin != "anomaly"
                let got = IdentityShieldRules.massimaSicurezza(shield: shield, protection: protection)
                XCTAssertEqual(crypto, got, "\(shield) \(String(describing: protection))")
                XCTAssertEqual(IdentityShieldRules.logLine(callId: callId, shield: shield, protection: protection).hasSuffix("max=\(got ? 1 : 0)"), true)
                if got { shown += 1 }
            }
        }
        XCTAssertEqual(shown, 2) // verified, PQ2, H, and a pin that is empty or "ok"
    }

    /// Badge colour mapping: the shield tones of the whole call bar, in one table.
    func testBadgeColourMapping() {
        XCTAssertEqual(.pending, shield(known: false))
        XCTAssertEqual(.verified, shield(record: .forKey))
        XCTAssertEqual(.toVerify, shield(record: .none))
        XCTAssertEqual(.changed, shield(record: .otherKeySameDevice))
        // PQC: grey / green / amber (never purple, never red)
        let tones = [nil, pq("PQ2", "H"), pq("PQ2S"), pq("PQ1"), pq("CL")].map { IdentityShieldRules.pqcShield($0) }
        XCTAssertEqual([.grey, .green, .green, .amber, .amber], tones)
        XCTAssertFalse(tones.contains(.purple))
        XCTAssertFalse(tones.contains(.red))
    }

    // MARK: The QA-SHIELD line

    func testLogLine_closedVocabularyNoKeyNoName() {
        XCTAssertEqual("QA-SHIELD call=aabbccdd id=verified pq=pq2 max=1",
                       IdentityShieldRules.logLine(callId: callId, shield: .verified, protection: pq("PQ2", "H")))
        XCTAssertEqual("QA-SHIELD call=aabbccdd id=pending pq=pending max=0",
                       IdentityShieldRules.logLine(callId: callId, shield: .pending, protection: nil))
        XCTAssertEqual("QA-SHIELD call=aabbccdd id=to_verify pq=pq max=0",
                       IdentityShieldRules.logLine(callId: callId, shield: .toVerify, protection: pq("PQ2", "C")))
        XCTAssertEqual("QA-SHIELD call=aabbccdd id=changed pq=reduced max=0",
                       IdentityShieldRules.logLine(callId: callId, shield: .changed, protection: pq("PQ1")))
        XCTAssertEqual("QA-SHIELD call=aabbccdd id=verified pq=cl max=0",
                       IdentityShieldRules.logLine(callId: callId, shield: .verified, protection: pq("CL")))
        XCTAssertEqual("QA-SHIELD call=aabbccdd id=verified pq=pq max=0",
                       IdentityShieldRules.logLine(callId: callId, shield: .verified, protection: pq("PQ2S")))
        // Massima needs a hybrid signature AND no anomaly: the flag of the line follows the same rule
        XCTAssertTrue(IdentityShieldRules.logLine(callId: callId, shield: .verified, protection: pq("PQ2", "H", "anomaly")).hasSuffix("max=0"))
        // the call id is cut to its first 8 hex characters
        XCTAssertEqual("QA-SHIELD call=aabbccdd id=pending pq=pending max=0",
                       IdentityShieldRules.logLine(callId: "AABBCCDD-1111-2222-3333-444455556666", shield: .pending, protection: nil))
    }
}
