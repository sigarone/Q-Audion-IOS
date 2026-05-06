import XCTest
import CoreVideo
@testable import QAudionEngine

#if canImport(VideoToolbox)
/// Integration test for the HEVC encoder. Skipped on platforms / sims
/// without HEVC hardware (the CI Mac mini M2 has it; older runners may
/// not). When skipped, the test passes silently — the goal here is a
/// smoke test, not a regression KAT (HEVC bitstreams are not bit-stable
/// across encoder versions).
final class HevcEncoderTests: XCTestCase {

    func testStartAndEncodeOneFrame() throws {
        let encoder = HevcEncoder(width: 320, height: 240, bitrateBps: 200_000, fps: 24)
        do {
            try encoder.start()
        } catch {
            // HEVC HW unavailable on this runner — accept and skip.
            print("[HevcEncoderTests] start failed (likely HEVC HW unavailable): \(error)")
            throw XCTSkip("HEVC HW not available on this test runner")
        }
        defer { encoder.invalidate() }

        let nalExpect = expectation(description: "received at least one NAL unit")
        var receivedKeyFrame = false
        encoder.onNal = { nal, isKey in
            // Annex-B prefix must be 0x00 0x00 0x00 0x01.
            XCTAssertEqual(Array(nal.prefix(4)), [0x00, 0x00, 0x00, 0x01])
            if isKey { receivedKeyFrame = true }
            nalExpect.fulfill()
        }

        let pixelBuffer = try Self.makeBlankPixelBuffer(width: 320, height: 240)
        try encoder.encode(pixelBuffer: pixelBuffer)
        encoder.flush()

        wait(for: [nalExpect], timeout: 5.0)
        XCTAssertTrue(receivedKeyFrame, "first encoded frame should be a key frame (with VPS/SPS/PPS)")
    }

    private static func makeBlankPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferCGImageCompatibilityKey: false,
            kCVPixelBufferCGBitmapContextCompatibilityKey: false,
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let pb = pb else {
            throw NSError(domain: "test", code: Int(status))
        }
        // Fill Y plane with mid-grey so the encoder has actual entropy.
        CVPixelBufferLockBaseAddress(pb, [])
        if let yPtr = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            for row in 0..<height {
                memset(yPtr.advanced(by: row * yStride), 128, width)
            }
        }
        if let uvPtr = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            for row in 0..<(height / 2) {
                memset(uvPtr.advanced(by: row * uvStride), 128, width)
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }
}
#endif
