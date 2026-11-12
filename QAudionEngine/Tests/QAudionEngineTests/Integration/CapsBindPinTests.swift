import XCTest
import CryptoKit
@testable import QAudionEngine

/// `capsBindV1` at the level of a call: simulated peers (an older build, a build whose tag is removed on the path), the sticky
/// pins keyed by (contact, signer key) with their three exits, the rule that an anomaly only warns and that nothing can arm a hold,
/// the clearing sites (logout, session expiry, account switch, full wipe) and the role of a same-account call.
///
/// This code was written on a machine that cannot compile Swift for iOS: the macOS CI job is what runs it.
final class CapsBindPinTests: XCTestCase {

    private let callId = "11111111-2222-3333-4444-555555555555"
    private let peerUser = "Peer-User-ID"
    private let keyA = Data(repeating: 0xA1, count: 32)
    private let keyB = Data(repeating: 0xB2, count: 32)

    private func newBook() -> (CapsPinBook, MemoryCapsPinPersistence) {
        let store = MemoryCapsPinPersistence()
        return (CapsPinBook(persistence: store), store)
    }

    private func bundle(tag: Bool, extra: String = "") -> BundleCapsBind {
        let caps = tag ? "{\"ratchetV3\":true,\"capsBindV1\":true}" : "{\"ratchetV3\":true}"
        return CapsBind.analyze(json: "{\"capabilities\":" + caps + extra + "}")
    }

    private func transcript() -> Data { Data(repeating: 0x42, count: 32) }

    private func macs(_ t: Data) -> (Data, Data) {
        let key = Data(repeating: 0x07, count: 32)
        return (KeyConfirmation.macInit(kcKey: key, transcript: t), KeyConfirmation.macResp(kcKey: key, transcript: t))
    }

    /// What one side computes for the round: its own bundle as sent, the peer's as received.
    private func transcriptFor(offer: BundleCapsBind, accept: BundleCapsBind, ownIsOffer: Bool) -> Data {
        let own = ownIsOffer ? offer : accept
        let peer = ownIsOffer ? accept : offer
        if CapsBind.isActive(own: own, peer: peer),
           let x = CapsBind.kcTranscriptX(kcTranscript: transcript(), offer: offer, accept: accept) { return x }
        return transcript()
    }

    // MARK: - Simulated peers

    func testACallWithAnOlderPeerKeepsTodaysMacs() {
        let current = bundle(tag: true)
        let older = bundle(tag: false)
        // The offerer is current, the acceptor is older: the older one never sends the tag.
        let offererSide = transcriptFor(offer: current, accept: older, ownIsOffer: true)
        let acceptorSide = transcriptFor(offer: current, accept: older, ownIsOffer: false)
        XCTAssertEqual(offererSide, transcript())
        XCTAssertEqual(acceptorSide, transcript())
        XCTAssertEqual(macs(offererSide).0, macs(acceptorSide).0)
        XCTAssertEqual(macs(offererSide).1, macs(acceptorSide).1)
        XCTAssertEqual(macs(offererSide).0, macs(transcript()).0, "the MACs are the ones a build without the tag computes")
    }

    func testTwoCurrentPeersAgreeOnTheExtendedMac() {
        let a = bundle(tag: true)
        let b = bundle(tag: true, extra: ",\"relayKemUnknown\":1")
        let offererSide = transcriptFor(offer: a, accept: b, ownIsOffer: true)
        let acceptorSide = transcriptFor(offer: a, accept: b, ownIsOffer: false)
        XCTAssertNotEqual(offererSide, transcript())
        XCTAssertEqual(offererSide, acceptorSide)
        XCTAssertEqual(macs(offererSide).0, macs(acceptorSide).0)
    }

    func testTheTagRemovedFromOneLegMakesTheMacsDiffer() {
        let sentOffer = bundle(tag: true)
        let sentAccept = bundle(tag: true)
        let receivedAccept = bundle(tag: false)
        // The offerer receives an ACCEPT without the tag; the acceptor received the OFFER intact.
        let offererSide = transcriptFor(offer: sentOffer, accept: receivedAccept, ownIsOffer: true)
        let acceptorSide = transcriptFor(offer: sentOffer, accept: sentAccept, ownIsOffer: false)
        XCTAssertNotEqual(macs(offererSide).0, macs(acceptorSide).0)
        XCTAssertNotEqual(macs(offererSide).1, macs(acceptorSide).1)
    }

    func testAnotherTagRemovedFromBothBundlesMakesTheMacsDiffer() {
        let sentOffer = CapsBind.analyze(json: "{\"capabilities\":{\"capsBindV1\":true,\"relayKemV1\":true}}")
        let sentAccept = CapsBind.analyze(json: "{\"capabilities\":{\"capsBindV1\":true,\"relayKemV1\":true}}")
        let changedOffer = CapsBind.analyze(json: "{\"capabilities\":{\"capsBindV1\":true}}")
        let changedAccept = CapsBind.analyze(json: "{\"capabilities\":{\"capsBindV1\":true}}")
        let offererSide = transcriptFor(offer: sentOffer, accept: changedAccept, ownIsOffer: true)
        let acceptorSide = transcriptFor(offer: changedOffer, accept: sentAccept, ownIsOffer: false)
        XCTAssertNotEqual(offererSide, acceptorSide)
    }

    func testAKeyMemberChangedOnThePathMakesTheMacsDiffer() {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        let other = Data(repeating: 2, count: 32).base64EncodedString()
        let sent = bundle(tag: true, extra: ",\"mldsaKeyId\":\"" + key + "\"")
        let altered = bundle(tag: true, extra: ",\"mldsaKeyId\":\"" + other + "\"")
        let accept = bundle(tag: true)
        XCTAssertNotEqual(transcriptFor(offer: sent, accept: accept, ownIsOffer: true),
                          transcriptFor(offer: altered, accept: accept, ownIsOffer: false))
    }

    // MARK: - The malformed rule

    private func offerForPolicy() -> AndroidHandshakeBundle {
        AndroidHandshakeBundle(
            kind: .offer, callId: callId,
            pqcPublicKey: Data(repeating: 0xA1, count: 1568).base64EncodedString(),
            x25519PublicKey: Data(repeating: 0xA2, count: 32).base64EncodedString(),
            sasCommit: Data(repeating: 0xC1, count: 32).base64EncodedString(),
            rekeyNonce: V6TestFixtures.rekeyNonce.base64EncodedString(), rekeyRound: 1)
    }

    func testARepeatedMemberWithTheTagEndsAsMalformed() {
        let integration = QAudionCallIntegration()
        let repeated = CapsBind.analyze(json: "{\"capabilities\":{\"capsBindV1\":true,\"zzTag\":true,\"zzTag\":true}}")
        let verdict = integration.evaluateInbound(
            bundle: offerForPolicy(), callId: callId, peerId: "peer-1", peerDeviceId: nil,
            expectedOfferBinding: nil, capsBind: repeated).verdict
        XCTAssertEqual(verdict, .malformed(code: "handshake_malformed"))
    }

    func testARepeatedMemberWithoutTheTagIsDecodedAsToday() {
        let integration = QAudionCallIntegration()
        let repeated = CapsBind.analyze(json: "{\"capabilities\":{\"zzTag\":true,\"zzTag\":true}}")
        let verdict = integration.evaluateInbound(
            bundle: offerForPolicy(), callId: callId, peerId: "peer-1", peerDeviceId: nil,
            expectedOfferBinding: nil, capsBind: repeated).verdict
        XCTAssertNotEqual(verdict, .malformed(code: "handshake_malformed"))
    }

    func testABuildThatDoesNotAdvertiseTheTagNeverAppliesTheRule() {
        let previous = QAudionCallIntegration.capsBindV1Enabled
        QAudionCallIntegration.capsBindV1Enabled = false
        defer { QAudionCallIntegration.capsBindV1Enabled = previous }
        let integration = QAudionCallIntegration()
        let repeated = CapsBind.analyze(json: "{\"capabilities\":{\"capsBindV1\":true,\"capsBindV1\":true}}")
        let verdict = integration.evaluateInbound(
            bundle: offerForPolicy(), callId: callId, peerId: "peer-1", peerDeviceId: nil,
            expectedOfferBinding: nil, capsBind: repeated).verdict
        XCTAssertNotEqual(verdict, .malformed(code: "handshake_malformed"))
    }

    func testTheDecoderRejectionStaysMalformedWhateverTheTag() {
        // A bundle string that names its kind but does not decode is a malformed bundle (the call ends), tag or no tag.
        for caps in ["{\"capsBindV1\":true", "{\"ratchetV3\":true"] {
            let wire = callId + "|{\"kind\":\"OFFER\",\"callId\":\"" + callId + "\",\"capabilities\":" + caps
            XCTAssertNil(AndroidHandshakeEnvelope.parse(wire))
            XCTAssertEqual(AndroidHandshakeEnvelope.malformedBundleCallId(wire), callId)
        }
    }

    func testTheTagIsReadLeniently() throws {
        let wire = callId + "|{\"kind\":\"OFFER\",\"callId\":\"" + callId + "\",\"pqcPublicKey\":\"AA==\",\"x25519PublicKey\":\"AA==\","
            + "\"capabilities\":{\"ratchetV3\":true,\"capsBindV1\":\"yes\"}}"
        let parsed = try XCTUnwrap(AndroidHandshakeEnvelope.parse(wire))
        XCTAssertNil(parsed.bundle.capabilities?.capsBindV1)
        XCTAssertEqual(parsed.capsBind.hasTag, false)
        let withTag = callId + "|{\"kind\":\"OFFER\",\"callId\":\"" + callId + "\",\"pqcPublicKey\":\"AA==\",\"x25519PublicKey\":\"AA==\","
            + "\"capabilities\":{\"ratchetV3\":true,\"capsBindV1\":true}}"
        let parsedWithTag = try XCTUnwrap(AndroidHandshakeEnvelope.parse(withTag))
        XCTAssertEqual(parsedWithTag.bundle.capabilities?.capsBindV1, true)
        XCTAssertEqual(parsedWithTag.capsBind.hasTag, true)
    }

    func testTheTagGoesOnTheWireOnlyWhileItIsAdvertised() {
        let on = AndroidHandshakeBundle(kind: .offer, callId: callId, capabilities: AndroidHandshakeBundle.Capabilities(ratchetV3: true, capsBindV1: true))
        let off = AndroidHandshakeBundle(kind: .offer, callId: callId, capabilities: AndroidHandshakeBundle.Capabilities(ratchetV3: true))
        XCTAssertTrue(AndroidHandshakeEnvelope.jsonPayload(of: on).contains("\"capsBindV1\":true"))
        XCTAssertFalse(AndroidHandshakeEnvelope.jsonPayload(of: off).contains("capsBindV1"))
        XCTAssertTrue(CapsBind.analyze(bundle: on).hasTag)
        XCTAssertFalse(CapsBind.analyze(bundle: off).hasTag)
    }

    // MARK: - Pins: set, anomaly, warning only

    func testAVerifiedFirstRoundSetsThePinAndALaterOneWithoutTheTagWarns() {
        let (book, _) = newBook()
        let state = CapsBindCallState()
        book.setCapsBind(peerUserId: peerUser, signerKey: keyA)
        XCTAssertEqual(book.record(peerUserId: peerUser.lowercased(), signerKey: keyA)?.caps, ["capsBindV1"], "keyed by the lowercase id")

        let ok = state.judgeRound1(callId: "call-ok", peerUserId: peerUser, peer: bundle(tag: true), verifiedSignerKey: keyA,
                                   book: book, armedForHold: false)
        XCTAssertEqual(ok?.pin, .ok)
        let anomaly = state.judgeRound1(callId: "call-anomaly", peerUserId: peerUser, peer: bundle(tag: false), verifiedSignerKey: keyA,
                                        book: book, armedForHold: false)
        XCTAssertEqual(anomaly?.pin, .anomaly)
        XCTAssertEqual(anomaly?.reason, .capsBindV1Missing)
        XCTAssertEqual(anomaly?.hold, false)
    }

    func testAnotherDeviceOfTheSameContactHasItsOwnRecord() {
        let (book, _) = newBook()
        let state = CapsBindCallState()
        book.setCapsBind(peerUserId: peerUser, signerKey: keyA)
        let other = state.judgeRound1(callId: "c", peerUserId: peerUser, peer: bundle(tag: false), verifiedSignerKey: keyB,
                                      book: book, armedForHold: false)
        XCTAssertEqual(other?.pin, CapsPinPolicy.Pin.unpinned, "a key with no record starts with no pin")
    }

    func testAKeyThatDidNotVerifyReadsAndWritesNothing() {
        let (book, store) = newBook()
        let state = CapsBindCallState()
        book.setCapsBind(peerUserId: peerUser, signerKey: keyA)
        let before = store.snapshot()
        XCTAssertNil(state.judgeRound1(callId: "c", peerUserId: peerUser, peer: bundle(tag: false), verifiedSignerKey: nil,
                                       book: book, armedForHold: false))
        XCTAssertEqual(store.snapshot(), before)
        XCTAssertNil(state.pinCall(callId: "c"))
    }

    func testTheWarningNamesTheMissingProtectionAndNothingIsHeld() {
        XCTAssertFalse(CapsPinPolicy.holdEnabled)
        XCTAssertFalse(CapsPinPolicy.armedDefault)
        XCTAssertEqual(CapsPinReason.allCases, [.capsBindV1Missing])
    }

    func testTheFlagCannotArmAHold() {
        let (book, _) = newBook()
        let state = CapsBindCallState()
        book.setCapsBind(peerUserId: peerUser, signerKey: keyA)
        // The flag ON, ON once and then OFF or missing, the stored arming flag, and a build whose compiled default is switched on by a hook.
        let combos: [(flag: Bool?, compiled: Bool)] = [(true, false), (false, false), (nil, false), (nil, true), (true, true)]
        for (index, combo) in combos.enumerated() {
            book.observeFlag(combo.flag)
            let armed = CapsPinPolicy.isArmedForHold(book: book, flagValue: combo.flag, compiledArming: combo.compiled)
            XCTAssertFalse(armed, "combo \(index)")
            let call = state.judgeRound1(callId: "c\(index)", peerUserId: peerUser, peer: bundle(tag: false), verifiedSignerKey: keyA,
                                         book: book, armedForHold: armed)
            XCTAssertEqual(call?.pin, .anomaly, "combo \(index)")
            XCTAssertEqual(call?.hold, false, "combo \(index)")
        }
        XCTAssertTrue(book.isArmedFlagStored, "the flag is read and stored, and still gates nothing")
        XCTAssertFalse(CapsPinPolicy.isArmedForHold(book: book, flagValue: nil))
    }

    func testTheDisabledHoldReferenceStaysTestableOnlyWhenSwitchedOnByAHook() {
        let (book, _) = newBook()
        book.setCapsBind(peerUserId: peerUser, signerKey: keyA)
        let record = book.record(peerUserId: peerUser, signerKey: keyA)
        XCTAssertEqual(CapsPinPolicy.decideRound1(record: record, peerHasCapsBind: false, armed: false).hold, false)
        XCTAssertTrue(CapsPinPolicy.isArmedForHold(book: book, flagValue: true, holdEnabled: true))
        XCTAssertFalse(CapsPinPolicy.isArmedForHold(book: book, flagValue: true, holdEnabled: false))
    }

    func testAMarkerNamingTheTagIsIgnored() {
        let (book, _) = newBook()
        let state = CapsBindCallState()
        book.setCapsBind(peerUserId: peerUser, signerKey: keyA)
        let withMarker = bundle(tag: false, extra: ",\"capsWithdrawn\":[\"capsBindV1\"]")
        XCTAssertEqual(withMarker.withdrawn, ["capsBindV1"])
        let call = state.judgeRound1(callId: "c", peerUserId: peerUser, peer: withMarker, verifiedSignerKey: keyA,
                                     book: book, armedForHold: false)
        XCTAssertEqual(call?.pin, .anomaly)
        XCTAssertEqual(call?.withdrawIgnored, true)
        XCTAssertEqual(state.lineWords(callId: "c").withdraw, "ignored")
        XCTAssertNotNil(book.record(peerUserId: peerUser, signerKey: keyA), "the record is unchanged")
    }

    func testRollbackTwoCallsBothWarnAndNeitherIsHeld() {
        let (book, _) = newBook()
        let state = CapsBindCallState()
        book.setCapsBind(peerUserId: peerUser, signerKey: keyA)
        for id in ["first", "second"] {
            let call = state.judgeRound1(callId: id, peerUserId: peerUser, peer: bundle(tag: false), verifiedSignerKey: keyA,
                                         book: book, armedForHold: false)
            XCTAssertEqual(call?.pin, .anomaly, id)
            XCTAssertEqual(call?.hold, false, id)
            XCTAssertEqual(state.lineWords(callId: id).pin, "anomaly", id)
        }
    }

    func testConfirmingTheSafetyCodeFromTheWarningDropsTheTagOnce() {
        let (book, _) = newBook()
        let state = CapsBindCallState()
        book.setCapsBind(peerUserId: peerUser, signerKey: keyA)
        _ = state.judgeRound1(callId: "c", peerUserId: peerUser, peer: bundle(tag: false), verifiedSignerKey: keyA,
                              book: book, armedForHold: false)
        XCTAssertTrue(state.confirmAnomaly(callId: "c", book: book))
        XCTAssertNil(book.record(peerUserId: peerUser, signerKey: keyA), "a record left with nothing is no record")
        XCTAssertFalse(state.confirmAnomaly(callId: "c", book: book), "once")
        // Later calls of that device without the tag are no anomaly; with the tag they are pinned again by the rule Set.
        let later = state.judgeRound1(callId: "d", peerUserId: peerUser, peer: bundle(tag: false), verifiedSignerKey: keyA,
                                      book: book, armedForHold: false)
        XCTAssertEqual(later?.pin, CapsPinPolicy.Pin.unpinned)
        book.setCapsBind(peerUserId: peerUser, signerKey: keyA)
        XCTAssertEqual(book.record(peerUserId: peerUser, signerKey: keyA)?.caps, ["capsBindV1"])
    }

    func testConfirmingACallThatWasNoAnomalyChangesNothing() {
        let (book, _) = newBook()
        let state = CapsBindCallState()
        book.setCapsBind(peerUserId: peerUser, signerKey: keyA)
        _ = state.judgeRound1(callId: "c", peerUserId: peerUser, peer: bundle(tag: true), verifiedSignerKey: keyA,
                              book: book, armedForHold: false)
        XCTAssertFalse(state.confirmAnomaly(callId: "c", book: book))
        XCTAssertNotNil(book.record(peerUserId: peerUser, signerKey: keyA))
    }

    func testASecondCallNeverOverwritesTheFirstCallsDecision() {
        let (book, _) = newBook()
        let state = CapsBindCallState()
        book.setCapsBind(peerUserId: peerUser, signerKey: keyA)
        _ = state.judgeRound1(callId: "live", peerUserId: peerUser, peer: bundle(tag: false), verifiedSignerKey: keyA,
                              book: book, armedForHold: false)
        _ = state.judgeRound1(callId: "second", peerUserId: peerUser, peer: bundle(tag: true), verifiedSignerKey: keyA,
                              book: book, armedForHold: false)
        XCTAssertEqual(state.pinCall(callId: "live")?.pin, .anomaly)
        XCTAssertEqual(state.pinCall(callId: "second")?.pin, .ok)
        XCTAssertTrue(state.confirmAnomaly(callId: "live", book: book))
        XCTAssertFalse(state.confirmAnomaly(callId: "second", book: book))
    }

    func testOnlyAnOverwriteOfTheExactEntryDropsTheReplacedKeysRecord() {
        let outcomes: [(PeerIdentityPinStore.RepinOutcome, Bool)] = [
            (.overwritten, true), (.added, false), (.unchanged, false), (.failed, false)
        ]
        for (outcome, drops) in outcomes {
            let (book, _) = newBook()
            book.setCapsBind(peerUserId: peerUser, signerKey: keyA)
            // A first-time second device: its pin lookup fell back to the first device's key, which it did not replace.
            book.noteRepin(outcome, peerUserId: peerUser, replacedKey: keyA, newKey: keyB)
            XCTAssertEqual(book.record(peerUserId: peerUser, signerKey: keyA) == nil, drops, "\(outcome)")
        }
        let (book, _) = newBook()
        book.setCapsBind(peerUserId: peerUser, signerKey: keyA)
        book.setCapsBind(peerUserId: peerUser, signerKey: keyB)
        book.noteRepin(.overwritten, peerUserId: peerUser, replacedKey: keyA, newKey: keyB)
        XCTAssertNil(book.record(peerUserId: peerUser, signerKey: keyA))
        XCTAssertNotNil(book.record(peerUserId: peerUser, signerKey: keyB), "the new key's own record stays")
        book.noteRepin(.overwritten, peerUserId: peerUser, replacedKey: keyB, newKey: keyB)
        XCTAssertNotNil(book.record(peerUserId: peerUser, signerKey: keyB), "the same key replaces nothing")
        book.noteRepin(.overwritten, peerUserId: peerUser, replacedKey: nil, newKey: keyB)
        XCTAssertNotNil(book.record(peerUserId: peerUser, signerKey: keyB))
    }

    func testTheProtectionLineWords() {
        let (book, _) = newBook()
        let state = CapsBindCallState()
        CapsBindCallRegistry.reset()
        book.setCapsBind(peerUserId: peerUser, signerKey: keyA)
        _ = state.judgeRound1(callId: "line-call", peerUserId: peerUser, peer: bundle(tag: false), verifiedSignerKey: keyA,
                              book: book, armedForHold: false)
        XCTAssertEqual(state.lineWords(callId: "line-call").pin, "anomaly")
        XCTAssertEqual(state.lineWords(callId: "line-call").caps, "")
        CapsBindCallRegistry.noteRound1(callId: "line-call", ownTag: true, peerTag: true, selfIsCaller: true)
        XCTAssertEqual(state.lineWords(callId: "line-call").caps, "capsBindV1")
        XCTAssertEqual(state.lineWords(callId: "unknown").pin, "")
    }

    // MARK: - Clearing sites and survival

    func testLogoutAndExpiryClearThePinsButKeepTheArmingFlag() {
        let (book, store) = newBook()
        book.setCapsBind(peerUserId: peerUser, signerKey: keyA)
        book.observeFlag(true)
        book.clearPins()
        XCTAssertEqual(book.recordCount, 0)
        XCTAssertTrue(store.snapshot().pinHoldArmed)
    }

    func testAFullWipeClearsBoth() {
        let (book, store) = newBook()
        book.setCapsBind(peerUserId: peerUser, signerKey: keyA)
        book.observeFlag(true)
        book.clearAll()
        XCTAssertEqual(store.snapshot(), CapsPinState())
    }

    func testPinsSurviveARestartAndATeardown() throws {
        let suite = "capsbind.test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let book = CapsPinBook(persistence: UserDefaultsCapsPinPersistence(defaults: defaults))
        book.setCapsBind(peerUserId: peerUser, signerKey: keyA)
        book.observeFlag(true)

        // A call tears down: the integration forgets the call, the records stay.
        let integration = QAudionCallIntegration()
        integration.capsBindBook = book
        integration.capsBindState.noteSent(callId: callId, info: bundle(tag: true))
        _ = integration.capsBindState.judgeRound1(
            callId: callId, peerUserId: peerUser, peer: bundle(tag: false), verifiedSignerKey: keyA,
            book: book, armedForHold: false)
        integration.onCallEnded()
        XCTAssertNil(integration.capsBindState.pinCall(callId: callId), "the per-call state goes with the call")
        XCTAssertNotNil(book.record(peerUserId: peerUser, signerKey: keyA))

        // The process restarts: a new book over the same storage reads both the records and the arming flag.
        let restarted = CapsPinBook(persistence: UserDefaultsCapsPinPersistence(defaults: defaults))
        XCTAssertEqual(restarted.record(peerUserId: peerUser, signerKey: keyA)?.caps, ["capsBindV1"])
        XCTAssertTrue(restarted.isArmedFlagStored)

        // Only the explicit sites clear them.
        restarted.clearPins()
        XCTAssertEqual(CapsPinBook(persistence: UserDefaultsCapsPinPersistence(defaults: defaults)).recordCount, 0)
        XCTAssertTrue(CapsPinBook(persistence: UserDefaultsCapsPinPersistence(defaults: defaults)).isArmedFlagStored)
    }

    func testTheOnlyCodePathsThatClearPinsAreTheExplicitSites() throws {
        let root = try repositoryRoot()
        let wipe = try String(contentsOf: root.appendingPathComponent("QAudionApp/Services/LocalCryptoWipe.swift"), encoding: .utf8)
        XCTAssertTrue(wipe.contains("CapsPinBook.shared.clearPins()"))
        XCTAssertFalse(wipe.contains("CapsPinBook.shared.clearAll()"),
                       "the wipe helper keeps the arming flag; the full-wipe sites clear it")
        let appState = try String(contentsOf: root.appendingPathComponent("QAudionApp/AppState.swift"), encoding: .utf8)
        // Logout reaches the wipe helper; expiry, a locked account and an account switch clear the pins; both full wipes clear both.
        XCTAssertGreaterThanOrEqual(appState.components(separatedBy: "CapsPinBook.shared.clearPins()").count - 1, 3)
        XCTAssertGreaterThanOrEqual(appState.components(separatedBy: "CapsPinBook.shared.clearAll()").count - 1, 1)
        // No call-end, stop, background or terminate handler of the engine or the call service touches the book.
        for path in ["QAudionEngine/Sources/QAudionEngine/Integration/QAudionCallIntegration.swift",
                     "QAudionApp/Services/CallService.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(source.contains("clearPins"), path)
            XCTAssertFalse(source.contains("capsBindBook.clearAll"), path)
        }
    }

    private func repositoryRoot(file: StaticString = #filePath) throws -> URL {
        var url = URL(fileURLWithPath: "\(file)")
        for _ in 0..<8 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("QAudionApp/AppState.swift").path) { return url }
        }
        throw NSError(domain: "CapsBindPinTests", code: 1)
    }

    // MARK: - The role of a same-account call

    func testTheRoleOfTheLegacyOuterLayerForASameAccountCall() {
        CapsBindCallRegistry.reset()
        // Not a tie: the user-id rule, whatever the tags say.
        CapsBindCallRegistry.noteRound1(callId: "a", ownTag: true, peerTag: false, selfIsCaller: true)
        XCTAssertTrue(CapsBindCallRegistry.selfIsRoleA(callId: "a", selfUserId: "alice", peerUserId: "bob"))
        XCTAssertFalse(CapsBindCallRegistry.selfIsRoleA(callId: "a", selfUserId: "bob", peerUserId: "alice"))
        // A tie with an older device on the other side: this device takes B, the older one A.
        XCTAssertFalse(CapsBindCallRegistry.selfIsRoleA(callId: "a", selfUserId: "Abc", peerUserId: "abc"))
        // A tie with no round-1 facts: as an older build, role A.
        XCTAssertTrue(CapsBindCallRegistry.selfIsRoleA(callId: "none", selfUserId: "Abc", peerUserId: "abc"))
        // Both current: the caller A, the callee B.
        CapsBindCallRegistry.noteRound1(callId: "b", ownTag: true, peerTag: true, selfIsCaller: true)
        XCTAssertTrue(CapsBindCallRegistry.selfIsRoleA(callId: "b", selfUserId: "Abc", peerUserId: "abc"))
        CapsBindCallRegistry.noteRound1(callId: "c", ownTag: true, peerTag: true, selfIsCaller: false)
        XCTAssertFalse(CapsBindCallRegistry.selfIsRoleA(callId: "C", selfUserId: "Abc", peerUserId: "abc"))
        // This device without the tag, the peer with it: role A, as an older build.
        CapsBindCallRegistry.noteRound1(callId: "d", ownTag: false, peerTag: true, selfIsCaller: false)
        XCTAssertTrue(CapsBindCallRegistry.selfIsRoleA(callId: "d", selfUserId: "Abc", peerUserId: "abc"))
    }

    func testTheLiveCallsEntryIsNeverEvictedAndReleasedOnesAreBounded() {
        CapsBindCallRegistry.reset()
        CapsBindCallRegistry.noteRound1(callId: "live", ownTag: true, peerTag: true, selfIsCaller: true)
        for i in 0..<40 {
            CapsBindCallRegistry.noteRound1(callId: "call-\(i)", ownTag: true, peerTag: true, selfIsCaller: true)
            CapsBindCallRegistry.release(callId: "call-\(i)")
        }
        XCTAssertNotNil(CapsBindCallRegistry.round1(callId: "live"), "pinned while its call lives")
        XCTAssertNil(CapsBindCallRegistry.round1(callId: "call-0"), "released entries are bounded")
        XCTAssertNotNil(CapsBindCallRegistry.round1(callId: "call-39"))
        // More than the bound of calls live at once: none of them is evicted.
        CapsBindCallRegistry.reset()
        for i in 0..<20 { CapsBindCallRegistry.noteRound1(callId: "open-\(i)", ownTag: true, peerTag: true, selfIsCaller: true) }
        for i in 0..<20 { XCTAssertNotNil(CapsBindCallRegistry.round1(callId: "open-\(i)"), "open-\(i)") }
        // Releasing the call makes it evictable.
        CapsBindCallRegistry.release(callId: "open-0")
        XCTAssertNil(CapsBindCallRegistry.round1(callId: "open-0"))
    }

    func testTheCallsEntryIsReleasedWhenItsIntegrationEndsTheCall() {
        CapsBindCallRegistry.reset()
        let integration = QAudionCallIntegration()
        integration.capsBindState.noteRound1(callId: "mine", ownTag: true, peerTag: true, selfIsCaller: false,
                                                epoch: integration.capsBindState.epoch)
        for i in 0..<30 {
            CapsBindCallRegistry.noteRound1(callId: "other-\(i)", ownTag: true, peerTag: true, selfIsCaller: true)
            CapsBindCallRegistry.release(callId: "other-\(i)")
        }
        XCTAssertNotNil(CapsBindCallRegistry.round1(callId: "mine"), "live: pinned")
        integration.onCallEnded()
        CapsBindCallRegistry.noteRound1(callId: "next", ownTag: true, peerTag: true, selfIsCaller: true)
        CapsBindCallRegistry.release(callId: "next")
        XCTAssertNil(CapsBindCallRegistry.round1(callId: "mine"), "released at the end of the call, then evictable")
    }

    func testACallThatEndsWhileAStepWaitsLeavesNoPinnedEntry() {
        CapsBindCallRegistry.reset()
        let state = CapsBindCallState()
        // The step starts, and suspends (the wait for the signer key) ...
        let startedAt = state.epoch
        // ... the call is torn down meanwhile ...
        state.reset()
        // ... and the step resumes: it registers nothing.
        XCTAssertFalse(state.noteRound1(callId: "gone", ownTag: true, peerTag: true, selfIsCaller: false, epoch: startedAt))
        XCTAssertNil(CapsBindCallRegistry.round1(callId: "gone"))
        // A step that began after the teardown registers, and its own teardown releases the entry.
        XCTAssertTrue(state.noteRound1(callId: "next", ownTag: true, peerTag: true, selfIsCaller: false, epoch: state.epoch))
        XCTAssertNotNil(CapsBindCallRegistry.round1(callId: "next"))
        state.reset()
        for i in 0..<30 {
            CapsBindCallRegistry.noteRound1(callId: "other-\(i)", ownTag: true, peerTag: true, selfIsCaller: true)
            CapsBindCallRegistry.release(callId: "other-\(i)")
        }
        XCTAssertNil(CapsBindCallRegistry.round1(callId: "next"), "released, so it falls out of the bound")
    }

    func testRegisteringAndEndingTheCallFromTwoThreadsNeverLeavesAPinnedEntry() {
        for round in 0..<50 {
            CapsBindCallRegistry.reset()
            let state = CapsBindCallState()
            let startedAt = state.epoch
            let id = "race-\(round)"
            let group = DispatchGroup()
            DispatchQueue.global().async(group: group) {
                _ = state.noteRound1(callId: id, ownTag: true, peerTag: true, selfIsCaller: false, epoch: startedAt)
            }
            DispatchQueue.global().async(group: group) { state.reset() }
            group.wait()
            // Whichever ran first, the entry is either absent or already released: filling the registry evicts it.
            for i in 0..<30 {
                CapsBindCallRegistry.noteRound1(callId: "fill-\(round)-\(i)", ownTag: true, peerTag: true, selfIsCaller: true)
                CapsBindCallRegistry.release(callId: "fill-\(round)-\(i)")
            }
            XCTAssertNil(CapsBindCallRegistry.round1(callId: id), "round \(round)")
        }
    }

    func testTheOfferStepChecksTheCallIsStillThereAfterTheSignerKeyWait() throws {
        let root = try repositoryRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("QAudionEngine/Sources/QAudionEngine/Integration/QAudionCallIntegration.swift"), encoding: .utf8)
        let wait = try XCTUnwrap(source.range(of: "guard await awaitLocalSignerKey() else {"))
        let guardAt = try XCTUnwrap(source.range(of: "guard capsBindState.epoch == capsEpoch else {", range: wait.upperBound..<source.endIndex))
        let register = try XCTUnwrap(source.range(of: "capsBindState.noteRound1(", range: wait.upperBound..<source.endIndex))
        XCTAssertLessThan(wait.lowerBound, guardAt.lowerBound)
        XCTAssertLessThan(guardAt.lowerBound, register.lowerBound)
    }

    // MARK: - The peer's bundle is analysed from its raw text

    private func rawOffer(extra: String) -> String {
        callId + "|{\"kind\":\"OFFER\",\"callId\":\"" + callId + "\",\"pqcPublicKey\":\"AA==\",\"x25519PublicKey\":\"AA==\","
            + "\"capabilities\":{\"ratchetV3\":true,\"sframeV1\":true,\"vkeyV1\":true,\"srtpDirKeyV1\":true,\"pskMixV1\":true,"
            + "\"hsTranscriptBindV1\":true,\"capsBindV1\":true,\"frameKeyV6\":true}" + extra + "}"
    }

    func testTheParsedBundleCarriesTheRawAnalysisWithItsUnknownMembers() throws {
        let extra = ",\"capsWithdrawn\":[\"relayRotV1\"],\"relayKem\":{\"x25519\":\"" + Data(repeating: 7, count: 32).base64EncodedString() + "\"}"
        let parsed = try XCTUnwrap(AndroidHandshakeEnvelope.parse(rawOffer(extra: extra)))
        XCTAssertTrue(parsed.capsBind.hasTag)
        // The two names beyond CAPS9: the tag and the unknown one, as sorted bytes.
        XCTAssertEqual(parsed.capsBind.capsx.first, 2)
        XCTAssertEqual(parsed.capsBind.withdrawn, ["relayRotV1"])
        // The typed bundle cannot stand in for the raw text: it drops what it does not model.
        let typed = CapsBind.analyze(bundle: parsed.bundle)
        XCTAssertEqual(typed.capsx.first, 1)
        XCTAssertNotEqual(typed.extx, parsed.capsBind.extx)
    }

    func testTheKeyConfirmationAgreesWithAPeerThatComputedItFromTheRawText() throws {
        let extra = ",\"capsWithdrawn\":[\"relayRotV1\"]"
        let wire = rawOffer(extra: extra)
        let payload = String(wire.dropFirst(callId.count + 1))
        let parsed = try XCTUnwrap(AndroidHandshakeEnvelope.parse(wire))
        // The offerer built its own OFFER from these bytes; the acceptor received the same bytes and analysed them with parse.
        let offererOwn = CapsBind.analyze(json: payload)
        let accept = bundle(tag: true)
        let offererSide = CapsBind.kcTranscriptX(kcTranscript: transcript(), offer: offererOwn, accept: accept)
        let acceptorSide = CapsBind.kcTranscriptX(kcTranscript: transcript(), offer: parsed.capsBind, accept: accept)
        XCTAssertNotNil(offererSide)
        XCTAssertEqual(offererSide, acceptorSide)
        XCTAssertEqual(macs(try XCTUnwrap(offererSide)).0, macs(try XCTUnwrap(acceptorSide)).0)
        XCTAssertNotEqual(CapsBind.kcTranscriptX(kcTranscript: transcript(), offer: CapsBind.analyze(bundle: parsed.bundle), accept: accept),
                          offererSide, "the re-encoded typed bundle would disagree")
    }

    func testTheProductionCallSitesPassTheRawAnalysisAndNoFallbackRemains() throws {
        let root = try repositoryRoot()
        let appState = try String(contentsOf: root.appendingPathComponent("QAudionApp/AppState.swift"), encoding: .utf8)
        XCTAssertEqual(appState.components(separatedBy: "capsBind: parsed.capsBind,").count - 1, 2, "offer and accept")
        let integration = try String(
            contentsOf: root.appendingPathComponent("QAudionEngine/Sources/QAudionEngine/Integration/QAudionCallIntegration.swift"), encoding: .utf8)
        XCTAssertFalse(integration.contains("receivedCapsBind"), "the optional parameter and its fallback are gone")
        XCTAssertFalse(integration.contains("CapsBind.analyze(bundle: bundle)"), "a received bundle is never re-encoded")
    }

    func testTheWipeSitesClearTheArmingFlagAfterTheRuntimeReset() throws {
        let root = try repositoryRoot()
        for path in ["QAudionApp/AppState.swift", "QAudionApp/Views/Settings/AccountSettingsScreen.swift", "QAudionApp/Services/LegalService.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            let clear = try XCTUnwrap(text.range(of: "CapsPinBook.shared.clearAll()"), path)
            let before = String(text[..<clear.lowerBound].suffix(300))
            XCTAssertTrue(before.contains("resetAccountScopedRuntimeState()"), path)
        }
    }

}
