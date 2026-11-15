import XCTest
import Foundation
@testable import QAudionEngine

final class VoiceTimeMapTests: XCTestCase {

    /// Dropping the blocks behind the read position, including the periodic compaction of the block list, never changes
    /// the time of a position that is still ahead.
    func testTrimmingKeepsTheAnswers() {
        let rate = 48_000
        let trimmed = VoiceTimeMap(rate: rate)
        let whole = VoiceTimeMap(rate: rate)
        var clock: Int64 = 1_000_000_000_000
        var state: UInt64 = 12_345
        var total = 0
        for _ in 0..<12_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let length = 100 + Int((state >> 33) % 900)
            let jitter = Int64((state >> 40) % 3_000_000)
            total += length
            clock += Int64(length) * 1_000_000_000 / Int64(rate) + jitter
            trimmed.append(count: length, tNs: clock)
            whole.append(count: length, tNs: clock)
        }
        var position = 5_000
        var checked = 0
        while position < total - 5_000 {
            XCTAssertEqual(trimmed.tNs(num: position, den: 2), whole.tNs(num: position, den: 2), "position \(position)")
            XCTAssertEqual(trimmed.tNs(num: position + 301, den: 2), whole.tNs(num: position + 301, den: 2))
            trimmed.trim(before: position - 600, den: 2)
            position += 7_001
            checked += 1
        }
        XCTAssertGreaterThan(checked, 500)
    }
}
