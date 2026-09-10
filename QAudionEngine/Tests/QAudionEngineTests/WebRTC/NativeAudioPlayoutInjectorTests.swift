import XCTest
#if canImport(WebRTC)
import WebRTC
#endif
@testable import QAudionEngine

/// W-RXFALLBACKINJECT (2026-09-10) — tests for `NativeAudioPlayoutInjector`.
///
/// `audioProcessingProcess(audioBuffer:)` itself cannot be unit-tested:
/// `RTCAudioBuffer`'s only initializer takes a raw `webrtc::AudioBuffer*` and
/// is not reachable from test code (same limitation
/// `NativeAudioCaptureTapTests` already documents for the TX side). The
/// ring-buffer (`push`/`pop`) and the mix-and-clamp math (`mixed`) are the
/// whole of that method's real logic, split out specifically so both are
/// directly testable — covering both here covers the RX injection path end
/// to end short of the real native callback.
final class NativeAudioPlayoutInjectorTests: XCTestCase {
    #if canImport(WebRTC)

    // MARK: - mixed (pure add-and-clamp)

    func test_mixed_addsSamplesOntoDestination() {
        let destination: [Float] = [0, 100, -100]
        let samples: [Int16] = [10, 20, -30]
        let result = NativeAudioPlayoutInjector.mixed(destination: destination, adding: samples)
        XCTAssertEqual(result, [10, 120, -130])
    }

    func test_mixed_clampsToFloatS16Range() {
        let destination: [Float] = [32000, -32000]
        let samples: [Int16] = [32767, -32768]
        let result = NativeAudioPlayoutInjector.mixed(destination: destination, adding: samples)
        XCTAssertEqual(result, [32768.0, -32768.0], "sum must clamp to WebRTC's own FloatS16 range, never wrap")
    }

    func test_mixed_leavesTrailingDestinationUntouchedWhenFewerSamples() {
        let destination: [Float] = [1, 2, 3, 4]
        let samples: [Int16] = [10]
        let result = NativeAudioPlayoutInjector.mixed(destination: destination, adding: samples)
        XCTAssertEqual(result, [11, 2, 3, 4])
    }

    // MARK: - push / pop (ring buffer)

    func test_pushThenPop_returnsSamplesInFIFOOrder() {
        let injector = NativeAudioPlayoutInjector(capacitySamples: 16)
        let samples: [Int16] = [1, 2, 3]
        samples.withUnsafeBufferPointer { injector.push($0) }

        XCTAssertEqual(injector.pop(maxCount: 3), [1, 2, 3])
    }

    func test_pop_returnsFewerThanRequestedWhenUnderfilled() {
        let injector = NativeAudioPlayoutInjector(capacitySamples: 16)
        let samples: [Int16] = [7, 8]
        samples.withUnsafeBufferPointer { injector.push($0) }

        XCTAssertEqual(injector.pop(maxCount: 10), [7, 8], "must never block/pad waiting for more than is actually queued")
    }

    func test_pop_returnsEmptyWhenNothingQueued() {
        let injector = NativeAudioPlayoutInjector(capacitySamples: 16)
        XCTAssertEqual(injector.pop(maxCount: 5), [])
    }

    func test_push_dropsOldestSamplesOnOverflow() {
        let injector = NativeAudioPlayoutInjector(capacitySamples: 4)
        let samples: [Int16] = [1, 2, 3, 4, 5, 6]
        samples.withUnsafeBufferPointer { injector.push($0) }

        // Capacity 4, pushed 6 -> the two OLDEST (1, 2) must have been
        // dropped to make room, never the producer blocked or the newest
        // data lost — matches this app's other jitter buffers' drop-oldest
        // policy.
        XCTAssertEqual(injector.pop(maxCount: 4), [3, 4, 5, 6])
    }

    func test_resetForNewCall_clearsQueuedAudio() {
        let injector = NativeAudioPlayoutInjector(capacitySamples: 16)
        let samples: [Int16] = [1, 2, 3]
        samples.withUnsafeBufferPointer { injector.push($0) }

        injector.resetForNewCall()

        XCTAssertEqual(injector.pop(maxCount: 3), [], "a call boundary must not leak the previous call's audio into the next")
    }

    // MARK: - inject(_:) (the real Data entry point)

    func test_inject_littleEndianDataRoundTripsToOriginalSamples() {
        let injector = NativeAudioPlayoutInjector(capacitySamples: 16)
        let samples: [Int16] = [1000, -2000, 32767, -32768]
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }

        injector.inject(data)

        XCTAssertEqual(injector.pop(maxCount: samples.count), samples)
    }

    func test_inject_emptyDataIsANoOp() {
        let injector = NativeAudioPlayoutInjector(capacitySamples: 16)
        injector.inject(Data())
        XCTAssertEqual(injector.pop(maxCount: 4), [])
    }

    // MARK: - Lifecycle methods don't require a real RTCAudioBuffer

    func test_initializeAndRelease_neverCrashWithoutAProcessCall() {
        let injector = NativeAudioPlayoutInjector(capacitySamples: 16)
        injector.audioProcessingInitialize(sampleRate: 48_000, channels: 1)
        injector.audioProcessingRelease()
        injector.audioProcessingInitialize(sampleRate: 24_000, channels: 1)
    }

    #else
    func testWebRTCNotAvailableInThisTarget() {
        XCTAssertTrue(true, "WebRTC framework not available in this target — skipping")
    }
    #endif
}
