import XCTest
@testable import QAudionEngine

/// Byte-for-byte parity tests against Android's `CanonicalCbor` and the
/// Node oracle `qaudion-desktop/scripts/ratchet-kat-dump.mjs`.
///
/// These are CRITICAL tests: if the iOS encoder ever drifts from the
/// canonical encoding, every v3.1 message AAD or HKDF init `info` will
/// silently mismatch, which means AEAD decryption will fail with no
/// useful diagnostic. The ratchet engine treats AEAD failure as "drop
/// silently" by design (don't leak which class of attack).
final class CanonicalCborTests: XCTestCase {

    // MARK: - Heads (RFC 8949 §4.2 smallest encoding)

    func testHeadEncodingSmallestForm() {
        // uint(0) = 1 byte (0x00)
        XCTAssertEqual(CanonicalCbor.encode(.uint(0)), Data([0x00]))
        // uint(23) = 1 byte (0x17)
        XCTAssertEqual(CanonicalCbor.encode(.uint(23)), Data([0x17]))
        // uint(24) = 2 bytes (0x18 0x18)
        XCTAssertEqual(CanonicalCbor.encode(.uint(24)), Data([0x18, 0x18]))
        // uint(255) = 2 bytes (0x18 0xFF)
        XCTAssertEqual(CanonicalCbor.encode(.uint(255)), Data([0x18, 0xFF]))
        // uint(256) = 3 bytes (0x19 0x01 0x00)
        XCTAssertEqual(CanonicalCbor.encode(.uint(256)), Data([0x19, 0x01, 0x00]))
        // uint(65535) = 3 bytes (0x19 0xFF 0xFF)
        XCTAssertEqual(CanonicalCbor.encode(.uint(65535)), Data([0x19, 0xFF, 0xFF]))
        // uint(65536) = 5 bytes (0x1A 0x00 0x01 0x00 0x00)
        XCTAssertEqual(CanonicalCbor.encode(.uint(65536)), Data([0x1A, 0x00, 0x01, 0x00, 0x00]))
    }

    // MARK: - Text

    func testTextStringEncoding() {
        // "" = 1 byte (0x60)
        XCTAssertEqual(CanonicalCbor.encode(.text("")), Data([0x60]))
        // "v3" = 0x62 'v' '3'
        XCTAssertEqual(CanonicalCbor.encode(.text("v3")),
                       Data([0x62, 0x76, 0x33]))
        // "lo->hi" = 0x66 + 6 ASCII bytes
        XCTAssertEqual(CanonicalCbor.encode(.text("lo->hi")),
                       Data([0x66, 0x6C, 0x6F, 0x2D, 0x3E, 0x68, 0x69]))
    }

    // MARK: - Array

    func testInitInfoArray() {
        // ["v3", "lo->hi", "alice", "bob"]
        let bytes = CanonicalCbor.buildInitInfo(direction: "lo->hi", lo: "alice", hi: "bob")
        var expected = Data([0x84])                                        // array(4)
        expected.append(Data([0x62, 0x76, 0x33]))                          // "v3"
        expected.append(Data([0x66, 0x6C, 0x6F, 0x2D, 0x3E, 0x68, 0x69]))  // "lo->hi"
        expected.append(Data([0x65, 0x61, 0x6C, 0x69, 0x63, 0x65]))        // "alice"
        expected.append(Data([0x63, 0x62, 0x6F, 0x62]))                    // "bob"
        XCTAssertEqual(bytes, expected)
    }

    // MARK: - Map (canonical key sort)

    func testBuildMessageADCanonicalKeyOrder() {
        // Insertion order is intentionally scrambled — must come out as m,r,s,v
        // (all keys length 1, sort by byte: 0x6D < 0x72 < 0x73 < 0x76).
        let bytes = CanonicalCbor.buildMessageAD(
            senderId: "alice",
            recipientId: "bob",
            clientMsgId: "msg-42")
        var expected = Data([0xA4])                                        // map(4)
        // "m" -> "msg-42"
        expected.append(Data([0x61, 0x6D]))                                // "m"
        expected.append(Data([0x66, 0x6D, 0x73, 0x67, 0x2D, 0x34, 0x32]))  // "msg-42"
        // "r" -> "bob"
        expected.append(Data([0x61, 0x72]))                                // "r"
        expected.append(Data([0x63, 0x62, 0x6F, 0x62]))                    // "bob"
        // "s" -> "alice"
        expected.append(Data([0x61, 0x73]))                                // "s"
        expected.append(Data([0x65, 0x61, 0x6C, 0x69, 0x63, 0x65]))        // "alice"
        // "v" -> 3
        expected.append(Data([0x61, 0x76]))                                // "v"
        expected.append(Data([0x03]))                                      // uint(3)
        XCTAssertEqual(bytes, expected)
    }

    func testMapKeyLengthThenLexSort() {
        // Mix of 1- and 2-byte keys. Length-first sort puts short keys first.
        let v: CanonicalCbor.Value = .map([
            ("zz", .uint(2)),     // 2-byte key
            ("a", .uint(1)),     // 1-byte key
            ("aa", .uint(3)),     // 2-byte
        ])
        let bytes = CanonicalCbor.encode(v)
        // Expected order: "a", "aa", "zz" (length-first).
        var expected = Data([0xA3])                            // map(3)
        expected.append(Data([0x61, 0x61])); expected.append(Data([0x01]))   // "a"  -> 1
        expected.append(Data([0x62, 0x61, 0x61])); expected.append(Data([0x03])) // "aa" -> 3
        expected.append(Data([0x62, 0x7A, 0x7A])); expected.append(Data([0x02])) // "zz" -> 2
        XCTAssertEqual(bytes, expected)
    }

    // MARK: - Bytes

    func testByteStringEncoding() {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let bytes = CanonicalCbor.encode(.bytes(payload))
        XCTAssertEqual(bytes, Data([0x44, 0xDE, 0xAD, 0xBE, 0xEF]))
    }

    // MARK: - encodeAny

    func testEncodeAnyAcceptsHeterogeneousArray() throws {
        let bytes = try CanonicalCbor.encodeAny(["v3", "lo->hi", "alice", "bob"])
        let expected = CanonicalCbor.buildInitInfo(direction: "lo->hi", lo: "alice", hi: "bob")
        XCTAssertEqual(bytes, expected)
    }
}
