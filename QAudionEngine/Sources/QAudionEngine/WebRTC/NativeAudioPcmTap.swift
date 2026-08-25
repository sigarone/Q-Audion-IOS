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
/// `RTCAudioTrack.addRenderer(_:)` / `RTCAudioRenderer.render(pcmBuffer:)`
/// are grep-verified against the REAL header at the exact pinned commit this
/// vendored `WebRTC` binaryTarget builds from (`webrtc-sdk/webrtc.git`,
/// branch `m144_release` — same commit family `Package.swift`'s comment
/// cites for the AES-256 patch): `sdk/objc/api/peerconnection/
/// RTCAudioTrack.h` declares `-(void)addRenderer:(id<RTCAudioRenderer>)
/// renderer;` and `sdk/objc/base/RTCAudioRenderer.h` declares the protocol
/// method `-(void)renderPCMBuffer:(AVAudioPCMBuffer *)pcmBuffer
/// NS_SWIFT_NAME(render(pcmBuffer:));` — fetched and read in full via `gh api`
/// against that exact branch during this task, not assumed from memory (same
/// discipline C4a used for `LKRTCFrameCryptor`). `addRenderer`/
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
                                          lock: lock) else { return }
        sink(data)
    }

    /// Convert an arbitrary-format `AVAudioPCMBuffer` (WebRTC's ADM may hand
    /// back Float32 deinterleaved, Int16, mono or stereo, at whatever rate
    /// the active `AVAudioSession`/ADM negotiated) to little-endian Int16
    /// mono `Data` at `targetSampleRate`. Multi-channel input is downmixed
    /// by averaging channels (voice call audio; stereo-image loss is
    /// irrelevant to every consumer here — they all want a mono speech
    /// signal). Builds (and caches) an `AVAudioConverter` only when the
    /// input format actually differs from the target, so the common case
    /// (ADM already at 48 kHz mono) is a cheap direct memcpy-style loop.
    static func int16LEData(
        from buffer: AVAudioPCMBuffer,
        targetSampleRate: Double,
        converter: inout AVAudioConverter?,
        converterInputFormat: inout AVAudioFormat?,
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
        lock.lock()
        let needsNewConverter = converter == nil || converterInputFormat != inFormat
        if needsNewConverter {
            converter = AVAudioConverter(from: inFormat, to: targetFormat)
            converterInputFormat = inFormat
        }
        let activeConverter = converter
        lock.unlock()

        guard let activeConverter else { return nil }

        // VERIFICATION GAP (no Xcode/Swift toolchain on this box): the
        // `AVAudioConverter.convert(to:error:withInputFrom:)` push-style API
        // and `AVAudioConverterInputStatus`/`AVAudioConverterOutputStatus`
        // are stable public Foundation/AVFoundation API (not part of the
        // vendored WebRTC binary, so no framework-pinning risk the way
        // `RTCFrameCryptor` has), used here in its standard documented
        // "one-shot single input buffer" shape — but this exact call could
        // not be compiled/exercised in this session. First real Xcode build
        // must confirm; report to orchestrator either way.
        let ratio = targetSampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return nil }

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
            }
            return nil
        }
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
