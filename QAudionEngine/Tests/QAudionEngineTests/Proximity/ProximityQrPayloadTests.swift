import XCTest
@testable import QAudionEngine

/// Proximity pairing v1 — QR payload codec (spec §5), pinned against
/// `proximity-pairing-kat.json` (independent Python reference implementation)
/// plus every strictness rule the decoder must enforce.
final class ProximityQrPayloadTests: XCTestCase {

    // MARK: - KAT

    private struct QrKatInputs: Decodable {
        let sessionId: String
        let frameIndex: UInt32
    }

    private struct QrKatExpected: Decodable {
        let commitment: String
        let frameKey: String
        let qrBytes: String
        let qrText: String
    }

    private struct QrKatRoot: Decodable {
        let inputs: QrKatInputs
        let expected: QrKatExpected
    }

    private struct QrKat {
        let sessionId: Data
        let frameIndex: UInt32
        let commitment: Data
        let frameKey: Data
        let qrBytes: Data
        let qrText: String

        /// The 114 base64url characters after the prefix.
        var remainder: String {
            return String(qrText.dropFirst(ProximityPairing.urlPrefix.count))
        }
    }

    private struct QrHexDecodingError: Error {}

    private static let base64UrlAlphabet: [Character] =
        Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    private func loadKat() throws -> QrKat {
        let maybeUrl: URL? = Bundle.module.url(forResource: "proximity-pairing-kat", withExtension: "json")
        let url: URL = try XCTUnwrap(maybeUrl, "proximity-pairing-kat.json missing from Bundle.module")
        let json: Data = try Data(contentsOf: url)
        let root: QrKatRoot = try JSONDecoder().decode(QrKatRoot.self, from: json)
        let sessionId: Data = try ProximityQrPayloadTests.qrHex(root.inputs.sessionId)
        let commitment: Data = try ProximityQrPayloadTests.qrHex(root.expected.commitment)
        let frameKey: Data = try ProximityQrPayloadTests.qrHex(root.expected.frameKey)
        let qrBytes: Data = try ProximityQrPayloadTests.qrHex(root.expected.qrBytes)
        return QrKat(sessionId: sessionId,
                     frameIndex: root.inputs.frameIndex,
                     commitment: commitment,
                     frameKey: frameKey,
                     qrBytes: qrBytes,
                     qrText: root.expected.qrText)
    }

    func testKatVectorShape() throws {
        let kat = try loadKat()
        XCTAssertEqual(kat.frameIndex, 7)
        XCTAssertEqual(kat.qrBytes.count, ProximityPairing.qrPayloadBytes)
        let expectedTextLength: Int = ProximityPairing.urlPrefix.count + ProximityPairing.qrBase64Characters
        XCTAssertEqual(kat.qrText.count, expectedTextLength)
        XCTAssertTrue(kat.qrText.hasPrefix(ProximityPairing.urlPrefix))
    }

    func testKatQrTextDecodesToExpectedFields() throws {
        let kat = try loadKat()
        let payload = try ProximityQrPayload.decode(text: kat.qrText)
        XCTAssertEqual(payload.version, ProximityPairing.protocolVersion)
        XCTAssertEqual(payload.sessionId, kat.sessionId)
        XCTAssertEqual(payload.frameIndex, 7)
        XCTAssertEqual(payload.commitment, kat.commitment)
        XCTAssertEqual(payload.frameKey, kat.frameKey)
    }

    func testKatQrTextReencodesExactly() throws {
        let kat = try loadKat()
        let payload = try ProximityQrPayload.decode(text: kat.qrText)
        XCTAssertEqual(payload.encodedBytes, kat.qrBytes)
        XCTAssertEqual(payload.qrText, kat.qrText)
    }

    func testKatFieldsEncodeToExpectedBytesAndText() throws {
        let kat = try loadKat()
        let payload = try ProximityQrPayload(sessionId: kat.sessionId,
                                             commitment: kat.commitment,
                                             frameIndex: kat.frameIndex,
                                             frameKey: kat.frameKey)
        XCTAssertEqual(payload.encodedBytes, kat.qrBytes)
        XCTAssertEqual(payload.qrText, kat.qrText)
        let reference: String = ProximityPairing.urlPrefix + ProximityQrPayloadTests.referenceBase64Url(kat.qrBytes)
        XCTAssertEqual(payload.qrText, reference)
    }

    func testKatQrBytesDecode() throws {
        let kat = try loadKat()
        let payload = try ProximityQrPayload.decode(bytes: kat.qrBytes)
        XCTAssertEqual(payload.sessionId, kat.sessionId)
        XCTAssertEqual(payload.commitment, kat.commitment)
        XCTAssertEqual(payload.frameIndex, kat.frameIndex)
        XCTAssertEqual(payload.frameKey, kat.frameKey)
        XCTAssertEqual(payload.qrText, kat.qrText)
    }

    // MARK: - decode(bytes:)

    func testDecodeBytesAcceptsSliceWithNonZeroStartIndex() throws {
        let kat = try loadKat()
        var padded = Data([0xAA, 0xBB, 0xCC])
        padded.append(kat.qrBytes)
        padded.append(Data([0xDD]))
        let slice: Data = padded[3..<(3 + ProximityPairing.qrPayloadBytes)]
        XCTAssertEqual(slice.startIndex, 3)
        let payload = try ProximityQrPayload.decode(bytes: slice)
        XCTAssertEqual(payload.encodedBytes, kat.qrBytes)
        XCTAssertEqual(payload.sessionId.startIndex, 0)
        XCTAssertEqual(payload.frameKey.startIndex, 0)
    }

    func testDecodeBytesRejectsWrongLengths() throws {
        let kat = try loadKat()
        assertBytesRejected(Data())
        assertBytesRejected(Data([ProximityPairing.protocolVersion]))
        assertBytesRejected(Data(kat.qrBytes.prefix(84)))
        var longer: Data = kat.qrBytes
        longer.append(Data([0x00]))
        assertBytesRejected(longer)
    }

    func testDecodeBytesRejectsOtherVersions() throws {
        let kat = try loadKat()
        let versions: [UInt8] = [0x00, 0x02, 0x81, 0xFF]
        for version in versions {
            var bytes: Data = kat.qrBytes
            bytes[0] = version
            assertBytesRejected(bytes)
        }
    }

    // MARK: - decode(text:) — accepted forms

    func testSurroundingWhitespaceIsTrimmed() throws {
        let kat = try loadKat()
        let padded: String = "  \n\t" + kat.qrText + " \r\n\t "
        let payload = try ProximityQrPayload.decode(text: padded)
        XCTAssertEqual(payload.encodedBytes, kat.qrBytes)
    }

    func testUppercasePrefixIsAccepted() throws {
        let kat = try loadKat()
        let upper: String = "QAUDION://PAIR/" + kat.remainder
        XCTAssertEqual(try ProximityQrPayload.decode(text: upper).encodedBytes, kat.qrBytes)
        let mixed: String = "QaUdIoN://pAiR/" + kat.remainder
        XCTAssertEqual(try ProximityQrPayload.decode(text: mixed).encodedBytes, kat.qrBytes)
    }

    // MARK: - decode(text:) — rejections

    func testRejectsWrongScheme() throws {
        let kat = try loadKat()
        assertTextRejected("qaudiox://pair/" + kat.remainder)
        assertTextRejected("qaudio://pair/" + kat.remainder)
        assertTextRejected("https://pair/" + kat.remainder)
        assertTextRejected("qaudion:/pair/" + kat.remainder)
        assertTextRejected("qaudion//pair/" + kat.remainder)
        assertTextRejected("xqaudion://pair/" + kat.remainder)
    }

    func testRejectsWrongHost() throws {
        let kat = try loadKat()
        assertTextRejected("qaudion://paix/" + kat.remainder)
        assertTextRejected("qaudion://link/" + kat.remainder)
        assertTextRejected("qaudion://pairs/" + kat.remainder)
        assertTextRejected("qaudion://pair" + kat.remainder)
        assertTextRejected("qaudion://pair//" + kat.remainder)
        assertTextRejected("qaudion://user@pair/" + kat.remainder)
    }

    func testRejectsPadding() throws {
        let kat = try loadKat()
        assertTextRejected(kat.qrText + "=")
        assertTextRejected(kat.qrText + "==")
        assertTextRejected(String(kat.qrText.dropLast()) + "=")
        assertTextRejected(String(kat.qrText.dropLast(2)) + "==")
    }

    func testRejectsWrongLength() throws {
        let kat = try loadKat()
        let short: String = String(kat.qrText.dropLast())
        XCTAssertEqual(short.count - ProximityPairing.urlPrefix.count, 113)
        assertTextRejected(short)
        let long: String = kat.qrText + "A"
        XCTAssertEqual(long.count - ProximityPairing.urlPrefix.count, 115)
        assertTextRejected(long)
        assertTextRejected(kat.qrText + kat.remainder)
        assertTextRejected(ProximityPairing.urlPrefix)
        assertTextRejected("")
        assertTextRejected("   ")
        assertTextRejected("qaudion")
    }

    func testRejectsInvalidCharacters() throws {
        let kat = try loadKat()
        let invalid: [Character] = ["+", "/", "=", ".", " ", "%", "~", "?", "#", "\u{0}", "\n", "é", "\u{FF21}", "\u{00A0}"]
        let positions: [Int] = [0, 1, 57, 112, 113]
        for position in positions {
            for replacement in invalid {
                var chars: [Character] = Array(kat.remainder)
                chars[position] = replacement
                let mutated: String = ProximityPairing.urlPrefix + String(chars)
                assertTextRejected(mutated)
            }
        }
    }

    func testRejectsNonCanonicalLastCharacter() throws {
        let kat = try loadKat()
        let remainderChars: [Character] = Array(kat.remainder)
        let lastIndex: Int = remainderChars.count - 1
        let alphabet: [Character] = ProximityQrPayloadTests.base64UrlAlphabet
        let found: Int? = alphabet.firstIndex(of: remainderChars[lastIndex])
        let canonicalValue: Int = try XCTUnwrap(found)
        // 85 bytes = 28 full groups + 1 byte: the last symbol carries 2 data bits + 4 zero bits.
        XCTAssertEqual(canonicalValue & 0x0F, 0)
        for lowBits in 1..<16 {
            var chars: [Character] = remainderChars
            chars[lastIndex] = alphabet[canonicalValue | lowBits]
            let mutated: String = ProximityPairing.urlPrefix + String(chars)
            assertTextRejected(mutated)
        }
    }

    func testRejectsVersionTwoText() throws {
        let kat = try loadKat()
        var bytes: Data = kat.qrBytes
        bytes[0] = 0x02
        let text: String = ProximityPairing.urlPrefix + ProximityQrPayloadTests.referenceBase64Url(bytes)
        XCTAssertEqual(text.count, kat.qrText.count)
        assertTextRejected(text)
    }

    func testRejectsQueryAndFragment() throws {
        let kat = try loadKat()
        assertTextRejected(kat.qrText + "?x")
        assertTextRejected(kat.qrText + "#x")
        assertTextRejected(kat.qrText + "/")
        assertTextRejected(String(kat.qrText.dropLast(2)) + "?x")
        assertTextRejected(String(kat.qrText.dropLast(2)) + "#x")
    }

    func testRejectsInteriorWhitespace() throws {
        let kat = try loadKat()
        var chars: [Character] = Array(kat.remainder)
        chars.insert(" ", at: 40)
        let spaced: String = ProximityPairing.urlPrefix + String(chars)
        assertTextRejected(spaced)
        assertTextRejected("qaudion:// pair/" + kat.remainder)
        assertTextRejected(ProximityPairing.urlPrefix + " " + kat.remainder)
    }

    func testRejectsPercentEncodedPrefix() throws {
        let kat = try loadKat()
        assertTextRejected("qaudion%3A%2F%2Fpair%2F" + kat.remainder)
        assertTextRejected("qaudion://%70air/" + kat.remainder)
    }

    /// Changing any single character either fails strict decoding or yields a
    /// different payload: two distinct texts never decode to the same value.
    func testSingleCharacterMutationsNeverAlias() throws {
        let kat = try loadKat()
        let original = try ProximityQrPayload.decode(text: kat.qrText)
        let remainderChars: [Character] = Array(kat.remainder)
        var aliasCount: Int = 0
        var wrongErrorCount: Int = 0
        for position in 0..<remainderChars.count {
            for symbol in ProximityQrPayloadTests.base64UrlAlphabet where symbol != remainderChars[position] {
                var chars: [Character] = remainderChars
                chars[position] = symbol
                let mutated: String = ProximityPairing.urlPrefix + String(chars)
                do {
                    let decoded = try ProximityQrPayload.decode(text: mutated)
                    if decoded == original { aliasCount += 1 }
                } catch {
                    if !ProximityQrPayloadTests.isInvalidQrCode(error) { wrongErrorCount += 1 }
                }
            }
        }
        XCTAssertEqual(aliasCount, 0)
        XCTAssertEqual(wrongErrorCount, 0)
    }

    // MARK: - looksLikeProximityPairing

    func testLooksLikeProximityPairing() throws {
        let kat = try loadKat()
        let padded: String = "  \n" + kat.qrText + "\n"
        let upper: String = "QAUDION://PAIR/" + kat.remainder
        XCTAssertTrue(ProximityQrPayload.looksLikeProximityPairing(kat.qrText))
        XCTAssertTrue(ProximityQrPayload.looksLikeProximityPairing(padded))
        XCTAssertTrue(ProximityQrPayload.looksLikeProximityPairing(upper))
        XCTAssertTrue(ProximityQrPayload.looksLikeProximityPairing("qaudion://pair/not-validated"))
        XCTAssertTrue(ProximityQrPayload.looksLikeProximityPairing(ProximityPairing.urlPrefix))

        XCTAssertFalse(ProximityQrPayload.looksLikeProximityPairing(""))
        XCTAssertFalse(ProximityQrPayload.looksLikeProximityPairing("qaudion://pai"))
        XCTAssertFalse(ProximityQrPayload.looksLikeProximityPairing("qaudion://link/abc"))
        XCTAssertFalse(ProximityQrPayload.looksLikeProximityPairing("https://example.com/pair/abc"))
        XCTAssertFalse(ProximityQrPayload.looksLikeProximityPairing("xqaudion://pair/abc"))
        XCTAssertFalse(ProximityQrPayload.looksLikeProximityPairing("qaudion:/pair/abc"))
    }

    // MARK: - Round trip

    func testFrameIndexIsBigEndian() throws {
        let kat = try loadKat()
        let payload = try ProximityQrPayload(sessionId: kat.sessionId,
                                             commitment: kat.commitment,
                                             frameIndex: 0x0102_0304,
                                             frameKey: kat.frameKey)
        let bytes: Data = payload.encodedBytes
        XCTAssertEqual(bytes.count, ProximityPairing.qrPayloadBytes)
        XCTAssertEqual(bytes[0], ProximityPairing.protocolVersion)
        XCTAssertEqual(Data(bytes[1..<17]), kat.sessionId)
        XCTAssertEqual(Data(bytes[17..<49]), kat.commitment)
        XCTAssertEqual(Data(bytes[49..<53]), Data([0x01, 0x02, 0x03, 0x04]))
        XCTAssertEqual(Data(bytes[53..<85]), kat.frameKey)
    }

    func testRandomPayloadsRoundTrip() throws {
        let indices: [UInt32] = [0, 1, 7, 0xFF, 0x100, 0x7FFF_FFFF, 0x8000_0000, UInt32.max]
        for iteration in 0..<256 {
            let frameIndex: UInt32 = iteration < indices.count
                ? indices[iteration]
                : UInt32.random(in: UInt32.min...UInt32.max)
            let payload = try ProximityQrPayload(
                sessionId: ProximityQrPayloadTests.randomBytes(ProximityPairing.sessionIdBytes),
                commitment: ProximityQrPayloadTests.randomBytes(ProximityPairing.commitmentBytes),
                frameIndex: frameIndex,
                frameKey: ProximityQrPayloadTests.randomBytes(ProximityPairing.frameKeyBytes)
            )
            let bytes: Data = payload.encodedBytes
            let text: String = payload.qrText
            XCTAssertEqual(bytes.count, ProximityPairing.qrPayloadBytes)
            let expectedTextLength: Int = ProximityPairing.urlPrefix.count + ProximityPairing.qrBase64Characters
            XCTAssertEqual(text.count, expectedTextLength)
            let reference: String = ProximityPairing.urlPrefix + ProximityQrPayloadTests.referenceBase64Url(bytes)
            XCTAssertEqual(text, reference)
            XCTAssertEqual(try ProximityQrPayload.decode(text: text), payload)
            XCTAssertEqual(try ProximityQrPayload.decode(bytes: bytes), payload)
            XCTAssertTrue(ProximityQrPayload.looksLikeProximityPairing(text))
        }
    }

    // MARK: - Helpers (private to this file)

    private func assertTextRejected(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ProximityQrPayload.decode(text: text), "strict decoder accepted a malformed code",
                             file: file, line: line) { error in
            let isExpected: Bool = ProximityQrPayloadTests.isInvalidQrCode(error)
            XCTAssertTrue(isExpected, "expected ProximityPairingError.invalidQrCode", file: file, line: line)
        }
    }

    private func assertBytesRejected(_ bytes: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ProximityQrPayload.decode(bytes: bytes), "decoder accepted malformed bytes",
                             file: file, line: line) { error in
            let isExpected: Bool = ProximityQrPayloadTests.isInvalidQrCode(error)
            XCTAssertTrue(isExpected, "expected ProximityPairingError.invalidQrCode", file: file, line: line)
        }
    }

    private static func isInvalidQrCode(_ error: Error) -> Bool {
        guard let pairingError = error as? ProximityPairingError else { return false }
        if case .invalidQrCode = pairingError { return true }
        return false
    }

    /// Independent of the codec under test: Foundation base64 + alphabet swap.
    private static func referenceBase64Url(_ data: Data) -> String {
        let standard: String = data.base64EncodedString()
        let urlSafe: String = standard
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return urlSafe
    }

    private static func randomBytes(_ count: Int) -> Data {
        var out = Data(capacity: count)
        for _ in 0..<count {
            let byte: UInt8 = UInt8.random(in: UInt8.min...UInt8.max)
            out.append(contentsOf: [byte])
        }
        return out
    }

    private static func qrHex(_ hex: String) throws -> Data {
        let chars: [UInt8] = Array(hex.utf8)
        guard chars.count % 2 == 0 else { throw QrHexDecodingError() }
        var out = Data(capacity: chars.count / 2)
        var index: Int = 0
        while index < chars.count {
            guard let high = qrNibble(chars[index]), let low = qrNibble(chars[index + 1]) else {
                throw QrHexDecodingError()
            }
            let byte: UInt8 = (high << 4) | low
            out.append(contentsOf: [byte])
            index += 2
        }
        return out
    }

    private static func qrNibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x61 + 10
        case 0x41...0x46: return c - 0x41 + 10
        default: return nil
        }
    }
}
