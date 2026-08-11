import XCTest
@testable import QAudionEngine

final class MeshPacketTests: XCTestCase {

    private func nodeId(_ hex: String) throws -> MeshNodeId {
        try MeshNodeId(hex: hex)
    }

    func testEncodeDecodeRoundTripMinimal() throws {
        let sender = try nodeId("0011223344556677")
        let recipient = try nodeId("8899aabbccddeeff")
        let packet = try MeshPacket(
            type: .data, senderId: sender, recipientId: recipient,
            timestampMs: 1_700_000_000_123, payload: Data([0xDE, 0xAD, 0xBE, 0xEF])
        )
        let decoded = MeshPacket.decode(packet.encode())
        XCTAssertEqual(decoded, packet)
    }

    func testEncodeDecodeRoundTripWithTTLAndSourceRoute() throws {
        let sender = try nodeId("0011223344556677")
        let recipient = try nodeId("8899aabbccddeeff")
        let hop1 = try nodeId("1111111111111111")
        let hop2 = try nodeId("2222222222222222")
        let packet = try MeshPacket(
            type: .fragment, senderId: sender, recipientId: recipient,
            ttl: 5, sourceRoute: [hop1, hop2],
            timestampMs: 42, payload: Data(repeating: 0x7A, count: 100)
        )
        let decoded = MeshPacket.decode(packet.encode())
        XCTAssertEqual(decoded, packet)
        XCTAssertEqual(decoded?.ttl, 5)
        XCTAssertEqual(decoded?.sourceRoute, [hop1, hop2])
    }

    func testEncodeDecodeRoundTripBroadcastAnnounce() throws {
        let sender = try nodeId("a13f0c8e77b20001")
        let packet = try MeshPacket(
            type: .announce, senderId: sender, recipientId: .broadcast,
            timestampMs: 0, payload: Data()
        )
        let decoded = MeshPacket.decode(packet.encode())
        XCTAssertEqual(decoded, packet)
        XCTAssertEqual(decoded?.recipientId, .broadcast)
        XCTAssertNil(decoded?.ttl)
        XCTAssertTrue(decoded?.sourceRoute.isEmpty ?? false)
    }

    func testDecodeNeverThrowsOnGarbageBytes() {
        XCTAssertNil(MeshPacket.decode(Data([0xFF, 0xFF, 0xFF])))
        XCTAssertNil(MeshPacket.decode(Data()))
        XCTAssertNil(MeshPacket.decode(Data(repeating: 0x00, count: 3)))
    }

    func testDecodeRejectsUnknownType() throws {
        let sender = try nodeId("0011223344556677")
        let recipient = try nodeId("8899aabbccddeeff")
        var packet = try MeshPacket(
            type: .data, senderId: sender, recipientId: recipient,
            timestampMs: 1, payload: Data()
        ).encode()
        // Byte 1 is the type discriminator — corrupt it to an unassigned value.
        packet[packet.startIndex.advanced(by: 1)] = 0xEE
        XCTAssertNil(MeshPacket.decode(packet))
    }

    func testDecodeRejectsTruncatedPayload() throws {
        let sender = try nodeId("0011223344556677")
        let recipient = try nodeId("8899aabbccddeeff")
        let packet = try MeshPacket(
            type: .data, senderId: sender, recipientId: recipient,
            timestampMs: 1, payload: Data([1, 2, 3, 4, 5])
        )
        var bytes = packet.encode()
        bytes.removeLast(3) // claims 5 payload bytes but only 2 are present
        XCTAssertNil(MeshPacket.decode(bytes))
    }

    func testInitRejectsOversizedPayload() throws {
        let sender = try nodeId("0011223344556677")
        let recipient = try nodeId("8899aabbccddeeff")
        let oversized = Data(repeating: 0, count: MeshPacket.maxPayloadBytes + 1)
        XCTAssertThrowsError(try MeshPacket(
            type: .data, senderId: sender, recipientId: recipient,
            timestampMs: 0, payload: oversized
        ))
    }

    func testInitRejectsOutOfRangeTTL() throws {
        let sender = try nodeId("0011223344556677")
        let recipient = try nodeId("8899aabbccddeeff")
        XCTAssertThrowsError(try MeshPacket(
            type: .data, senderId: sender, recipientId: recipient,
            ttl: 256, timestampMs: 0, payload: Data()
        ))
    }

    func testWithTTLProducesNewInstanceWithOtherFieldsUnchanged() throws {
        let sender = try nodeId("0011223344556677")
        let recipient = try nodeId("8899aabbccddeeff")
        let packet = try MeshPacket(
            type: .data, senderId: sender, recipientId: recipient,
            ttl: 5, timestampMs: 99, payload: Data([1, 2, 3])
        )
        let relayed = packet.withTTL(4)
        XCTAssertEqual(relayed.ttl, 4)
        XCTAssertEqual(relayed.senderId, packet.senderId)
        XCTAssertEqual(relayed.payload, packet.payload)
        XCTAssertEqual(relayed.timestampMs, packet.timestampMs)
    }
}
