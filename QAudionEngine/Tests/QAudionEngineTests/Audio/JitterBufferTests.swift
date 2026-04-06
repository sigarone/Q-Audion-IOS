import XCTest
@testable import QAudionEngine

final class JitterBufferTests: XCTestCase {
    func testPushPop() {
        let buf = JitterBuffer(capacity: 5)
        let frame = Data(repeating: 0xAA, count: 100)
        buf.push(frame)
        XCTAssertEqual(buf.size, 1)
        XCTAssertEqual(buf.pop(), frame)
        XCTAssertEqual(buf.size, 0)
    }
    func testPopEmpty() {
        let buf = JitterBuffer(capacity: 5)
        XCTAssertNil(buf.pop())
        XCTAssertEqual(buf.underrunCount, 1)
    }
    func testOverrunDiscardsOldest() {
        let buf = JitterBuffer(capacity: 2)
        buf.push(Data([0x01])); buf.push(Data([0x02])); buf.push(Data([0x03]))
        XCTAssertEqual(buf.overrunCount, 1)
        XCTAssertEqual(buf.pop(), Data([0x02]))
    }
    func testClear() {
        let buf = JitterBuffer(capacity: 10)
        buf.push(Data([0x01])); buf.push(Data([0x02]))
        buf.clear()
        XCTAssertEqual(buf.size, 0)
        XCTAssertTrue(buf.isEmpty)
    }
    func testComfortNoise() {
        XCTAssertEqual(JitterBuffer(capacity: 5).generateComfortNoise().count, AudioConstants.bytesPerFrame)
    }
    func testFIFOOrder() {
        let buf = JitterBuffer(capacity: 10)
        buf.push(Data([0x01])); buf.push(Data([0x02])); buf.push(Data([0x03]))
        XCTAssertEqual(buf.pop(), Data([0x01]))
        XCTAssertEqual(buf.pop(), Data([0x02]))
        XCTAssertEqual(buf.pop(), Data([0x03]))
    }
}
