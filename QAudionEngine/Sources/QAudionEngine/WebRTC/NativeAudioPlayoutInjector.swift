import Foundation
#if canImport(WebRTC)
import WebRTC

/// W-RXFALLBACKINJECT (2026-09-10) — the RX/playout twin of
/// `NativeAudioCaptureTap`'s TX/capture fix, closing the OTHER half of the
/// same asymmetric-fallback defect.
///
/// WHY THIS FILE EXISTS: on a native-audio-srtp call, `startAudioIOIfReady`'s
/// IOS-C4b guard deliberately never starts this device's own `AudioCapture`
/// `AVAudioEngine` while the local native path is healthy — starting a
/// second duplex (mic+speaker) audio stack next to WebRTC's own already-live
/// VoiceProcessingIO unit is exactly the two-stacks contention that guard
/// exists to avoid (confirmed: WebRTC's own `audio_device_ios.mm` only
/// starts/stops that native unit on RTCAudioTrack add/remove, never on
/// `isEnabled`/`RTCAudioSession.isAudioEnabled` toggling — muting a track
/// does not free it). That guard is correct for THIS device's own send path.
///
/// But it left a real gap: if the PEER's own native TX dies and the peer
/// falls back to the legacy DataChannel/WS-relay pipeline for send, THIS
/// device still receives, decrypts, and decodes that peer's real audio
/// correctly (confirmed live: Guardian voice-analysis counters on the
/// decoded PCM advanced normally) — but `CallService.playDecodedLegacyPcm`
/// had nowhere to put it, since `audioCapture`'s engine was never running.
/// The PCM reached `AudioCapture.scheduleForPlayout`'s guard and was
/// silently dropped every time (confirmed live via `call.audio.diag`
/// telemetry across 3 independent test calls: `playout_dropped` in the
/// thousands, `speaker_route_ever=false`, on the device whose own native
/// path was otherwise healthy).
///
/// THE FIX: `RTCAudioCustomProcessingDelegate` attached to
/// `RTCDefaultAudioProcessingModule.renderPreProcessingDelegate` — a public
/// WebRTC extension point (already wired but left `nil` in
/// `QAudionPeerConnectionFactory.buildFactory()`) that runs once per ~10 ms
/// audio-processing callback on the RENDER (far-end/playout) stream, BEFORE
/// it reaches the native VoiceProcessingIO unit's output — i.e. the exact
/// signal about to hit the speaker. Mixing (adding, not replacing) queued
/// legacy-relay PCM into that buffer lets this one native audio unit render
/// both signals — no second engine, no route contention. Consulted
/// (`or-multi.ps1 -N 3`, 2026-09-10) against the two alternatives before
/// building this: a second playback-only `AVAudioEngine` (both models: high
/// risk — iOS treats VoiceProcessingIO as an exclusive I/O resource, a
/// second concurrent engine silently drops buffers or steals the route) and
/// fully detaching the native transceiver to fall over to legacy full-duplex
/// (functionally correct but a real mid-call SDP-renegotiation cost, an area
/// with its own prior incidents in this app). This render-injection pattern
/// is what both models converged on independently as the standard
/// production approach for mixing an extra audio source into an
/// already-live native pipeline.
///
/// SCALE (do not "fix" this to match `NativeAudioCaptureTap`'s W-CAPSCALEFIX
/// — the two run in OPPOSITE directions): `RTCAudioBuffer.rawBuffer(
/// forChannel:)` is WebRTC's own internal "FloatS16" scale (`float
/// [-32768, 32768]`, verified against `RTCAudioBuffer.mm`'s real source —
/// same citation as the capture-side fix). `NativeAudioCaptureTap` reads
/// FROM that scale and must DIVIDE by 32768 before handing samples to a
/// Core-Audio-convention (`float [-1, 1]`) `AVAudioPCMBuffer`/
/// `AVAudioConverter`. This type does the reverse: it WRITES directly into
/// that same raw native buffer, in place, with no Core Audio API in
/// between — so an `Int16` sample needs only a direct cast to `Float`, never
/// a division. Getting this backwards would make injected audio ~32768x too
/// quiet (silence in practice) instead of correctly mixed.
///
/// THREAD SAFETY: `inject(_:)` is called from the decode path (main queue,
/// see `CallService.handleIncomingEncryptedFrame`); `audioProcessingProcess`
/// runs on WebRTC's own real-time audio-processing thread. Both sides hold
/// the SAME lock only for a short fixed-size array copy — no allocation, no
/// blocking call, matching `NativeAudioCaptureTap`'s own "cheap enough to
/// hold across it, nothing else ever contends" reasoning.
///
/// LIFETIME: one instance lives for the whole process, built once alongside
/// the persistent factory/APM in `QAudionPeerConnectionFactory.buildFactory()`
/// (`W-PERSISTENTFACTORY`) — unlike `NativeAudioCaptureTap`, which needs a
/// fresh per-call instance because its `sink` closure captures per-call TX
/// routing state, this type takes no per-call state, so `resetForNewCall()`
/// (called from `CallService`'s own per-call teardown) is enough to keep one
/// call's leftover buffered audio from bleeding into the next.
public final class NativeAudioPlayoutInjector: NSObject, RTCAudioCustomProcessingDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var ringBuffer: [Int16]
    private let capacity: Int
    private var readIndex = 0
    private var writeIndex = 0
    private var filledCount = 0

    /// - Parameter capacitySamples: bound on how much queued audio this can
    ///   hold before dropping the OLDEST sample to make room (same
    ///   drop-oldest-never-block-the-producer policy every other jitter
    ///   buffer in this app already uses). Default is 1 second at
    ///   `AudioConstants.sampleRate` — generous headroom for the decode
    ///   path's own delivery jitter without letting latency creep unbounded.
    public init(capacitySamples: Int = AudioConstants.sampleRate) {
        self.capacity = max(capacitySamples, AudioConstants.samplesPerFrame * 4)
        self.ringBuffer = [Int16](repeating: 0, count: self.capacity)
        super.init()
    }

    /// Called from `CallService.playDecodedLegacyPcm` with little-endian
    /// Int16 mono PCM at `AudioConstants.sampleRate` (48 kHz) — the same
    /// format `QAudionCallIntegration.processIncomingAudio` always returns,
    /// so no resample is needed here; `audioProcessingProcess` below writes
    /// samples straight into the native render buffer at whatever rate the
    /// APM actually negotiated, which matches 48 kHz on every real call this
    /// app makes (see `AudioConstants`). MUST NOT block for long.
    public func inject(_ pcm: Data) {
        let sampleCount = pcm.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return }
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            push(raw.bindMemory(to: Int16.self))
        }
    }

    /// Drops any audio queued by a call that just ended, so it cannot bleed
    /// into the next call's render stream. Call from the same per-call
    /// teardown path that resets this service's other per-call audio state.
    public func resetForNewCall() {
        lock.lock()
        readIndex = 0
        writeIndex = 0
        filledCount = 0
        lock.unlock()
    }

    public func audioProcessingInitialize(sampleRate: Int, channels: Int) {
        // No per-call state depends on the negotiated rate/channel count —
        // see this type's own doc for why no resample step is needed here.
    }

    public func audioProcessingProcess(audioBuffer: RTCAudioBuffer) {
        let frameCount = audioBuffer.frames
        guard frameCount > 0, audioBuffer.channels > 0 else { return }

        let popped = pop(maxCount: frameCount)
        guard !popped.isEmpty else { return }

        // Mix (add, not replace) so this coexists correctly with whatever
        // the native unit is already rendering — silence/comfort noise on
        // the common path this exists for (the peer muted its native
        // sender), but additive stays correct even when it isn't. See this
        // type's own SCALE note: a direct cast, never a division, because
        // this writes straight into WebRTC's own FloatS16-scale buffer.
        for channel in 0..<audioBuffer.channels {
            let dst = audioBuffer.rawBuffer(forChannel: channel)
            let existing = Array(UnsafeBufferPointer(start: dst, count: popped.count))
            let mixed = Self.mixed(destination: existing, adding: popped)
            for i in 0..<popped.count {
                dst[i] = mixed[i]
            }
        }
    }

    public func audioProcessingRelease() {
        resetForNewCall()
    }

    /// Ring-buffer write half of `inject(_:)`, split out so a plain `[Int16]`
    /// (constructible from test code, unlike a real `Data`-backed
    /// `UnsafeBufferPointer` from a live decode) exercises the SAME
    /// drop-oldest-on-overflow logic the real audio path runs.
    func push(_ samples: UnsafeBufferPointer<Int16>) {
        lock.lock()
        defer { lock.unlock() }
        for sample in samples {
            if filledCount >= capacity {
                readIndex = (readIndex + 1) % capacity
                filledCount -= 1
            }
            ringBuffer[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
            filledCount += 1
        }
    }

    /// Ring-buffer read half of `audioProcessingProcess`, split out for the
    /// same test-reachability reason as `push(_:)` above. Returns up to
    /// `maxCount` samples in FIFO order (fewer if less is queued — the
    /// caller pads/handles the shortfall as silence, never blocks waiting
    /// for more).
    func pop(maxCount: Int) -> [Int16] {
        lock.lock()
        defer { lock.unlock() }
        let available = min(filledCount, maxCount)
        var popped = [Int16](repeating: 0, count: available)
        for i in 0..<available {
            popped[i] = ringBuffer[readIndex]
            readIndex = (readIndex + 1) % capacity
        }
        filledCount -= available
        return popped
    }

    /// Pure add-and-clamp mix, split out from `audioProcessingProcess` so it
    /// is directly unit-testable without a real (test-unconstructible)
    /// `RTCAudioBuffer` — same testability pattern as
    /// `NativeAudioCaptureTap.planarFloatBuffer`. Clamps to WebRTC's own
    /// FloatS16 range (`[-32768, 32768]`, see this type's SCALE note) so a
    /// loud injected sample landing on top of real native signal can't wrap
    /// or otherwise corrupt the buffer.
    static func mixed(destination: [Float], adding samples: [Int16]) -> [Float] {
        var result = destination
        for i in 0..<min(destination.count, samples.count) {
            let sum = destination[i] + Float(samples[i])
            result[i] = min(32768.0, max(-32768.0, sum))
        }
        return result
    }
}
#endif
