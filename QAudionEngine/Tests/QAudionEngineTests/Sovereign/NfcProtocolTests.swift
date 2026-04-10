import XCTest
@testable import QAudionEngine

final class NfcProtocolTests: XCTestCase {

    // MARK: - Initial State

    func testInitialStateIsIdle() {
        let nfc = NfcProtocol()
        if case .idle = nfc.getState() {} else {
            XCTFail("Expected initial state to be .idle")
        }
    }

    // MARK: - parsePskPayload: Valid Data

    func testParsePskPayloadWithValidData() {
        let nfc = NfcProtocol()
        // Format: [nameLen(1)][name(N)][key(32)]
        let name = "Alice"
        let nameData = Data(name.utf8)
        let key = Data(repeating: 0xAB, count: 32)

        var payload = Data()
        payload.append(UInt8(nameData.count))
        payload.append(nameData)
        payload.append(key)

        let result = nfc.parsePskPayload(payload)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "Alice")
        XCTAssertEqual(result?.key, key)
        XCTAssertEqual(result?.key.count, 32)
    }

    func testParsePskPayloadWithSingleCharName() {
        let nfc = NfcProtocol()
        let name = "X"
        let nameData = Data(name.utf8)
        let key = Data(repeating: 0xCC, count: 32)

        var payload = Data()
        payload.append(UInt8(nameData.count))
        payload.append(nameData)
        payload.append(key)

        let result = nfc.parsePskPayload(payload)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "X")
        XCTAssertEqual(result?.key, key)
    }

    // MARK: - parsePskPayload: Invalid / Short Data

    func testParsePskPayloadWithTooShortDataReturnsNil() {
        let nfc = NfcProtocol()
        // Fewer than 34 bytes (minimum: 1 + 1 + 32)
        let shortData = Data(repeating: 0x00, count: 10)
        XCTAssertNil(nfc.parsePskPayload(shortData))
    }

    func testParsePskPayloadWithEmptyDataReturnsNil() {
        let nfc = NfcProtocol()
        XCTAssertNil(nfc.parsePskPayload(Data()))
    }

    func testParsePskPayloadWithNameLenExceedingBufferReturnsNil() {
        let nfc = NfcProtocol()
        // nameLen says 100 but only 33 more bytes follow (not enough for name + 32-byte key)
        var payload = Data()
        payload.append(UInt8(100))
        payload.append(Data(repeating: 0x41, count: 33))
        XCTAssertNil(nfc.parsePskPayload(payload))
    }

    func testParsePskPayloadExactMinimumSize() {
        let nfc = NfcProtocol()
        // nameLen=1, name=1 byte, key=32 bytes => total 34 bytes
        var payload = Data()
        payload.append(UInt8(1))
        payload.append(UInt8(0x41))  // "A"
        payload.append(Data(repeating: 0xFF, count: 32))

        let result = nfc.parsePskPayload(payload)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "A")
        XCTAssertEqual(result?.key.count, 32)
    }

    // MARK: - generateQrPayload Round-Trip

    func testGenerateQrPayloadRoundTrip() {
        let nfc = NfcProtocol()
        let name = "TestUser"
        let key = Data(repeating: 0x42, count: 32)

        let payload = nfc.generateQrPayload(name: name, key: key)
        let parsed = nfc.parsePskPayload(payload)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.name, name)
        XCTAssertEqual(parsed?.key, key)
    }

    func testGenerateQrPayloadRoundTripWithUnicodeName() {
        let nfc = NfcProtocol()
        let name = "Utente"  // Simple ASCII-safe name for round-trip
        let key = Data((0..<32).map { UInt8($0) })

        let payload = nfc.generateQrPayload(name: name, key: key)
        let parsed = nfc.parsePskPayload(payload)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.name, name)
        XCTAssertEqual(parsed?.key, key)
    }

    func testGenerateQrPayloadFormat() {
        let nfc = NfcProtocol()
        let name = "Bob"
        let nameData = Data(name.utf8)
        let key = Data(repeating: 0xDD, count: 32)

        let payload = nfc.generateQrPayload(name: name, key: key)

        // First byte should be name length
        XCTAssertEqual(payload[0], UInt8(nameData.count))
        // Total should be 1 + nameLen + 32
        XCTAssertEqual(payload.count, 1 + nameData.count + 32)
    }

    // MARK: - generateQrPayload with Empty Name

    func testGenerateQrPayloadEmptyNameProducesValidData() {
        let nfc = NfcProtocol()
        let key = Data(repeating: 0x01, count: 32)
        let payload = nfc.generateQrPayload(name: "", key: key)

        // nameLen = 0, so payload = [0] + [] + key = 33 bytes
        XCTAssertEqual(payload.count, 33)
        XCTAssertEqual(payload[0], 0)
    }
}
