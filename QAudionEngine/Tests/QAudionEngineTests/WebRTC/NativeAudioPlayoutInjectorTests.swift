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

    // MARK: - overwritten (pure overwrite-and-clamp, W-RXGHOSTFIX)

    /// Was additive ("mix") — changed after a live test found real relayed
    /// audio audible but blended with a "ghost" underneath, traced to
    /// WebRTC's own NetEQ concealment/comfort-noise filler for the peer's
    /// muted native sender still occupying the buffer we were adding onto.
    func test_overwritten_replacesDestinationRatherThanAdding() {
        let destination: [Float] = [500, 100, -100]
        let samples: [Int16] = [10, 20, -30]
        let result = NativeAudioPlayoutInjector.overwritten(destination: destination, with: samples)
        XCTAssertEqual(result, [10, 20, -30], "must REPLACE the ghost/comfort-noise filler, not blend with it")
    }

    func test_overwritten_clampsToFloatS16Range() {
        let destination: [Float] = [0, 0]
        let samples: [Int16] = [32767, -32768]
        let result = NativeAudioPlayoutInjector.overwritten(destination: destination, with: samples)
        XCTAssertEqual(result, [32767.0, -32768.0])
    }

    func test_overwritten_leavesTrailingDestinationUntouchedWhenFewerSamples() {
        let destination: [Float] = [1, 2, 3, 4]
        let samples: [Int16] = [10]
        let result = NativeAudioPlayoutInjector.overwritten(destination: destination, with: samples)
        XCTAssertEqual(result, [10, 2, 3, 4], "positions beyond what we have queued must stay untouched, not zeroed")
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

    // MARK: - resample / inject rate handling (W-RXINJECTRATE)

    /// A route change (e.g. to the earpiece) commonly negotiates a rate
    /// other than 48 kHz — `NativeAudioPcmTap`'s own doc already documents
    /// 24 kHz as the everyday earpiece case, not an edge case. `resample`
    /// must actually resample rather than silently pass through mismatched
    /// data (the live bug this fix closed: injecting 48kHz-paced samples
    /// into a lower-rate buffer plays back sped up and pitch-shifted).
    /// `AVAudioConverter`'s own real filter needs a few buffers to prime for
    /// a genuine rate change (see `NativeAudioPcmTap.int16LEData`'s own
    /// BUGFIX note) — several calls here, same as a real call's repeated
    /// 60 ms decode chunks, mirrors that instead of asserting on the very
    /// first one.
    func test_resample_toLowerRateEventuallyProducesShorterOutput() {
        let injector = NativeAudioPlayoutInjector(capacitySamples: 100_000)
        let frameCount = 2880 // 60 ms @ 48 kHz, this app's audio profile
        var samples: [Int16] = []
        samples.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            samples.append(Int16(sin(2.0 * Double.pi * 300.0 * Double(i) / 48_000.0) * 10_000.0))
        }
        var data = Data(capacity: frameCount * MemoryLayout<Int16>.size)
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }

        var resampled: Data?
        for _ in 0..<5 {
            resampled = injector.resample(data, targetSampleRate: 24_000)
        }

        let outCount = (resampled?.count ?? 0) / MemoryLayout<Int16>.size
        XCTAssertGreaterThan(outCount, 0, "after priming, resampling to 24kHz must produce real output")
        XCTAssertLessThan(outCount, frameCount, "half-rate output must be shorter than the 48kHz input")
    }

    func test_resample_sameRateDoesNotChangeSampleCount() {
        let injector = NativeAudioPlayoutInjector(capacitySamples: 16)
        let samples: [Int16] = [1000, -2000, 3000, -4000]
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }

        let result = injector.resample(data, targetSampleRate: Double(AudioConstants.sampleRate))
        XCTAssertEqual(result?.count, data.count, "resampling to the SAME rate must not change the sample count")
    }

    func test_inject_resamplesWhenNegotiatedRateDiffers() {
        let injector = NativeAudioPlayoutInjector(capacitySamples: 100_000)
        injector.audioProcessingInitialize(sampleRate: 24_000, channels: 1)

        let frameCount = 2880
        var samples: [Int16] = []
        samples.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            samples.append(Int16(sin(2.0 * Double.pi * 300.0 * Double(i) / 48_000.0) * 10_000.0))
        }
        var data = Data(capacity: frameCount * MemoryLayout<Int16>.size)
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }

        for _ in 0..<5 {
            injector.inject(data)
        }

        let queued = injector.pop(maxCount: 1_000_000)
        XCTAssertGreaterThan(queued.count, 0, "after priming, resampled audio must have been queued")
        XCTAssertLessThan(queued.count, frameCount * 5, "queuing at 24kHz must hold fewer samples than the raw 48kHz input pushed")
    }

    func test_inject_isExactPassthroughWhenNegotiatedRateMatches() {
        let injector = NativeAudioPlayoutInjector(capacitySamples: 100)
        injector.audioProcessingInitialize(sampleRate: AudioConstants.sampleRate, channels: 1)

        let samples: [Int16] = [10, 20, 30]
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }

        injector.inject(data)

        XCTAssertEqual(injector.pop(maxCount: 3), samples, "matching rate must be an exact passthrough, no resample artifacts")
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
