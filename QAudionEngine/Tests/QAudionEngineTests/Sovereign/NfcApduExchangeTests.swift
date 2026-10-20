import XCTest
import CryptoKit
@testable import QAudionEngine

/// The screen state machine of the iPhone reader (`NfcApduExchange`) over a simulated card: what the user sees after
/// tap 1, that nothing is stored until both users confirmed and the card proved it stored the key, and what the user
/// sees when the other person rejects, has not decided, or the time runs out. No CoreNFC session is opened.
@MainActor
final class NfcApduExchangeTests: XCTestCase {

    private final class StoreLog {
        var calls: [(psk: Data, peer: Data)] = []
    }

    private struct Rig {
        let exchange: NfcApduExchange
        let card: NfcCardSimulator
        let clock: NfcTestClock
        let store: StoreLog
        var states: StatesBox
    }

    private final class StatesBox {
        var states: [NfcApduExchange.State] = []
    }

    private func makeRig(assessor: ((NfcPairingV2Identity, NfcPairingV2Policy.ServerCheck) -> NfcPeerAssessment)? = nil,
                         pinned: Data? = nil) throws -> Rig {
        let clock = NfcTestClock()
        let readerSeed = try ProximityPairingCrypto.randomBytes(32)
        let readerPub = try Curve25519.Signing.PrivateKey(rawRepresentation: readerSeed).publicKey.rawRepresentation
        let local = NfcPairingV2LocalIdentity(identity: try NfcPairingV2Identity(publicKey: readerPub, userId: "reader-account-01"),
                                              signingPrivateKey: readerSeed)
        let cardSeed = try ProximityPairingCrypto.randomBytes(32)
        let cardPub = try Curve25519.Signing.PrivateKey(rawRepresentation: cardSeed).publicKey.rawRepresentation
        let card = try NfcCardSimulator(seed: cardSeed, publicKey: cardPub, userId: "card-account-02")
        card.clock = clock

        let exchange = NfcApduExchange(availability: NfcAvailability { true })
        exchange.localIdentityPublicKey = readerPub
        exchange.localUserId = "reader-account-01"
        exchange.expectedPeerIdentityPub = pinned
        exchange.identityProvider = { local }
        exchange.opensSessions = false
        exchange.timerSleepMs = { ms in try? await Task.sleep(nanoseconds: ms * 1_000_000) }
        exchange.environment = NfcReaderEnvironment(nowMs: { clock.now }, sleepMs: { clock.now += $0 },
                                                    entropy: { try NfcReaderEntropy.fresh() })
        exchange.assessor = assessor ?? { _, _ in
            NfcPeerAssessment(contactName: "Anna", warning: nil, peerKnown: true, pinned: false)
        }
        let store = StoreLog()
        exchange.onPskDerived = { psk, peer in
            store.calls.append((psk, peer))
            return NfcApduExchange.StoreOutcome(replaced: false, deleted: 0)
        }
        let box = StatesBox()
        exchange.onStateChanged = { box.states.append($0) }
        return Rig(exchange: exchange, card: card, clock: clock, store: store, states: box)
    }

    // MARK: - The happy path

    func testBothTapsShowTheRightScreensAndStoreOnlyAtTheEnd() async throws {
        let rig = try makeRig()
        XCTAssertTrue(rig.exchange.prepareCeremony())
        let firstEnd = await rig.exchange.performFirstTap(over: rig.card)
        guard case .sasConfirm(let sas, let peerName) = rig.exchange.state else {
            return XCTFail("expected the code on screen, got \(rig.exchange.state)")
        }
        XCTAssertEqual(peerName, "Anna")
        XCTAssertEqual(sas, rig.card.sasShownToUser, "both screens show the same code")
        XCTAssertEqual(firstEnd, .finished(message: firstEndMessage(sas)))
        XCTAssertTrue(rig.store.calls.isEmpty, "nothing is stored after tap 1")

        rig.card.pendingAnswers = 1
        rig.exchange.confirmSas()
        XCTAssertEqual(rig.exchange.state, .holdAgain(peerDeviceName: "Anna"))
        XCTAssertTrue(rig.store.calls.isEmpty)
        let secondEnd = await rig.exchange.performConfirmTap(over: rig.card)
        XCTAssertEqual(rig.exchange.state, .success(peerDeviceName: "Anna"))
        guard case .finished(let message) = secondEnd else { return XCTFail("expected a finished tap, got \(secondEnd)") }
        XCTAssertTrue(message.contains("Anna"))
        XCTAssertEqual(rig.store.calls.count, 1)
        XCTAssertEqual(rig.store.calls.first?.psk, rig.card.storedPsk)
        XCTAssertEqual(rig.store.calls.first?.peer, rig.card.identity.publicKey)
        XCTAssertTrue(rig.card.finalized)

        // The sequence the user went through.
        let kinds = rig.states.states.map { Self.kind($0) }
        XCTAssertEqual(kinds, ["exchanging", "sasConfirm", "holdAgain", "confirming", "waitingForPeer", "success"])
    }

    private func firstEndMessage(_ sas: String) -> String {
        NfcApduExchange.codeMessage(sas)
    }

    private static func kind(_ state: NfcApduExchange.State) -> String {
        switch state {
        case .idle: return "idle"
        case .waiting: return "waiting"
        case .exchanging: return "exchanging"
        case .sasConfirm: return "sasConfirm"
        case .holdAgain: return "holdAgain"
        case .confirming: return "confirming"
        case .waitingForPeer: return "waitingForPeer"
        case .success: return "success"
        case .peerRejected: return "peerRejected"
        case .error: return "error"
        }
    }

    func testTheCodeIsGroupedInThrees() {
        XCTAssertEqual(NfcApduExchange.groupedCode("123456"), "123 456")
        XCTAssertEqual(NfcApduExchange.groupedCode("000007"), "000 007")
        XCTAssertEqual(NfcApduExchange.groupedCode("12"), "12")
    }

    // MARK: - Reject, cancel, timeout

    func testRejectingTheCodeCancelsWithoutSendingOrStoring() async throws {
        let rig = try makeRig()
        XCTAssertTrue(rig.exchange.prepareCeremony())
        _ = await rig.exchange.performFirstTap(over: rig.card)
        let sent = rig.card.log.count
        rig.exchange.rejectSas()
        guard case .error(let message) = rig.exchange.state else { return XCTFail("expected an error screen") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(rig.card.log.count, sent, "a reject is not sent")
        XCTAssertTrue(rig.store.calls.isEmpty)
        XCTAssertNil(rig.card.storedPsk)
        // Nothing left to confirm.
        rig.exchange.confirmSas()
        XCTAssertEqual(rig.card.log.count, sent)
    }

    func testCancelAtAnyPointDiscardsTheCeremony() async throws {
        let rig = try makeRig()
        XCTAssertTrue(rig.exchange.prepareCeremony())
        _ = await rig.exchange.performFirstTap(over: rig.card)
        rig.exchange.confirmSas()
        XCTAssertEqual(rig.exchange.state, .holdAgain(peerDeviceName: "Anna"))
        rig.exchange.cancel()
        XCTAssertEqual(rig.exchange.state, .idle)
        let late = await rig.exchange.performConfirmTap(over: rig.card)
        XCTAssertEqual(late, .failed(message: NfcApduExchange.message(for: NfcPairingV2Failure(.noCeremony))))
        XCTAssertTrue(rig.store.calls.isEmpty)
        XCTAssertEqual(rig.card.count("confirm"), 0)
    }

    func testConfirmingWithoutACodeOnScreenDoesNothing() async throws {
        let rig = try makeRig()
        XCTAssertTrue(rig.exchange.prepareCeremony())
        rig.exchange.confirmSas()
        XCTAssertEqual(rig.exchange.state, .idle)
        rig.exchange.holdAgain()
        XCTAssertEqual(rig.exchange.state, .idle)
        XCTAssertTrue(rig.card.log.isEmpty)
    }

    func testTheCodeExpiresAfter120Seconds() async throws {
        let rig = try makeRig()
        XCTAssertTrue(rig.exchange.prepareCeremony())
        _ = await rig.exchange.performFirstTap(over: rig.card)
        rig.clock.now += NfcPairingV2.userConfirmationTimeoutMs + 1
        rig.exchange.confirmationTimerFired()
        XCTAssertEqual(rig.exchange.state, .error(NfcApduExchange.message(for: NfcPairingV2Failure(.timeout))))
        rig.exchange.confirmSas()
        XCTAssertEqual(rig.card.count("confirm"), 0)
        XCTAssertTrue(rig.store.calls.isEmpty)
    }

    func testConfirmingAfterTheTimeIsOverIsRefused() async throws {
        let rig = try makeRig()
        XCTAssertTrue(rig.exchange.prepareCeremony())
        _ = await rig.exchange.performFirstTap(over: rig.card)
        rig.clock.now += NfcPairingV2.userConfirmationTimeoutMs + 1
        rig.exchange.confirmSas()
        XCTAssertEqual(rig.exchange.state, .error(NfcApduExchange.message(for: NfcPairingV2Failure(.timeout))))
        XCTAssertEqual(rig.card.count("confirm"), 0)
    }

    func testCancelWhileTheSecondTapRunsStoresNothing() async throws {
        let rig = try makeRig()
        XCTAssertTrue(rig.exchange.prepareCeremony())
        _ = await rig.exchange.performFirstTap(over: rig.card)
        rig.exchange.confirmSas()
        // The user backs out in the very moment the card's proof arrives.
        let exchange = rig.exchange
        rig.card.beforeCommand = { step in
            if step == "confirm" { exchange.cancel() }
        }
        let end = await rig.exchange.performConfirmTap(over: rig.card)
        guard case .failed = end else { return XCTFail("expected a failed tap, got \(end)") }
        XCTAssertTrue(rig.store.calls.isEmpty, "nothing is stored after the user cancelled")
        XCTAssertEqual(rig.card.count("finalize"), 0)
        XCTAssertEqual(rig.exchange.state, .idle, "a cancelled ceremony does not come back to life")
    }

    func testCancelWhileTheFirstTapRunsLeavesNothingOnScreen() async throws {
        let rig = try makeRig()
        XCTAssertTrue(rig.exchange.prepareCeremony())
        let exchange = rig.exchange
        rig.card.beforeCommand = { step in
            if step == "auth" { exchange.cancel() }
        }
        let end = await rig.exchange.performFirstTap(over: rig.card)
        guard case .failed = end else { return XCTFail("expected a failed tap, got \(end)") }
        XCTAssertEqual(rig.exchange.state, .idle)
        XCTAssertNil(rig.exchange.identityWarning)
        rig.exchange.confirmSas()
        XCTAssertEqual(rig.exchange.state, .idle)
        XCTAssertEqual(rig.card.count("confirm"), 0)
    }

    // MARK: - The other person

    func testOtherPersonRejectsAndNothingIsStored() async throws {
        let rig = try makeRig()
        XCTAssertTrue(rig.exchange.prepareCeremony())
        _ = await rig.exchange.performFirstTap(over: rig.card)
        rig.card.user = .rejected
        rig.exchange.confirmSas()
        let end = await rig.exchange.performConfirmTap(over: rig.card)
        XCTAssertEqual(rig.exchange.state, .peerRejected(peerDeviceName: "Anna"))
        XCTAssertEqual(end, .failed(message: NfcApduExchange.message(for: NfcPairingV2Failure(.peerRejected))))
        XCTAssertTrue(rig.store.calls.isEmpty)
    }

    func testOtherPersonNotDecidedOffersToHoldTheFonesTogetherAgain() async throws {
        let rig = try makeRig()
        XCTAssertTrue(rig.exchange.prepareCeremony())
        _ = await rig.exchange.performFirstTap(over: rig.card)
        rig.card.user = .undecided
        rig.exchange.confirmSas()
        let first = await rig.exchange.performConfirmTap(over: rig.card)
        guard case .holdAgain = first else { return XCTFail("expected a hold-again end, got \(first)") }
        XCTAssertEqual(rig.exchange.state, .holdAgain(peerDeviceName: "Anna"))
        XCTAssertTrue(rig.store.calls.isEmpty)

        rig.card.user = .confirmed
        rig.exchange.holdAgain()
        let second = await rig.exchange.performConfirmTap(over: rig.card)
        guard case .finished = second else { return XCTFail("expected a finished tap, got \(second)") }
        XCTAssertEqual(rig.exchange.state, .success(peerDeviceName: "Anna"))
        XCTAssertEqual(rig.store.calls.count, 1)
    }

    func testLostFieldDuringTheSecondTapKeepsTheScreenOnHoldAgain() async throws {
        let rig = try makeRig()
        XCTAssertTrue(rig.exchange.prepareCeremony())
        _ = await rig.exchange.performFirstTap(over: rig.card)
        rig.exchange.confirmSas()
        rig.card.failBefore = ["confirm"]
        let end = await rig.exchange.performConfirmTap(over: rig.card)
        guard case .holdAgain = end else { return XCTFail("expected a hold-again end, got \(end)") }
        XCTAssertEqual(rig.exchange.state, .holdAgain(peerDeviceName: "Anna"))
        XCTAssertTrue(rig.store.calls.isEmpty)
    }

    func testStoreFailureOnThisPhoneIsReportedAsSuch() async throws {
        let rig = try makeRig()
        rig.exchange.onPskDerived = { _, _ in throw NfcPairingV2Failure(.storeFailed) }
        XCTAssertTrue(rig.exchange.prepareCeremony())
        _ = await rig.exchange.performFirstTap(over: rig.card)
        rig.exchange.confirmSas()
        _ = await rig.exchange.performConfirmTap(over: rig.card)
        XCTAssertEqual(rig.exchange.state,
                       .error(NfcApduExchange.message(for: NfcPairingV2Failure(.storeFailed), localStoreFailed: true)))
        XCTAssertNotEqual(NfcApduExchange.message(for: NfcPairingV2Failure(.storeFailed), localStoreFailed: true),
                          NfcApduExchange.message(for: NfcPairingV2Failure(.storeFailed), localStoreFailed: false))
        XCTAssertEqual(rig.card.count("finalize"), 0)
    }

    func testNoStoreHandlerMeansNothingIsStored() async throws {
        let rig = try makeRig()
        rig.exchange.onPskDerived = nil
        XCTAssertTrue(rig.exchange.prepareCeremony())
        _ = await rig.exchange.performFirstTap(over: rig.card)
        rig.exchange.confirmSas()
        _ = await rig.exchange.performConfirmTap(over: rig.card)
        guard case .error = rig.exchange.state else { return XCTFail("expected an error screen") }
        XCTAssertEqual(rig.card.count("finalize"), 0)
    }

    // MARK: - Failures on tap 1

    func testEveryTokenHasATextAndNoneCarriesSecrets() {
        var texts = Set<String>()
        for token in NfcPairingV2Token.allCases {
            let text = NfcApduExchange.message(for: NfcPairingV2Failure(token))
            XCTAssertFalse(text.isEmpty, token.rawValue)
            texts.insert(text)
        }
        XCTAssertGreaterThanOrEqual(texts.count, 12, "the distinct situations read differently")
    }

    func testFailureOfTapOneShowsAnErrorAndStagesNothing() async throws {
        let rig = try makeRig()
        rig.card.selectData = Data([0x01])
        XCTAssertTrue(rig.exchange.prepareCeremony())
        let end = await rig.exchange.performFirstTap(over: rig.card)
        let expected = NfcApduExchange.message(for: NfcPairingV2Failure(.version))
        XCTAssertEqual(end, .failed(message: expected))
        XCTAssertEqual(rig.exchange.state, .error(expected))
        rig.exchange.confirmSas()
        XCTAssertEqual(rig.exchange.state, .error(expected))
    }

    func testPinnedContactWithAnotherKeyIsRefused() async throws {
        let other = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 4, count: 32)).publicKey.rawRepresentation
        let rig = try makeRig(pinned: other)
        XCTAssertTrue(rig.exchange.prepareCeremony())
        _ = await rig.exchange.performFirstTap(over: rig.card)
        XCTAssertEqual(rig.exchange.state, .error(NfcApduExchange.message(for: NfcPairingV2Failure(.peerIdentityChanged))))
    }

    // MARK: - Identity policy on the screen

    func testWarningIsOnScreenWithTheCode() async throws {
        let rig = try makeRig(assessor: { peer, check in
            NfcPairingV2Policy.assess(peer: peer, pinnedKeys: [Data(repeating: 1, count: 32)], contactName: nil, serverCheck: check)
        })
        XCTAssertTrue(rig.exchange.prepareCeremony())
        _ = await rig.exchange.performFirstTap(over: rig.card)
        guard case .sasConfirm(_, let name) = rig.exchange.state else { return XCTFail("expected the code") }
        XCTAssertNotNil(rig.exchange.identityWarning)
        XCTAssertNotEqual(name, "Anna", "an unknown phone is not given the name of a contact")
        XCTAssertFalse(name.isEmpty)
    }

    func testServerKeysThatDoNotIncludeTheProvenKeyAddAWarning() async throws {
        var seenCheck: NfcPairingV2Policy.ServerCheck?
        let rig = try makeRig(assessor: { peer, check in
            seenCheck = check
            return NfcPairingV2Policy.assess(peer: peer, pinnedKeys: [], contactName: nil, serverCheck: check)
        })
        rig.exchange.serverIdentityKeys = { _ in [Data(repeating: 9, count: 32)] }
        XCTAssertTrue(rig.exchange.prepareCeremony())
        _ = await rig.exchange.performFirstTap(over: rig.card)
        XCTAssertEqual(seenCheck, .mismatch)
        XCTAssertNotNil(rig.exchange.identityWarning)

        let confirmedRig = try makeRig(assessor: { peer, check in
            seenCheck = check
            return NfcPairingV2Policy.assess(peer: peer, pinnedKeys: [], contactName: nil, serverCheck: check)
        })
        let key = confirmedRig.card.identity.publicKey
        confirmedRig.exchange.serverIdentityKeys = { _ in [key] }
        XCTAssertTrue(confirmedRig.exchange.prepareCeremony())
        _ = await confirmedRig.exchange.performFirstTap(over: confirmedRig.card)
        XCTAssertEqual(seenCheck, .confirmed)
        XCTAssertNil(confirmedRig.exchange.identityWarning)

        let offline = try makeRig(assessor: { peer, check in
            seenCheck = check
            return NfcPairingV2Policy.assess(peer: peer, pinnedKeys: [], contactName: nil, serverCheck: check)
        })
        offline.exchange.serverIdentityKeys = { _ in [] }
        XCTAssertTrue(offline.exchange.prepareCeremony())
        _ = await offline.exchange.performFirstTap(over: offline.card)
        XCTAssertEqual(seenCheck, .unavailable)
        XCTAssertNil(offline.exchange.identityWarning)
    }

    // MARK: - Prerequisites

    func testNoIdentityMeansNoCeremony() {
        let exchange = NfcApduExchange(availability: NfcAvailability { true })
        exchange.identityProvider = { nil }
        exchange.opensSessions = false
        exchange.localIdentityPublicKey = Data(repeating: 1, count: 32)
        XCTAssertFalse(exchange.prepareCeremony())
        guard case .error = exchange.state else { return XCTFail("expected an error screen") }

        let noKey = NfcApduExchange(availability: NfcAvailability { true })
        XCTAssertFalse(noKey.prepareCeremony())
        guard case .error = noKey.state else { return XCTFail("expected an error screen") }
    }
}
