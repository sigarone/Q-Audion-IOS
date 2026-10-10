import XCTest
import UIKit
@testable import QAudionApp

/// Ridurre traffico e riapplicazioni dell'avatar: la decisione di invio (`AvatarAnnouncePolicy`), il registro di cio' che e' stato
/// inviato (`AvatarSentLedger`), il controllo di completezza dei byte ricevuti (`AvatarImageIntegrity`) e l'applicazione di un avatar
/// ricevuto (`AvatarInboundApplier`). Tutto puro: nessun Keychain, nessuna rete, nessun file vero; l'orologio e' un argomento e il
/// registro usa un dominio `UserDefaults` privato.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
final class AvatarAnnouncePolicyTests: XCTestCase {

    private typealias Trigger = AvatarAnnounceCoordinator.Trigger
    private let allChecks: [Trigger] = [.chatDecrypt, .callConnect, .keyExchange]

    private func decide(
        _ trigger: Trigger,
        hash: String = "H1",
        key: String = "AAAA",
        prior: AvatarAnnouncePolicy.SentState? = AvatarAnnouncePolicy.SentState(contentHash: "H1", pairKey: "AAAA"),
        callAge: TimeInterval? = nil,
        lastAttempt: TimeInterval? = nil,
        requested: Bool = false
    ) -> AvatarAnnouncePolicy.Verdict {
        AvatarAnnouncePolicy.decide(
            trigger: trigger, currentHash: hash, currentPairKey: key, prior: prior, callAgeSec: callAge,
            lastAttemptAgeSec: lastAttempt, peerRequested: requested)
    }

    // MARK: - non si invia per ripetizione

    /// Il caso tipico: stesso contenuto, stessa chiave, il contatto ha gia' l'avatar. Nessun momento di controllo (messaggio,
    /// chiamata, scambio chiavi) invia, comunque si ripeta.
    func testSameContentAndSameKeySendsNothingAtAnyCheck() {
        for trigger in allChecks {
            XCTAssertEqual(decide(trigger), .skip(.same), "\(trigger)")
        }
    }

    func testRepeatedChecksStaySilent() {
        for _ in 0..<10 {
            for trigger in allChecks { XCTAssertEqual(decide(trigger), .skip(.same)) }
        }
    }

    // MARK: - si invia quando serve

    func testChangedContentSendsAtAnyCheck() {
        for trigger in allChecks {
            XCTAssertEqual(decide(trigger, hash: "H2"), .send(.changed), "\(trigger)")
        }
    }

    func testNeverSentToThisContactSends() {
        for trigger in allChecks {
            XCTAssertEqual(decide(trigger, prior: nil), .send(.newPeerDevice), "\(trigger)")
            XCTAssertEqual(decide(trigger, prior: AvatarAnnouncePolicy.SentState()), .send(.newPeerDevice), "\(trigger)")
        }
    }

    /// Un contatto che reinstalla rifa' lo scambio chiavi: la chiave a coppia cambia e l'avatar va rimandato anche se il contenuto e' lo stesso.
    func testChangedPairKeySendsEvenWithSameContent() {
        for trigger in allChecks {
            XCTAssertEqual(decide(trigger, key: "BBBB"), .send(.newPeerDevice), "\(trigger)")
        }
    }

    /// Senza una chiave dello scambio chiavi (contatto raggiunto solo con la chiave di una chiamata) la chiave non e' un segnale.
    func testMissingPairKeyIsNotASignal() {
        let none = AvatarSentLedger.noPairKey
        XCTAssertEqual(decide(.keyExchange, key: "BBBB", prior: AvatarAnnouncePolicy.SentState(contentHash: "H1", pairKey: none)), .skip(.same))
        XCTAssertEqual(decide(.keyExchange, key: none, prior: AvatarAnnouncePolicy.SentState(contentHash: "H1", pairKey: "AAAA")), .skip(.same))
        XCTAssertEqual(decide(.keyExchange, key: "BBBB", prior: AvatarAnnouncePolicy.SentState(contentHash: "H1", pairKey: nil)), .skip(.same))
        XCTAssertEqual(decide(.keyExchange, key: none, prior: AvatarAnnouncePolicy.SentState(contentHash: "H1", pairKey: none)), .skip(.same))
    }

    /// Azione esplicita: la foto cambiata invia sempre, anche con gli stessi byte (la foto scelta di nuovo) e nei primi secondi di una chiamata.
    func testAvatarChangedAlwaysSends() {
        XCTAssertEqual(decide(.avatarChanged), .send(.changed))
        XCTAssertEqual(decide(.avatarChanged, callAge: 5), .send(.changed))
        XCTAssertEqual(decide(.avatarChanged, prior: nil), .send(.changed))
    }

    // MARK: - guardia dell'inizio chiamata

    func testNothingIsSentInTheFirstSecondsOfACall() {
        for trigger in allChecks {
            XCTAssertEqual(decide(trigger, hash: "H2", callAge: 0), .skip(.callGuard), "\(trigger)")
            XCTAssertEqual(decide(trigger, prior: nil, callAge: 25), .skip(.callGuard), "\(trigger)")
            XCTAssertEqual(decide(trigger, key: "BBBB", callAge: 89.9), .skip(.callGuard), "\(trigger)")
        }
    }

    func testTheGuardEndsAtItsLimit() {
        XCTAssertEqual(AvatarAnnouncePolicy.callGuardSec, 90)
        XCTAssertEqual(decide(.callConnect, hash: "H2", callAge: 90), .send(.changed))
        XCTAssertEqual(decide(.callConnect, hash: "H2", callAge: 3_600), .send(.changed))
        XCTAssertEqual(decide(.callConnect, callAge: 90), .skip(.same))
    }

    func testTheGuardAppliesEvenWhenNothingWouldBeSent() {
        XCTAssertEqual(decide(.callConnect, callAge: 10), .skip(.callGuard))
    }

    // MARK: - freno anti-raffica

    func testASendIsHeldBackRightAfterAnAttempt() {
        for trigger in allChecks {
            XCTAssertEqual(decide(trigger, hash: "H2", lastAttempt: 0), .skip(.brake), "\(trigger)")
            XCTAssertEqual(decide(trigger, prior: nil, lastAttempt: 119.9), .skip(.brake), "\(trigger)")
            XCTAssertEqual(decide(trigger, key: "BBBB", lastAttempt: 60), .skip(.brake), "\(trigger)")
        }
    }

    func testTheBrakeEndsAtItsLimit() {
        XCTAssertEqual(AvatarAnnouncePolicy.attemptBrakeSec, 120)
        XCTAssertEqual(decide(.chatDecrypt, hash: "H2", lastAttempt: 120), .send(.changed))
        XCTAssertEqual(decide(.chatDecrypt, hash: "H2", lastAttempt: nil), .send(.changed))
    }

    /// Il freno non e' un criterio: se non c'e' nulla da inviare il motivo resta "uguale", e un avatar uguale non parte mai.
    func testTheBrakeNeverMakesSomethingSendThatWasNotNeeded() {
        XCTAssertEqual(decide(.chatDecrypt, lastAttempt: 0), .skip(.same))
        XCTAssertEqual(decide(.chatDecrypt, lastAttempt: 100_000), .skip(.same))
    }

    func testThePickedPhotoIgnoresTheBrakeAndTheGuardWinsOverIt() {
        XCTAssertEqual(decide(.avatarChanged, lastAttempt: 1), .send(.changed))
        XCTAssertEqual(decide(.callConnect, hash: "H2", callAge: 10, lastAttempt: 5), .skip(.callGuard))
    }

    // MARK: - punto d'ingresso del segnale "all'altro manca"

    func testPeerRequestSendsOutsideTheGuardOnly() {
        XCTAssertEqual(decide(.chatDecrypt, requested: true), .send(.requested))
        XCTAssertEqual(decide(.chatDecrypt, requested: true, callAge: 10), .skip(.callGuard))
        XCTAssertEqual(decide(.chatDecrypt, requested: false), .skip(.same))
    }

    // MARK: - codici del log

    func testCodesMatchTheLogVocabulary() {
        XCTAssertEqual(AvatarAnnouncePolicy.SendCause.changed.rawValue, 1)
        XCTAssertEqual(AvatarAnnouncePolicy.SendCause.newPeerDevice.rawValue, 2)
        XCTAssertEqual(AvatarAnnouncePolicy.SendCause.requested.rawValue, 3)
        XCTAssertEqual(AvatarAnnouncePolicy.SkipCause.same.code, 4)
        XCTAssertEqual(AvatarAnnouncePolicy.SkipCause.callGuard.code, 5)
        XCTAssertEqual(AvatarAnnouncePolicy.SkipCause.brake.code, 5)
    }

    // MARK: - una sequenza di chiamate, come la guida il coordinatore

    /// Registro vero (dominio privato) e stessa sequenza del coordinatore: la prima volta si invia, poi sei chiamate (con i loro due
    /// controlli ciascuna) non inviano; contenuto nuovo e chiave nuova inviano.
    func testManyCallsSendOnce() throws {
        let suite = "avatar-reduction-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let ledger = AvatarSentLedger(defaults: defaults)
        let peer = "11111111-2222-3333-4444-555555555555"
        let avatarA = Data([1, 2, 3])
        let avatarB = Data([4, 5, 6])

        func check(_ trigger: Trigger, _ bytes: Data, key: String = "AAAA") -> AvatarAnnouncePolicy.Verdict {
            let hash = AvatarContentHash.hex(of: bytes)
            let verdict = AvatarAnnouncePolicy.decide(
                trigger: trigger, currentHash: hash, currentPairKey: key, prior: ledger.sentState(toPeer: peer), callAgeSec: nil)
            if case .send = verdict {
                ledger.markSent(version: 1, contentHash: hash, pairKey: key, toPeer: peer, at: Date(timeIntervalSince1970: 1))
            }
            return verdict
        }

        XCTAssertEqual(check(.callConnect, avatarA), .send(.newPeerDevice))
        var sends = 0
        for _ in 0..<6 {
            for trigger in [Trigger.callConnect, .keyExchange] {
                if case .send = check(trigger, avatarA) { sends += 1 }
            }
        }
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(check(.chatDecrypt, avatarB), .send(.changed))
        XCTAssertEqual(check(.keyExchange, avatarB), .skip(.same))
        XCTAssertEqual(check(.keyExchange, avatarB, key: "BBBB"), .send(.newPeerDevice))
    }
}

final class AvatarSentLedgerTests: XCTestCase {

    private func makeLedger() throws -> (AvatarSentLedger, UserDefaults) {
        let suite = "avatar-ledger-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (AvatarSentLedger(defaults: defaults), defaults)
    }

    func testEmptyLedgerKnowsNothing() throws {
        let (ledger, _) = try makeLedger()
        XCTAssertEqual(ledger.lastVersionSent(toPeer: "p"), -1)
        XCTAssertNil(ledger.lastSentAt(toPeer: "p"))
        XCTAssertEqual(ledger.sentState(toPeer: "p"), AvatarAnnouncePolicy.SentState())
    }

    func testMarkSentRecordsHashKeyVersionAndTimePerPeer() throws {
        let (ledger, _) = try makeLedger()
        let at = Date(timeIntervalSince1970: 4_000_000)
        ledger.markSent(version: 7, contentHash: "H1", pairKey: "AAAA", toPeer: "p", at: at)
        ledger.markSent(version: 3, contentHash: "H2", pairKey: "BBBB", toPeer: "q", at: at.addingTimeInterval(10))
        XCTAssertEqual(ledger.lastVersionSent(toPeer: "p"), 7)
        XCTAssertEqual(ledger.lastSentAt(toPeer: "p"), at)
        XCTAssertEqual(ledger.sentState(toPeer: "p"), .init(contentHash: "H1", pairKey: "AAAA"))
        XCTAssertEqual(ledger.sentState(toPeer: "q"), .init(contentHash: "H2", pairKey: "BBBB"))
    }

    func testMarkSentOverwritesHashAndKey() throws {
        let (ledger, _) = try makeLedger()
        ledger.markSent(version: 7, contentHash: "H1", pairKey: "AAAA", toPeer: "p", at: Date(timeIntervalSince1970: 1))
        ledger.markSent(version: 8, contentHash: "H2", pairKey: "BBBB", toPeer: "p", at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(ledger.sentState(toPeer: "p"), .init(contentHash: "H2", pairKey: "BBBB"))
    }

    /// Lo stato scritto prima di questa modifica (solo versione e ora, con le stesse chiavi) resta leggibile e non ha impronta.
    func testStateWrittenBeforeTheHashWasRecordedIsStillRead() throws {
        let (ledger, defaults) = try makeLedger()
        defaults.set(["p": 4], forKey: AvatarSentLedger.versionsKey)
        defaults.set(["p": 5_000_000.0], forKey: AvatarSentLedger.sentAtKey)
        XCTAssertEqual(ledger.lastVersionSent(toPeer: "p"), 4)
        XCTAssertEqual(ledger.lastSentAt(toPeer: "p"), Date(timeIntervalSince1970: 5_000_000))
        XCTAssertEqual(ledger.sentState(toPeer: "p"), AvatarAnnouncePolicy.SentState())
    }

    func testAdoptBaselineKeepsVersionAndTime() throws {
        let (ledger, defaults) = try makeLedger()
        defaults.set(["p": 4], forKey: AvatarSentLedger.versionsKey)
        defaults.set(["p": 5_000_000.0], forKey: AvatarSentLedger.sentAtKey)
        ledger.adoptBaseline(contentHash: "H1", pairKey: "AAAA", toPeer: "p")
        XCTAssertEqual(ledger.sentState(toPeer: "p"), .init(contentHash: "H1", pairKey: "AAAA"))
        XCTAssertEqual(ledger.lastVersionSent(toPeer: "p"), 4)
        XCTAssertEqual(ledger.lastSentAt(toPeer: "p"), Date(timeIntervalSince1970: 5_000_000))
    }

    func testRecordPairKeyLeavesTheHashAlone() throws {
        let (ledger, _) = try makeLedger()
        ledger.markSent(version: 7, contentHash: "H1", pairKey: AvatarSentLedger.noPairKey, toPeer: "p", at: Date(timeIntervalSince1970: 1))
        ledger.recordPairKey("AAAA", toPeer: "p")
        XCTAssertEqual(ledger.sentState(toPeer: "p"), .init(contentHash: "H1", pairKey: "AAAA"))
    }

    func testPairKeyIdIsAShortPrefixOfTheFingerprint() {
        let full = String(repeating: "ab12", count: 16)
        let id = AvatarSentLedger.pairKeyId(fingerprint: full)
        XCTAssertEqual(id.count, AvatarSentLedger.pairKeyIdLength)
        XCTAssertEqual(id, String(full.prefix(16)))
        XCTAssertNotEqual(id, full)
    }

    func testPairKeyIdDiffersWhenTheFingerprintDiffers() {
        let first = AvatarSentLedger.pairKeyId(fingerprint: "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
        let second = AvatarSentLedger.pairKeyId(fingerprint: "ff112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
        XCTAssertNotEqual(first, second)
    }

    func testPairKeyIdOfNoEntryIsTheNoKeyMarker() {
        XCTAssertEqual(AvatarSentLedger.pairKeyId(fingerprint: nil), AvatarSentLedger.noPairKey)
        XCTAssertEqual(AvatarSentLedger.pairKeyId(fingerprint: ""), AvatarSentLedger.noPairKey)
    }
}

final class AvatarContentHashTests: XCTestCase {

    func testKnownSha256Vector() {
        XCTAssertEqual(
            AvatarContentHash.hex(of: Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testDifferentBytesGiveDifferentHashes() {
        XCTAssertNotEqual(AvatarContentHash.hex(of: Data([1, 2, 3])), AvatarContentHash.hex(of: Data([1, 2, 4])))
        XCTAssertEqual(AvatarContentHash.hex(of: Data([1, 2, 3])), AvatarContentHash.hex(of: Data([1, 2, 3])))
        XCTAssertEqual(AvatarContentHash.hex(of: Data()).count, 64)
    }
}

/// Il coordinatore con orologio, chiave a coppia, file dell'avatar e invio finti: i casi della politica visti dal punto in cui si
/// decide (registro vero su un dominio `UserDefaults` privato, nessuna rete, nessun Keychain).
@MainActor
final class AvatarAnnounceCoordinatorTests: XCTestCase {

    private let peer = "11111111-2222-3333-4444-555555555555"

    @MainActor
    private final class Rig {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var version = 1_700_000_000
        var pairKey = "AAAA"
        var outcome: FileV2AvatarSender.Outcome = .sent
        var onSleep: (() -> Void)?
        private(set) var sent: [URL] = []
        private(set) var slept: [TimeInterval] = []
        let directory: URL
        let defaults: UserDefaults
        let suite: String
        var coordinator: AvatarAnnounceCoordinator!

        init() throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("avatar-coordinator-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let suiteName = "avatar-coordinator-tests-\(UUID().uuidString)"
            directory = folder
            suite = suiteName
            defaults = UserDefaults(suiteName: suiteName) ?? .standard
            coordinator = AvatarAnnounceCoordinator(
                appState: nil,
                selfAvatarVersion: { [unowned self] in self.version },
                selfAvatarFile: { [unowned self] in
                    let url = self.directory.appendingPathComponent("self.jpg")
                    return FileManager.default.fileExists(atPath: url.path) ? url : nil
                },
                sendAvatar: { [unowned self] url, _ in
                    self.sent.append(url)
                    return self.outcome
                },
                sleep: { [unowned self] seconds in
                    self.slept.append(seconds)
                    self.clock = self.clock.addingTimeInterval(seconds)
                    self.onSleep?()
                },
                ledger: AvatarSentLedger(defaults: defaults),
                now: { [unowned self] in self.clock },
                pairKeyId: { [unowned self] _ in self.pairKey })
        }

        var ledger: AvatarSentLedger { AvatarSentLedger(defaults: defaults) }

        func setAvatar(_ bytes: Data) throws {
            try bytes.write(to: directory.appendingPathComponent("self.jpg"))
        }

        func advance(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }

        func tearDown() {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private func makeRig() throws -> Rig {
        let rig = try Rig()
        addTeardownBlock { rig.tearDown() }
        return rig
    }

    private let avatarA = Data([1, 2, 3, 4])
    private let avatarB = Data([5, 6, 7, 8])

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<60 where !condition() { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    // MARK: - primo invio, invariato, cambiato

    func testFirstSendNeverDeliveredBeforeSendsAndRecordsTheContent() async throws {
        let rig = try makeRig()
        try rig.setAvatar(avatarA)
        await rig.coordinator.announce(to: peer, trigger: .callConnect)
        XCTAssertEqual(rig.sent.count, 1)
        XCTAssertEqual(rig.ledger.sentState(toPeer: peer), .init(contentHash: AvatarContentHash.hex(of: avatarA), pairKey: "AAAA"))
    }

    func testAnUnchangedAvatarIsNotSentAgainAtAnyCheck() async throws {
        let rig = try makeRig()
        try rig.setAvatar(avatarA)
        await rig.coordinator.announce(to: peer, trigger: .callConnect)
        for trigger in [AvatarAnnounceCoordinator.Trigger.keyExchange, .chatDecrypt, .callConnect, .keyExchange] {
            rig.advance(3_600)
            await rig.coordinator.announce(to: peer, trigger: trigger)
        }
        XCTAssertEqual(rig.sent.count, 1)
    }

    func testAChangedAvatarIsSent() async throws {
        let rig = try makeRig()
        try rig.setAvatar(avatarA)
        await rig.coordinator.announce(to: peer, trigger: .callConnect)
        try rig.setAvatar(avatarB)
        rig.advance(300)
        await rig.coordinator.announce(to: peer, trigger: .chatDecrypt)
        XCTAssertEqual(rig.sent.count, 2)
        XCTAssertEqual(rig.ledger.sentState(toPeer: peer).contentHash, AvatarContentHash.hex(of: avatarB))
    }

    func testTheUserPickingAPhotoAlwaysSends() async throws {
        let rig = try makeRig()
        try rig.setAvatar(avatarA)
        await rig.coordinator.announce(to: peer, trigger: .callConnect)
        await rig.coordinator.announce(to: peer, trigger: .avatarChanged)
        XCTAssertEqual(rig.sent.count, 2)
    }

    // MARK: - scambio chiavi

    /// Il contatto ha reinstallato: la chiave a coppia e' un'altra, e l'avatar torna a partire anche se il contenuto e' lo stesso.
    func testAKeyExchangeThatChangedThePairKeyResends() async throws {
        let rig = try makeRig()
        try rig.setAvatar(avatarA)
        await rig.coordinator.announce(to: peer, trigger: .callConnect)
        rig.pairKey = "BBBB"
        rig.advance(300)
        await rig.coordinator.announce(to: peer, trigger: .keyExchange)
        XCTAssertEqual(rig.sent.count, 2)
        XCTAssertEqual(rig.ledger.sentState(toPeer: peer).pairKey, "BBBB")
    }

    /// Lo scambio di fine chiamata rigenera la stessa chiave: non azzera nulla.
    func testAKeyExchangeWithTheSamePairKeyDoesNotResend() async throws {
        let rig = try makeRig()
        try rig.setAvatar(avatarA)
        await rig.coordinator.announce(to: peer, trigger: .callConnect)
        rig.advance(300)
        await rig.coordinator.announce(to: peer, trigger: .keyExchange)
        XCTAssertEqual(rig.sent.count, 1)
    }

    // MARK: - fallimenti e freno

    func testAFailedSendIsNotRecordedAndTheBrakeStopsABurst() async throws {
        let rig = try makeRig()
        try rig.setAvatar(avatarA)
        rig.outcome = .failed(code: "announce_not_sent")
        await rig.coordinator.announce(to: peer, trigger: .chatDecrypt)
        XCTAssertEqual(rig.sent.count, 1)
        XCTAssertNil(rig.ledger.sentState(toPeer: peer).contentHash, "a send that did not go out is not recorded")
        for _ in 0..<5 {
            rig.advance(10)
            await rig.coordinator.announce(to: peer, trigger: .chatDecrypt)
        }
        XCTAssertEqual(rig.sent.count, 1, "no burst while the brake is on")
        rig.advance(AvatarAnnouncePolicy.attemptBrakeSec)
        await rig.coordinator.announce(to: peer, trigger: .chatDecrypt)
        XCTAssertEqual(rig.sent.count, 2, "tried again once the brake is over")
        rig.outcome = .sent
        rig.advance(AvatarAnnouncePolicy.attemptBrakeSec)
        await rig.coordinator.announce(to: peer, trigger: .chatDecrypt)
        XCTAssertEqual(rig.sent.count, 3)
        XCTAssertEqual(rig.ledger.sentState(toPeer: peer).contentHash, AvatarContentHash.hex(of: avatarA))
        rig.advance(AvatarAnnouncePolicy.attemptBrakeSec)
        await rig.coordinator.announce(to: peer, trigger: .chatDecrypt)
        XCTAssertEqual(rig.sent.count, 3, "recorded now: nothing more to send")
    }

    func testNoChannelIsNotRecordedEither() async throws {
        let rig = try makeRig()
        try rig.setAvatar(avatarA)
        rig.outcome = .noChannel
        await rig.coordinator.announce(to: peer, trigger: .callConnect)
        XCTAssertNil(rig.ledger.sentState(toPeer: peer).contentHash)
        XCTAssertEqual(rig.ledger.lastVersionSent(toPeer: peer), -1)
        rig.outcome = .sent
        rig.advance(AvatarAnnouncePolicy.attemptBrakeSec)
        await rig.coordinator.announce(to: peer, trigger: .keyExchange)
        XCTAssertEqual(rig.sent.count, 2)
        XCTAssertNotNil(rig.ledger.sentState(toPeer: peer).contentHash)
    }

    func testTheBrakeDoesNotHoldBackThePhotoTheUserJustPicked() async throws {
        let rig = try makeRig()
        try rig.setAvatar(avatarA)
        rig.outcome = .failed(code: "x")
        await rig.coordinator.announce(to: peer, trigger: .chatDecrypt)
        rig.advance(5)
        await rig.coordinator.announce(to: peer, trigger: .avatarChanged)
        XCTAssertEqual(rig.sent.count, 2)
    }

    // MARK: - niente da inviare

    func testNothingIsSentWithoutASelfAvatar() async throws {
        let rig = try makeRig()
        try rig.setAvatar(avatarA)
        rig.version = 0
        await rig.coordinator.announce(to: peer, trigger: .callConnect)
        XCTAssertTrue(rig.sent.isEmpty)
    }

    func testNothingIsSentWhenTheLocalFileIsMissing() async throws {
        let rig = try makeRig()
        await rig.coordinator.announce(to: peer, trigger: .callConnect)
        XCTAssertTrue(rig.sent.isEmpty)
    }

    /// Stato scritto prima che si registrasse l'impronta (solo versione e ora): stesso avatar, non si rimanda a tutti all'aggiornamento.
    func testStateFromBeforeTheHashWasRecordedIsAdoptedWithoutSending() async throws {
        let rig = try makeRig()
        try rig.setAvatar(avatarA)
        rig.defaults.set([peer: rig.version], forKey: AvatarSentLedger.versionsKey)
        rig.defaults.set([peer: 1_799_000_000.0], forKey: AvatarSentLedger.sentAtKey)
        await rig.coordinator.announce(to: peer, trigger: .callConnect)
        XCTAssertTrue(rig.sent.isEmpty)
        XCTAssertEqual(rig.ledger.sentState(toPeer: peer), .init(contentHash: AvatarContentHash.hex(of: avatarA), pairKey: "AAAA"))
        // And a later change is still seen.
        try rig.setAvatar(avatarB)
        await rig.coordinator.announce(to: peer, trigger: .chatDecrypt)
        XCTAssertEqual(rig.sent.count, 1)
    }

    func testTwoContactsAreIndependent() async throws {
        let rig = try makeRig()
        try rig.setAvatar(avatarA)
        await rig.coordinator.announce(to: peer, trigger: .callConnect)
        await rig.coordinator.announce(to: "99999999-2222-3333-4444-555555555555", trigger: .callConnect)
        XCTAssertEqual(rig.sent.count, 2)
    }

    // MARK: - guardia dell'inizio chiamata

    func testNothingGoesOutInTheFirstSecondsOfACallAndIsCheckedAgainAtTheEndOfTheGuard() async throws {
        let rig = try makeRig()
        try rig.setAvatar(avatarA)
        rig.coordinator.noteCall(active: true)
        rig.advance(25)
        await rig.coordinator.announce(to: peer, trigger: .callConnect)
        XCTAssertTrue(rig.sent.isEmpty, "inside the guard")
        try await waitUntil { !rig.sent.isEmpty }
        XCTAssertEqual(rig.sent.count, 1, "sent when the guard ended, the call being still on")
        XCTAssertEqual(rig.slept, [AvatarAnnouncePolicy.callGuardSec - 25 + 1])
    }

    func testTheCheckAtTheEndOfTheGuardIsDroppedIfTheCallIsOver() async throws {
        let rig = try makeRig()
        try rig.setAvatar(avatarA)
        rig.coordinator.noteCall(active: true)
        rig.advance(25)
        rig.onSleep = { [unowned rig] in rig.coordinator.noteCall(active: false) }
        await rig.coordinator.announce(to: peer, trigger: .callConnect)
        try await waitUntil { !rig.slept.isEmpty }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(rig.sent.isEmpty, "the key exchange that follows a call checks again, not this")
    }

    func testThePickedPhotoGoesOutEvenInTheFirstSecondsOfACall() async throws {
        let rig = try makeRig()
        try rig.setAvatar(avatarA)
        rig.coordinator.noteCall(active: true)
        await rig.coordinator.announce(to: peer, trigger: .avatarChanged)
        XCTAssertEqual(rig.sent.count, 1)
    }

    func testTheGuardKeepsTheStartOfTheCallAcrossStateChangesThatAreStillActive() async throws {
        let rig = try makeRig()
        try rig.setAvatar(avatarA)
        rig.coordinator.noteCall(active: true)
        rig.advance(60)
        rig.coordinator.noteCall(active: true)
        rig.advance(40)
        await rig.coordinator.announce(to: peer, trigger: .chatDecrypt)
        XCTAssertEqual(rig.sent.count, 1, "100 s since the first active state, not 40")
    }
}

final class AvatarImageIntegrityTests: XCTestCase {

    private let jpegHead: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00]
    private let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private let pngHeaderChunk: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x49, 0x48, 0x44, 0x52, 0x00, 0xAA, 0xBB, 0xCC, 0xDD]
    private let pngEnd: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]

    private func jpeg(_ tail: [UInt8] = [0xFF, 0xD9]) -> Data { Data(jpegHead + [0x12, 0x34, 0xFF, 0x00, 0x56] + tail) }
    private func png(_ tail: [UInt8]? = nil) -> Data { Data(pngSignature + pngHeaderChunk + (tail ?? pngEnd)) }

    // MARK: - JPEG

    func testJpegWithEndMarkerIsComplete() {
        XCTAssertEqual(AvatarImageIntegrity.check(jpeg()), .complete)
    }

    func testJpegWithoutEndMarkerIsIncomplete() {
        XCTAssertEqual(AvatarImageIntegrity.check(jpeg([0x12, 0x34])), .incomplete(kind: 1))
        XCTAssertEqual(AvatarImageIntegrity.check(jpeg([0xFF])), .incomplete(kind: 1))
        XCTAssertEqual(AvatarImageIntegrity.check(Data(jpegHead)), .incomplete(kind: 1))
    }

    /// Un FF D9 in mezzo ai dati (per esempio l'EOI di una miniatura) non basta: deve essere la fine.
    func testJpegWithEndMarkerOnlyInTheMiddleIsIncomplete() {
        let data = Data(jpegHead + [0xFF, 0xD9, 0x12, 0x34, 0x56])
        XCTAssertEqual(AvatarImageIntegrity.check(data), .incomplete(kind: 1))
    }

    func testJpegTolerates64TrailingZeroBytesButNotMore() {
        XCTAssertEqual(AvatarImageIntegrity.check(jpeg([0xFF, 0xD9] + [UInt8](repeating: 0, count: 3))), .complete)
        XCTAssertEqual(
            AvatarImageIntegrity.check(jpeg([0xFF, 0xD9] + [UInt8](repeating: 0, count: AvatarImageIntegrity.maxTrailingPadding))),
            .complete)
        XCTAssertEqual(
            AvatarImageIntegrity.check(jpeg([0xFF, 0xD9] + [UInt8](repeating: 0, count: AvatarImageIntegrity.maxTrailingPadding + 1))),
            .incomplete(kind: 1))
    }

    /// Un file tagliato che finisce con byte nulli (un FF 00 di riempimento nei dati) non diventa completo per via dei nulli.
    func testJpegCutInsideTheDataEndingInZerosIsIncomplete() {
        XCTAssertEqual(AvatarImageIntegrity.check(jpeg([0x56, 0xFF, 0x00, 0x00])), .incomplete(kind: 1))
    }

    // MARK: - PNG

    func testPngWithIendChunkIsComplete() {
        XCTAssertEqual(AvatarImageIntegrity.check(png()), .complete)
    }

    func testPngWithoutIendChunkIsIncomplete() {
        XCTAssertEqual(AvatarImageIntegrity.check(png(Array(pngEnd.dropLast(3)))), .incomplete(kind: 2))
        XCTAssertEqual(AvatarImageIntegrity.check(png([0x01, 0x02, 0x03])), .incomplete(kind: 2))
        XCTAssertEqual(AvatarImageIntegrity.check(Data(pngSignature)), .incomplete(kind: 2))
    }

    func testPngWithTrailingZerosIsStillComplete() {
        XCTAssertEqual(AvatarImageIntegrity.check(png(pngEnd + [0x00, 0x00])), .complete)
    }

    // MARK: - altro

    func testOtherFormatsAndEmptyDataHaveNoEndCheck() {
        XCTAssertEqual(AvatarImageIntegrity.check(Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01])), .unknownFormat)
        XCTAssertEqual(AvatarImageIntegrity.check(Data()), .unknownFormat)
        XCTAssertEqual(AvatarImageIntegrity.check(Data([0xFF, 0xD8])), .unknownFormat)
    }

    // MARK: - immagini vere

    private func makeImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48))
        return renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 48))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 24, y: 0, width: 24, height: 48))
        }
    }

    func testARealJpegIsCompleteAndCutOffIsNot() throws {
        let data = try XCTUnwrap(makeImage().jpegData(compressionQuality: 0.8))
        XCTAssertEqual(AvatarImageIntegrity.check(data), .complete)
        XCTAssertEqual(AvatarImageIntegrity.check(data.dropLast(10)), .incomplete(kind: 1))
        XCTAssertEqual(AvatarImageIntegrity.check(data.prefix(data.count / 2)), .incomplete(kind: 1))
    }

    func testARealPngIsCompleteAndCutOffIsNot() throws {
        let data = try XCTUnwrap(makeImage().pngData())
        XCTAssertEqual(AvatarImageIntegrity.check(data), .complete)
        XCTAssertEqual(AvatarImageIntegrity.check(data.dropLast(10)), .incomplete(kind: 2))
        XCTAssertEqual(AvatarImageIntegrity.check(data.prefix(data.count / 2)), .incomplete(kind: 2))
    }
}

final class AvatarInboundApplierTests: XCTestCase {

    private enum RigError: Error { case disk }

    private let jpegHead: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00]
    private let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private let pngEnd: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]

    private func jpeg(_ seed: UInt8) -> Data { Data(jpegHead + [seed, 0x34, 0xFF, 0x00, 0x56, 0xFF, 0xD9]) }
    private func truncatedJpeg(_ seed: UInt8) -> Data { Data(jpegHead + [seed, 0x34, 0xFF, 0x00, 0x56]) }
    private func png(_ seed: UInt8) -> Data { Data(pngSignature + [0x00, 0x00, 0x00, 0x01, 0x49, 0x48, 0x44, 0x52, seed] + pngEnd) }
    private func truncatedPng(_ seed: UInt8) -> Data { Data(pngSignature + [0x00, 0x00, 0x00, 0x01, 0x49, 0x48, 0x44, 0x52, seed]) }

    /// Disco, contatto e aggiornamento delle viste finti, con il conto di quello che l'applicatore ha fatto.
    private final class Rig {
        var file: Data?
        var cached: Int
        var now: Date
        var decodable = true
        var persisted = true
        var failWrite = false
        /// What the cache reduction keeps of a received picture (the same bytes unless a test sets it).
        var reduced: ((Data) -> Data)?
        var receivedHash: String?
        private(set) var savedHashes: [String] = []
        private(set) var writes: [Data] = []
        private(set) var versionsRegistered: [Int] = []
        private(set) var refreshes = 0

        init(file: Data?, cached: Int, now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
            self.file = file
            self.cached = cached
            self.now = now
        }

        func makeApplier() -> AvatarInboundApplier {
            return AvatarInboundApplier(
                decodes: { [unowned self] _ in self.decodable },
                readCurrent: { [unowned self] in self.file },
                write: { [unowned self] data in
                    if self.failWrite { throw RigError.disk }
                    self.writes.append(data)
                    self.file = data
                },
                cachedVersion: { [unowned self] in self.cached },
                setLocalPath: { [unowned self] version in
                    self.versionsRegistered.append(version)
                    if self.persisted { self.cached = version }
                    return self.persisted
                },
                notify: { [unowned self] in self.refreshes += 1 },
                now: { [unowned self] in self.now },
                lastReceivedHash: { [unowned self] in self.receivedHash },
                saveReceivedHash: { [unowned self] hash in
                    self.savedHashes.append(hash)
                    self.receivedHash = hash
                },
                reduce: { [unowned self] data in self.reduced?(data) ?? data })
        }
    }

    private func assertUntouched(_ rig: Rig, file: Data?, cached: Int, line: UInt = #line) {
        XCTAssertTrue(rig.writes.isEmpty, "no file write", line: line)
        XCTAssertTrue(rig.versionsRegistered.isEmpty, "no version registered", line: line)
        XCTAssertEqual(rig.refreshes, 0, "no view refresh", line: line)
        XCTAssertEqual(rig.file, file, "the file on disk is intact", line: line)
        XCTAssertEqual(rig.cached, cached, "the version is unchanged", line: line)
    }

    // MARK: - identico

    func testIdenticalAvatarChangesNothing() throws {
        let rig = Rig(file: jpeg(1), cached: 1_700_000_000)
        XCTAssertEqual(try rig.makeApplier().apply(jpeg(1)), .identical)
        assertUntouched(rig, file: jpeg(1), cached: 1_700_000_000)
    }

    func testIdenticalAvatarTwiceStaysUntouched() throws {
        let rig = Rig(file: jpeg(1), cached: 10)
        let applier = rig.makeApplier()
        XCTAssertEqual(try applier.apply(jpeg(1)), .identical)
        XCTAssertEqual(try applier.apply(jpeg(1)), .identical)
        assertUntouched(rig, file: jpeg(1), cached: 10)
    }

    /// Il file c'e' ma il contatto non ha un avatar applicato (riga nuova o ricreata): va applicato, anche se i byte coincidono.
    func testSameBytesWithoutAnAppliedVersionAreApplied() throws {
        let rig = Rig(file: jpeg(1), cached: -1)
        let outcome = try rig.makeApplier().apply(jpeg(1))
        XCTAssertEqual(outcome, .applied(version: Int(rig.now.timeIntervalSince1970)))
        XCTAssertEqual(rig.refreshes, 1)
    }

    // MARK: - diverso

    func testDifferentAvatarIsWrittenRegisteredAndNotified() throws {
        let rig = Rig(file: jpeg(1), cached: 1_700_000_000)
        let outcome = try rig.makeApplier().apply(jpeg(2))
        let expected = Int(rig.now.timeIntervalSince1970)
        XCTAssertEqual(outcome, .applied(version: expected))
        XCTAssertEqual(rig.writes, [jpeg(2)])
        XCTAssertEqual(rig.file, jpeg(2))
        XCTAssertEqual(rig.versionsRegistered, [expected])
        XCTAssertEqual(rig.refreshes, 1)
    }

    func testFirstAvatarOfAContactIsApplied() throws {
        let rig = Rig(file: nil, cached: -1)
        XCTAssertEqual(try rig.makeApplier().apply(jpeg(2)), .applied(version: Int(rig.now.timeIntervalSince1970)))
        XCTAssertEqual(rig.writes.count, 1)
        XCTAssertEqual(rig.refreshes, 1)
    }

    /// La versione non scende mai: con l'orologio indietro rispetto all'ultima, sale di uno.
    func testVersionNeverGoesBelowTheLastOne() throws {
        let rig = Rig(file: jpeg(1), cached: 5_000_000_000, now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(try rig.makeApplier().apply(jpeg(2)), .applied(version: 5_000_000_001))
        XCTAssertEqual(rig.versionsRegistered, [5_000_000_001])
    }

    func testValidPngIsAccepted() throws {
        let rig = Rig(file: jpeg(1), cached: 3)
        XCTAssertEqual(try rig.makeApplier().apply(png(7)), .applied(version: Int(rig.now.timeIntervalSince1970)))
        XCTAssertEqual(rig.file, png(7))
    }

    func testDecodableFormatWithoutAnEndCheckIsAccepted() throws {
        let gif = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00])
        let rig = Rig(file: jpeg(1), cached: 3)
        XCTAssertEqual(try rig.makeApplier().apply(gif), .applied(version: Int(rig.now.timeIntervalSince1970)))
    }

    // MARK: - incompleto

    func testTruncatedJpegIsRejectedAndThePreviousAvatarIsIntact() throws {
        let rig = Rig(file: jpeg(1), cached: 1_700_000_000)
        XCTAssertEqual(try rig.makeApplier().apply(truncatedJpeg(2)), .incomplete(kind: 1))
        assertUntouched(rig, file: jpeg(1), cached: 1_700_000_000)
    }

    func testTruncatedPngIsRejectedAndThePreviousAvatarIsIntact() throws {
        let rig = Rig(file: png(1), cached: 1_700_000_000)
        XCTAssertEqual(try rig.makeApplier().apply(truncatedPng(2)), .incomplete(kind: 2))
        assertUntouched(rig, file: png(1), cached: 1_700_000_000)
    }

    func testTruncatedAvatarForAContactWithoutOneWritesNothing() throws {
        let rig = Rig(file: nil, cached: -1)
        XCTAssertEqual(try rig.makeApplier().apply(truncatedJpeg(2)), .incomplete(kind: 1))
        assertUntouched(rig, file: nil, cached: -1)
    }

    func testTruncatedAvatarThatEqualsTheCurrentFileIsStillRejected() throws {
        let rig = Rig(file: truncatedJpeg(2), cached: 4)
        XCTAssertEqual(try rig.makeApplier().apply(truncatedJpeg(2)), .incomplete(kind: 1))
        assertUntouched(rig, file: truncatedJpeg(2), cached: 4)
    }

    // MARK: - non decodificabile, errori

    func testUndecodableDataIsRejectedUntouched() throws {
        let rig = Rig(file: jpeg(1), cached: 9)
        rig.decodable = false
        XCTAssertEqual(try rig.makeApplier().apply(jpeg(2)), .undecodable)
        assertUntouched(rig, file: jpeg(1), cached: 9)
    }

    func testRefusedRegistrationWritesButDoesNotNotify() throws {
        let rig = Rig(file: jpeg(1), cached: 9)
        rig.persisted = false
        let outcome = try rig.makeApplier().apply(jpeg(2))
        XCTAssertEqual(outcome, .notPersisted(version: Int(rig.now.timeIntervalSince1970)))
        XCTAssertEqual(rig.refreshes, 0)
        XCTAssertEqual(rig.writes.count, 1)
        XCTAssertEqual(rig.cached, 9)
    }

    // MARK: - avatar grande: copia ridotta in cache

    /// Un avatar ricevuto molto piu' grande della regola si mostra, ma in cache va la copia ridotta (altri byte), con la sua versione.
    func testALargeAvatarIsKeptAsItsReducedCopy() throws {
        let rig = Rig(file: nil, cached: -1)
        let received = jpeg(9)
        let kept = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0xFF, 0xD9])
        rig.reduced = { _ in kept }
        let outcome = try rig.makeApplier().apply(received)
        XCTAssertEqual(outcome, .applied(version: Int(rig.now.timeIntervalSince1970)))
        XCTAssertEqual(rig.writes, [kept])
        XCTAssertEqual(rig.file, kept)
        XCTAssertEqual(rig.savedHashes, [AvatarContentHash.hex(of: received)])
    }

    /// Lo stesso avatar grande ricevuto di nuovo non si riscrive: il file in cache ha altri byte, ma l'impronta dei byte ricevuti e' la stessa.
    func testTheSameLargeAvatarAgainIsIdenticalEvenThoughTheCachedFileIsTheReducedCopy() throws {
        let rig = Rig(file: nil, cached: -1)
        let received = jpeg(9)
        let kept = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0xFF, 0xD9])
        rig.reduced = { _ in kept }
        let applier = rig.makeApplier()
        _ = try applier.apply(received)
        let writesAfterFirst = rig.writes.count
        let versionAfterFirst = rig.cached
        let refreshesAfterFirst = rig.refreshes
        XCTAssertEqual(try applier.apply(received), .identical)
        XCTAssertEqual(rig.writes.count, writesAfterFirst)
        XCTAssertEqual(rig.cached, versionAfterFirst)
        XCTAssertEqual(rig.refreshes, refreshesAfterFirst)
    }

    func testADifferentLargeAvatarAfterTheFirstIsApplied() throws {
        let rig = Rig(file: nil, cached: -1)
        rig.reduced = { _ in Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0xFF, 0xD9]) }
        let applier = rig.makeApplier()
        _ = try applier.apply(jpeg(9))
        rig.now = rig.now.addingTimeInterval(60)
        XCTAssertEqual(try applier.apply(jpeg(10)), .applied(version: Int(rig.now.timeIntervalSince1970)))
        XCTAssertEqual(rig.savedHashes, [AvatarContentHash.hex(of: jpeg(9)), AvatarContentHash.hex(of: jpeg(10))])
    }

    /// A, poi B, poi di nuovo A: A non e' "identico", e' diverso dall'ultimo ricevuto.
    func testBackToAnEarlierAvatarIsApplied() throws {
        let rig = Rig(file: nil, cached: -1)
        let applier = rig.makeApplier()
        _ = try applier.apply(jpeg(1))
        rig.now = rig.now.addingTimeInterval(60)
        _ = try applier.apply(jpeg(2))
        rig.now = rig.now.addingTimeInterval(60)
        XCTAssertEqual(try applier.apply(jpeg(1)), .applied(version: Int(rig.now.timeIntervalSince1970)))
        XCTAssertEqual(rig.writes, [jpeg(1), jpeg(2), jpeg(1)])
    }

    func testTheReceivedHashIsNotSavedWhenTheContactRefusesTheVersion() throws {
        let rig = Rig(file: jpeg(1), cached: 9)
        rig.persisted = false
        _ = try rig.makeApplier().apply(jpeg(2))
        XCTAssertTrue(rig.savedHashes.isEmpty)
    }

    func testAHashWithoutAnAppliedVersionDoesNotMakeItIdentical() throws {
        let rig = Rig(file: jpeg(1), cached: -1)
        rig.receivedHash = AvatarContentHash.hex(of: jpeg(2))
        XCTAssertEqual(try rig.makeApplier().apply(jpeg(2)), .applied(version: Int(rig.now.timeIntervalSince1970)))
    }

    func testAHashWithNoFileOnDiskDoesNotMakeItIdentical() throws {
        let rig = Rig(file: nil, cached: 5)
        rig.receivedHash = AvatarContentHash.hex(of: jpeg(2))
        XCTAssertEqual(try rig.makeApplier().apply(jpeg(2)), .applied(version: Int(rig.now.timeIntervalSince1970)))
    }

    func testAWriteFailureThrowsAndNothingIsRegistered() {
        let rig = Rig(file: jpeg(1), cached: 9)
        rig.failWrite = true
        XCTAssertThrowsError(try rig.makeApplier().apply(jpeg(2)))
        XCTAssertTrue(rig.versionsRegistered.isEmpty)
        XCTAssertEqual(rig.refreshes, 0)
        XCTAssertEqual(rig.cached, 9)
    }
}

final class AvatarImageGeometryTests: XCTestCase {

    private func jpeg(width: CGFloat, height: CGFloat) throws -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
    }

    func testLongAndShortSidesOfALandscapeAndAPortraitPicture() throws {
        XCTAssertEqual(AvatarImageGeometry.measure(try jpeg(width: 64, height: 32)), AvatarImageGeometry.Size(longSide: 64, shortSide: 32))
        XCTAssertEqual(AvatarImageGeometry.measure(try jpeg(width: 32, height: 64)), AvatarImageGeometry.Size(longSide: 64, shortSide: 32))
        XCTAssertEqual(AvatarImageGeometry.measure(try jpeg(width: 40, height: 40)), AvatarImageGeometry.Size(longSide: 40, shortSide: 40))
    }

    func testNotAPictureHasNoSize() {
        XCTAssertNil(AvatarImageGeometry.measure(Data([1, 2, 3, 4])))
        XCTAssertNil(AvatarImageGeometry.measure(Data()))
    }
}

final class AvatarReceivedLedgerTests: XCTestCase {

    func testRecordsTheLastHashPerSender() throws {
        let suite = "avatar-recv-ledger-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let ledger = AvatarReceivedLedger(defaults: defaults)
        XCTAssertNil(ledger.hash(fromPeer: "p"))
        ledger.save("H1", fromPeer: "p")
        ledger.save("H2", fromPeer: "q")
        XCTAssertEqual(ledger.hash(fromPeer: "p"), "H1")
        XCTAssertEqual(ledger.hash(fromPeer: "q"), "H2")
        ledger.save("H3", fromPeer: "p")
        XCTAssertEqual(ledger.hash(fromPeer: "p"), "H3")
        XCTAssertEqual(ledger.hash(fromPeer: "q"), "H2")
    }
}
