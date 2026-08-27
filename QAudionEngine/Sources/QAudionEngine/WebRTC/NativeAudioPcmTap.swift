import Foundation
import AVFoundation
#if canImport(WebRTC)
import WebRTC

/// IOS-C4b / PCM-TAP PARITY (2026-08-26) — the audio-srtp equivalent of
/// Android's `PeerConnectionFactoryProvider.audioSrtpTxSink`/
/// `audioSrtpRxSink` (`W-AUDIOSRTPFEATUREPARITY`, 2026-08-24).
///
/// WHY THIS FILE EXISTS (do not remove without re-reading this doc): when a
/// call negotiates ``CallCapabilities/audioSrtpV1``, `CallService`'s manual
/// AVAudioEngine capture/decode pipeline is bypassed (native WebRTC owns
/// capture + playout directly via its own audio device module) — and
/// `QAudionCallIntegration.processIncomingAudio` is the ONLY place that ever
/// runs on decoded call PCM: it is what feeds `guardianMode`
/// (DeepfakeMonitor-equivalent anti-spoofing), `contactVoiceVerifier` (Tier 2
/// "voce remota"), `voiceLearningSession` (Feature B "voce verificata"),
/// `voiceAnalysis` (pitch/formant/confidence — FormantTracker/PitchExtractor/
/// ConfidenceIndicator via `VoiceAnalysisEngine`), and `spectrumExtractor`
/// (Guardian ribbon spectrum) — see that method's own doc. A native-SRTP call
/// receives NO serialized DataChannel/WS frame at all (the peer sends real
/// RTP, not sealed frames), so without an equivalent tap on the native path
/// every one of those consumers silently sees zero frames for the call's
/// whole life. This is Android's real, shipped, one-day-earlier incident
/// (`CallCapabilities.kt:337-349`) — confirmed present on iOS by tracing
/// `VoiceLearningSession`'s own doc ("frames are fed from the exact same tap
/// point already used by the Guardian anti-spoof pipeline") to
/// `QAudionCallIntegration.analyze(_:)`, which is reached ONLY from
/// `processIncomingAudio`.
///
/// `RTCAudioTrack.add(_:)` / `RTCAudioRenderer.render(pcmBuffer:)`
/// are grep-verified against the REAL header at the exact pinned commit this
/// vendored `WebRTC` binaryTarget builds from (`webrtc-sdk/webrtc.git`,
/// branch `m144_release` — same commit family `Package.swift`'s comment
/// cites for the AES-256 patch): `sdk/objc/api/peerconnection/
/// RTCAudioTrack.h` declares `-(void)addRenderer:(id<RTCAudioRenderer>)
/// renderer;` and `sdk/objc/base/RTCAudioRenderer.h` declares the protocol
/// method `-(void)renderPCMBuffer:(AVAudioPCMBuffer *)pcmBuffer
/// NS_SWIFT_NAME(render(pcmBuffer:));` — fetched and read in full via `gh api`
/// against that exact branch during this task, not assumed from memory (same
/// discipline C4a used for `LKRTCFrameCryptor`). CORRECTION (2026-08-26,
/// first real CI compile): the ObjC selector is `addRenderer:`, but Swift's
/// automatic API-name importer drops "Renderer" from the Swift-visible name
/// because it matches the parameter type (`RTCAudioRenderer`) — the actual
/// Swift call is `track.add(_:)`, confirmed by the compiler's own rename
/// diagnostic on the first CI build, not by re-reading the header (a plain
/// header grep cannot show Swift's importer-side renaming). `addRenderer`/
/// `removeRenderer` are declared on the base `RTCAudioTrack` class (shared by
/// local and remote tracks), so the SAME renderer type attaches to either a
/// local (TX/mic) or remote (RX/peer) track — mirroring Android's TX/RX sink
/// pair exactly.
///
/// Output format: little-endian Int16 mono PCM at
/// `AudioConstants.sampleRate` (48 kHz) — the SAME layout the sealed-
/// DataChannel decode path already hands to `enqueueForAnalysis`/
/// `ownerContinuityMonitor.feed` (see `spectrumExtractor.compute`'s own
/// "Little-endian Int16 PCM @ 48 kHz" comment in
/// `QAudionCallIntegration.analyze`), so the SAME consumer methods can be
/// reused verbatim — no new parsing/consumer code, only a new PRODUCER.
public final class NativeAudioPcmTap: NSObject, RTCAudioRenderer, @unchecked Sendable {
    private let sink: (Data) -> Void
    private let targetSampleRate: Double
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    /// Live-debug watchdog only (see the BUGFIX note in `int16LEData`) —
    /// counts consecutive general-path conversions that produced zero
    /// frames, so a genuinely stuck converter can be told apart from the
    /// resampler's brief, expected priming window at the start of a call
    /// or after a route change, without flooding the log every ~10 ms.
    private var consecutiveEmptyConversions = 0
    private let lock = NSLock()

    /// - Parameters:
    ///   - targetSampleRate: output sample rate, matching
    ///     `AudioConstants.sampleRate` (48 000) by default — the rate every
    ///     existing RX/TX consumer already assumes.
    ///   - sink: called synchronously on WebRTC's own audio callback thread
    ///     with each converted little-endian Int16 mono PCM chunk. MUST NOT
    ///     block — same never-block contract as
    ///     `QAudionCallIntegration.enqueueForAnalysis`/
    ///     `OwnerContinuityMonitor.feed`, both of which already only enqueue.
    public init(targetSampleRate: Double = Double(AudioConstants.sampleRate), sink: @escaping (Data) -> Void) {
        self.targetSampleRate = targetSampleRate
        self.sink = sink
        super.init()
    }

    public func render(pcmBuffer: AVAudioPCMBuffer) {
        guard let data = Self.int16LEData(from: pcmBuffer,
                                          targetSampleRate: targetSampleRate,
                                          converter: &converter,
                                          converterInputFormat: &converterInputFormat,
                                          consecutiveEmptyConversions: &consecutiveEmptyConversions,
                                          lock: lock) else { return }
        sink(data)
    }

    /// Convert an arbitrary-format `AVAudioPCMBuffer` to little-endian
    /// Int16 mono `Data` at `targetSampleRate`.
    ///
    /// CORRECTION (2026-08-27) — the doc here previously claimed WebRTC's
    /// ADM "may hand back Float32 deinterleaved... at whatever rate the
    /// active AVAudioSession/ADM negotiated", framing the rate mismatch as
    /// a maybe. Verified against the REAL pinned source this session
    /// (`sdk/objc/api/RTCAudioRendererAdapter.mm`'s `OnData`, fetched via
    /// `gh api` against `webrtc-sdk/webrtc@m144_release`, the exact branch
    /// this file's own top-of-file doc already cites): the buffer handed to
    /// `render(pcmBuffer:)` is ALWAYS `AVAudioPCMFormatInt16`, interleaved
    /// — never Float32 — but `sample_rate` is whatever the ADM is actually
    /// running, NOT hardcoded to 48 kHz. On iOS that is a real, everyday
    /// mismatch, not a corner case: the built-in EARPIECE route commonly
    /// negotiates 24 kHz for a voice-mode `AVAudioSession`. So the "fast
    /// path" below (bit-for-bit copy) only ever fires when the ADM happens
    /// to already be at `targetSampleRate`; a genuine resample through
    /// `AVAudioConverter` is the routine case, not the exception, on a
    /// route like the earpiece — see the BUGFIX note further down for why
    /// that matters. Multi-channel input is downmixed by averaging channels
    /// (voice call audio; stereo-image loss is irrelevant to every consumer
    /// here — they all want a mono speech signal). Builds (and caches) an
    /// `AVAudioConverter` only when the input format actually differs from
    /// the target, so the common case (ADM already at 48 kHz mono) is a
    /// cheap direct memcpy-style loop.
    static func int16LEData(
        from buffer: AVAudioPCMBuffer,
        targetSampleRate: Double,
        converter: inout AVAudioConverter?,
        converterInputFormat: inout AVAudioFormat?,
        consecutiveEmptyConversions: inout Int,
        lock: NSLock
    ) -> Data? {
        let inFormat = buffer.format
        guard inFormat.sampleRate > 0, buffer.frameLength > 0 else { return nil }

        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: targetSampleRate,
                                         channels: 1,
                                         interleaved: true)
        guard let targetFormat else { return nil }

        // Fast path: already mono Int16 interleaved at the target rate.
        if inFormat.commonFormat == .pcmFormatInt16,
           inFormat.channelCount == 1,
           inFormat.sampleRate == targetSampleRate,
           inFormat.isInterleaved,
           let ch = buffer.int16ChannelData {
            consecutiveEmptyConversions = 0
            let count = Int(buffer.frameLength)
            var data = Data(capacity: count * MemoryLayout<Int16>.size)
            let ptr = ch[0]
            for i in 0..<count {
                withUnsafeBytes(of: ptr[i].littleEndian) { data.append(contentsOf: $0) }
            }
            return data
        }

        // General path: build/reuse an AVAudioConverter to mono Int16 @
        // targetSampleRate. Rebuilt only when the INPUT format's own
        // signature changes mid-call (e.g. a route change that alters the
        // hardware sample rate) — cheap comparison, avoids reallocating a
        // converter on every single buffer in the common steady-state case.
        //
        // THREAD-SAFETY (2026-08-27, independent review) — the WHOLE
        // critical section below (converter lookup/creation, the
        // `convert()` call itself, and the empty-streak counter) is now
        // held under ONE lock acquisition for the rest of this function,
        // not just the converter pointer swap. `AVAudioConverter` is not
        // documented as safe for concurrent use on the same instance, and
        // `render(pcmBuffer:)`'s own doc only claims it runs "on WebRTC's
        // own audio callback thread" — not that it is guaranteed serial.
        // Releasing the lock before calling `convert()` (as a prior
        // version of this function did) would let two overlapping
        // `render()` calls corrupt the SAME converter's internal
        // (unsynchronized) resampler state. A ~10-20 ms buffer's worth of
        // conversion is cheap enough that holding this PER-TAP-INSTANCE
        // lock across it costs nothing measurable — nothing else ever
        // contends for it.
        lock.lock()
        defer { lock.unlock() }

        let needsNewConverter = converter == nil || converterInputFormat != inFormat
        if needsNewConverter {
            converter = AVAudioConverter(from: inFormat, to: targetFormat)
            converterInputFormat = inFormat
            consecutiveEmptyConversions = 0
            // Live-debug: fires only on (re)creation — once per call in
            // the common case, again on a route change — never
            // per-buffer, so this is cheap. Confirms on the NEXT real
            // call whether the general (resampling) path is actually
            // engaged and at what input rate, settling whether the
            // earpiece-route theory in the BUGFIX note below is what
            // tonight's call hit.
            print("[NativeAudioPcmTap] general path (re)built converter: in sr=\(inFormat.sampleRate) ch=\(inFormat.channelCount) interleaved=\(inFormat.isInterleaved) commonFormat=\(inFormat.commonFormat.rawValue) -> target sr=\(targetSampleRate) mono int16, converterCreated=\(converter != nil)")
        }

        guard let activeConverter = converter else { return nil }

        let ratio = targetSampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return nil }

        // BUGFIX (2026-08-27, second real live call, still silent) —
        // superseding the two same-day fixes above (`.reset()` before
        // every `convert()`, `.endOfStream` on the second pull): they
        // fixed a REAL bug (the pre-existing `.noDataNow`-only code
        // returned empty forever after the first successful convert), but
        // only for a bit-depth/channel-only conversion, which is the ONLY
        // case they were confirmed against. `.reset()`+`.endOfStream`
        // forces a full FLUSH-AND-TERMINATE of the converter's internal
        // state on literally every single ~10 ms callback — harmless when
        // there is no real resampling filter (zero group delay, so a
        // one-shot flush of one buffer always has everything it needs),
        // but for a GENUINE sample-rate change the filter needs to
        // accumulate a few real buffers of history before it can emit
        // anything, and Apple's own documented contract for
        // `.endOfStream` is explicit: "reaches the end of the stream, and
        // doesn't return any data." Forcing that on a single buffer that
        // hasn't primed the filter yet is a DOCUMENTED way to get zero
        // frames back — every call, for the whole call, because `.reset()`
        // wipes any history right back to nothing before the next attempt
        // ever gets a chance to accumulate it.
        //
        // This is not a corner case here: the real WebRTC ObjC renderer
        // adapter (`sdk/objc/api/RTCAudioRendererAdapter.mm`'s `OnData`,
        // verified via `gh api` against the real pinned `m144_release`
        // source — see the doc comment above) hands `render(pcmBuffer:)`
        // Int16 interleaved PCM at whatever `sample_rate` the ADM is
        // actually running, not hardcoded to 48 kHz — and the iPhone
        // built-in EARPIECE route commonly negotiates 24 kHz for a
        // voice-mode `AVAudioSession`, an everyday iOS routing fact, not
        // an edge case.
        //
        // Fix: stop treating each buffer as an isolated one-shot stream.
        // `activeConverter` already lives for the call's whole life
        // (rebuilt only when `needsNewConverter` above detects the INPUT
        // format itself changed, e.g. a route change — which is the
        // correct, natural reset point). Never call `.reset()` and never
        // signal `.endOfStream` here; signal `.noDataNow` instead ("no
        // more input on THIS pull, but the stream keeps going"), which
        // lets the converter's internal resampler state accumulate across
        // calls exactly like a real continuous stream. It may legitimately
        // return zero frames for the first call or two after
        // (re)creation while it primes — tracked by
        // `consecutiveEmptyConversions` purely as a live-debug signal, see
        // that property's doc — then settle into steady, non-empty output
        // for the rest of the call, instead of never producing any.
        var delivered = false
        var conversionError: NSError?
        activeConverter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
            if delivered {
                outStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, outBuffer.frameLength > 0, let ch = outBuffer.int16ChannelData else {
            if let conversionError {
                print("[NativeAudioPcmTap] AVAudioConverter failed: \(conversionError.localizedDescription)")
            } else {
                // Expected during the resampler's brief priming window
                // (see above) — only worth a live-debug signal if it NEVER
                // recovers, so this is deliberately logged just twice
                // (~0.5s and ~2s of continuous emptiness at a ~10 ms
                // cadence) rather than every callback.
                consecutiveEmptyConversions += 1
                let streak = consecutiveEmptyConversions
                if streak == 50 || streak == 200 {
                    print("[NativeAudioPcmTap] general path produced EMPTY output for \(streak) consecutive buffers — converter may be stuck (in sr=\(inFormat.sampleRate) ch=\(inFormat.channelCount) -> target sr=\(targetSampleRate))")
                }
            }
            return nil
        }
        consecutiveEmptyConversions = 0
        let count = Int(outBuffer.frameLength)
        var data = Data(capacity: count * MemoryLayout<Int16>.size)
        let ptr = ch[0]
        for i in 0..<count {
            withUnsafeBytes(of: ptr[i].littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
#endif
