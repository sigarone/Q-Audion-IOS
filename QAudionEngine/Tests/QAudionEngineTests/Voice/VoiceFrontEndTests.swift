import XCTest
import Foundation
@testable import QAudionEngine

final class VoiceFrontEndTests: XCTestCase {

    /// A tap rate the resampler does not support leaves the front-end inactive for the rest of the call, even when a
    /// supported rate comes back.
    func testAnUnsupportedRateStaysInactive() throws {
        let bundle = try VoiceKat.bundle()
        let engine = VoiceFrontEnd(bundle: bundle, vad: StoredProbabilityVad([]))
        var released = 0
        engine.onChunk = { _ in released += 1 }

        let block = [Int16](repeating: 100, count: 441)
        try engine.onRx(block, rateHz: 44_100, tNs: 1_000_000_000, tapTicks: 0)
        XCTAssertTrue(engine.isInactive)
        let supported = [Int16](repeating: 100, count: 480)
        for i in 0..<400 {
            try engine.onRx(supported, rateHz: 48_000, tNs: 1_010_000_000 + Int64(i) * 10_000_000, tapTicks: Int64(i + 1) * 960)
        }
        engine.finish()
        XCTAssertTrue(engine.isInactive)
        XCTAssertEqual(released, 0)
        XCTAssertNil(engine.mediaStartNs)
    }
}
