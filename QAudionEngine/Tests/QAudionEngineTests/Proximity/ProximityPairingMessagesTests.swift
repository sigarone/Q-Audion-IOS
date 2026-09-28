import XCTest
import CryptoKit
@testable import QAudionEngine

/// Spec §8 message codec: round trips, KAT byte-identity, strict rejection.
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

    private static func sampleOffer() throws -> ProximityMessage.Offer {
        return ProximityMessage.Offer(mlKemPublicKey: filled(ProximityPairing.mlKemPublicKeyBytes, 0x11),
                                      displayerEphemeralX25519: filled(32, 0x22),
                                      displayerNonce: filled(32, 0x33),
                                      identity: try identity(userId: "displayer-ü", seed: 0x44))
    }

    private static func sampleAccept() throws -> ProximityMessage.Accept {
        return ProximityMessage.Accept(mlKemCiphertext: filled(ProximityPairing.mlKemCiphertextBytes, 0x55),
                                       identity: try identity(userId: "scanner", seed: 0x66),
                                       signature: filled(64, 0x77),
                                       mac: filled(32, 0x88))
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
            throw MessagesKatError(message: "missing KAT hex")
        }
        return data
    }

    private func katString(_ kat: [String: Any], _ key: String) throws -> String {
        guard let text = kat[key] as? String else {
            throw MessagesKatError(message: "missing KAT string")
        }
        return text
    }

    private func assertRejected(_ message: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ProximityMessage.decode(message), file: file, line: line) { (error: Error) in
            let typed: ProximityPairingError? = error as? ProximityPairingError
            var isViolation: Bool = false
            if let typedError = typed, case .protocolViolation = typedError {
                isViolation = true
            }
            XCTAssertTrue(isViolation, file: file, line: line)
        }
    }

    private func message(_ type: UInt8, _ body: Data) -> Data {
        var out = Data([type])
        out.append(body)
        return out
    }

    /// OFFER body with a caller-chosen length field and userId bytes.
    private func offerBody(lengthField: UInt16, userId: Data) -> Data {
        var body = Data()
        body.append(ProximityPairingMessagesTests.filled(ProximityPairing.mlKemPublicKeyBytes, 1))
        body.append(ProximityPairingMessagesTests.filled(32 * 4, 2))
        let high: UInt8 = UInt8(truncatingIfNeeded: lengthField >> 8)
        let low: UInt8 = UInt8(truncatingIfNeeded: lengthField)
        body.append(contentsOf: [high, low])
        body.append(userId)
        return body
    }

    /// ACCEPT body with a caller-chosen length field, userId bytes and trailer length.
    private func acceptBody(lengthField: UInt16, userId: Data, trailerBytes: Int) -> Data {
        var body = Data()
        body.append(ProximityPairingMessagesTests.filled(ProximityPairing.mlKemCiphertextBytes, 1))
        body.append(ProximityPairingMessagesTests.filled(64, 2))
        let high: UInt8 = UInt8(truncatingIfNeeded: lengthField >> 8)
        let low: UInt8 = UInt8(truncatingIfNeeded: lengthField)
        body.append(contentsOf: [high, low])
        body.append(userId)
        body.append(ProximityPairingMessagesTests.filled(trailerBytes, 3))
        return body
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

    func testOfferRoundTrip() throws {
        let offer: ProximityMessage.Offer = try ProximityPairingMessagesTests.sampleOffer()
        let encoded: Data = ProximityMessage.offer(offer).encoded()
        let userIdCount: Int = Data("displayer-ü".utf8).count
        let expectedCount: Int = 1 + 1568 + 32 * 4 + 2 + userIdCount
        XCTAssertEqual(encoded.count, expectedCount)
        XCTAssertEqual(try ProximityMessage.decode(encoded), .offer(offer))
        let body: Data = encoded.subdata(in: 1..<encoded.count)
        XCTAssertEqual(ProximityMessage.offerBody(offer), body)
    }

    func testAcceptRoundTrip() throws {
        let accept: ProximityMessage.Accept = try ProximityPairingMessagesTests.sampleAccept()
        let encoded: Data = ProximityMessage.accept(accept).encoded()
        let expectedCount: Int = 1 + 1568 + 64 + 2 + 7 + 96
        XCTAssertEqual(encoded.count, expectedCount)
        XCTAssertEqual(try ProximityMessage.decode(encoded), .accept(accept))
        let unsigned: Data = ProximityMessage.acceptUnsignedBody(mlKemCiphertext: accept.mlKemCiphertext,
                                                                 identity: accept.identity)
        let expectedUnsigned: Data = encoded.subdata(in: 1..<(encoded.count - 96))
        XCTAssertEqual(unsigned, expectedUnsigned)
    }

    func testFinishConfirmAbortBusyRoundTrip() throws {
        let finish = ProximityMessage.finish(ProximityMessage.Finish(
            signature: ProximityPairingMessagesTests.filled(64, 0x10),
            mac: ProximityPairingMessagesTests.filled(32, 0x20)))
        let finishBytes: Data = finish.encoded()
        XCTAssertEqual(finishBytes.count, 97)
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

    func testDecodeAcceptsSliceWithNonZeroStartIndex() throws {
        let hello: ProximityMessage.Hello = ProximityPairingMessagesTests.sampleHello()
        var padded = Data([0xEE, 0xEE, 0xEE])
        padded.append(ProximityMessage.hello(hello).encoded())
        let slice: Data = padded[3...]
        XCTAssertEqual(slice.startIndex, 3)
        XCTAssertEqual(try ProximityMessage.decode(slice), .hello(hello))
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
        let decoded: ProximityMessage = try ProximityMessage.decode(offerMessage)
        guard case .offer(let offer) = decoded else {
            XCTFail("not an OFFER")
            return
        }
        XCTAssertEqual(offer.mlKemPublicKey, try katHex(kat, "displayerMlKemPublicKey"))
        XCTAssertEqual(offer.displayerEphemeralX25519, try katHex(kat, "displayerEphemeralX25519"))
        XCTAssertEqual(offer.displayerNonce, try katHex(kat, "displayerNonce"))
        XCTAssertEqual(offer.identity.signingPublicKey, try katHex(kat, "displayerSigningPublicKey"))
        XCTAssertEqual(offer.identity.encryptionPublicKey, try katHex(kat, "displayerEncryptionPublicKey"))
        let expectedUserId: String = try katString(kat, "displayerUserId")
        XCTAssertEqual(Data(offer.identity.userId.utf8), Data(expectedUserId.utf8))
        XCTAssertEqual(decoded.encoded(), offerMessage)
        XCTAssertEqual(ProximityMessage.offerBody(offer), try katHex(kat, "offerBody"))
    }

    func testKatAcceptUnsignedBodyAndConfirmMessage() throws {
        let kat: [String: Any] = try loadExpected()
        let scannerIdentity = try ProximityPeerIdentity(userId: try katString(kat, "scannerUserId"),
                                                        signingPublicKey: try katHex(kat, "scannerSigningPublicKey"),
                                                        encryptionPublicKey: try katHex(kat, "scannerEncryptionPublicKey"))
        let unsigned: Data = ProximityMessage.acceptUnsignedBody(mlKemCiphertext: try katHex(kat, "mlKemCiphertext"),
                                                                 identity: scannerIdentity)
        XCTAssertEqual(unsigned, try katHex(kat, "acceptUnsignedBody"))

        let confirmMessage: Data = try katHex(kat, "confirmMessageScanner")
        let decoded: ProximityMessage = try ProximityMessage.decode(confirmMessage)
        XCTAssertEqual(decoded, .confirm(mac: try katHex(kat, "confirmMacScanner")))
        XCTAssertEqual(decoded.encoded(), confirmMessage)
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

    func testRejectsMalformedOffer() throws {
        let valid: Data = message(0x02, offerBody(lengthField: 3, userId: Data("abc".utf8)))
        XCTAssertNoThrow(try ProximityMessage.decode(valid))

        // Trailing byte.
        var trailing: Data = valid
        trailing.append(0x00)
        assertRejected(trailing)
        // Truncated userId.
        assertRejected(valid.subdata(in: 0..<(valid.count - 1)))
        // Length field disagrees with the bytes present.
        assertRejected(message(0x02, offerBody(lengthField: 4, userId: Data("abc".utf8))))
        assertRejected(message(0x02, offerBody(lengthField: 2, userId: Data("abc".utf8))))
        // n = 0.
        assertRejected(message(0x02, offerBody(lengthField: 0, userId: Data())))
        // n = 257 with 257 bytes present.
        let longId: Data = Data(repeating: 0x61, count: 257)
        assertRejected(message(0x02, offerBody(lengthField: 257, userId: longId)))
        // n = 256 is the maximum and is accepted.
        let maxId: Data = Data(repeating: 0x61, count: 256)
        XCTAssertNoThrow(try ProximityMessage.decode(message(0x02, offerBody(lengthField: 256, userId: maxId))))
        // Invalid UTF-8.
        assertRejected(message(0x02, offerBody(lengthField: 2, userId: Data([0xC3, 0x28]))))
        assertRejected(message(0x02, offerBody(lengthField: 1, userId: Data([0xFF]))))
        // Fixed part only.
        assertRejected(message(0x02, ProximityPairingMessagesTests.filled(1568 + 128 + 2, 0)))
    }

    func testRejectsMalformedAccept() throws {
        let valid: Data = message(0x03, acceptBody(lengthField: 2, userId: Data("id".utf8), trailerBytes: 96))
        XCTAssertNoThrow(try ProximityMessage.decode(valid))

        assertRejected(message(0x03, acceptBody(lengthField: 2, userId: Data("id".utf8), trailerBytes: 95)))
        assertRejected(message(0x03, acceptBody(lengthField: 2, userId: Data("id".utf8), trailerBytes: 97)))
        assertRejected(message(0x03, acceptBody(lengthField: 3, userId: Data("id".utf8), trailerBytes: 96)))
        assertRejected(message(0x03, acceptBody(lengthField: 0, userId: Data(), trailerBytes: 96)))
        let longId: Data = Data(repeating: 0x62, count: 257)
        assertRejected(message(0x03, acceptBody(lengthField: 257, userId: longId, trailerBytes: 96)))
        assertRejected(message(0x03, acceptBody(lengthField: 1, userId: Data([0x80]), trailerBytes: 96)))
        assertRejected(message(0x03, ProximityPairingMessagesTests.filled(10, 0)))
    }

    func testRejectsWrongFixedLengths() {
        assertRejected(message(0x04, ProximityPairingMessagesTests.filled(95, 0)))
        assertRejected(message(0x04, ProximityPairingMessagesTests.filled(97, 0)))
        assertRejected(message(0x05, ProximityPairingMessagesTests.filled(31, 0)))
        assertRejected(message(0x05, ProximityPairingMessagesTests.filled(33, 0)))
        assertRejected(message(0x05, Data()))
        assertRejected(message(0x06, Data()))
        assertRejected(message(0x06, Data([1, 2])))
        assertRejected(message(0x07, Data([0])))
    }
}
