import XCTest
@testable import QAudionEngine

/// KAT + round-trip tests for the MASQUE CONNECT-UDP wire codec.
/// Vectors for the varint are the canonical examples from RFC 9000 §A.1.
final class MasqueCodecTests: XCTestCase {

    // MARK: - QUIC varint (RFC 9000 §16 / §A.1)

    func testVarintEncodeRFC9000Vectors() {
        XCTAssertEqual(MasqueVarint.encode(37), [0x25])
        XCTAssertEqual(MasqueVarint.encode(15293), [0x7b, 0xbd])
        XCTAssertEqual(MasqueVarint.encode(494878333), [0x9d, 0x7f, 0x3e, 0x7d])
        XCTAssertEqual(MasqueVarint.encode(151288809941952652),
                       [0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c])
    }

    func testVarintDecodeRFC9000Vectors() {
        XCTAssertEqual(MasqueVarint.decode([0x25][...])?.value, 37)
        XCTAssertEqual(MasqueVarint.decode([0x7b, 0xbd][...])?.value, 15293)
        XCTAssertEqual(MasqueVarint.decode([0x9d, 0x7f, 0x3e, 0x7d][...])?.value, 494878333)
        XCTAssertEqual(
            MasqueVarint.decode([0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c][...])?.value,
            151288809941952652)
    }

    func testVarintDecodeReportsConsumedLength() {
        // A 2-byte varint followed by trailing bytes must consume exactly 2.
        let bytes: [UInt8] = [0x7b, 0xbd, 0xde, 0xad]
        let decoded = MasqueVarint.decode(bytes[...])
        XCTAssertEqual(decoded?.value, 15293)
        XCTAssertEqual(decoded?.length, 2)
    }

    func testVarintDecodeRejectsTruncated() {
        // First byte announces 4-byte form but only 2 bytes present.
        XCTAssertNil(MasqueVarint.decode([0x9d, 0x7f][...]))
        XCTAssertNil(MasqueVarint.decode([][...]))
    }

    func testVarintRoundTripBoundaries() {
        for v in [UInt64(0), 63, 64, 16383, 16384, 1_073_741_823, 1_073_741_824,
                  MasqueVarint.maxValue] {
            guard let decoded = MasqueVarint.decode(MasqueVarint.encode(v)[...]) else {
                return XCTFail("nil decode for \(v)")
            }
            XCTAssertEqual(decoded.value, v)
        }
    }

    // MARK: - CONNECT-UDP HTTP Datagram payload (RFC 9298 §5)

    func testDatagramEncodePrependsZeroContextID() {
        let udp = Data([0x01, 0x02, 0x03])
        // Context ID 0 → single varint byte 0x00, then the UDP payload.
        XCTAssertEqual(MasqueDatagramCodec.encode(udpPayload: udp), Data([0x00, 0x01, 0x02, 0x03]))
    }

    func testDatagramRoundTrip() {
        let udp = Data((0..<300).map { UInt8($0 & 0xFF) })   // > 1-byte varint range payload
        let wire = MasqueDatagramCodec.encode(udpPayload: udp)
        XCTAssertEqual(MasqueDatagramCodec.decode(wire), udp)
    }

    func testDatagramDecodeRejectsUnknownContext() {
        // Context ID 1 (varint 0x01) is not the UDP context → drop.
        XCTAssertNil(MasqueDatagramCodec.decode(Data([0x01, 0xaa, 0xbb])))
    }

    func testDatagramDecodeEmptyPayloadIsValid() {
        XCTAssertEqual(MasqueDatagramCodec.decode(Data([0x00])), Data())
    }

    // MARK: - CONNECT-UDP request descriptor (RFC 9298 §3)

    func testConnectUdpPathTemplate() {
        let req = MasqueConnectUdpRequest(
            proxyAuthority: "voip.bcrypto.com",
            targetHost: "217.160.65.35",
            targetPort: 3478)
        XCTAssertEqual(req.path, "/.well-known/masque/udp/217.160.65.35/3478/")
    }

    func testConnectUdpHeadersIncludeExtendedConnectAndCapsule() {
        let req = MasqueConnectUdpRequest(
            proxyAuthority: "voip.bcrypto.com",
            targetHost: "217.160.65.35",
            targetPort: 3478,
            bearerToken: "tok123")
        let fields = req.headerFields()
        func value(_ name: String) -> String? { fields.first { $0.name == name }?.value }
        XCTAssertEqual(value(":method"), "CONNECT")
        XCTAssertEqual(value(":protocol"), "connect-udp")
        XCTAssertEqual(value(":scheme"), "https")
        XCTAssertEqual(value(":authority"), "voip.bcrypto.com")
        XCTAssertEqual(value(":path"), "/.well-known/masque/udp/217.160.65.35/3478/")
        XCTAssertEqual(value("capsule-protocol"), "?1")
        XCTAssertEqual(value("authorization"), "Bearer tok123")
    }

    func testConnectUdpOmitsAuthWhenNoToken() {
        let req = MasqueConnectUdpRequest(
            proxyAuthority: "h", targetHost: "1.2.3.4", targetPort: 5349)
        XCTAssertFalse(req.headerFields().contains { $0.name == "authorization" })
    }

    func testIPv6TargetHostIsPercentEncoded() {
        let req = MasqueConnectUdpRequest(
            proxyAuthority: "h", targetHost: "fd00::1", targetPort: 3478)
        // The colons in the IPv6 literal must be %3A inside the single segment.
        XCTAssertEqual(req.path, "/.well-known/masque/udp/fd00%3A%3A1/3478/")
    }

    // MARK: - TURN URL → UDP target

    func testParseTurnTargetIPv4() {
        let t = MasqueConnectUdpRequest.parseTurnTarget("turn:217.160.65.35:3478?transport=udp")
        XCTAssertEqual(t?.host, "217.160.65.35")
        XCTAssertEqual(t?.port, 3478)
    }

    func testParseTurnsTargetTLS() {
        let t = MasqueConnectUdpRequest.parseTurnTarget("turns:turn.bcrypto.com:5349?transport=tcp")
        XCTAssertEqual(t?.host, "turn.bcrypto.com")
        XCTAssertEqual(t?.port, 5349)
    }

    func testParseTurnTargetIPv6() {
        let t = MasqueConnectUdpRequest.parseTurnTarget("turn:[fd00::1]:3478")
        XCTAssertEqual(t?.host, "fd00::1")
        XCTAssertEqual(t?.port, 3478)
    }

    func testParseTurnTargetRejectsNonTurnAndMissingPort() {
        XCTAssertNil(MasqueConnectUdpRequest.parseTurnTarget("stun:1.2.3.4:3478"))
        XCTAssertNil(MasqueConnectUdpRequest.parseTurnTarget("turn:1.2.3.4"))
        XCTAssertNil(MasqueConnectUdpRequest.parseTurnTarget("turn:1.2.3.4:notaport"))
    }
}
