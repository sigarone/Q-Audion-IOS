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
/// (`QAudionPeerConnectionFactory.createFactory`'s returned module), which
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
/// PER-CALL, NOT GLOBAL — `capturePostProcessingDelegate` lives on the
/// per-call `RTCDefaultAudioProcessingModule` `QAudionPeerConnectionFactory.
/// createFactory` mints (a fresh factory/ADM/APM triple per call, matching
/// `QAudionWebRtcCallController`'s existing per-call `createFactory` calls —
/// not the cached `.factory` singleton), so there is no cross-call
/// interference: two calls never share one APM instance.
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
            channels.append(Array(UnsafeBufferPointer(start: audioBuffer.rawBufferForChannel(ch), count: frameCount)))
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

    /// Wraps planar (non-interleaved) Float32 channel data — the exact shape
    /// `RTCAudioBuffer.rawBufferForChannel(_:)` exposes — into an
    /// `AVAudioPCMBuffer`, so `NativeAudioPcmTap.int16LEData` can be reused
    /// unchanged for the resample/downmix/Int16 conversion.
    ///
    /// `RTCAudioBuffer.rawBufferForChannel(_:)` indexes
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
