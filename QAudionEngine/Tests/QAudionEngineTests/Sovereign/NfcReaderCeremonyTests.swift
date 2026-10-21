import XCTest
import CryptoKit
@testable import QAudionEngine

/// The reader of NFC pairing v2 (docs/security/NFC_PAIRING_V2.md sections 5, 6 and 9) over a simulated card, with no
/// CoreNFC: the two-tap flow, the checks in their order, the loss rows of section 9 and the rule that nothing is
/// stored (and nothing is sent that could make the card store) before both users confirmed.
final class NfcReaderCeremonyTests: XCTestCase {

    // MARK: - Setup

    final class LineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    /// Records what the store step of the app was asked to do.
    final class StoreRecorder {
        var calls: [(psk: Data, peer: NfcPairingV2Identity)] = []
        var fail = false
        func store(_ psk: Data, _ peer: NfcPairingV2Identity) async throws -> NfcReaderStoreOutcome {
            if fail { throw NfcPairingV2Failure(.storeFailed) }
            calls.append((psk, peer))
            return NfcReaderStoreOutcome(replaced: false, deleted: 0)
        }
    }

    struct Rig {
        let ceremony: NfcReaderCeremony
        let card: NfcCardSimulator
        let clock: NfcTestClock
        let readerIdentity: NfcPairingV2LocalIdentity
        let recorder = StoreRecorder()
    }

    /// A reader and a card with the values of the shared vectors.
    private func katRig(pinnedPeerKey: Data? = nil, sealedAuth: Data? = nil) throws -> Rig {
        let kat = try NfcPairingV2Kat.load()
        let clock = NfcTestClock()
        let card = try kat.card(sealedAuth: sealedAuth)
        card.clock = clock
        let entropy = try kat.readerEntropy()
        let local = try kat.readerIdentity()
        let environment = NfcReaderEnvironment(nowMs: { clock.now }, sleepMs: { clock.now += $0 }, entropy: { entropy })
        return Rig(ceremony: NfcReaderCeremony(local: local, pinnedPeerKey: pinnedPeerKey, environment: environment),
                   card: card, clock: clock, readerIdentity: local)
    }

    /// A reader and a card with fresh keys and fresh randomness.
    private func liveRig(pinnedPeerKey: Data? = nil, sameIdentity: Bool = false, readerSeed fixedReaderSeed: Data? = nil,
                         cardSeed fixedCardSeed: Data? = nil) throws -> Rig {
        let clock = NfcTestClock()
        let readerSeed = try fixedReaderSeed ?? ProximityPairingCrypto.randomBytes(32)
        let readerKey = try Curve25519.Signing.PrivateKey(rawRepresentation: readerSeed)
        let local = NfcPairingV2LocalIdentity(
            identity: try NfcPairingV2Identity(publicKey: readerKey.publicKey.rawRepresentation, userId: "reader-account-01"),
            signingPrivateKey: readerSeed)
        let cardSeed = try sameIdentity ? readerSeed : (fixedCardSeed ?? ProximityPairingCrypto.randomBytes(32))
        let cardKey = try Curve25519.Signing.PrivateKey(rawRepresentation: cardSeed)
        let card = try NfcCardSimulator(seed: cardSeed, publicKey: cardKey.publicKey.rawRepresentation, userId: "card-account-02")
        card.clock = clock
        let environment = NfcReaderEnvironment(nowMs: { clock.now }, sleepMs: { clock.now += $0 },
                                               entropy: { try NfcReaderEntropy.fresh() })
        return Rig(ceremony: NfcReaderCeremony(local: local, pinnedPeerKey: pinnedPeerKey, environment: environment),
                   card: card, clock: clock, readerIdentity: local)
    }

    private func confirmTap(_ rig: Rig, progress: @escaping @MainActor (NfcPairingLog.PeerDecision) -> Void = { _ in }) async -> NfcReaderConfirmResult {
        await rig.ceremony.runConfirmTap(over: rig.card, progress: progress, store: rig.recorder.store)
    }

    private func expectFailure(_ expected: NfcPairingV2Token, _ rig: Rig, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await rig.ceremony.runFirstTap(over: rig.card)
            XCTFail("the first tap must fail with \(expected.rawValue)", file: file, line: line)
        } catch let failure as NfcPairingV2Failure {
            XCTAssertEqual(failure.token, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
        XCTAssertFalse(rig.ceremony.hasStagedCeremony, "a failed first tap stages nothing", file: file, line: line)
        XCTAssertTrue(rig.recorder.calls.isEmpty, file: file, line: line)
    }

    override func tearDown() {
        NfcPairingLog.install(sink: nil)
        super.tearDown()
    }

    // MARK: - The flow of the vectors

    func testFirstTapReproducesTheVectorCodeIdentityAndLogTag() async throws {
        let kat = try NfcPairingV2Kat.load()
        let rig = try katRig()
        let first = try await rig.ceremony.runFirstTap(over: rig.card)
        XCTAssertEqual(first.sas, try kat.string(["exchange", "derived", "sas"]))
        XCTAssertEqual(first.logTag, try kat.string(["exchange", "derived", "logTag"]))
        XCTAssertEqual(first.peer.publicKey, try kat.party("card").publicKey)
        XCTAssertEqual(first.peer.userId, try kat.party("card").userId)
        XCTAssertTrue(first.revealDelivered)
        XCTAssertEqual(rig.card.sasShownToUser, first.sas, "both screens show the same code")
        XCTAssertEqual(rig.card.peerShownToUser?.publicKey, try kat.party("reader").publicKey)
        XCTAssertTrue(rig.ceremony.hasStagedCeremony)
        XCTAssertTrue(rig.recorder.calls.isEmpty, "tap 1 stores nothing")

        // The command sequence of tap 1, byte for byte, up to AUTH_C (REVEAL carries a randomized signature).
        let names = rig.card.commandNames
        XCTAssertEqual(names, ["select"] + Array(repeating: "ek", count: 7) + ["hello"] + Array(repeating: "ct", count: 7) + ["auth", "reveal"])
        let apdus = try kat.apdus()
        for (index, entry) in rig.card.log.enumerated() where entry.name != "reveal" {
            XCTAssertEqual(entry.command, apdus[index].command, "\(index) \(apdus[index].name)")
            XCTAssertEqual(entry.response, apdus[index].response, "\(index) \(apdus[index].name)")
        }
    }

    func testTwoTapFlowOverTheVectorStoresTheVectorKeyOnlyAfterTheCardProvedItStored() async throws {
        let kat = try NfcPairingV2Kat.load()
        let rig = try katRig()
        _ = try await rig.ceremony.runFirstTap(over: rig.card)
        rig.card.pendingAnswers = 1
        rig.ceremony.userDidConfirm()
        var pendingSeen = 0
        let result = await confirmTap(rig, progress: { decision in if decision == .pending { pendingSeen += 1 } })
        XCTAssertEqual(result, .stored(finalizeAcknowledged: true))
        XCTAssertEqual(pendingSeen, 1)
        XCTAssertEqual(rig.recorder.calls.count, 1)
        XCTAssertEqual(rig.recorder.calls.first?.psk, try kat.derived("psk"))
        XCTAssertEqual(rig.recorder.calls.first?.peer.publicKey, try kat.party("card").publicKey)
        XCTAssertEqual(rig.card.storedPsk, try kat.derived("psk"))
        XCTAssertTrue(rig.card.finalized)
        XCTAssertFalse(rig.ceremony.hasStagedCeremony, "everything is zeroized once the ceremony is over")

        // Tap 2, byte for byte.
        let apdus = try kat.apdus()
        func command(_ name: String) throws -> Data { try XCTUnwrap(apdus.first(where: { $0.name == name })?.command) }
        let names = rig.card.commandNames
        let tap2Start = try XCTUnwrap(names.lastIndex(of: "select"))
        XCTAssertEqual(Array(names[tap2Start...]), ["select", "confirm", "confirm", "finalize"])
        XCTAssertEqual(rig.card.log.first(where: { $0.name == "finalize" })?.command, try command("FINALIZE"))
        XCTAssertEqual(rig.card.log.last(where: { $0.name == "confirm" })?.command, try command("CONFIRM (card confirmed)"))
        XCTAssertEqual(rig.card.log.last(where: { $0.name == "confirm" })?.response,
                       try XCTUnwrap(apdus.first(where: { $0.name == "CONFIRM (card confirmed)" })?.response))
    }

    func testTwoTapFlowWithFreshKeys() async throws {
        let rig = try liveRig()
        let first = try await rig.ceremony.runFirstTap(over: rig.card)
        XCTAssertEqual(first.sas.count, 6)
        XCTAssertEqual(first.sas, rig.card.sasShownToUser)
        XCTAssertEqual(first.peer.publicKey, rig.card.identity.publicKey)
        XCTAssertEqual(rig.card.peerShownToUser?.publicKey, rig.readerIdentity.identity.publicKey)
        XCTAssertEqual(rig.card.peerShownToUser?.userId, "reader-account-01")
        rig.ceremony.userDidConfirm()
        let result = await confirmTap(rig)
        XCTAssertEqual(result, .stored(finalizeAcknowledged: true))
        XCTAssertEqual(rig.recorder.calls.count, 1)
        XCTAssertEqual(rig.recorder.calls.first?.psk, rig.card.storedPsk, "both phones hold the same key")
        XCTAssertEqual(rig.recorder.calls.first?.psk.count, 32)
        XCTAssertTrue(rig.card.finalized)
    }

    func testTwoPairingsOfTheSamePhonesGiveDifferentCodesAndKeys() async throws {
        let readerSeed = try ProximityPairingCrypto.randomBytes(32)
        let cardSeed = try ProximityPairingCrypto.randomBytes(32)
        var codes: [String] = []
        var keys: [Data] = []
        for _ in 0..<2 {
            let rig = try liveRig(readerSeed: readerSeed, cardSeed: cardSeed)
            let first = try await rig.ceremony.runFirstTap(over: rig.card)
            codes.append(first.sas)
            rig.ceremony.userDidConfirm()
            _ = await confirmTap(rig)
            keys.append(try XCTUnwrap(rig.recorder.calls.first?.psk))
        }
        XCTAssertNotEqual(keys[0], keys[1], "a fresh key for every pairing")
        XCTAssertNotEqual(codes[0], codes[1], "a fresh code for every pairing")
    }

    // MARK: - Nothing is stored or sent before both users confirmed

    func testNothingIsStoredAfterTapOne() async throws {
        let rig = try liveRig()
        _ = try await rig.ceremony.runFirstTap(over: rig.card)
        XCTAssertTrue(rig.recorder.calls.isEmpty)
        XCTAssertNil(rig.card.storedPsk)
        XCTAssertEqual(rig.card.count("confirm"), 0)
        XCTAssertEqual(rig.card.count("finalize"), 0)
    }

    func testTapTwoWithoutTheUsersConfirmationSendsNothing() async throws {
        let rig = try liveRig()
        _ = try await rig.ceremony.runFirstTap(over: rig.card)
        let before = rig.card.log.count
        let result = await confirmTap(rig)
        XCTAssertEqual(result, .failed(.order))
        XCTAssertEqual(rig.card.log.count, before, "no APDU at all")
        XCTAssertTrue(rig.recorder.calls.isEmpty)
        XCTAssertNil(rig.card.storedPsk)
    }

    func testLocalRejectSendsNothingThatCouldMakeTheCardStore() async throws {
        let rig = try liveRig()
        _ = try await rig.ceremony.runFirstTap(over: rig.card)
        let before = rig.card.log.count
        rig.ceremony.rejectLocally()
        XCTAssertFalse(rig.ceremony.hasStagedCeremony)
        let result = await confirmTap(rig)
        XCTAssertEqual(result, .failed(.order))
        XCTAssertEqual(rig.card.log.count, before, "a reject is not sent: the card times out by itself")
        XCTAssertNil(rig.card.storedPsk)
        XCTAssertTrue(rig.recorder.calls.isEmpty)
    }

    func testCardUserRejectsProvenByRejectTag() async throws {
        let rig = try liveRig()
        _ = try await rig.ceremony.runFirstTap(over: rig.card)
        rig.card.user = .rejected
        rig.ceremony.userDidConfirm()
        let result = await confirmTap(rig)
        XCTAssertEqual(result, .peerRejected)
        XCTAssertTrue(rig.recorder.calls.isEmpty)
        XCTAssertNil(rig.card.storedPsk)
        XCTAssertEqual(rig.card.count("finalize"), 0)
        XCTAssertFalse(rig.ceremony.hasStagedCeremony)
    }

    // MARK: - Unauthenticated answers only report

    func testForgedOrUnauthenticatedAnswersNeverStoreAndNeverFinalize() async throws {
        let kat = try NfcPairingV2Kat.load()
        let tagsOfTheVector = try [kat.derived("confirmReader"), kat.derived("rejectReader"), kat.derived("finalizeReader")]
        var forged: [(String, Data)] = [
            ("pending with trailing bytes", Data([0x00, 0x01])),
            ("confirmed without a tag", Data([0x01])),
            ("confirmed with a random tag", Data([0x01]) + Data(repeating: 0xAB, count: 32)),
            ("confirmed with the reader's own tag", Data([0x01]) + tagsOfTheVector[0]),
            ("rejected with the reader's reject tag", Data([0x02]) + tagsOfTheVector[1]),
            ("no ceremony", Data([0x03])),
            ("aborted", Data([0x04])),
            ("unknown state", Data([0x7F])),
            ("empty", Data()),
        ]
        forged.append(("confirmed with a short tag", Data([0x01]) + Data(repeating: 0, count: 31)))
        for (label, answer) in forged {
            let rig = try katRig()
            _ = try await rig.ceremony.runFirstTap(over: rig.card)
            rig.card.dataOverride["confirm"] = answer
            rig.ceremony.userDidConfirm()
            let result = await confirmTap(rig)
            XCTAssertEqual(result, .failed(.noCeremony), label)
            XCTAssertTrue(rig.recorder.calls.isEmpty, label)
            XCTAssertEqual(rig.card.count("finalize"), 0, label)
            XCTAssertFalse(rig.ceremony.hasStagedCeremony, label)
        }
        for status: UInt16 in [0x6985, 0x6700, 0x6D00, 0x6982] {
            let rig = try katRig()
            _ = try await rig.ceremony.runFirstTap(over: rig.card)
            rig.card.statusOverride["confirm"] = status
            rig.ceremony.userDidConfirm()
            let result = await confirmTap(rig)
            XCTAssertEqual(result, .failed(.noCeremony), String(format: "%04x", status))
            XCTAssertTrue(rig.recorder.calls.isEmpty)
        }
    }

    func testCardStoreFailureIsReportedAndNothingIsStored() async throws {
        let rig = try liveRig()
        _ = try await rig.ceremony.runFirstTap(over: rig.card)
        rig.card.storeFails = true
        rig.ceremony.userDidConfirm()
        let result = await confirmTap(rig)
        XCTAssertEqual(result, .failed(.storeFailed))
        XCTAssertTrue(rig.recorder.calls.isEmpty)
        XCTAssertNil(rig.card.storedPsk)
        XCTAssertEqual(rig.card.count("finalize"), 0)
    }

    func testLocalStoreFailureStopsBeforeFinalize() async throws {
        let rig = try liveRig()
        _ = try await rig.ceremony.runFirstTap(over: rig.card)
        rig.recorder.fail = true
        rig.ceremony.userDidConfirm()
        let result = await confirmTap(rig)
        XCTAssertEqual(result, .failed(.storeFailed))
        XCTAssertEqual(rig.card.count("finalize"), 0, "FINALIZE only after this phone stored the key")
        XCTAssertFalse(rig.ceremony.hasStagedCeremony)
    }

    // MARK: - Losses (section 9)

    func testCardNotDecidedWhenThePollEndsKeepsTheStagedStateAndAnotherTapFinishes() async throws {
        let rig = try liveRig()
        _ = try await rig.ceremony.runFirstTap(over: rig.card)
        rig.card.user = .undecided
        rig.ceremony.userDidConfirm()
        var pending = 0
        let first = await confirmTap(rig, progress: { _ in pending += 1 })
        XCTAssertEqual(first, .stillPending)
        XCTAssertGreaterThan(pending, 10)
        XCTAssertTrue(rig.ceremony.hasStagedCeremony, "kept for the 120 s of the user")
        XCTAssertTrue(rig.recorder.calls.isEmpty)
        // The poll respects its budget: 250 ms apart, 20 s at most.
        XCTAssertLessThanOrEqual(rig.card.count("confirm"), 20_000 / 250 + 1)

        rig.card.user = .confirmed
        let second = await confirmTap(rig)
        XCTAssertEqual(second, .stored(finalizeAcknowledged: true))
        XCTAssertEqual(rig.recorder.calls.count, 1)
    }

    func testLostConfirmAnswerIsRecoveredByAnotherTapWhileTheCardKeepsTheCeremony() async throws {
        // Row 5: the card stored and answered 01 || confirm_C, the answer never reached us.
        let rig = try liveRig()
        _ = try await rig.ceremony.runFirstTap(over: rig.card)
        rig.card.dropResponse = ["confirm"]
        rig.ceremony.userDidConfirm()
        let first = await confirmTap(rig)
        XCTAssertEqual(first, .fieldLost)
        XCTAssertNotNil(rig.card.storedPsk, "the card stored its copy")
        XCTAssertTrue(rig.recorder.calls.isEmpty, "this phone stores nothing without a verified confirm_C")
        XCTAssertTrue(rig.ceremony.hasStagedCeremony)

        rig.card.dropResponse = []
        let second = await confirmTap(rig)
        XCTAssertEqual(second, .stored(finalizeAcknowledged: true))
        XCTAssertEqual(rig.recorder.calls.first?.psk, rig.card.storedPsk)
    }

    func testLostConfirmAnswerWithoutAnotherTapLeavesTheReaderWithoutTheNewKey() async throws {
        // Row 6: reader K0, card has K1 waiting.
        let rig = try liveRig()
        _ = try await rig.ceremony.runFirstTap(over: rig.card)
        rig.card.failBefore = []
        rig.card.dropResponse = ["confirm"]
        rig.ceremony.userDidConfirm()
        _ = await confirmTap(rig)
        XCTAssertNotNil(rig.card.storedPsk)
        XCTAssertTrue(rig.recorder.calls.isEmpty)
        // The user never taps again: the reader's 120 s run out.
        rig.clock.now += 121_000
        let late = await confirmTap(rig)
        XCTAssertEqual(late, .failed(.timeout))
        XCTAssertTrue(rig.recorder.calls.isEmpty)
        XCTAssertFalse(rig.ceremony.hasStagedCeremony)
    }

    func testLostFinalizeIsReportedAsUnacknowledgedAndTheKeyStaysStored() async throws {
        // Row 4: FINALIZE never reaches the card.
        let rig = try liveRig()
        _ = try await rig.ceremony.runFirstTap(over: rig.card)
        rig.card.failBefore = ["finalize"]
        rig.ceremony.userDidConfirm()
        let result = await confirmTap(rig)
        XCTAssertEqual(result, .stored(finalizeAcknowledged: false))
        XCTAssertEqual(rig.recorder.calls.count, 1)
        XCTAssertFalse(rig.card.finalized)
        XCTAssertNotNil(rig.card.storedPsk)

        // The answer to FINALIZE is lost instead: the card did finalize, we only did not hear it.
        let other = try liveRig()
        _ = try await other.ceremony.runFirstTap(over: other.card)
        other.card.dropResponse = ["finalize"]
        other.ceremony.userDidConfirm()
        let lost = await confirmTap(other)
        XCTAssertEqual(lost, .stored(finalizeAcknowledged: false))
        XCTAssertTrue(other.card.finalized)
        XCTAssertEqual(other.recorder.calls.count, 1, "stored once, never again")
    }

    func testFinalizeIsRepeatedUntilTheCardAnswers() async throws {
        let rig = try liveRig()
        _ = try await rig.ceremony.runFirstTap(over: rig.card)
        rig.ceremony.userDidConfirm()
        // The card answers 00 (not finished storing) twice before it acknowledges.
        rig.card.finalizePendingAnswers = 2
        let result = await confirmTap(rig)
        XCTAssertEqual(result, .stored(finalizeAcknowledged: true))
        XCTAssertEqual(rig.card.count("finalize"), 3)
        XCTAssertEqual(rig.recorder.calls.count, 1, "the key is stored once, FINALIZE is the part that repeats")
        XCTAssertTrue(rig.card.finalized)
    }

    func testFinalizeIsStillSentWhenTheCardsProofArrivesAtTheEndOfThePollBudget() async throws {
        let rig = try liveRig()
        _ = try await rig.ceremony.runFirstTap(over: rig.card)
        // The card is slow to store: it answers 00 for almost the whole budget, then proves it, 400 ms late.
        rig.card.pendingAnswers = 79
        let card = rig.card
        let clock = rig.clock
        rig.card.beforeCommand = { step in
            if step == "confirm", card.pendingAnswers == 0 { clock.now += 400 }
        }
        rig.ceremony.userDidConfirm()
        let result = await confirmTap(rig)
        XCTAssertEqual(result, .stored(finalizeAcknowledged: true))
        XCTAssertTrue(rig.card.finalized, "the key was stored, so the card hears FINALIZE even past the 20 s")
    }

    func testCeremonyEndedByACallMeansThe03AndNothingIsStored() async throws {
        // Row 8: the card finalized another key by a call and ended the ceremony.
        let rig = try liveRig()
        _ = try await rig.ceremony.runFirstTap(over: rig.card)
        rig.card.endCeremony()
        rig.ceremony.userDidConfirm()
        let result = await confirmTap(rig)
        XCTAssertEqual(result, .failed(.noCeremony))
        XCTAssertTrue(rig.recorder.calls.isEmpty)
    }

    func testRevealThatNeverReachedTheCardIsSettledByTheConfirmation() async throws {
        let rig = try liveRig()
        rig.card.failBefore = ["reveal"]
        let first = try await rig.ceremony.runFirstTap(over: rig.card)
        XCTAssertFalse(first.revealDelivered, "the code is shown anyway")
        XCTAssertEqual(first.sas.count, 6)
        XCTAssertNil(rig.card.sasShownToUser, "the card never accepted it")
        rig.card.failBefore = []
        rig.ceremony.userDidConfirm()
        let result = await confirmTap(rig)
        XCTAssertEqual(result, .failed(.noCeremony), "CONFIRM gets 03")
        XCTAssertTrue(rig.recorder.calls.isEmpty)
        XCTAssertNil(rig.card.storedPsk)
    }

    func testRevealAcceptedButItsAnswerLostStillCompletes() async throws {
        let rig = try liveRig()
        rig.card.dropResponse = ["reveal"]
        let first = try await rig.ceremony.runFirstTap(over: rig.card)
        XCTAssertFalse(first.revealDelivered)
        XCTAssertEqual(rig.card.sasShownToUser, first.sas, "the card did accept: both screens agree")
        rig.card.dropResponse = []
        rig.ceremony.userDidConfirm()
        let result = await confirmTap(rig)
        XCTAssertEqual(result, .stored(finalizeAcknowledged: true))
    }

    func testRevealThatWasNeverSentBecauseTheTimeRanOutShowsNoCode() async throws {
        let rig = try liveRig()
        // The AUTH_C answer takes the whole first-tap budget: REVEAL cannot be transmitted.
        rig.card.latencyMs["auth"] = NfcPairingV2.firstTapBudgetMs + 1
        await expectFailure(.timeout, rig)
        XCTAssertEqual(rig.card.count("reveal"), 0)
        XCTAssertNil(rig.card.sasShownToUser)
    }

    func testAuthAndRevealAreNeverRepeated() async throws {
        let rig = try liveRig()
        _ = try await rig.ceremony.runFirstTap(over: rig.card)
        XCTAssertEqual(rig.card.count("auth"), 1)
        XCTAssertEqual(rig.card.count("reveal"), 1)
    }

    func testTheUserHasOnly120Seconds() async throws {
        // The decision comes too late: tap 2 is refused and nothing is sent.
        let late = try liveRig()
        _ = try await late.ceremony.runFirstTap(over: late.card)
        late.ceremony.userDidConfirm()
        late.clock.now += NfcPairingV2.userConfirmationTimeoutMs + 1
        let before = late.card.log.count
        let result = await confirmTap(late)
        XCTAssertEqual(result, .failed(.timeout))
        XCTAssertEqual(late.card.log.count, before)
        XCTAssertFalse(late.ceremony.hasStagedCeremony)

        // Confirming after the 120 s does nothing.
        let never = try liveRig()
        _ = try await never.ceremony.runFirstTap(over: never.card)
        never.clock.now += NfcPairingV2.userConfirmationTimeoutMs + 1
        XCTAssertEqual(never.ceremony.remainingConfirmationMs(), 0)
        never.ceremony.userDidConfirm()
        let refused = await confirmTap(never)
        XCTAssertEqual(refused, .failed(.order))

        // A poll that is running when the 120 s end stops there: it never stores after them.
        let edge = try liveRig()
        _ = try await edge.ceremony.runFirstTap(over: edge.card)
        edge.card.user = .undecided
        edge.clock.now += 110_000
        edge.ceremony.userDidConfirm()
        let polled = await confirmTap(edge)
        XCTAssertEqual(polled, .stillPending)
        XCTAssertLessThanOrEqual(edge.ceremony.remainingConfirmationMs(), 1_000)
        XCTAssertTrue(edge.recorder.calls.isEmpty)
    }

    func testAnotherVersionOnTheSecondSelectStopsTheCeremony() async throws {
        let rig = try liveRig()
        _ = try await rig.ceremony.runFirstTap(over: rig.card)
        rig.card.selectData = Data([0x01])
        rig.ceremony.userDidConfirm()
        let result = await confirmTap(rig)
        XCTAssertEqual(result, .failed(.version))
        XCTAssertTrue(rig.recorder.calls.isEmpty)
    }

    // MARK: - Tap 1 failures

    func testStatusWordsOfTheCardMapToTheTokensOfTheDocument() async throws {
        let table: [(step: String, status: UInt16, token: NfcPairingV2Token)] = [
            ("select", 0x6A82, .version),
            ("select", 0x6985, .notArmed),
            ("ek", 0x6985, .notArmed),
            ("ek", 0x6D00, .version),
            ("ek", 0x6700, .length),
            ("hello", 0x6A80, .version),
            ("hello", 0x6985, .order),
            ("hello", 0x6700, .length),
            ("ct", 0x6985, .order),
            ("ct", 0x6A86, .length),
            ("auth", 0x6985, .order),
            ("auth", 0x6F00, .cardError),
            ("reveal", 0x6982, .cardError),
            ("reveal", 0x6A80, .length),
        ]
        for row in table {
            let rig = try liveRig()
            rig.card.statusOverride[row.step] = row.status
            await expectFailure(row.token, rig)
        }
    }

    func testAnUnarmedCardIsReportedAsNotReady() async throws {
        let rig = try liveRig()
        rig.card.armed = false
        await expectFailure(.notArmed, rig)
        XCTAssertEqual(rig.card.count("ek"), 1, "the first refusal ends the ceremony")
    }

    func testSelectWithoutAVersionByteOrWithAnotherOneMeansUpdateTheOtherApp() async throws {
        for data in [nil, Data([0x01]), Data([0x03]), Data([0x02, 0x00]), Data()] as [Data?] {
            let rig = try liveRig()
            rig.card.selectData = data
            await expectFailure(.version, rig)
            XCTAssertEqual(rig.card.count("ek"), 0, "nothing is sent to a card that is not on v2")
        }
    }

    func testHelloRoundTripOverTheLimitEndsTheCeremony() async throws {
        let slow = try liveRig()
        slow.card.latencyMs["hello"] = NfcPairingV2.helloRoundTripLimitMs + 1
        await expectFailure(.rtt, slow)
        XCTAssertEqual(slow.card.count("ct"), 0)

        let atTheLimit = try liveRig()
        atTheLimit.card.latencyMs["hello"] = NfcPairingV2.helloRoundTripLimitMs
        _ = try await atTheLimit.ceremony.runFirstTap(over: atTheLimit.card)
        XCTAssertTrue(atTheLimit.ceremony.hasStagedCeremony)
    }

    func testFieldLostAtAnyStepOfTapOneIsAFieldLostNeverARejection() async throws {
        for step in ["select", "ek", "hello", "ct", "auth"] {
            let rig = try liveRig()
            rig.card.failBefore = [step]
            await expectFailure(.fieldLost, rig)
        }
        let rig = try liveRig()
        rig.card.dropResponse = ["hello"]
        await expectFailure(.fieldLost, rig)
    }

    func testAllZeroX25519FromTheCardIsRefused() async throws {
        let rig = try liveRig()
        // The card answers HELLO with the X25519 point 0.
        rig.card.dataOverride["hello"] = Data(count: 32) + Data(repeating: 7, count: 32)
        await expectFailure(.x25519Zero, rig)
        XCTAssertEqual(rig.card.count("auth"), 0)
    }

    func testWrongLengthAnswersAreRefused() async throws {
        let cases: [(String, Data, NfcPairingV2Token)] = [
            ("hello", Data(repeating: 1, count: 63), .length),
            ("hello", Data(repeating: 1, count: 65), .length),
            ("ct", Data(repeating: 1, count: 223), .length),
        ]
        for (step, data, token) in cases {
            let rig = try liveRig()
            rig.card.dataOverride[step] = data
            await expectFailure(token, rig)
        }
        // A tampered AUTH_C box is `open_failed`, and a ciphertext that does not decapsulate to the card's secret
        // shows up the same way (implicit rejection): there is no separate "bad ct" path.
        let box = try liveRig()
        box.card.dataOverride["auth"] = Data(repeating: 9, count: 160)
        await expectFailure(.openFailed, box)
        let ct = try liveRig()
        ct.card.dataOverride["ct"] = Data(repeating: 3, count: 224)
        await expectFailure(.openFailed, ct)
    }

    // MARK: - The identity checks, end to end

    func testTheCardCannotPresentTheReadersOwnIdentity() async throws {
        let rig = try liveRig(sameIdentity: true)
        await expectFailure(.identitySelf, rig)
        XCTAssertEqual(rig.card.count("reveal"), 0, "nothing of ours is revealed to a card that failed its proof")
    }

    func testPinnedIdentityOfAContactIsEnforced() async throws {
        let other = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 9, count: 32)).publicKey.rawRepresentation
        let rig = try liveRig(pinnedPeerKey: other)
        await expectFailure(.peerIdentityChanged, rig)
        XCTAssertEqual(rig.card.count("reveal"), 0)

        let cardSeed = try ProximityPairingCrypto.randomBytes(32)
        let cardPub = try Curve25519.Signing.PrivateKey(rawRepresentation: cardSeed).publicKey.rawRepresentation
        let pinned = try liveRig(pinnedPeerKey: cardPub, cardSeed: cardSeed)
        let first = try await pinned.ceremony.runFirstTap(over: pinned.card)
        XCTAssertEqual(first.peer.publicKey, pinned.card.identity.publicKey)
    }

    func testEveryReaderNegativeOfTheVectorIsRefusedWithItsToken() async throws {
        let kat = try NfcPairingV2Kat.load()
        var checked = 0
        for entry in kat.negatives where (entry["checkedBy"] as? String) == "reader" {
            guard let hex = entry["sealedCard"] as? String, let reason = entry["reason"] as? String else { continue }
            var pinned: Data?
            if let key = entry["expectedIdPub"] as? String { pinned = try NfcPairingV2Kat.data(key) }
            let rig = try katRig(pinnedPeerKey: pinned, sealedAuth: try NfcPairingV2Kat.data(hex))
            do {
                _ = try await rig.ceremony.runFirstTap(over: rig.card)
                XCTFail("\(entry["name"] ?? "") must be refused")
            } catch let failure as NfcPairingV2Failure {
                XCTAssertEqual(failure.token.rawValue, reason, "\(entry["name"] ?? "")")
            }
            XCTAssertFalse(rig.ceremony.hasStagedCeremony)
            XCTAssertEqual(rig.card.count("reveal"), 0, "\(entry["name"] ?? "")")
            checked += 1
        }
        XCTAssertEqual(checked, 9)
    }

    func testTheCardRefusesAForgedReveal() async throws {
        // A reader that signs with a key other than the one in its identity block: the card refuses and disarms.
        let rig = try liveRig()
        let wrongSeed = try ProximityPairingCrypto.randomBytes(32)
        let forged = NfcPairingV2LocalIdentity(identity: rig.readerIdentity.identity, signingPrivateKey: wrongSeed)
        let environment = NfcReaderEnvironment(nowMs: { rig.clock.now }, sleepMs: { rig.clock.now += $0 },
                                               entropy: { try NfcReaderEntropy.fresh() })
        let ceremony = NfcReaderCeremony(local: forged, environment: environment)
        do {
            _ = try await ceremony.runFirstTap(over: rig.card)
            XCTFail("the card must refuse the REVEAL")
        } catch let failure as NfcPairingV2Failure {
            XCTAssertEqual(failure.token, .cardError)
            XCTAssertEqual(failure.statusWord, 0x6982)
        }
        XCTAssertNil(rig.card.sasShownToUser, "the card never showed a code")
        XCTAssertEqual(rig.card.lastFailure, .signature)
        XCTAssertFalse(rig.card.armed, "one handshake per arming: the card is disarmed after a failed one")
        XCTAssertFalse(ceremony.hasStagedCeremony)
    }

    // MARK: - Logging

    func testLogLinesCarryOnlyTheAllowedFields() async throws {
        let box = LineBox()
        NfcPairingLog.install(sink: { tag, line in
            XCTAssertEqual(tag, NfcPairingLog.tag)
            box.append(line)
        })
        let kat = try NfcPairingV2Kat.load()
        let rig = try katRig()
        _ = try await rig.ceremony.runFirstTap(over: rig.card)
        rig.ceremony.userDidConfirm()
        _ = await confirmTap(rig)
        let failing = try liveRig()
        failing.card.latencyMs["hello"] = 900
        _ = try? await failing.ceremony.runFirstTap(over: failing.card)

        let lines = box.all
        XCTAssertFalse(lines.isEmpty)
        let allowedKeys: Set<String> = ["role", "step", "result", "sw", "chunk", "rtt_ms", "ms", "tag",
                                        "peerKnown", "pinned", "stored", "pending", "replaced", "via", "deleted"]
        let secrets: [String] = [
            try kat.string(["exchange", "derived", "sas"]),
            NfcPairingV2Kat.hex(try kat.derived("psk")), NfcPairingV2Kat.hex(try kat.derived("th1")),
            NfcPairingV2Kat.hex(try kat.party("card").publicKey), NfcPairingV2Kat.hex(try kat.party("reader").publicKey),
            try kat.party("card").userId, try kat.party("reader").userId,
            NfcPairingV2Kat.hex(try kat.derived("confirmCard")), NfcPairingV2Kat.hex(try kat.derived("confirmReader")),
        ]
        for line in lines {
            XCTAssertTrue(line.hasPrefix("nfc.pair."), line)
            let parts = line.split(separator: " ")
            for field in parts.dropFirst() {
                let pair = field.split(separator: "=", maxSplits: 1)
                XCTAssertEqual(pair.count, 2, line)
                XCTAssertTrue(allowedKeys.contains(String(pair[0])), line)
                XCTAssertTrue(pair[1].utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F }, line)
                XCTAssertLessThanOrEqual(pair[1].count, 24, line)
            }
            for secret in secrets where secret.count >= 6 {
                XCTAssertFalse(line.contains(secret), "a secret is on a log line")
            }
        }
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("nfc.pair.start"))
        XCTAssertTrue(text.contains("rtt_ms="))
        XCTAssertTrue(text.contains("nfc.pair.commit"))
        XCTAssertTrue(text.contains("nfc.pair.finalize"))
        XCTAssertTrue(text.contains("result=rtt"), "a failure carries its token")
        XCTAssertTrue(text.contains("tag=" + (try kat.string(["exchange", "derived", "logTag"]))))
    }

    func testLogLineFormatterReplacesAnythingThatLooksLikeASecret() {
        let line = NfcPairingLog.line("nfc.pair.step", [("result", String(repeating: "ab", count: 32)), ("tag", "ABCDEF"), ("ms", "12")])
        XCTAssertEqual(line, "nfc.pair.step result=x tag=x ms=12")
    }
}
