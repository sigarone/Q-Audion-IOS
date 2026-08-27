import XCTest
import AVFoundation
#if canImport(WebRTC)
import WebRTC
#endif
@testable import QAudionEngine

/// IOS-C4b / PCM-TAP PARITY — tests for `NativeAudioPcmTap.int16LEData`, the
/// pure(-ish) conversion function feeding the native-audio-srtp voice-
/// analysis/spectrum pipeline (see that type's own doc for the full
/// incident: two same-day "BUGFIX" comments on 2026-08-26 that fixed a real
/// `AVAudioConverter` misuse but only for a bit-depth/channel-only
/// conversion, then a third fix on 2026-08-27 for the case that actually
/// matters on a real device — a genuine SAMPLE-RATE change, which the real,
/// `gh api`-verified WebRTC ObjC renderer adapter
/// (`sdk/objc/api/RTCAudioRendererAdapter.mm`) hits routinely: it always
/// hands `render(pcmBuffer:)` Int16 interleaved PCM, but at whatever
/// `sample_rate` the ADM is actually running — commonly 24 kHz on the
/// iPhone's built-in earpiece route, not 48 kHz).
///
/// No `RTCAudioRenderer`/live WebRTC track needed here — `int16LEData` is a
/// `static func` operating purely on `AVAudioPCMBuffer`/`AVAudioConverter`
/// (AVFoundation, not WebRTC types), but the file that declares it is
/// wrapped in `#if canImport(WebRTC)` (the class conforms to
/// `RTCAudioRenderer`), so these tests are gated the same way.
final class NativeAudioPcmTapTests: XCTestCase {
    #if canImport(WebRTC)

    // MARK: - Helpers

    /// Builds an Int16 interleaved `AVAudioPCMBuffer` — the REAL format
    /// `RTCAudioRendererAdapter::OnData` always constructs (verified this
    /// session against the real `m144_release` source; see the type doc) —
    /// filled with a simple non-zero sine wave so a conversion's output can
    /// be checked for "did real audio survive" without depending on any
    /// particular sample value.
    private func makeInt16Buffer(sampleRate: Double, channels: AVAudioChannelCount,
                                  frameCount: Int, amplitude: Int16 = 8000,
                                  phaseOffset: Int = 0) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                                   channels: channels, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let ch = buffer.int16ChannelData![0]
        // ~300 Hz tone — comfortably inside voice band, never silent.
        for i in 0..<(frameCount * Int(channels)) {
            let t = Double(phaseOffset + i / Int(channels))
            let sample = Double(amplitude) * sin(2.0 * Double.pi * 300.0 * t / sampleRate)
            ch[i] = Int16(sample)
        }
        return buffer
    }

    // MARK: - Fast path (already Int16 mono interleaved @ target rate)

    func test_fastPath_roundTripsInt16MonoAtTargetRateByteForByte() {
        let buffer = makeInt16Buffer(sampleRate: 48_000, channels: 1, frameCount: 480)
        var converter: AVAudioConverter?
        var converterInputFormat: AVAudioFormat?
        var consecutiveEmpty = 0
        let lock = NSLock()

        let data = NativeAudioPcmTap.int16LEData(
            from: buffer, targetSampleRate: 48_000,
            converter: &converter, converterInputFormat: &converterInputFormat,
            consecutiveEmptyConversions: &consecutiveEmpty, lock: lock)

        XCTAssertNotNil(data, "fast path must never drop an already-matching buffer")
        XCTAssertEqual(data?.count, 480 * MemoryLayout<Int16>.size)
        // Fast path must not touch the general-path converter machinery.
        XCTAssertNil(converter, "fast path must not allocate an AVAudioConverter")

        let ch = buffer.int16ChannelData![0]
        data?.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<480 {
                XCTAssertEqual(samples[i], ch[i].littleEndian, "sample \(i) mismatched on round-trip")
            }
        }
    }

    // MARK: - General path — channel-only conversion (same rate, zero resampling latency)

    /// Same scenario the 2026-08-26 BUGFIX comments were confirmed against:
    /// no sample-rate change, so the converter's very first `convert()` call
    /// must already succeed. This is the regression guard for THAT fix
    /// staying correct after today's rewrite (no `.reset()`/`.endOfStream`).
    func test_generalPath_stereoToMonoSameRateProducesNonEmptyOutputOnFirstCall() {
        let buffer = makeInt16Buffer(sampleRate: 48_000, channels: 2, frameCount: 480)
        var converter: AVAudioConverter?
        var converterInputFormat: AVAudioFormat?
        var consecutiveEmpty = 0
        let lock = NSLock()

        let data = NativeAudioPcmTap.int16LEData(
            from: buffer, targetSampleRate: 48_000,
            converter: &converter, converterInputFormat: &converterInputFormat,
            consecutiveEmptyConversions: &consecutiveEmpty, lock: lock)

        XCTAssertNotNil(data, "a same-rate channel-only conversion has zero filter latency and must succeed immediately")
        XCTAssertNotNil(converter, "general path must build a converter for a channel-count mismatch")
        XCTAssertGreaterThan(data?.count ?? 0, 0)
    }

    // MARK: - General path — genuine sample-rate conversion (the real bug)

    /// The scenario this session's fix targets: 24 kHz mono Int16 in (the
    /// iPhone built-in earpiece route's common negotiated rate) up-sampled
    /// to 48 kHz, fed as a REAL continuous stream — one ~10 ms buffer per
    /// call, same persistent `converter`/`converterInputFormat` state
    /// threaded through every call, exactly like `NativeAudioPcmTap.render`
    /// does for the whole life of a call. The resampler may legitimately
    /// need a call or two to prime (see the BUGFIX note in
    /// `NativeAudioPcmTap.int16LEData`) — this asserts it reliably SETTLES
    /// into steady non-empty output well before the end of a normal call,
    /// which is the property the old `.reset()`+`.endOfStream`-every-call
    /// pattern could not guarantee (Apple's own documented contract for
    /// `.endOfStream`: "reaches the end of the stream, and doesn't return
    /// any data").
    func test_generalPath_realSampleRateChangeSettlesIntoSteadyNonEmptyOutput() {
        var converter: AVAudioConverter?
        var converterInputFormat: AVAudioFormat?
        var consecutiveEmpty = 0
        let lock = NSLock()

        let callbacks = 40
        let framesPerCallback = 240 // 10 ms @ 24 kHz
        var results: [Data?] = []
        for callIndex in 0..<callbacks {
            let buffer = makeInt16Buffer(sampleRate: 24_000, channels: 1,
                                         frameCount: framesPerCallback,
                                         phaseOffset: callIndex * framesPerCallback)
            let data = NativeAudioPcmTap.int16LEData(
                from: buffer, targetSampleRate: 48_000,
                converter: &converter, converterInputFormat: &converterInputFormat,
                consecutiveEmptyConversions: &consecutiveEmpty, lock: lock)
            results.append(data)
        }

        XCTAssertNotNil(converter, "general path must build a converter for a real sample-rate change")

        let nonEmptyCount = results.filter { ($0?.count ?? 0) > 0 }.count
        XCTAssertGreaterThan(nonEmptyCount, 0,
            "a real 24 kHz -> 48 kHz stream must eventually produce output — zero across \(callbacks) calls " +
            "reproduces the exact silent-tap symptom this fix addresses")

        // Steady state: once the resampler has seen a handful of real
        // buffers, it must not go silent again for the rest of the call —
        // that would mean the tap works for a moment and then drops out,
        // which is just as broken for a live meter as never working.
        let tail = results.suffix(10)
        let tailNonEmpty = tail.filter { ($0?.count ?? 0) > 0 }.count
        XCTAssertGreaterThanOrEqual(tailNonEmpty, 8,
            "expected steady non-empty output in the last 10 of \(callbacks) calls, got \(tailNonEmpty) — " +
            "converter never reached (or fell back out of) steady state")
    }

    /// The old converter-recreation bug this session's fix must not
    /// reintroduce: a route change mid-call (input format signature
    /// changes) must swap in a fresh converter and resume producing
    /// output, not get stuck reusing stale state bound to the old format.
    func test_generalPath_formatChangeMidStreamRebuildsConverterAndKeepsProducingOutput() {
        var converter: AVAudioConverter?
        var converterInputFormat: AVAudioFormat?
        var consecutiveEmpty = 0
        let lock = NSLock()

        // Prime at 24 kHz for a while (mirrors the earpiece route).
        for callIndex in 0..<20 {
            let buffer = makeInt16Buffer(sampleRate: 24_000, channels: 1, frameCount: 240,
                                         phaseOffset: callIndex * 240)
            _ = NativeAudioPcmTap.int16LEData(
                from: buffer, targetSampleRate: 48_000,
                converter: &converter, converterInputFormat: &converterInputFormat,
                consecutiveEmptyConversions: &consecutiveEmpty, lock: lock)
        }
        let converterBeforeRouteChange = converter

        // Route change: now 48 kHz stereo (e.g. switched to a Bluetooth/
        // wired accessory route).
        var resultsAfterRouteChange: [Data?] = []
        for callIndex in 0..<20 {
            let buffer = makeInt16Buffer(sampleRate: 48_000, channels: 2, frameCount: 480,
                                         phaseOffset: callIndex * 480)
            let data = NativeAudioPcmTap.int16LEData(
                from: buffer, targetSampleRate: 48_000,
                converter: &converter, converterInputFormat: &converterInputFormat,
                consecutiveEmptyConversions: &consecutiveEmpty, lock: lock)
            resultsAfterRouteChange.append(data)
        }

        XCTAssertFalse(converter === converterBeforeRouteChange,
                       "a real input-format change must rebuild the converter, not reuse the stale one")
        let tailNonEmpty = resultsAfterRouteChange.suffix(10).filter { ($0?.count ?? 0) > 0 }.count
        XCTAssertGreaterThanOrEqual(tailNonEmpty, 8,
            "must recover to steady non-empty output after a mid-call route/format change")
    }

    #endif
}
