import XCTest
import UIKit
@testable import QAudionApp

/// Ridurre traffico e riapplicazioni dell'avatar: la decisione di rinvio (`AvatarAnnouncePolicy`), il registro di cio' che e' stato
/// inviato (`AvatarSentLedger`), il controllo di completezza dei byte ricevuti (`AvatarImageIntegrity`) e l'applicazione di un avatar
/// ricevuto (`AvatarInboundApplier`). Tutto puro: nessun Keychain, nessuna rete, nessun file vero; l'orologio e' un argomento e il
/// registro usa un dominio `UserDefaults` privato.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
final class AvatarAnnouncePolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 3_000_000)
    private let hour: TimeInterval = 3_600

    private func decide(
        _ trigger: AvatarAnnounceCoordinator.Trigger,
        version: Int = 5,
        priorVersion: Int = 5,
        sentAgo: TimeInterval? = 60,
        priorKey: String? = "AAAA",
        key: String = "AAAA"
    ) -> AvatarAnnouncePolicy.Verdict {
        let sentAt: Date? = sentAgo.map { t0.addingTimeInterval(-$0) }
        return AvatarAnnouncePolicy.decide(
            trigger: trigger, version: version, priorVersion: priorVersion, priorSentAt: sentAt,
            priorPairKey: priorKey, currentPairKey: key, now: t0)
    }

    // MARK: - lo scambio chiavi

    /// Il caso tipico: stessa versione, stessa chiave, il contatto ha gia' ricevuto l'avatar. Non si rimanda, qualunque
    /// sia l'eta' dell'ultimo invio (il rinvio di auto-guarigione e' a carico degli altri trigger).
    func testKeyExchangeWithSameVersionAndSameKeySendsNothing() {
        XCTAssertEqual(decide(.keyExchange, sentAgo: 21), .skip(.pairKeyUnchanged))
        XCTAssertEqual(decide(.keyExchange, sentAgo: 30 * 24 * hour), .skip(.pairKeyUnchanged))
    }

    func testKeyExchangeWithChangedKeySendsEvenInsideTheCooldown() {
        XCTAssertEqual(decide(.keyExchange, sentAgo: 21, key: "BBBB"), .send(.pairKeyChanged))
    }

    func testKeyExchangeAfterTheKeyDisappearedAndCameBackDifferentSends() {
        XCTAssertEqual(decide(.keyExchange, priorKey: AvatarSentLedger.noPairKey, key: "BBBB"), .send(.pairKeyChanged))
        XCTAssertEqual(decide(.keyExchange, priorKey: "AAAA", key: AvatarSentLedger.noPairKey), .send(.pairKeyChanged))
    }

    func testKeyExchangeWithNewerVersionSendsEvenWithSameKey() {
        XCTAssertEqual(decide(.keyExchange, version: 6, priorVersion: 5), .send(.versionAhead))
    }

    func testKeyExchangeToAContactThatNeverGotTheAvatarSends() {
        XCTAssertEqual(decide(.keyExchange, priorVersion: -1, sentAgo: nil, priorKey: nil), .send(.versionAhead))
    }

    /// Un invio fatto prima che si registrasse la chiave non si riconosce come "invariato": decide solo il cooldown, cosi'
    /// all'aggiornamento non parte un rinvio a tutti i contatti.
    func testKeyExchangeWithNoRecordedKeyFallsBackToTheCooldown() {
        XCTAssertEqual(decide(.keyExchange, sentAgo: hour, priorKey: nil), .skip(.withinCooldown))
        XCTAssertEqual(decide(.keyExchange, sentAgo: 6 * hour, priorKey: nil), .send(.cooldownElapsed))
    }

    // MARK: - il cooldown

    func testCooldownValues() {
        XCTAssertEqual(AvatarAnnouncePolicy.cooldownSec(for: .callConnect), 6 * hour)
        XCTAssertEqual(AvatarAnnouncePolicy.cooldownSec(for: .keyExchange), 6 * hour)
        XCTAssertEqual(AvatarAnnouncePolicy.cooldownSec(for: .chatDecrypt), hour)
        XCTAssertEqual(AvatarAnnouncePolicy.cooldownSec(for: .avatarChanged), 0)
    }

    func testCallConnectRespectsTheNewCooldownAtItsEdges() {
        XCTAssertEqual(decide(.callConnect, sentAgo: 120), .skip(.withinCooldown))
        XCTAssertEqual(decide(.callConnect, sentAgo: 6 * hour - 1), .skip(.withinCooldown))
        XCTAssertEqual(decide(.callConnect, sentAgo: 6 * hour), .send(.cooldownElapsed))
        XCTAssertEqual(decide(.callConnect, sentAgo: 7 * hour), .send(.cooldownElapsed))
    }

    func testCallConnectWithChangedKeySendsInsideTheCooldown() {
        XCTAssertEqual(decide(.callConnect, sentAgo: 120, key: "BBBB"), .send(.pairKeyChanged))
    }

    func testCallConnectToAContactWithNoSendTimeSends() {
        XCTAssertEqual(decide(.callConnect, sentAgo: nil), .send(.cooldownElapsed))
    }

    func testChatDecryptKeepsItsOwnHourlyCooldown() {
        XCTAssertEqual(decide(.chatDecrypt, sentAgo: hour - 1), .skip(.withinCooldown))
        XCTAssertEqual(decide(.chatDecrypt, sentAgo: hour), .send(.cooldownElapsed))
    }

    func testAvatarChangedAlwaysSends() {
        XCTAssertEqual(decide(.avatarChanged, sentAgo: 1), .send(.noCooldown))
        XCTAssertEqual(decide(.avatarChanged, version: 6, priorVersion: 5, sentAgo: 1), .send(.versionAhead))
    }

    /// Il ciclo di una chiamata, come lo guida il coordinatore: registro e orologio iniettato. Alla connessione si invia; allo
    /// scambio chiavi 21 s dopo la fine non si rimanda; alla chiamata dopo (un'ora dopo) non si rimanda; sei ore dopo si'.
    func testACallCycleSendsOnceThenWaitsForTheCooldown() throws {
        let suite = "avatar-reduction-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let ledger = AvatarSentLedger(defaults: defaults)
        let peer = "11111111-2222-3333-4444-555555555555"

        func verdict(_ trigger: AvatarAnnounceCoordinator.Trigger, at now: Date, key: String = "AAAA") -> AvatarAnnouncePolicy.Verdict {
            AvatarAnnouncePolicy.decide(
                trigger: trigger, version: 5, priorVersion: ledger.lastVersionSent(toPeer: peer),
                priorSentAt: ledger.lastSentAt(toPeer: peer), priorPairKey: ledger.lastPairKey(toPeer: peer),
                currentPairKey: key, now: now)
        }

        XCTAssertEqual(verdict(.callConnect, at: t0), .send(.versionAhead))
        ledger.markSent(version: 5, pairKey: "AAAA", toPeer: peer, at: t0)

        XCTAssertEqual(verdict(.keyExchange, at: t0.addingTimeInterval(21 + 600)), .skip(.pairKeyUnchanged))
        XCTAssertEqual(verdict(.callConnect, at: t0.addingTimeInterval(hour)), .skip(.withinCooldown))
        XCTAssertEqual(verdict(.callConnect, at: t0.addingTimeInterval(6 * hour)), .send(.cooldownElapsed))
        XCTAssertEqual(verdict(.keyExchange, at: t0.addingTimeInterval(hour), key: "BBBB"), .send(.pairKeyChanged))
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
        XCTAssertNil(ledger.lastPairKey(toPeer: "p"))
    }

    func testMarkSentRecordsVersionTimeAndKeyPerPeer() throws {
        let (ledger, _) = try makeLedger()
        let at = Date(timeIntervalSince1970: 4_000_000)
        ledger.markSent(version: 7, pairKey: "AAAA", toPeer: "p", at: at)
        ledger.markSent(version: 3, pairKey: "BBBB", toPeer: "q", at: at.addingTimeInterval(10))
        XCTAssertEqual(ledger.lastVersionSent(toPeer: "p"), 7)
        XCTAssertEqual(ledger.lastSentAt(toPeer: "p"), at)
        XCTAssertEqual(ledger.lastPairKey(toPeer: "p"), "AAAA")
        XCTAssertEqual(ledger.lastVersionSent(toPeer: "q"), 3)
        XCTAssertEqual(ledger.lastPairKey(toPeer: "q"), "BBBB")
    }

    /// Lo stato scritto prima di questa modifica (solo versione e ora, con le stesse chiavi) resta valido e non ha una chiave.
    func testStateWrittenBeforeTheKeyWasRecordedIsStillRead() throws {
        let (ledger, defaults) = try makeLedger()
        defaults.set(["p": 4], forKey: AvatarSentLedger.versionsKey)
        defaults.set(["p": 5_000_000.0], forKey: AvatarSentLedger.sentAtKey)
        XCTAssertEqual(ledger.lastVersionSent(toPeer: "p"), 4)
        XCTAssertEqual(ledger.lastSentAt(toPeer: "p"), Date(timeIntervalSince1970: 5_000_000))
        XCTAssertNil(ledger.lastPairKey(toPeer: "p"))
    }

    func testMarkSentOverwritesTheKey() throws {
        let (ledger, _) = try makeLedger()
        ledger.markSent(version: 7, pairKey: "AAAA", toPeer: "p", at: Date(timeIntervalSince1970: 1))
        ledger.markSent(version: 7, pairKey: "BBBB", toPeer: "p", at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(ledger.lastPairKey(toPeer: "p"), "BBBB")
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
                now: { [unowned self] in self.now })
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

    func testAWriteFailureThrowsAndNothingIsRegistered() {
        let rig = Rig(file: jpeg(1), cached: 9)
        rig.failWrite = true
        XCTAssertThrowsError(try rig.makeApplier().apply(jpeg(2)))
        XCTAssertTrue(rig.versionsRegistered.isEmpty)
        XCTAssertEqual(rig.refreshes, 0)
        XCTAssertEqual(rig.cached, 9)
    }
}
