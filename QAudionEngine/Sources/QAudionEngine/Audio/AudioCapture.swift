import Foundation
#if canImport(AVFoundation)
import AVFoundation

public final class AudioCapture {
    public var onFrame: ((Data) -> Void)?
    private var engine: AVAudioEngine?
    // SINGLE-ENGINE FIX — playback player node hosted on the SAME AVAudioEngine
    // as the capture tap. Two SEPARATE AVAudioEngine instances on one
    // AVAudioSession both instantiate the single hardware RemoteIO / Voice-
    // Processing I/O unit; starting the second one tears down the first's
    // OUTPUT route → the session reports "active" and engines report "started"
    // but NO PCM ever reaches the DAC → total silence in BOTH directions
    // (capture/input keeps working, which is why tx_enc grew while nobody heard
    // anything). Confirmed independently by OpenRouter (large) + Gemini + the
    // RemoteIO mechanism. One engine owning BOTH the input tap and the player
    // node fixes it — and lets VP-IO's AEC reference the playback for echo
    // cancellation, the canonical VoIP graph.
    private var playerNode: AVAudioPlayerNode?
    private var playFormat: AVAudioFormat?
    private var isRunning = false
    // W-AEC-FIX — VP-IO input-pull sink: when Voice-Processing I/O is active the
    // inputNode tap starves on iPad + builtInSpeaker unless the mic is actively
    // pulled through the graph; this muted mixer is that pull (see start()).
    private var inputSink: AVAudioMixerNode?
    // W-AEC-FIX — set true by the tap callback on its first delivered buffer.
    // The starve watchdog checks it to detect the VP-IO "tap never fires" case.
    private var firstFrameReceived = false
    private let audioPipeline: AudioProcessingPipeline
    // W475 — re-chunking accumulator. `installTap` delivers buffers of
    // an arbitrary size; the Opus encoder needs EXACTLY bytesPerFrame.
    // Touched only on the single tap-callback thread, so no lock.
    private var pcmAccumulator = Data()
    // AGC-DIAG (2026-07-10) — cheap per-call level tracker to get real
    // evidence on suspected AGC pumping/crackling near the mic on the
    // speaker route (W574c enables AGC there on purpose — see
    // AudioProcessingPipeline.enableVoiceProcessing). Int comparisons only,
    // no allocation, on samples already decoded for the accumulator above —
    // safe on the 50fps tap callback. `clipThreshold` is ~97% of Int16
    // full-scale (32767); `consumeLevelStats()` reads+resets at call end.
    private var peakAmplitude: Int16 = 0
    private var clipSampleCount: Int64 = 0
    private static let clipThreshold: Int16 = 31800
    // W-MICAGC (2026-07-12) — gentle software make-up AGC. Server telemetry
    // showed the iOS mic ships systematically quiet (tx peak median ~5%, RMS ~1%
    // of full scale) because VP-IO/AGC is OFF on the earpiece route (W556) and
    // the TX-LIMITER below only CAPS peaks, never lifts level. This is the
    // middle ground between "raw = too quiet" and "Apple VP-IO AGC = spara
    // troppo / pumping": a SLOW, BOOST-ONLY make-up gain toward a target RMS,
    // gated on voice (never amplifies silence/background hiss) and capped so an
    // already-loud frame is never over-driven (the limiter still backstops
    // peaks). ONLY runs when VP-IO is inactive — when VP-IO is on, Apple's own
    // AGC is already normalising, so stacking ours would double-boost. Lock-free
    // single-thread state (the 50 fps tap callback). Killswitch if it regresses.
    public static var micAgcEnabled = true
    private var micAgcGain: Float = 1.0
    private var micAgcMaxGainThisCall: Float = 1.0   // for telemetry
    // W-DEZIPPER (2026-07-12) — the gain actually applied to the LAST sample of
    // the previous frame. The make-up gain is ramped per-sample from this to the
    // current frame's target so the gain is continuous across the 20 ms frame
    // boundary; a constant-per-frame gain that changes frame-to-frame steps the
    // waveform at each boundary → an audible click every frame ("scoppiettante").
    private var micAgcRampFrom: Float = 1.0
    private static let agcTargetRms: Float = 0.12    // 12% of full scale
    // W-QUIETMIC (2026-07-12) — the iPhone earpiece mic sits very low on normal
    // speech: telemetry across calls c591a0b2/28398a12/7b03662a shows raw RMS
    // ~0.5–1.1% even at normal volume, so the old 2% gate held the AGC OFF for
    // most real speech → faint + inconsistent level ("non lineare"). Dropped to
    // 0.8%: engages on normal-quiet speech but still sits above the measured
    // room-noise floor (<0.8%), so silence/hiss is never pumped up (VP-IO NS is
    // off — W556). Above-gate speech is boosted toward agcTargetRms as intended.
    private static let agcNoiseGate: Float = 0.008   // below this = silence → hold gain
    private static let agcMaxGain: Float = 6.0
    // When VP-IO is active Apple's own AGC already contributes some make-up
    // gain, so our software make-up runs ON TOP of it with a lower ceiling to
    // bound any double-AGC interaction (still boost-only + noise-gated + slow,
    // so it can't pump). Evidence (call c4185402): iOS mic is intrinsically
    // quiet — ~5% peak raw, ~11% with VP-IO's AGC — vs Android ~71%; gating our
    // AGC to VP-IO-off left the transmitted level faint. Lifting under VP-IO too
    // closes that gap.
    private static let agcMaxGainVpio: Float = 3.0
    private static let agcPeakHeadroom: Float = 0.90 // never boost a frame's peak past 90%
    // TX-RMS (2026-07-12) — sum of squares + sample count for the mic RMS,
    // accumulated on the same 50fps tap callback as peakAmplitude (no lock,
    // no extra decode). `consumeLevelStats()` folds these into `rms` (in Int16
    // sample units) and resets them; CallService reports it as tx `rms_pct`.
    private var sumSqAmplitude: Double = 0
    private var rmsSampleCount: Int64 = 0
    /// Read the accumulated peak/clip/rms stats for the CURRENT call and reset
    /// them for the next one. Call from teardown, before `stop()` clears
    /// other per-call state. `rms` is in Int16 sample units (0…32767).
    public func consumeLevelStats() -> (peak: Int16, clipSamples: Int64, rms: Double, agcGain: Float) {
        let rms = rmsSampleCount > 0 ? (sumSqAmplitude / Double(rmsSampleCount)).squareRoot() : 0
        let stats = (peakAmplitude, clipSampleCount, rms, micAgcMaxGainThisCall)
        peakAmplitude = 0
        clipSampleCount = 0
        sumSqAmplitude = 0
        rmsSampleCount = 0
        micAgcMaxGainThisCall = 1.0
        return stats
    }
    // M-12 — AVAudioSession interruption (phone call, Siri, alarm)
    // handling. Without this the capture engine stays dead after an
    // interruption ends, silently killing call audio.
    private var interruptionObserver: NSObjectProtocol?
    private var wasInterrupted = false
    // W571 — route change observer (headset plug/unplug, Bluetooth connect/
    // disconnect). Without this, when a Bluetooth HFP device disconnects
    // the AVAudioEngine silently routes to the built-in speaker — correct
    // routing — but if the built-in microphone is at a different sample
    // rate or format the engine enters a degraded state: capture tap
    // continues on the old format → frame-size mismatches → Opus encode
    // errors or silence. Restarting the engine on route change ensures
    // the tap format matches the new hardware route.
    private var routeChangeObserver: NSObjectProtocol?

    // W574o — route-change anti-thrash. A flapping Bluetooth HFP link (and the
    // engine restart itself re-running AVAudioSession route selection) fired
    // new/oldDeviceAvailable several times per second; restarting on each one
    // thrashed the audio path so decrypted voice never played steadily (device
    // telemetry 1.0.658: route flapped BT↔built-in every ~1-2s while frames were
    // decrypting fine). Two purely time-based guards, no timers / no thread change:
    //   * throttle  — at most one route-driven restart per second;
    //   * suppress  — ignore the route change our OWN restart provokes (~0.6s),
    //                 which breaks the self-induced restart loop.
    private var lastEngineRestart: Date = .distantPast
    private var restartSuppressUntil: Date = .distantPast
    private let routeRestartThrottle: TimeInterval = 1.0

    // W-SPKFIX (2026-07-12) — in-call speaker toggle. `AppState.setSpeaker`
    // flips the OUTPUT route by adding `.defaultToSpeaker` to setCategory AND
    // calling overrideOutputAudioPort. On iOS 26 the *category* change fires a
    // route notification with reason `.categoryChange` (the override is then a
    // no-op → no `.override`), and handleRouteChange only rebuilt the engine on
    // `.override`/device cases — so `.categoryChange` fell through and the
    // engine was NEVER rebuilt for the new route. The single VP-IO/RemoteIO
    // graph's input tap silently dies when the underlying output route flips
    // out from under it: TX (mic) stopped the instant speaker was pressed and
    // never recovered (confirmed call 92dab394, v1.0.767 — RX kept flowing, TX
    // heartbeat froze at 250). Fix: detect the speaker<->earpiece flip
    // REASON-AGNOSTICALLY (compare the live route against the route the engine
    // was built for) and debounce-rebuild. A mid-call restart preserves the
    // route because pipeline.isConfigured stays true (only deactivateSession at
    // call end clears it) so start() skips configureForVoIP and does NOT reset
    // the speaker category.
    private var engineBuiltForSpeaker = false
    private var pendingRouteRestart: DispatchWorkItem?

    /// Initialize with an optional audio processing pipeline.
    /// When provided, the pipeline configures AVAudioSession for VoIP and
    /// enables Apple's Voice Processing I/O (hardware AEC, NS, AGC) on the
    /// input node before capturing begins.
    public init(audioPipeline: AudioProcessingPipeline? = nil) {
        self.audioPipeline = audioPipeline ?? AudioProcessingPipeline()
    }

    public func start() throws {
        guard !isRunning else { return }
        // W475 — start each capture session with an empty re-chunk
        // accumulator so a stale partial frame from a prior call or a
        // pre-interruption session can't desync the frame boundaries.
        pcmAccumulator = Data()
        firstFrameReceived = false  // W-AEC-FIX — re-arm the VP-IO starve watchdog
        micAgcGain = 1.0            // W-MICAGC — start each call at unity gain
        micAgcMaxGainThisCall = 1.0
        micAgcRampFrom = 1.0        // W-DEZIPPER — reset the per-sample gain-ramp state

        // 1. Configure AVAudioSession for VoIP (hardware AEC, AGC, NS)
        if !audioPipeline.isActive {
            try audioPipeline.configureForVoIP()
        }

        // 2. Create the audio engine
        let engine = AVAudioEngine()

        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(AudioConstants.sampleRate),
            channels: AVAudioChannelCount(AudioConstants.channels),
            interleaved: true
        )!

        // SINGLE-ENGINE FIX — attach + connect the PLAYBACK player node on the
        // SAME engine that owns the capture tap, BEFORE engine.start(), so the
        // one RemoteIO/VPIO unit drives both mic-in and speaker-out.
        // W-CANONICAL (2026-07-12) — moved BEFORE setVoiceProcessingEnabled:
        // Apple's documented silent-failure mode is enabling VP-IO on an engine
        // whose output side has no render chain yet (AEC gets no reference →
        // echo / severely quiet output, a plausible W574f contributor). The
        // player→mainMixer connection gives VP-IO its AEC reference from the
        // moment it is enabled. (The mixer resamples; the canonical Int16/48k
        // connection format stays valid whatever VP-IO negotiates underneath.)
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        // 3. Enable Voice Processing I/O on the input node BEFORE installing the tap.
        //    This activates Apple's full VoIP DSP chain:
        //    - Echo cancellation (AEC)
        //    - Noise suppression (NS)
        //    - Automatic gain control (AGC)
        try audioPipeline.enableVoiceProcessing(on: engine)
        // W-CANONICAL — latch the per-ENGINE-INSTANCE VP decision. The tap and
        // the custom-DSP bypass below key off THIS captured value, never off
        // live session/global state, so a mid-call watchdog flip can't desync
        // the "who owns AGC" decision (double-AGC risk) for buffers already in
        // flight on the old engine (each rebuild captures its own fresh value).
        let vpioActiveThisEngine = audioPipeline.voiceProcessingIsActive

        // 4. Install the input tap to capture PCM frames
        let inputNode = engine.inputNode

        // W574k — the tap format MUST match the input node's REAL output bus
        // format. Voice Processing I/O runs the input node as Float32 (and on
        // a warm engine / 2nd call it's already negotiated), so passing our
        // hardcoded Int16 `format` made installTap throw
        //   "Failed to create tap due to format mismatch, <…1 ch, 48000 Hz, Int16>"
        // → NSException → SIGABRT. That hit BOTH startCall and
        // activateIncomingCallAudio (both call start()), so the iPad crashed
        // whether it dialled OR answered. The tap callback below already
        // converts Float32→Int16, so feeding it the node's native format is
        // safe; fall back to our canonical format only if the node reports an
        // invalid (0-channel / 0-Hz) format before the engine is prepared.
        let nodeFormat = inputNode.outputFormat(forBus: 0)
        let tapFormat: AVAudioFormat = (nodeFormat.channelCount > 0 && nodeFormat.sampleRate > 0)
            ? nodeFormat
            : format
        // W-CANONICAL — report the REAL post-enable tap format to telemetry
        // (call.audio.diag tap_sr/tap_ch): a tap_sr ≠ 48000 is exactly the
        // route/rate class behind the W556 "metallica e scattosa" artifact,
        // now handled by the converter below but kept visible per call.
        audioPipeline.noteTapFormat(sampleRate: tapFormat.sampleRate,
                                    channels: Int(tapFormat.channelCount))

        // W-CANONICAL — the missing resampler. The TX chain assumed 48 kHz all
        // the way to Opus (the W475 re-chunker slices by BYTE COUNT and
        // OpusCodec is pinned at 48 kHz), but nothing ever converted the tap's
        // real rate: any route granting ≠48 kHz (Bluetooth HFP 16 k, some
        // headsets 24/44.1 k) fed wrong-rate samples into a 48 k encoder →
        // pitch/tempo warp + aliasing ("metallica") and buffer-size mismatch
        // ("scattosa"). This AVAudioConverter — rebuilt on EVERY engine
        // (re)start from the freshly-read post-enable tap format — makes that
        // whole failure class structurally impossible: the accumulator only
        // ever sees canonical 48 kHz / mono / Int16. nil on the (typical)
        // built-in-mic path where the tap is already at the canonical rate —
        // the fast paths below stay allocation-identical to before.
        let needsConversion = tapFormat.sampleRate != Double(AudioConstants.sampleRate)
            || tapFormat.channelCount != AVAudioChannelCount(AudioConstants.channels)
        let rateConverter: AVAudioConverter? = needsConversion
            ? AVAudioConverter(from: tapFormat, to: format)
            : nil
        if needsConversion {
            let msg = "[AudioCapture] W-CANONICAL: tap format \(Int(tapFormat.sampleRate)) Hz/\(tapFormat.channelCount)ch ≠ canonical 48000/1 — AVAudioConverter engaged"
            print(msg)
        }

        // W-AEC-FIX — VP-IO input-pull. When Voice-Processing I/O is active the
        // inputNode tap STARVES on iPad + builtInSpeaker (the duplex VP-IO unit
        // doesn't pull the mic when the inputNode has no downstream consumer —
        // only a tap; "callback never fires", W574f). Route inputNode → a MUTED
        // sink mixer → mainMixer so the engine actively pulls the mic (keeping
        // the tap alive) with NO local loopback (sink outputVolume = 0; the only
        // thing reaching the speaker is the remote audio via the player node,
        // which is exactly the VP-IO AEC reference). Gated on VP-IO active — the
        // no-VP-IO path already taps fine and is left byte-for-byte unchanged.
        if audioPipeline.voiceProcessingIsActive {
            let sink = AVAudioMixerNode()
            engine.attach(sink)
            engine.connect(inputNode, to: sink, format: tapFormat)
            sink.outputVolume = 0
            engine.connect(sink, to: engine.mainMixerNode, format: tapFormat)
            self.inputSink = sink
        }

        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(AudioConstants.samplesPerFrame), format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.firstFrameReceived = true  // W-AEC-FIX — VP-IO tap is delivering
            // W574: VP-IO may deliver Float32 frames even though we requested Int16.
            // The tap bufferSize hint is also overridden by VP-IO (tied to hardware I/O
            // duration per W475). Guard on int16ChannelData first; if VP-IO delivered
            // Float32 natively, convert to Int16 so the accumulator/re-chunker always
            // receives 16-bit samples regardless of the engine's VP-IO state.
            // W-CANONICAL — when the tap's rate/channel layout differs from the
            // canonical 48 kHz/mono (BT HFP 16 k, headsets 24/44.1 k), run the
            // AVAudioConverter built at start(): proper polyphase resampling into
            // canonical Int16, instead of letting wrong-rate samples reach the
            // byte-count re-chunker (the W556 "metallica e scattosa" warp class).
            var raw: Data
            if let converter = rateConverter {
                let ratio = Double(AudioConstants.sampleRate) / max(buffer.format.sampleRate, 1)
                let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 64)
                guard let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
                var fed = false
                var convErr: NSError?
                let status = converter.convert(to: outBuf, error: &convErr) { _, outStatus in
                    if fed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    fed = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                guard status != .error, let int16Data = outBuf.int16ChannelData, outBuf.frameLength > 0 else { return }
                raw = Data(bytes: int16Data[0], count: Int(outBuf.frameLength) * 2)
            } else if let int16Data = buffer.int16ChannelData {
                raw = Data(bytes: int16Data[0], count: Int(buffer.frameLength) * 2)
            } else if let floatData = buffer.floatChannelData {
                let count = Int(buffer.frameLength)
                var int16Buf = [Int16](repeating: 0, count: count)
                let src = floatData[0]
                for i in 0..<count {
                    let clamped = max(-1.0 as Float, min(1.0 as Float, src[i]))
                    int16Buf[i] = Int16(clamped * Float(Int16.max))
                }
                raw = int16Buf.withUnsafeBytes { Data($0) }
            } else {
                return
            }
            // W-MICAGC — gentle make-up AGC. W-CANONICAL (2026-07-12): VP-IO is
            // now the single owner of AGC (Apple's, per-device tuned, enabled on
            // all routes inside enableVoiceProcessing) — the software make-up
            // AGC is HARD-BYPASSED whenever this engine instance was built with
            // VP-IO active (gain pinned at 1.0; two AGCs adapting on the same
            // signal is the classic pumping/double-boost pattern). It remains
            // ONLY as the leveling fallback for the raw-mic path: user
            // killswitch (CallsGate all-off) or the W-AEC-FIX starve-watchdog
            // rebuild, where no Apple AGC runs. `vpioActiveThisEngine` is the
            // per-engine-instance latch captured right after
            // setVoiceProcessingEnabled — never live global state.
            if Self.micAgcEnabled && !vpioActiveThisEngine {
                let maxGain = Self.agcMaxGain
                raw.withUnsafeMutableBytes { (rawBuf: UnsafeMutableRawBufferPointer) in
                    guard let samples = rawBuf.bindMemory(to: Int16.self).baseAddress else { return }
                    let n = rawBuf.count / 2
                    guard n > 0 else { return }
                    let fs = Float(Int16.max)
                    var sumSq: Double = 0
                    var peak: Float = 0
                    for i in 0..<n {
                        let s = Float(samples[i]) / fs
                        sumSq += Double(s * s)
                        let a = abs(s)
                        if a > peak { peak = a }
                    }
                    let rms = Float((sumSq / Double(n)).squareRoot())
                    // Only adapt when real voice is present (above the gate); on
                    // silence/background HOLD the gain so hiss is never pumped up.
                    if rms > Self.agcNoiseGate {
                        var desired = Self.agcTargetRms / rms
                        if desired < 1 { desired = 1 }                       // boost-only
                        if desired > maxGain { desired = maxGain }
                        if peak > 0 {                                        // never over-drive a loud frame
                            let peakCap = Self.agcPeakHeadroom / peak
                            if peakCap < desired { desired = peakCap }
                            if desired < 1 { desired = 1 }
                        }
                        // slow one-pole: rise slowly (lift quiet voice gently),
                        // fall a touch faster (duck loud); both slow enough that
                        // the ear does not perceive pumping.
                        let alpha: Float = desired > self.micAgcGain ? 0.02 : 0.05
                        self.micAgcGain += (desired - self.micAgcGain) * alpha
                    }
                    if self.micAgcGain < 1 { self.micAgcGain = 1 }
                    if self.micAgcGain > maxGain { self.micAgcGain = maxGain }
                    if self.micAgcGain > self.micAgcMaxGainThisCall { self.micAgcMaxGainThisCall = self.micAgcGain }
                    // W-DEZIPPER — apply the smooth make-up gain with PER-SAMPLE
                    // ramping from the previous frame's end gain to this frame's
                    // target, so the gain is CONTINUOUS across the 20 ms frame
                    // boundary. A constant per-frame gain that changed frame-to-
                    // frame stepped the waveform at each boundary → an audible click
                    // every frame (the "scoppiettante" crackle the user reported);
                    // the earlier per-frame peak clamp made it worse by dropping the
                    // gain hard on loud frames (it bound whenever micAgcGain*peak >
                    // 90% FS, i.e. on the loudest ~20 ms chunks). Peak safety is now
                    // a per-sample SOFT-KNEE (the same curve as the standalone
                    // TX-LIMITER below) applied INLINE right after the gain, so no
                    // sample is ever hard-flat-topped by the Int16 clamp before the
                    // limiter can shape it — de-zippered make-up + smooth limiting
                    // in one pass, no discontinuities.
                    let gStart = self.micAgcRampFrom
                    let gTarget = self.micAgcGain
                    if gTarget > 1.001 || gStart > 1.001 {
                        let inv: Float = 1 / Float(n)
                        let limThresh: Float = 0.90 * fs
                        let limCeil: Float = 0.98 * fs
                        let limRange: Float = limCeil - limThresh
                        for i in 0..<n {
                            let gi = gStart + (gTarget - gStart) * (Float(i) * inv)
                            var v = Float(samples[i]) * gi
                            let mag = abs(v)
                            if mag > limThresh {
                                let excess = mag - limThresh
                                let comp = limThresh + limRange * (1 - exp(-excess / limRange))
                                v = (v < 0 ? -1 : 1) * comp
                            }
                            samples[i] = Int16(clamping: Int(v.rounded()))
                        }
                    }
                    self.micAgcRampFrom = gTarget
                }
            }
            // AGC-DIAG — scan the samples we already have in hand (no extra
            // decode) for peak amplitude + near-full-scale clip count. `raw`
            // is exactly the int16 bytes about to be re-chunked below.
            raw.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
                guard let samples = rawBuf.bindMemory(to: Int16.self).baseAddress else { return }
                let n = raw.count / 2
                var localPeak = self.peakAmplitude
                var localClips = self.clipSampleCount
                var localSumSq = self.sumSqAmplitude
                for i in 0..<n {
                    // Int32 magnitude — avoids the abs(Int16.min) overflow trap.
                    let mag = Int32(samples[i]).magnitude
                    if mag > Int32(localPeak).magnitude { localPeak = Int16(clamping: mag) }
                    if mag >= Int32(Self.clipThreshold).magnitude { localClips += 1 }
                    // TX-RMS — sum of squares of the same samples (Double avoids
                    // Int overflow over a full call); RMS is derived at consume time.
                    let sq = Double(samples[i])
                    localSumSq += sq * sq
                }
                self.peakAmplitude = localPeak
                self.clipSampleCount = localClips
                self.sumSqAmplitude = localSumSq
                self.rmsSampleCount &+= Int64(n)
            }
            // TX-LIMITER (2026-07-11) — soft-knee peak limiter on the raw mic
            // samples before they reach Opus. W-CANONICAL (2026-07-12): runs
            // ONLY on the raw-mic fallback path (VP-IO off). With VP-IO active
            // the output is already level-managed by Apple's AGC — a second
            // nonlinear stage on an already-managed signal is pure added
            // distortion. On the fallback path it stays: no AEC/NS/AGC runs
            // there, and a loud/close mouth-to-mic can saturate downstream of
            // the ADC ("scoppiettio").
            if !vpioActiveThisEngine {
                raw.withUnsafeMutableBytes { (rawBuf: UnsafeMutableRawBufferPointer) in
                    guard let samples = rawBuf.bindMemory(to: Int16.self).baseAddress else { return }
                    let n = rawBuf.count / 2
                    let threshold: Float = 0.90 * Float(Int16.max)
                    let ceiling: Float = 0.98 * Float(Int16.max)
                    let range = ceiling - threshold
                    for i in 0..<n {
                        let sample = Float(samples[i])
                        let mag = abs(sample)
                        guard mag > threshold else { continue }
                        let excess = mag - threshold
                        let compressed = threshold + range * (1 - exp(-excess / range))
                        samples[i] = Int16(clamping: Int((sample < 0 ? -1 : 1) * compressed))
                    }
                }
            }
            // W475 — re-chunk into EXACT bytesPerFrame frames. `installTap`'s
            // bufferSize is only a hint, and VoiceProcessing I/O ties the tap
            // buffer to the hardware I/O duration — so `buffer.frameLength`
            // is an arbitrary size, frequently far larger than the 960
            // samples Opus requires. A mis-sized frame made OpusCodec.encode
            // return nil; QAudionEngine.processOutgoingAudio then fell back
            // to encrypting the RAW PCM, and once that raw buffer exceeded
            // maxPayloadSize (4096 B / >2048 samples — common) the
            // `payload.count <= maxPayloadSize` precondition in
            // EncryptedFrame.init trapped (SIGTRAP), crashing the call the
            // instant capture started on answer. It also killed TX outright:
            // Opus never once encoded a frame. Re-chunking guarantees every
            // onFrame delivery is exactly bytesPerFrame.
            self.pcmAccumulator.append(raw)
            let frameBytes = AudioConstants.bytesPerFrame
            var consumed = 0
            while self.pcmAccumulator.count - consumed >= frameBytes {
                let chunk = self.pcmAccumulator.subdata(in: consumed ..< consumed + frameBytes)
                consumed += frameBytes
                // W-CANONICAL — software NR retired (double-NS over VP-IO's);
                // chunks go straight to Opus.
                self.onFrame?(chunk)
            }
            if consumed > 0 {
                self.pcmAccumulator = consumed < self.pcmAccumulator.count
                    ? self.pcmAccumulator.subdata(in: consumed ..< self.pcmAccumulator.count)
                    : Data()
            }
        }

        // 5. Start the engine, then the player node (single engine drives both).
        engine.prepare()
        try engine.start()
        player.play()
        self.engine = engine
        self.playerNode = player
        self.playFormat = format
        isRunning = true
        // W-SPKFIX — record which output route (speaker vs earpiece) this engine
        // instance was built on, so handleRouteChange can detect a later
        // speaker<->earpiece flip reason-agnostically and rebuild.
        engineBuiltForSpeaker = AudioProcessingPipeline.currentRouteHasBuiltInSpeaker()

        // 6. M-12 — observe AVAudioSession interruptions so we can
        //    pause on .began and resume on .ended (.shouldResume).
        registerInterruptionObserver()

        // 7. W-AEC-FIX — if VP-IO is active, arm the starve watchdog. If the
        //    input tap never delivers a buffer within the window (the iPad
        //    VP-IO + builtInSpeaker starve, W574f), restart WITHOUT VP-IO so the
        //    mic transmits. Worst case = the pre-fix behaviour (echo, working
        //    TX); never a dead mic. iPhone / no-VP-IO never arms it.
        if audioPipeline.voiceProcessingIsActive {
            scheduleVpioStarveWatchdog()
        }
    }

    /// W-AEC-FIX — VP-IO input-tap starve detector. The iPad's VP-IO + built-in
    /// speaker route can leave the inputNode tap callback completely silent
    /// (W574f). If no buffer has arrived 1.2 s after start, fall back to a
    /// no-VP-IO restart so the call still has a live mic (echo returns, but a
    /// working call beats a dead one). One-shot per start(); a delivering tap
    /// (firstFrameReceived) cancels it.
    private func scheduleVpioStarveWatchdog() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.isRunning else { return }
            if self.firstFrameReceived { return }  // VP-IO tap is delivering — keep AEC
            print("[AudioCapture] W-AEC-FIX: VP-IO input tap starved (no frame in 1.2s) — restarting without VP-IO so the mic transmits")
            self.audioPipeline.forceDisableVoiceProcessing = true
            self.restartEngineForRoute()
        }
    }

    /// SINGLE-ENGINE FIX — schedule a decoded PCM frame for playback on the
    /// player node that lives on THIS capture engine. Replaces the old separate
    /// `AudioPlayback`, which ran a SECOND AVAudioEngine and was therefore mute.
    public func playFrame(_ pcmData: Data) {
        // W574j — build the playback buffer in the player node's LIVE output
        // format, not the cached `playFormat`. On iPad, enabling Voice
        // Processing I/O reconfigures the player→mixer bus to the hardware
        // format (typically Float32) AFTER our Int16 `connect(...)`. Scheduling
        // an Int16 buffer onto a Float32 bus fails AVAudioPlayerNode's format
        // precondition → AVAudioEngine throws an Obj-C NSException → SIGABRT.
        // This was invisible until W574i fixed the seal: once relay audio
        // actually decrypts, the receiver finally calls playFrame with real
        // PCM and the latent format mismatch crashed the iPad on answer.
        // Reading the bus format here (and converting the decoded Int16 mono
        // PCM into it) keeps scheduleBuffer valid on every device/route.
        guard isRunning,
              let player = playerNode,
              let engine = engine, engine.isRunning else { return }
        let outFmt = player.outputFormat(forBus: 0)
        let frames = pcmData.count / 2  // decoded PCM is Int16 mono
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: outFmt,
                                            frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let ch = Int(outFmt.channelCount)
        let scale: Float = 1.0 / 32768.0
        let filled: Bool = pcmData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let src = raw.bindMemory(to: Int16.self).baseAddress else { return false }
            if outFmt.commonFormat == .pcmFormatInt16, let dst = buffer.int16ChannelData {
                if outFmt.isInterleaved {
                    let d = dst[0]
                    for i in 0..<frames { let v = src[i]; for c in 0..<ch { d[i * ch + c] = v } }
                } else {
                    for c in 0..<ch { let d = dst[c]; for i in 0..<frames { d[i] = src[i] } }
                }
                return true
            } else if outFmt.commonFormat == .pcmFormatFloat32, let dst = buffer.floatChannelData {
                if outFmt.isInterleaved {
                    let d = dst[0]
                    for i in 0..<frames { let v = Float(src[i]) * scale; for c in 0..<ch { d[i * ch + c] = v } }
                } else {
                    for c in 0..<ch { let d = dst[c]; for i in 0..<frames { d[i] = Float(src[i]) * scale } }
                }
                return true
            }
            return false  // unsupported bus format → skip frame (never crash)
        }
        guard filled else { return }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    private func registerInterruptionObserver() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            self?.handleInterruption(note)
        }
        // W571 — route change observer. Handles headset plug/unplug and
        // Bluetooth HFP connect/disconnect. On .oldDeviceUnavailable
        // (headset removed) the engine may keep running on the now-removed
        // device route and go silent. Restarting on device unavailability
        // ensures the engine re-opens on the current hardware (earpiece
        // or built-in speaker) with the correct format.
        guard routeChangeObserver == nil else { return }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            self?.handleRouteChange(note)
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let rawReason = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }
        // W-SPKFIX — FIRST, reason-agnostically catch the in-call speaker toggle.
        // The output route flipping speaker<->earpiece (however it was triggered:
        // .categoryChange from setCategory .defaultToSpeaker, .override from
        // overrideOutputAudioPort, or an OS-driven proximity change) requires the
        // engine to rebuild on the new route or the mic input tap dies. Compare
        // the LIVE route against the one the engine was built for; if it flipped
        // and this isn't the echo of our own just-completed restart, debounce a
        // rebuild so the toggle's notification storm coalesces into ONE restart on
        // the settled route.
        if isRunning {
            let nowSpeaker = AudioProcessingPipeline.currentRouteHasBuiltInSpeaker()
            if nowSpeaker != engineBuiltForSpeaker && Date() >= restartSuppressUntil {
                print("[AudioCapture] W-SPKFIX: output route flipped to " +
                      (nowSpeaker ? "speaker" : "earpiece") +
                      " (reason=\(reason.rawValue)) — rebuilding engine on new route")
                scheduleDebouncedRouteRestart()
                return
            }
        }
        switch reason {
        case .oldDeviceUnavailable:
            // A device that was in use (Bluetooth HFP, wired headset) was removed.
            // AVAudioEngine may go silent if it was using the now-missing device.
            // Restart to pick up the new route (built-in mic/speaker) — but throttle
            // so a flapping route doesn't thrash the engine (W574o).
            if shouldSkipRouteRestart() { return }
            print("[AudioCapture] route change: old device unavailable — restarting engine")
            restartEngineForRoute()
        case .newDeviceAvailable:
            // New device connected (e.g. Bluetooth HFP). The engine may be using a
            // lower-quality route; restart to prefer the new device. Throttled (W574o).
            if shouldSkipRouteRestart() { return }
            print("[AudioCapture] route change: new device available — restarting engine")
            restartEngineForRoute()
        case .override:
            // W574c — the output route was overridden: this is the in-call speaker
            // button (`overrideOutputAudioPort(.speaker)` / `.none`). VP-IO is
            // route-dependent and can only be (un)set BEFORE engine start, so restart
            // to re-evaluate `enableVoiceProcessing` on the new route.
            //
            // W574p — W574o/14a0c7f assumed this notification was "one-shot" per tap
            // and left it unthrottled. Device telemetry (W556 session logs) shows
            // vpio flapping true/false every ~1s with `out=Speaker` UNCHANGED across
            // the flaps — i.e. `.override` itself re-fires (setCategory +
            // overrideOutputAudioPort can each provoke a route-change post, and the
            // restart's own configureForVoIP()→setActive is a further echo) faster
            // than the single restart it triggers can settle. Because this case
            // skipped shouldSkipRouteRestart(), every one of those echoes was
            // honored with a FULL engine teardown/rebuild, thrashing VP-IO and
            // producing the audible crackling — the exact BT-thrash failure mode
            // W574o fixed for the other two cases, just not this one. Apply the same
            // throttle/suppress guard: the first tap still restarts immediately
            // (nothing to skip yet), only the self-provoked echoes are now dropped.
            if shouldSkipRouteRestart() { return }
            print("[AudioCapture] route change: output override (speaker toggle) — restarting engine to re-evaluate VP-IO")
            restartEngineForRoute()
        default:
            break
        }
    }

    /// W-SPKFIX — coalesce a burst of route-change notifications (a single
    /// speaker toggle posts several within ~100 ms, and each restart's own
    /// setActive posts more) into ONE engine rebuild ~0.35 s after the LAST one,
    /// when the route has settled. restartEngineForRoute arms restartSuppressUntil
    /// (~0.6 s) so the rebuild's own echoes are ignored by the guard above,
    /// breaking the self-induced loop.
    private func scheduleDebouncedRouteRestart() {
        pendingRouteRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.restartEngineForRoute()
        }
        pendingRouteRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// W574o — skip a route-driven engine restart if we just restarted (the route
    /// change is the echo of our own `setActive`) or if we restarted < 1s ago (a
    /// flapping Bluetooth link). Keeps the genuine isolated headset plug/unplug case
    /// (W571) working — those are not rapid repeats.
    private func shouldSkipRouteRestart() -> Bool {
        let now = Date()
        if now < restartSuppressUntil { return true }
        if now.timeIntervalSince(lastEngineRestart) < routeRestartThrottle { return true }
        return false
    }

    /// Tear down and rebuild the engine on the current hardware route. Records the
    /// restart time and arms a short suppress window so the route change this restart
    /// itself provokes is ignored (breaks the self-induced thrash loop).
    private func restartEngineForRoute() {
        guard isRunning else { return }
        audioPipeline.noteEngineRestart()  // W-CANONICAL — engine_restarts telemetry
        lastEngineRestart = Date()
        restartSuppressUntil = Date().addingTimeInterval(0.6)
        engine?.inputNode.removeTap(onBus: 0)
        playerNode?.stop()
        if let engine = engine { audioPipeline.disableVoiceProcessing(on: engine) }
        engine?.stop()
        engine = nil; playerNode = nil; playFormat = nil; inputSink = nil; isRunning = false
        do { try start() }
        catch { print("[AudioCapture] restart after route change failed: \(error.localizedDescription)") }
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // OS seized the audio session (phone call / Siri / alarm).
            // Tear down tap + engine and report not-running so the UI
            // reflects dead capture instead of a silent one-sided call.
            // Do NOT deactivate the session — the OS owns it for the
            // duration of the interruption.
            wasInterrupted = true
            engine?.inputNode.removeTap(onBus: 0)
            playerNode?.stop()
            if let engine = engine {
                audioPipeline.disableVoiceProcessing(on: engine)
            }
            engine?.stop()
            engine = nil
            playerNode = nil
            playFormat = nil
            inputSink = nil
            isRunning = false
        case .ended:
            guard wasInterrupted else { return }
            wasInterrupted = false
            var shouldResume = false
            if let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let opts = AVAudioSession.InterruptionOptions(rawValue: optRaw)
                shouldResume = opts.contains(.shouldResume)
            }
            guard shouldResume else { return }
            // start() reconfigures + reactivates the session and rebuilds
            // the engine/tap. The observer is still registered (only
            // stop()/deinit remove it) so start()'s register call no-ops.
            do {
                try start()
            } catch {
                let edesc: String = error.localizedDescription
                let line: String = "[AudioCapture] resume after interruption failed: " + edesc
                print(line)
            }
        @unknown default:
            break
        }
    }

    public func stop() {
        // W-SPKFIX — cancel any pending debounced route restart so it cannot
        // fire after the call has torn down the engine.
        pendingRouteRestart?.cancel()
        pendingRouteRestart = nil
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
            interruptionObserver = nil
        }
        if let obs = routeChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            routeChangeObserver = nil
        }
        engine?.inputNode.removeTap(onBus: 0)
        playerNode?.stop()
        if let engine = engine {
            audioPipeline.disableVoiceProcessing(on: engine)
        }
        engine?.stop()
        engine = nil
        playerNode = nil
        playFormat = nil
        inputSink = nil
        // W-AEC-FIX — clear the watchdog fallback so the NEXT call retries VP-IO
        // AEC fresh (a starve will just re-trigger the fallback if it recurs).
        audioPipeline.forceDisableVoiceProcessing = false
        audioPipeline.deactivateSession()
        isRunning = false
    }

    deinit {
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = routeChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    public var isCapturing: Bool { isRunning }

    /// Access the audio processing pipeline for stats or configuration changes.
    public var processingPipeline: AudioProcessingPipeline { audioPipeline }
}
#endif
