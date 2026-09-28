#if canImport(CoreBluetooth)
import XCTest
import CoreBluetooth
@testable import QAudionEngine

/// Pure checks of the BLE identifiers (spec §4, §7). CoreBluetooth radios do
/// not exist in the iOS Simulator, so the transports themselves are never
/// instantiated here.
final class ProximityBleTransportTests: XCTestCase {

    private struct BleKatError: Error {
        let message: String
    }

    // MARK: - Service UUID

    func testServiceUUIDIsSessionIdBytesAsUuid() {
        let bytes: [UInt8] = [0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47,
                              0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F]
        let sessionId = Data(bytes)
        let uuid: CBUUID? = ProximityBleUUIDs.serviceUUID(sessionId: sessionId)
        XCTAssertNotNil(uuid)
        XCTAssertEqual(uuid?.uuidString, "40414243-4445-4647-4849-4A4B4C4D4E4F")
        XCTAssertEqual(uuid?.data, sessionId)
    }

    func testServiceUUIDMatchesKatSessionId() throws {
        let sessionId: Data = try loadKatSessionId()
        XCTAssertEqual(sessionId.count, ProximityPairing.sessionIdBytes)
        let uuid: CBUUID? = ProximityBleUUIDs.serviceUUID(sessionId: sessionId)
        XCTAssertEqual(uuid?.uuidString, proxBleFormatUuid(sessionId))
    }

    func testServiceUUIDForRandomSessionIds() {
        for _ in 0..<32 {
            var bytes = [UInt8](repeating: 0, count: ProximityPairing.sessionIdBytes)
            for index in 0..<bytes.count {
                bytes[index] = UInt8.random(in: 0...255)
            }
            let sessionId = Data(bytes)
            let uuid: CBUUID? = ProximityBleUUIDs.serviceUUID(sessionId: sessionId)
            XCTAssertEqual(uuid?.uuidString, proxBleFormatUuid(sessionId))
            XCTAssertEqual(uuid?.data, sessionId)
        }
    }

    func testServiceUUIDAcceptsDataSliceWithNonZeroStartIndex() {
        var backing = Data([0xAA, 0xBB, 0xCC])
        let bytes: [UInt8] = [0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47,
                              0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F]
        backing.append(contentsOf: bytes)
        let slice: Data = backing[3..<19]
        XCTAssertEqual(slice.startIndex, 3)
        let uuid: CBUUID? = ProximityBleUUIDs.serviceUUID(sessionId: slice)
        XCTAssertEqual(uuid?.uuidString, "40414243-4445-4647-4849-4A4B4C4D4E4F")
    }

    func testServiceUUIDRejectsWrongLengths() {
        XCTAssertNil(ProximityBleUUIDs.serviceUUID(sessionId: Data()))
        XCTAssertNil(ProximityBleUUIDs.serviceUUID(sessionId: Data(repeating: 0x41, count: 2)))
        XCTAssertNil(ProximityBleUUIDs.serviceUUID(sessionId: Data(repeating: 0x41, count: 4)))
        XCTAssertNil(ProximityBleUUIDs.serviceUUID(sessionId: Data(repeating: 0x41, count: 15)))
        XCTAssertNil(ProximityBleUUIDs.serviceUUID(sessionId: Data(repeating: 0x41, count: 17)))
        XCTAssertNil(ProximityBleUUIDs.serviceUUID(sessionId: Data(repeating: 0x41, count: 32)))
    }

    // MARK: - Characteristics

    func testCharacteristicUUIDsMatchContract() {
        XCTAssertEqual(ProximityBleUUIDs.toDisplayerCharacteristic.uuidString,
                       ProximityPairing.toDisplayerCharacteristicUUID)
        XCTAssertEqual(ProximityBleUUIDs.toScannerCharacteristic.uuidString,
                       ProximityPairing.toScannerCharacteristicUUID)
        XCTAssertEqual(ProximityBleUUIDs.toDisplayerCharacteristic.uuidString,
                       "51A0C2D0-7E2B-4F6B-9E1D-0A8B5C3F2D01")
        XCTAssertEqual(ProximityBleUUIDs.toScannerCharacteristic.uuidString,
                       "51A0D2C0-7E2B-4F6B-9E1D-0A8B5C3F2D02")
        XCTAssertNotEqual(ProximityBleUUIDs.toDisplayerCharacteristic, ProximityBleUUIDs.toScannerCharacteristic)
        XCTAssertEqual(ProximityBleUUIDs.toDisplayerCharacteristic.data.count, 16)
        XCTAssertEqual(ProximityBleUUIDs.toScannerCharacteristic.data.count, 16)
    }

    // MARK: - Helpers

    private func loadKatSessionId() throws -> Data {
        guard let url = Bundle.module.url(forResource: "proximity-pairing-kat", withExtension: "json") else {
            throw BleKatError(message: "proximity-pairing-kat.json not found in test bundle")
        }
        let raw = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: raw, options: [])
        guard let root = object as? [String: Any],
              let inputs = root["inputs"] as? [String: Any],
              let hex = inputs["sessionId"] as? String,
              let decoded = proxBleHexDecode(hex) else {
            throw BleKatError(message: "missing or malformed inputs.sessionId")
        }
        return decoded
    }
}

/// Uppercase 8-4-4-4-12 rendering of 16 bytes.
private func proxBleFormatUuid(_ bytes: Data) -> String {
    let digits: [Character] = Array("0123456789ABCDEF")
    let normalized = [UInt8](bytes)
    var out: String = ""
    for (index, byte) in normalized.enumerated() {
        if index == 4 || index == 6 || index == 8 || index == 10 {
            out.append("-")
        }
        out.append(digits[Int(byte >> 4)])
        out.append(digits[Int(byte & 0x0F)])
    }
    return out
}

private func proxBleHexDecode(_ text: String) -> Data? {
    let chars = [UInt8](text.utf8)
    guard chars.count % 2 == 0 else { return nil }
    var out = Data(capacity: chars.count / 2)
    var index = 0
    while index < chars.count {
        guard let high = proxBleNibble(chars[index]), let low = proxBleNibble(chars[index + 1]) else { return nil }
        out.append((high << 4) | low)
        index += 2
    }
    return out
}

private func proxBleNibble(_ c: UInt8) -> UInt8? {
    switch c {
    case 0x30...0x39: return c - 0x30
    case 0x41...0x46: return c - 0x41 + 10
    case 0x61...0x66: return c - 0x61 + 10
    default: return nil
    }
}

#endif
