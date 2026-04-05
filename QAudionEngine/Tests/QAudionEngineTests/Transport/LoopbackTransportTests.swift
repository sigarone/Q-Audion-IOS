import XCTest
@testable import QAudionEngine

final class LoopbackTransportTests: XCTestCase {
    func testSendReceiveRoundTrip() {
        let transport = LoopbackTransport()
        transport.open(config: ChannelConfig(mode: .loopback))
        let expectation = XCTestExpectation(description: "Frame received")
        var receivedFrame: EncryptedFrame?
        transport.setOnFrameReceived { frame in receivedFrame = frame; expectation.fulfill() }
        transport.send(EncryptedFrame(sequenceNumber: 1, timestamp: 12345,
            nonce: Data(repeating: 0xAA, count: 12), payload: Data([0x01, 0x02]),
            tag: Data(repeating: 0xBB, count: 16)))
        wait(for: [expectation], timeout: 2.0)
        XCTAssertNotNil(receivedFrame)
        XCTAssertEqual(receivedFrame?.sequenceNumber, 1)
    }
    func testIsOpen() {
        let t = LoopbackTransport()
        XCTAssertFalse(t.isOpen())
        t.open(config: ChannelConfig(mode: .loopback))
        XCTAssertTrue(t.isOpen())
        t.close()
        XCTAssertFalse(t.isOpen())
    }
    func testStats() {
        let t = LoopbackTransport()
        t.open(config: ChannelConfig(mode: .loopback))
        t.setOnFrameReceived { _ in }
        t.send(EncryptedFrame(sequenceNumber: 0, timestamp: 0,
            nonce: Data(repeating: 0, count: 12), payload: Data(), tag: Data(repeating: 0, count: 16)))
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(t.getStats().framesSent, 1)
        XCTAssertEqual(t.getStats().framesReceived, 1)
    }
}
