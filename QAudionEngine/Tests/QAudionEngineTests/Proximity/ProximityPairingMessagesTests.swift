import XCTest
import CryptoKit
@testable import QAudionEngine

/// Spec §8 message codec: round trips, KAT byte-identity, strict rejection,
/// and the idBlock / sealed-plaintext parsers used once a sealed box is open.
final class ProximityPairingMessagesTests: XCTestCase {

    private struct MessagesKatError: Error {
        let message: String
    }

    // MARK: - Helpers

    private static func hexDecode(_ text: String) -> Data? {
        let chars: [UInt8] = Array(text.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var index: Int = 0
        while index < chars.count {
            guard let high = nibble(chars[index]), let low = nibble(chars[index + 1]) else { return nil }
            let byte: UInt8 = (high << 4) | low
            out.append(byte)
            index += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x61 + 10
        case 0x41...0x46: return c - 0x41 + 10
        default: return nil
        }
    }

    private static func filled(_ count: Int, _ value: UInt8) -> Data {
        return Data(repeating: value, count: count)
    }

    private static func identity(userId: String, seed: UInt8) throws -> ProximityPeerIdentity {
        return try ProximityPeerIdentity(userId: userId,
                                         signingPublicKey: filled(32, seed),
                                         encryptionPublicKey: filled(32, seed &+ 1))
    }

    private static func sampleOffer() -> ProximityMessage.Offer {
        return ProximityMessage.Offer(mlKemPublicKey: filled(ProximityPairing.mlKemPublicKeyBytes, 0x11),
                                      displayerEphemeralX25519: filled(32, 0x22),
                                      displayerNonce: filled(32, 0x33))
    }

    /// A sealed box of the length a real one with an `n`-byte userId has.
    private static func sealedBytes(userIdBytes n: Int, _ value: UInt8) -> Data {
        return filled(ProximityPairing.sealedIdentityFixedBytes + n, value)
    }

    private static func sampleAccept() -> ProximityMessage.Accept {
        return ProximityMessage.Accept(mlKemCiphertext: filled(ProximityPairing.mlKemCiphertextBytes, 0x55),
                                       sealed: sealedBytes(userIdBytes: 7, 0x66))
    }

    private static func sampleHello() -> ProximityMessage.Hello {
        return ProximityMessage.Hello(frameIndex: 0x01020304,
                                      scannerEphemeralX25519: filled(32, 0x99),
                                      scannerNonce: filled(32, 0xAA),
                                      tag: filled(32, 0xBB))
    }

    private func loadExpected() throws -> [String: Any] {
        guard let url = Bundle.module.url(forResource: "proximity-pairing-kat", withExtension: "json") else {
            throw MessagesKatError(message: "proximity-pairing-kat.json not found")
        }
        let raw: Data = try Data(contentsOf: url)
        let object: Any = try JSONSerialization.jsonObject(with: raw, options: [])
        guard let root = object as? [String: Any] else {
            throw MessagesKatError(message: "malformed KAT")
        }
        var merged: [String: Any] = [:]
        if let inputs = root["inputs"] as? [String: Any] {
            for (key, value) in inputs {
                merged[key] = value
            }
        }
        if let expected = root["expected"] as? [String: Any] {
            for (key, value) in expected {
                merged[key] = value
            }
        }
        return merged
    }

    private func katHex(_ kat: [String: Any], _ key: String) throws -> Data {
        guard let text = kat[key] as? String, let data = ProximityPairingMessagesTests.hexDecode(text) else {
            throw MessagesKatError(message: "missing KAT hex " + key)
        }
        return data
    }

    private func katString(_ kat: [String: Any], _ key: String) throws -> String {
        guard let text = kat[key] as? String else {
            throw MessagesKatError(message: "missing KAT string " + key)
        }
        return text
    }

    private func isProtocolViolation(_ error: Error) -> Bool {
        guard let typed = error as? ProximityPairingError else { return false }
        if case .protocolViolation = typed { return true }
        return false
    }

    private func assertRejected(_ message: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ProximityMessage.decode(message), file: file, line: line) { (error: Error) in
            XCTAssertTrue(self.isProtocolViolation(error), file: file, line: line)
        }
    }

    private func assertIdBlockRejected(_ block: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ProximityMessage.decodeIdBlock(block), file: file, line: line) { (error: Error) in
            XCTAssertTrue(self.isProtocolViolation(error), file: file, line: line)
        }
    }

    private func assertPlaintextRejected(_ plaintext: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ProximityMessage.decodeSealedPlaintext(plaintext), file: file, line: line) {
            (error: Error) in
            XCTAssertTrue(self.isProtocolViolation(error), file: file, line: line)
        }
    }

    private func message(_ type: UInt8, _ body: Data) -> Data {
        var out = Data([type])
        out.append(body)
        return out
    }

    /// idBlock with a caller-chosen length field and userId bytes.
    private func rawIdBlock(lengthField: UInt16, userId: Data) -> Data {
        var block = Data()
        block.append(ProximityPairingMessagesTests.filled(32, 0x0A))
        block.append(ProximityPairingMessagesTests.filled(32, 0x0B))
        let high: UInt8 = UInt8(truncatingIfNeeded: lengthField >> 8)
        let low: UInt8 = UInt8(truncatingIfNeeded: lengthField)
        block.append(contentsOf: [high, low])
        block.append(userId)
        return block
    }

    /// idBlock ‖ sig[64] ‖ mac[32] with an extra `trailerDelta` bytes (negative: fewer).
    private func rawPlaintext(lengthField: UInt16, userId: Data, trailerDelta: Int = 0) -> Data {
        var plaintext: Data = rawIdBlock(lengthField: lengthField, userId: userId)
        let trailer: Int = ProximityPairing.ed25519SignatureBytes + ProximityPairing.macBytes + trailerDelta
        plaintext.append(ProximityPairingMessagesTests.filled(max(0, trailer), 0x0C))
        return plaintext
    }

    // MARK: - Round trips

    func testHelloRoundTrip() throws {
        let hello: ProximityMessage.Hello = ProximityPairingMessagesTests.sampleHello()
        let encoded: Data = ProximityMessage.hello(hello).encoded()
        XCTAssertEqual(encoded.count, 1 + ProximityPairing.helloBodyBytes)
        XCTAssertEqual(encoded.first, ProximityPairing.MessageType.hello.rawValue)
        let prefix: [UInt8] = [0x01, 0x01, 0x02, 0x03, 0x04]
        XCTAssertEqual(Array(encoded.prefix(5)), prefix)
        XCTAssertEqual(try ProximityMessage.decode(encoded), .hello(hello))
    }

    func testOfferRoundTripCarriesEphemeralKeysOnly() throws {
        let offer: ProximityMessage.Offer = ProximityPairingMessagesTests.sampleOffer()
        let encoded: Data = ProximityMessage.offer(offer).encoded()
        XCTAssertEqual(ProximityPairing.offerBodyBytes, 1568 + 32 + 32)
        XCTAssertEqual(encoded.count, 1 + ProximityPairing.offerBodyBytes)
        XCTAssertEqual(try ProximityMessage.decode(encoded), .offer(offer))
        let body: Data = encoded.subdata(in: 1..<encoded.count)
        XCTAssertEqual(ProximityMessage.offerBody(offer), body)
    }

    func testAcceptRoundTrip() throws {
        let accept: ProximityMessage.Accept = ProximityPairingMessagesTests.sampleAccept()
        let encoded: Data = ProximityMessage.accept(accept).encoded()
        // spec §8: ACCEPT body = 1746 + n.
        XCTAssertEqual(encoded.count, 1 + 1746 + 7)
        XCTAssertEqual(try ProximityMessage.decode(encoded), .accept(accept))
        let ct: Data = encoded.subdata(in: 1..<(1 + ProximityPairing.mlKemCiphertextBytes))
        XCTAssertEqual(ct, accept.mlKemCiphertext)
        let sealed: Data = encoded.subdata(in: (1 + ProximityPairing.mlKemCiphertextBytes)..<encoded.count)
        XCTAssertEqual(sealed, accept.sealed)
    }

    func testFinishConfirmAbortBusyRoundTrip() throws {
        let finish = ProximityMessage.finish(ProximityMessage.Finish(
            sealed: ProximityPairingMessagesTests.sealedBytes(userIdBytes: 5, 0x10)))
        let finishBytes: Data = finish.encoded()
        // spec §8: FINISH body = 178 + n.
        XCTAssertEqual(finishBytes.count, 1 + 178 + 5)
        XCTAssertEqual(try ProximityMessage.decode(finishBytes), finish)

        let confirm = ProximityMessage.confirm(mac: ProximityPairingMessagesTests.filled(32, 0x30))
        let confirmBytes: Data = confirm.encoded()
        XCTAssertEqual(confirmBytes.count, 33)
        XCTAssertEqual(try ProximityMessage.decode(confirmBytes), confirm)

        let abort = ProximityMessage.abort(reason: 8)
        let abortBytes: Data = abort.encoded()
        let expectedAbort: Data = Data([0x06, 0x08])
        XCTAssertEqual(abortBytes, expectedAbort)
        XCTAssertEqual(try ProximityMessage.decode(abortBytes), abort)

        let busyBytes: Data = ProximityMessage.busy.encoded()
        let expectedBusy: Data = Data([0x07])
        XCTAssertEqual(busyBytes, expectedBusy)
        XCTAssertEqual(try ProximityMessage.decode(busyBytes), ProximityMessage.busy)
    }

    func testLargestMessagesFitTheFramingCap() {
        let maxAccept: Int = 1 + ProximityPairing.mlKemCiphertextBytes + ProximityMessage.maxSealedBytes
        XCTAssertEqual(maxAccept, 1 + 1746 + 256)
        XCTAssertLessThanOrEqual(maxAccept, ProximityPairing.maxMessageBytes)
        XCTAssertEqual(ProximityMessage.minSealedBytes, 179)
        XCTAssertEqual(ProximityMessage.maxSealedBytes, 434)
    }

    func testDecodeAcceptsSliceWithNonZeroStartIndex() throws {
        let hello: ProximityMessage.Hello = ProximityPairingMessagesTests.sampleHello()
        var padded = Data([0xEE, 0xEE, 0xEE])
        padded.append(ProximityMessage.hello(hello).encoded())
        let slice: Data = padded[3...]
        XCTAssertEqual(slice.startIndex, 3)
        XCTAssertEqual(try ProximityMessage.decode(slice), .hello(hello))

        let accept: ProximityMessage.Accept = ProximityPairingMessagesTests.sampleAccept()
        var paddedAccept = Data([0xEE])
        paddedAccept.append(ProximityMessage.accept(accept).encoded())
        let acceptSlice: Data = paddedAccept[1...]
        XCTAssertEqual(try ProximityMessage.decode(acceptSlice), .accept(accept))
    }

    // MARK: - idBlock and sealed plaintext

    func testIdBlockRoundTrip() throws {
        let identity: ProximityPeerIdentity = try ProximityPairingMessagesTests.identity(userId: "user.A-1_x", seed: 0x44)
        let block: Data = ProximityMessage.idBlock(identity)
        XCTAssertEqual(block.count, ProximityPairing.idBlockFixedBytes + 10)
        XCTAssertEqual(Data(block.prefix(32)), identity.signingPublicKey)
        XCTAssertEqual(block.subdata(in: 32..<64), identity.encryptionPublicKey)
        XCTAssertEqual(Array(block.subdata(in: 64..<66)), [0x00, 0x0A])
        XCTAssertEqual(try ProximityMessage.decodeIdBlock(block), identity)

        // A slice with a non-zero startIndex parses the same.
        var padded = Data([0xEE, 0xEE])
        padded.append(block)
        XCTAssertEqual(try ProximityMessage.decodeIdBlock(padded[2...]), identity)
    }

    func testSealedPlaintextRoundTrip() throws {
        let identity: ProximityPeerIdentity = try ProximityPairingMessagesTests.identity(userId: "abc", seed: 0x70)
        let block: Data = ProximityMessage.idBlock(identity)
        let signature: Data = ProximityPairingMessagesTests.filled(64, 0x71)
        let mac: Data = ProximityPairingMessagesTests.filled(32, 0x72)
        let plaintext: Data = ProximityMessage.sealedPlaintext(idBlock: block, signature: signature, mac: mac)
        // spec §8: the opened plaintext is exactly 66 + n + 96.
        XCTAssertEqual(plaintext.count, 66 + 3 + 96)
        let opened: ProximityMessage.SealedIdentity = try ProximityMessage.decodeSealedPlaintext(plaintext)
        XCTAssertEqual(opened.identity, identity)
        XCTAssertEqual(opened.idBlock, block)
        XCTAssertEqual(opened.signature, signature)
        XCTAssertEqual(opened.mac, mac)

        // Longest userId the grammar allows.
        let longest: ProximityPeerIdentity = try ProximityPairingMessagesTests.identity(
            userId: String(repeating: "z", count: 256), seed: 0x73)
        let longPlaintext: Data = ProximityMessage.sealedPlaintext(idBlock: ProximityMessage.idBlock(longest),
                                                                   signature: signature, mac: mac)
        XCTAssertEqual(try ProximityMessage.decodeSealedPlaintext(longPlaintext).identity, longest)
    }

    func testRejectsMalformedIdBlock() {
        let valid: Data = rawIdBlock(lengthField: 3, userId: Data("abc".utf8))
        XCTAssertNoThrow(try ProximityMessage.decodeIdBlock(valid))

        var trailing: Data = valid
        trailing.append(0x00)
        assertIdBlockRejected(trailing)
        assertIdBlockRejected(valid.subdata(in: 0..<(valid.count - 1)))
        assertIdBlockRejected(rawIdBlock(lengthField: 4, userId: Data("abc".utf8)))
        assertIdBlockRejected(rawIdBlock(lengthField: 2, userId: Data("abc".utf8)))
        assertIdBlockRejected(rawIdBlock(lengthField: 0, userId: Data()))
        assertIdBlockRejected(rawIdBlock(lengthField: 257, userId: Data(repeating: 0x61, count: 257)))
        XCTAssertNoThrow(try ProximityMessage.decodeIdBlock(rawIdBlock(lengthField: 256,
                                                                       userId: Data(repeating: 0x61, count: 256))))
        // Invalid UTF-8.
        assertIdBlockRejected(rawIdBlock(lengthField: 2, userId: Data([0xC3, 0x28])))
        assertIdBlockRejected(rawIdBlock(lengthField: 1, userId: Data([0xFF])))
        // Valid UTF-8 outside the §8 grammar: padding, NBSP, zero-width, separators.
        let outsideGrammar: [Data] = [Data(" abc".utf8), Data("abc ".utf8), Data("a\u{00A0}b".utf8),
                                      Data("a\u{200B}b".utf8), Data("a|b".utf8), Data("a:b".utf8),
                                      Data("\u{00FC}".utf8), Data([0x61, 0x00])]
        for userId in outsideGrammar {
            let n: UInt16 = UInt16(userId.count)
            assertIdBlockRejected(rawIdBlock(lengthField: n, userId: userId))
        }
        // Keys only, no length field; nothing at all.
        assertIdBlockRejected(ProximityPairingMessagesTests.filled(64, 1))
        assertIdBlockRejected(Data())
    }

    func testRejectsMalformedSealedPlaintext() {
        let valid: Data = rawPlaintext(lengthField: 2, userId: Data("id".utf8))
        XCTAssertNoThrow(try ProximityMessage.decodeSealedPlaintext(valid))

        // One byte too many or too few after the idBlock.
        assertPlaintextRejected(rawPlaintext(lengthField: 2, userId: Data("id".utf8), trailerDelta: 1))
        assertPlaintextRejected(rawPlaintext(lengthField: 2, userId: Data("id".utf8), trailerDelta: -1))
        // The length field disagrees with where sig ‖ mac start.
        assertPlaintextRejected(rawPlaintext(lengthField: 3, userId: Data("id".utf8)))
        assertPlaintextRejected(rawPlaintext(lengthField: 1, userId: Data("id".utf8)))
        // n out of range.
        assertPlaintextRejected(rawPlaintext(lengthField: 0, userId: Data()))
        assertPlaintextRejected(rawPlaintext(lengthField: 257, userId: Data(repeating: 0x62, count: 257)))
        // Userid encoding / grammar.
        assertPlaintextRejected(rawPlaintext(lengthField: 1, userId: Data([0x80])))
        assertPlaintextRejected(rawPlaintext(lengthField: 3, userId: Data("a|b".utf8)))
        // Too short to hold anything.
        assertPlaintextRejected(ProximityPairingMessagesTests.filled(66 + 96, 0x01))
        assertPlaintextRejected(Data())
    }

    // MARK: - KAT

    func testKatHelloMessageDecodesAndReencodes() throws {
        let kat: [String: Any] = try loadExpected()
        let helloMessage: Data = try katHex(kat, "helloMessage")
        let decoded: ProximityMessage = try ProximityMessage.decode(helloMessage)
        guard case .hello(let hello) = decoded else {
            XCTFail("not a HELLO")
            return
        }
        XCTAssertEqual(hello.frameIndex, 7)
        XCTAssertEqual(hello.scannerEphemeralX25519, try katHex(kat, "scannerEphemeralX25519"))
        XCTAssertEqual(hello.scannerNonce, try katHex(kat, "scannerNonce"))
        XCTAssertEqual(hello.tag, try katHex(kat, "helloTag"))
        XCTAssertEqual(decoded.encoded(), helloMessage)
        XCTAssertEqual(ProximityMessage.helloBody(hello), try katHex(kat, "helloBody"))
    }

    func testKatOfferMessageDecodesAndReencodes() throws {
        let kat: [String: Any] = try loadExpected()
        let offerMessage: Data = try katHex(kat, "offerMessage")
        XCTAssertEqual(offerMessage.count, 1 + ProximityPairing.offerBodyBytes)
        let decoded: ProximityMessage = try ProximityMessage.decode(offerMessage)
        guard case .offer(let offer) = decoded else {
            XCTFail("not an OFFER")
            return
        }
        XCTAssertEqual(offer.mlKemPublicKey, try katHex(kat, "displayerMlKemPublicKey"))
        XCTAssertEqual(offer.displayerEphemeralX25519, try katHex(kat, "displayerEphemeralX25519"))
        XCTAssertEqual(offer.displayerNonce, try katHex(kat, "displayerNonce"))
        XCTAssertEqual(decoded.encoded(), offerMessage)
        XCTAssertEqual(ProximityMessage.offerBody(offer), try katHex(kat, "offerBody"))

        // No identity on the air in clear: neither the displayer's keys nor its userId.
        XCTAssertNil(offerMessage.range(of: try katHex(kat, "displayerSigningPublicKey")))
        XCTAssertNil(offerMessage.range(of: try katHex(kat, "displayerEncryptionPublicKey")))
        XCTAssertNil(offerMessage.range(of: Data(try katString(kat, "displayerUserId").utf8)))
    }

    func testKatIdBlocks() throws {
        let kat: [String: Any] = try loadExpected()
        let scanner = try ProximityPeerIdentity(userId: try katString(kat, "scannerUserId"),
                                                signingPublicKey: try katHex(kat, "scannerSigningPublicKey"),
                                                encryptionPublicKey: try katHex(kat, "scannerEncryptionPublicKey"))
        let displayer = try ProximityPeerIdentity(userId: try katString(kat, "displayerUserId"),
                                                  signingPublicKey: try katHex(kat, "displayerSigningPublicKey"),
                                                  encryptionPublicKey: try katHex(kat, "displayerEncryptionPublicKey"))
        XCTAssertEqual(ProximityMessage.idBlock(scanner), try katHex(kat, "scannerIdBlock"))
        XCTAssertEqual(ProximityMessage.idBlock(displayer), try katHex(kat, "displayerIdBlock"))
        XCTAssertEqual(try ProximityMessage.decodeIdBlock(try katHex(kat, "scannerIdBlock")), scanner)
        XCTAssertEqual(try ProximityMessage.decodeIdBlock(try katHex(kat, "displayerIdBlock")), displayer)
    }

    func testKatAcceptFinishConfirmAbortBusyLayouts() throws {
        let kat: [String: Any] = try loadExpected()
        let acceptMessage: Data = try katHex(kat, "acceptMessage")
        let decodedAccept: ProximityMessage = try ProximityMessage.decode(acceptMessage)
        guard case .accept(let accept) = decodedAccept else {
            XCTFail("not an ACCEPT")
            return
        }
        XCTAssertEqual(accept.mlKemCiphertext, try katHex(kat, "mlKemCiphertext"))
        XCTAssertEqual(accept.sealed, try katHex(kat, "sealedScanner"))
        XCTAssertEqual(decodedAccept.encoded(), acceptMessage)
        let userIdS: Int = Data(try katString(kat, "scannerUserId").utf8).count
        XCTAssertEqual(acceptMessage.count, 1 + 1746 + userIdS)
        XCTAssertNil(acceptMessage.range(of: try katHex(kat, "scannerSigningPublicKey")))
        XCTAssertNil(acceptMessage.range(of: Data(try katString(kat, "scannerUserId").utf8)))

        let finishMessage: Data = try katHex(kat, "finishMessage")
        let decodedFinish: ProximityMessage = try ProximityMessage.decode(finishMessage)
        guard case .finish(let finish) = decodedFinish else {
            XCTFail("not a FINISH")
            return
        }
        XCTAssertEqual(finish.sealed, try katHex(kat, "sealedDisplayer"))
        XCTAssertEqual(finish.sealed, try katHex(kat, "finishBody"))
        XCTAssertEqual(decodedFinish.encoded(), finishMessage)
        let userIdD: Int = Data(try katString(kat, "displayerUserId").utf8).count
        XCTAssertEqual(finishMessage.count, 1 + 178 + userIdD)
        XCTAssertNil(finishMessage.range(of: try katHex(kat, "displayerSigningPublicKey")))
        XCTAssertNil(finishMessage.range(of: Data(try katString(kat, "displayerUserId").utf8)))

        let confirmMessage: Data = try katHex(kat, "confirmMessageScanner")
        let decodedConfirm: ProximityMessage = try ProximityMessage.decode(confirmMessage)
        XCTAssertEqual(decodedConfirm, .confirm(mac: try katHex(kat, "confirmMacScanner")))
        XCTAssertEqual(decodedConfirm.encoded(), confirmMessage)

        let abortMessage: Data = try katHex(kat, "abortMessageUserRejected")
        XCTAssertEqual(try ProximityMessage.decode(abortMessage),
                       .abort(reason: ProximityPairing.AbortReason.userRejected.rawValue))
        XCTAssertEqual(ProximityMessage.abort(reason: 1).encoded(), abortMessage)
        let busyMessage: Data = try katHex(kat, "busyMessage")
        XCTAssertEqual(try ProximityMessage.decode(busyMessage), .busy)
        XCTAssertEqual(ProximityMessage.busy.encoded(), busyMessage)
    }

    func testKatUserIdGrammar() throws {
        guard let url = Bundle.module.url(forResource: "proximity-pairing-kat", withExtension: "json") else {
            throw MessagesKatError(message: "proximity-pairing-kat.json not found")
        }
        let raw: Data = try Data(contentsOf: url)
        let root: [String: Any]? = try JSONSerialization.jsonObject(with: raw, options: []) as? [String: Any]
        guard let userIds = root?["userIds"] as? [String: Any],
              let valid = userIds["valid"] as? [String],
              let invalid = userIds["invalid"] as? [String] else {
            throw MessagesKatError(message: "missing userIds vectors")
        }
        XCTAssertFalse(valid.isEmpty)
        XCTAssertFalse(invalid.isEmpty)
        for userId in valid {
            XCTAssertTrue(ProximityPairing.isValidUserId(userId), userId)
            XCTAssertNoThrow(try ProximityPeerIdentity(userId: userId,
                                                       signingPublicKey: ProximityPairingMessagesTests.filled(32, 1),
                                                       encryptionPublicKey: ProximityPairingMessagesTests.filled(32, 2)))
            let block: Data = rawIdBlock(lengthField: UInt16(Data(userId.utf8).count), userId: Data(userId.utf8))
            XCTAssertNoThrow(try ProximityMessage.decodeIdBlock(block), userId)
        }
        for userId in invalid {
            XCTAssertFalse(ProximityPairing.isValidUserId(userId), userId.debugDescription)
            XCTAssertThrowsError(try ProximityPeerIdentity(userId: userId,
                                                           signingPublicKey: ProximityPairingMessagesTests.filled(32, 1),
                                                           encryptionPublicKey: ProximityPairingMessagesTests.filled(32, 2)))
            let bytes: Data = Data(userId.utf8)
            let block: Data = rawIdBlock(lengthField: UInt16(truncatingIfNeeded: bytes.count), userId: bytes)
            assertIdBlockRejected(block)
        }
    }

    // MARK: - Rejections

    func testRejectsEmptyAndUnknownTypes() {
        assertRejected(Data())
        assertRejected(Data([0x00]))
        assertRejected(Data([0x08]))
        assertRejected(Data([0xFF]))
        var tooLarge = Data([0x02])
        tooLarge.append(ProximityPairingMessagesTests.filled(ProximityPairing.maxMessageBytes, 0))
        assertRejected(tooLarge)
    }

    func testRejectsWrongHelloLength() {
        assertRejected(message(0x01, ProximityPairingMessagesTests.filled(99, 1)))
        assertRejected(message(0x01, ProximityPairingMessagesTests.filled(101, 1)))
        assertRejected(message(0x01, Data()))
    }

    func testRejectsOfferOfAnyOtherLength() throws {
        let valid: Data = ProximityMessage.offer(ProximityPairingMessagesTests.sampleOffer()).encoded()
        XCTAssertNoThrow(try ProximityMessage.decode(valid))

        // Trailing byte / truncated.
        var trailing: Data = valid
        trailing.append(0x00)
        assertRejected(trailing)
        assertRejected(valid.subdata(in: 0..<(valid.count - 1)))
        // An OFFER that still carries an identity (the pre-SIGMA layout) is rejected.
        let identity: ProximityPeerIdentity = try ProximityPairingMessagesTests.identity(userId: "displayer", seed: 0x44)
        var withIdentity: Data = valid
        withIdentity.append(ProximityMessage.idBlock(identity))
        assertRejected(withIdentity)
        // Keys only, or nothing.
        assertRejected(message(0x02, ProximityPairingMessagesTests.filled(ProximityPairing.mlKemPublicKeyBytes, 0)))
        assertRejected(message(0x02, Data()))
    }

    func testRejectsAcceptWhoseSealedPartCannotBeABox() {
        let ct: Data = ProximityPairingMessagesTests.filled(ProximityPairing.mlKemCiphertextBytes, 1)
        func accept(sealedBytes count: Int) -> Data {
            var body: Data = ct
            body.append(ProximityPairingMessagesTests.filled(count, 2))
            return message(0x03, body)
        }
        // n = 1 and n = 256 are the bounds.
        XCTAssertNoThrow(try ProximityMessage.decode(accept(sealedBytes: 179)))
        XCTAssertNoThrow(try ProximityMessage.decode(accept(sealedBytes: 434)))
        // n = 0, n = 257.
        assertRejected(accept(sealedBytes: 178))
        assertRejected(accept(sealedBytes: 435))
        // The old signed-but-clear layout for a 2-byte userId (ct ‖ 66 + 2 ‖ 96).
        assertRejected(accept(sealedBytes: 66 + 2 + 96))
        // Ciphertext only, ciphertext short, nothing.
        assertRejected(message(0x03, ct))
        assertRejected(message(0x03, Data(ct.prefix(1000))))
        assertRejected(message(0x03, ProximityPairingMessagesTests.filled(10, 0)))
        assertRejected(message(0x03, Data()))
    }

    func testRejectsFinishWhoseLengthCannotBeABox() {
        XCTAssertNoThrow(try ProximityMessage.decode(message(0x04, ProximityPairingMessagesTests.filled(179, 0))))
        XCTAssertNoThrow(try ProximityMessage.decode(message(0x04, ProximityPairingMessagesTests.filled(434, 0))))
        assertRejected(message(0x04, ProximityPairingMessagesTests.filled(178, 0)))
        assertRejected(message(0x04, ProximityPairingMessagesTests.filled(435, 0)))
        // The old `sig ‖ mac` FINISH.
        assertRejected(message(0x04, ProximityPairingMessagesTests.filled(96, 0)))
        assertRejected(message(0x04, Data()))
    }

    func testRejectsWrongFixedLengths() {
        assertRejected(message(0x05, ProximityPairingMessagesTests.filled(31, 0)))
        assertRejected(message(0x05, ProximityPairingMessagesTests.filled(33, 0)))
        assertRejected(message(0x05, Data()))
        assertRejected(message(0x06, Data()))
        assertRejected(message(0x06, Data([1, 2])))
        assertRejected(message(0x07, Data([0])))
    }
}
