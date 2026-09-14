import Foundation
import AVFoundation
#if canImport(WebRTC)
import WebRTC

/// IOS-C4b / PCM-TAP PARITY — TX-tap correction (2026-09-08).
///
/// `NativeAudioPcmTap` (`RTCAudioRenderer`, `track.add(_:)`) works for the
/// REMOTE (RX) track but never fires on the LOCAL (mic) track: libwebrtc's
/// `LocalAudioSource::AddSink` (pc/local_audio_source.h) is an empty
/// override in this pinned build (grep-verified against the exact pinned
/// `webrtc-sdk/webrtc@m144_release` commit, not assumed) — `RTCAudioTrack.
/// add(_:)` on `QAudionPeerConnection.localAudioSrtpTrack` silently produced
/// zero PCM for the whole life of every native-audio-srtp call. This type is
/// the real TX hook: an `RTCAudioCustomProcessingDelegate` attached to
/// `RTCDefaultAudioProcessingModule.capturePostProcessingDelegate`
/// (`QAudionPeerConnectionFactory.sharedFactory`'s returned module), which
/// fires on the ACTUAL capture-side APM output — i.e. after hardware
/// AEC/NS/AGC, the same signal that gets encoded and sent — once per ~10 ms
/// audio-processing callback, on WebRTC's own audio-processing thread
/// (native `AudioCustomProcessingAdapter::Process`, which `os_unfair_lock_
/// trylock`s and SKIPS the callback entirely if still busy — same never-
/// block contract as `NativeAudioPcmTap.render`'s sink).
///
/// Output format: little-endian Int16 mono PCM at `AudioConstants.
/// sampleRate` (48 kHz) — reuses `NativeAudioPcmTap.int16LEData` verbatim
/// for the resample/downmix/Int16 conversion (same target shape every
/// existing sealed-DataChannel consumer already expects), fed through
/// `planarFloatBuffer(channels:sampleRate:)` below to bridge
/// `RTCAudioBuffer`'s native planar-Float32 shape into the
/// `AVAudioPCMBuffer` that function operates on.
///
/// W-PERSISTENTFACTORY (2026-09-09) — `capturePostProcessingDelegate` now
/// lives on the PROCESS-LIFETIME `RTCDefaultAudioProcessingModule`
/// `QAudionPeerConnectionFactory.sharedFactory` builds once and reuses for
/// every call (previously a fresh factory/ADM/APM triple per call — that
/// per-call teardown/recreate cycle is what caused a permanent native-
/// capture latch starting at call #2, see `QAudionPeerConnectionFactory`'s
/// own kdoc). This is still safe across calls without extra bookkeeping:
/// the property is `weak`, each call's `addLocalAudioTrack()` assigns its
/// OWN fresh `NativeAudioCaptureTap` instance to it, and this app only ever
/// runs one 1:1 call at a time — so a new call's assignment simply replaces
/// the previous call's (already-closed) tap in that one weak slot, with no
/// two calls ever contending for it concurrently.
public final class NativeAudioCaptureTap: NSObject, RTCAudioCustomProcessingDelegate, @unchecked Sendable {
    private let sink: (Data) -> Void
    private let targetSampleRate: Double
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var consecutiveEmptyConversions = 0
    private let lock = NSLock()
    /// Set by `audioProcessingInitialize`, which the adapter always calls
    /// before the first `audioProcessingProcess` (native `Initialize()`
    /// precedes `Process()` per the `webrtc::CustomProcessing` contract, and
    /// `SetDelegate` re-fires it immediately for an already-running module —
    /// see `RTCAudioCustomProcessingAdapter.mm`). The pre-init default is a
    /// defensive fallback only, never exercised on a real call.
    private var processingSampleRate: Double

    /// - Parameters:
    ///   - targetSampleRate: output sample rate, matching
    ///     `AudioConstants.sampleRate` (48 000) by default.
    ///   - sink: called synchronously on WebRTC's audio-processing thread
    ///     with each converted little-endian Int16 mono PCM chunk. MUST NOT
    ///     block — same contract as `NativeAudioPcmTap`'s sink.
    public init(targetSampleRate: Double = Double(AudioConstants.sampleRate), sink: @escaping (Data) -> Void) {
        self.targetSampleRate = targetSampleRate
        self.processingSampleRate = targetSampleRate
        self.sink = sink
        super.init()
    }

    public func audioProcessingInitialize(sampleRate: Int, channels: Int) {
        lock.lock()
        processingSampleRate = Double(sampleRate)
        // A (re-)initialize means the APM's own pipeline rate changed —
        // same "rebuild on input-format change" reset point `int16LEData`'s
        // general path already documents for a route change.
        converter = nil
        converterInputFormat = nil
        consecutiveEmptyConversions = 0
        lock.unlock()
    }

    public func audioProcessingProcess(audioBuffer: RTCAudioBuffer) {
        let channelCount = audioBuffer.channels
        let frameCount = audioBuffer.frames
        guard channelCount > 0, frameCount > 0 else { return }

        var channels: [[Float]] = []
        channels.reserveCapacity(channelCount)
        for ch in 0..<channelCount {
            let raw = UnsafeBufferPointer(start: audioBuffer.rawBuffer(forChannel: ch), count: frameCount)
            channels.append(Self.floatS16ToNormalized(raw))
        }

        guard let inBuffer = Self.planarFloatBuffer(channels: channels, sampleRate: processingSampleRate) else { return }
        guard let data = NativeAudioPcmTap.int16LEData(from: inBuffer,
                                                        targetSampleRate: targetSampleRate,
                                                        converter: &converter,
                                                        converterInputFormat: &converterInputFormat,
                                                        consecutiveEmptyConversions: &consecutiveEmptyConversions,
                                                        lock: lock) else { return }
        sink(data)
    }

    public func audioProcessingRelease() {
        lock.lock()
        converter = nil
        converterInputFormat = nil
        lock.unlock()
    }

    /// W-CAPSCALEFIX (2026-09-10) — `RTCAudioBuffer.rawBuffer(forChannel:)`
    /// returns `webrtc::AudioBuffer::channels()` UNSCALED (grep-verified
    /// against `RTCAudioBuffer.mm`'s real implementation at the pinned
    /// commit: `return _audioBuffer->channels()[channel];`, no rescale). That
    /// C++ class stores samples in WebRTC's own "FloatS16" convention —
    /// `float [-32768.0, 32768.0]`, the SAME scale as an `int16_t` sample
    /// just widened to `float` — per `common_audio/include/audio_util.h`'s
    /// own documented naming convention for every `S16`/`Float`/`FloatS16`
    /// conversion helper in that file. `planarFloatBuffer` below packages
    /// its input into an `AVAudioPCMBuffer` tagged `.pcmFormatFloat32`, and
    /// `NativeAudioPcmTap.int16LEData`'s `AVAudioConverter` step (reused
    /// here) treats ANY `.pcmFormatFloat32` buffer as Core Audio's own
    /// normalized convention — `float [-1.0, 1.0]` — when it rescales to
    /// Int16. Feeding it raw FloatS16 samples unscaled meant real speech
    /// (routinely hundreds to low thousands in FloatS16 units) was ~32768x
    /// louder than the converter's assumed full scale, so it hard-clipped to
    /// +/-32767 for nearly every non-near-zero sample — this file's own test
    /// suite (`NativeAudioCaptureTapTests`, `[0.1, -0.2, 0.3...]`/sine*0.5)
    /// only ever exercised `planarFloatBuffer` directly with already-
    /// normalized input, so this never had coverage. This divide-by-32768
    /// step is the missing FloatS16 -> normalized-Float32 conversion,
    /// applied once, right at the point the raw native buffer is read —
    /// everything downstream (`planarFloatBuffer`, `int16LEData`) already
    /// expects Core Audio's normalized convention and needs no other change.
    static func floatS16ToNormalized(_ samples: UnsafeBufferPointer<Float>) -> [Float] {
        let scale: Float = 1.0 / 32768.0
        return samples.map { $0 * scale }
    }

    /// Wraps planar (non-interleaved) Float32 channel data — the exact shape
    /// `RTCAudioBuffer.rawBuffer(forChannel:)` exposes — into an
    /// `AVAudioPCMBuffer`, so `NativeAudioPcmTap.int16LEData` can be reused
    /// unchanged for the resample/downmix/Int16 conversion.
    ///
    /// `RTCAudioBuffer.rawBuffer(forChannel:)` indexes
    /// `webrtc::AudioBuffer::channels()` — the FULL-BAND, `num_frames()`-long
    /// per-channel buffer — not the split-band `split_channels()`/
    /// `num_bands()` representation those two extra properties expose (grep-
    /// verified against `RTCAudioBuffer.mm`'s implementation at the pinned
    /// commit); every frame passed here is a real full-band sample, no band
    /// de-interleaving needed.
    ///
    /// Pure function (no WebRTC types in its signature) so it is directly
    /// unit-testable without a real, native-only `RTCAudioBuffer` — that
    /// type's only initializer (`initWithNativeType:`) takes a raw
    /// `webrtc::AudioBuffer*` and is not constructible from test code.
    static func planarFloatBuffer(channels: [[Float]], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let frameCount = channels.first?.count, frameCount > 0, sampleRate > 0,
              channels.allSatisfy({ $0.count == frameCount }),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels.count),
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let dst = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for (ch, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                dst[ch].update(from: base, count: frameCount)
            }
        }
        return buffer
    }
}
#endif
