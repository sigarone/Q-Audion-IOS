import XCTest
import AVFoundation
#if canImport(WebRTC)
import WebRTC
#endif
@testable import QAudionEngine

/// IOS-C4b TX-TAP FIX (2026-09-08) — tests for `NativeAudioCaptureTap.
/// planarFloatBuffer`, the pure conversion step that bridges
/// `RTCAudioBuffer`'s native planar-Float32 shape into the
/// `AVAudioPCMBuffer` `NativeAudioPcmTap.int16LEData` already operates on.
///
/// `RTCAudioCustomProcessingDelegate.audioProcessingProcess(audioBuffer:)`
/// itself cannot be unit-tested: `RTCAudioBuffer`'s only initializer
/// (`initWithNativeType:`) takes a raw `webrtc::AudioBuffer*` and is not
/// reachable from test code (same reason `NativeAudioPcmTapTests` tests
/// `int16LEData` directly instead of going through a live `RTCAudioTrack`).
/// `planarFloatBuffer` plus the existing, already-tested `int16LEData` is
/// the whole of `audioProcessingProcess`'s real logic, so exercising both in
/// sequence here covers the TX conversion path end to end.
final class NativeAudioCaptureTapTests: XCTestCase {
    #if canImport(WebRTC)

    // MARK: - planarFloatBuffer

    func test_planarFloatBuffer_monoProducesCorrectFormatAndSamples() {
        let samples: [Float] = [0.1, -0.2, 0.3, -0.4, 0.5]
        let buffer = NativeAudioCaptureTap.planarFloatBuffer(channels: [samples], sampleRate: 48_000)

        XCTAssertNotNil(buffer)
        XCTAssertEqual(buffer?.format.sampleRate, 48_000)
        XCTAssertEqual(buffer?.format.channelCount, 1)
        XCTAssertFalse(buffer?.format.isInterleaved ?? true, "RTCAudioBuffer is planar — must stay non-interleaved")
        XCTAssertEqual(buffer?.frameLength, AVAudioFrameCount(samples.count))

        let ch = buffer?.floatChannelData?[0]
        for (i, expected) in samples.enumerated() {
            XCTAssertEqual(ch?[i], expected, "sample \(i) mismatched")
        }
    }

    func test_planarFloatBuffer_stereoKeepsChannelsIndependent() {
        let left: [Float] = [1, 2, 3, 4]
        let right: [Float] = [-1, -2, -3, -4]
        let buffer = NativeAudioCaptureTap.planarFloatBuffer(channels: [left, right], sampleRate: 48_000)

        XCTAssertEqual(buffer?.format.channelCount, 2)
        let dst = buffer?.floatChannelData
        for i in 0..<4 {
            XCTAssertEqual(dst?[0][i], left[i])
            XCTAssertEqual(dst?[1][i], right[i])
        }
    }

    func test_planarFloatBuffer_rejectsEmptyChannelList() {
        XCTAssertNil(NativeAudioCaptureTap.planarFloatBuffer(channels: [], sampleRate: 48_000))
    }

    func test_planarFloatBuffer_rejectsEmptyFrames() {
        XCTAssertNil(NativeAudioCaptureTap.planarFloatBuffer(channels: [[]], sampleRate: 48_000))
    }

    func test_planarFloatBuffer_rejectsMismatchedChannelLengths() {
        XCTAssertNil(NativeAudioCaptureTap.planarFloatBuffer(channels: [[1, 2, 3], [1, 2]], sampleRate: 48_000))
    }

    func test_planarFloatBuffer_rejectsNonPositiveSampleRate() {
        XCTAssertNil(NativeAudioCaptureTap.planarFloatBuffer(channels: [[1, 2, 3]], sampleRate: 0))
    }

    // MARK: - End-to-end: planarFloatBuffer -> int16LEData (the real audioProcessingProcess path)

    /// The scenario `audioProcessingProcess` hits on every real call: mono
    /// capture-side Float32 PCM at whatever rate the APM is actually
    /// running (commonly 48 kHz, same as the target here so this exercises
    /// `int16LEData`'s fast-adjacent conversion path, not a resample).
    func test_endToEnd_planarFloatToInt16LE_producesRealNonSilentOutput() {
        let frameCount = 480 // 10 ms @ 48 kHz
        var samples: [Float] = []
        samples.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            samples.append(Float(sin(2.0 * Double.pi * 300.0 * Double(i) / 48_000.0)) * 0.5)
        }

        guard let inBuffer = NativeAudioCaptureTap.planarFloatBuffer(channels: [samples], sampleRate: 48_000) else {
            return XCTFail("planarFloatBuffer must succeed for valid mono input")
        }

        var converter: AVAudioConverter?
        var converterInputFormat: AVAudioFormat?
        var consecutiveEmpty = 0
        let lock = NSLock()
        let data = NativeAudioPcmTap.int16LEData(
            from: inBuffer, targetSampleRate: 48_000,
            converter: &converter, converterInputFormat: &converterInputFormat,
            consecutiveEmptyConversions: &consecutiveEmpty, lock: lock)

        XCTAssertNotNil(data, "a valid mono Float32 capture buffer must convert to Int16 LE PCM")
        XCTAssertEqual(data?.count, frameCount * MemoryLayout<Int16>.size)

        // Not a silence run of zero bytes — the tone must actually survive
        // the Float32 -> Int16 conversion (this is exactly the signal a
        // dead/never-firing tap would be indistinguishable from otherwise).
        let hasNonZeroSample = data?.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            raw.bindMemory(to: Int16.self).contains { $0 != 0 }
        } ?? false
        XCTAssertTrue(hasNonZeroSample, "converted PCM must contain real (non-zero) samples")
    }

    /// Same end-to-end path with a stereo capture buffer, the downmix case
    /// `int16LEData`'s general (`AVAudioConverter`) path already handles —
    /// asserts the TX bridge doesn't break that existing guarantee.
    func test_endToEnd_stereoPlanarDownmixesToMonoInt16LE() {
        let frameCount = 480
        let left = [Float](repeating: 0.4, count: frameCount)
        let right = [Float](repeating: -0.4, count: frameCount)
        guard let inBuffer = NativeAudioCaptureTap.planarFloatBuffer(channels: [left, right], sampleRate: 48_000) else {
            return XCTFail("planarFloatBuffer must succeed for valid stereo input")
        }

        var converter: AVAudioConverter?
        var converterInputFormat: AVAudioFormat?
        var consecutiveEmpty = 0
        let lock = NSLock()
        let data = NativeAudioPcmTap.int16LEData(
            from: inBuffer, targetSampleRate: 48_000,
            converter: &converter, converterInputFormat: &converterInputFormat,
            consecutiveEmptyConversions: &consecutiveEmpty, lock: lock)

        XCTAssertNotNil(data, "a valid stereo Float32 capture buffer must downmix to mono Int16 LE PCM")
        XCTAssertGreaterThan(data?.count ?? 0, 0)
    }

    // MARK: - Lifecycle methods don't require a real RTCAudioBuffer

    func test_initializeAndRelease_neverCrashWithoutAProcessCall() {
        let tap = NativeAudioCaptureTap(targetSampleRate: 48_000, sink: { _ in
            XCTFail("sink must not fire — no audioProcessingProcess call was made")
        })
        tap.audioProcessingInitialize(sampleRate: 24_000, channels: 1)
        tap.audioProcessingRelease()
        // Re-initialize after release, mirroring a route change followed by
        // a fresh APM Initialize() — must also not crash or fire the sink.
        tap.audioProcessingInitialize(sampleRate: 48_000, channels: 1)
    }

    #else
    func testWebRTCNotAvailableInThisTarget() {
        XCTAssertTrue(true, "WebRTC framework not available in this target — skipping")
    }
    #endif
}
