import Foundation
import QAudionEngine

/// W398 → W524 — Adaptive Bit Rate (ABR) controller for the video
/// pipeline. Full 4-layer port of Android's
/// `qaudion-engine/.../video/AdaptiveBitrateController.kt` algorithm,
/// using `VideoConstants.swift` thresholds (already byte-identical to
/// Android's `VideoConstants.kt`).
///
/// **Layers (matches Android order of evaluation):**
///   1. Bitrate AIMD — additive +50 kbps on low loss, multiplicative
///      ×0.7 on high loss; force-min on high latency; −20 % on high
///      jitter.
///   2. Resolution stepping — 720p → 480p → 360p when current bitrate
///      stays below `resolutionStepDownThresholdBps` for
///      `resolutionChangeSustainMs`; reverses upward when sustained
///      above `resolutionStepUpThresholdBps` for 2 × sustain window.
///   3. FPS adjustment — 24 → 15 → 10 as conditions degrade.
///   4. Video pause — at latency > 500 ms AND loss > 20 %; auto-resume
///      when latency < 300 ms AND loss < 10 %.
///
/// **Bug fix vs the original iOS port:** the previous version
/// interpreted `abrDecreaseFactor = 0.7` as `(1 − 0.7) = 0.3` and
/// multiplied by 0.3 (70 % drop) where Android multiplies by 0.7
/// directly (30 % drop). On first loss event iOS was crashing
/// 800 → 240 kbps where Android went 800 → 560 kbps; a single bad
/// window then ate all the bitrate budget the call recovered to.
///
/// **Feedback path:** the local inbound fragmenter exposes
/// `consumeAbrSampleExtended()` returning (received, lost,
/// avgLatencyMs, jitterMs). Loss is direct; latency is the average
/// reassembly tail (first → last fragment) and jitter is the std
/// deviation of inter-arrival times of completed frames. Both
/// proxies grow with transport delay variance and reorder — a
/// reasonable substitute for RTCP RTT/jitter on the WS relay path.
@MainActor
public final class AbrController {

    // MARK: - Public state (read-only mirrors of Android's `currentX`)

    public private(set) var currentBitrateBps: Int = VideoConstants.defaultVideoBitrateBps
    public private(set) var currentFps: Int = VideoConstants.defaultVideoFps
    public private(set) var currentResolution: ResolutionTier = .hd720
    public private(set) var isVideoPaused: Bool = false

    public enum ResolutionTier: Int {
        case hd720  = 0
        case sd480  = 1
        case low360 = 2

        public var width:  Int { switch self { case .hd720: 1280; case .sd480: 854; case .low360: 640 } }
        public var height: Int { switch self { case .hd720: 720;  case .sd480: 480; case .low360: 360 } }
    }

    // MARK: - Internal state

    /// Sustained-low-loss interval counter for the bitrate increase path.
    /// Mirrors the Android implementation: 5 windows × 2 s = 10 s before
    /// ramping up.
    private var sustainedLowLossCount: Int = 0
    private let sustainIntervalsForUp: Int = 5

    /// Sustained low / high bitrate markers for resolution stepping.
    /// Both are 0 when neither condition is currently held.
    private var lowBitrateSustainedSince: TimeInterval = 0
    private var highBitrateSustainedSince: TimeInterval = 0

    private weak var pipeline: VideoCallPipeline?
    private var timer: DispatchSourceTimer?

    /// W574o — resolves the active call_id so each `call.video.tune`
    /// telemetry event lands on the per-call server timeline (mirrors the
    /// audio tuner's callId). Set by AppState to BCryptoCallingApiImpl
    /// .getActiveCallId. nil → event still emitted, just unattributed.
    public var callIdProvider: (() -> String?)?

    /// W-SCREENPROFILE (2026-08-25) — mirrors `AppState.isScreenSharing`
    /// (set by `startScreenShare()`/`stopScreenShare()`) so the WS-HEVC
    /// leg's resolution ladder never steps DOWN a screen share the way it
    /// steps down camera video. Camera-oriented `updateResolution()` was
    /// previously ungated for screen share entirely — it only avoided
    /// visibly letterboxed frames as a SIDE EFFECT of
    /// `VideoCallPipeline.submitExternalFrame` re-deriving the encoder
    /// size from the incoming ReplayKit buffer every call, not as a
    /// designed profile, and it churned `VTCompressionSession` needlessly
    /// on every ABR tick during a share. Bitrate (layer 1) and FPS (layer
    /// 3) adaptation stay ON — dropping frame rate under pressure is the
    /// right trade for a screen share (mirrors the WebRTC leg's
    /// `.maintainResolution` degradation preference, see
    /// `QAudionPeerConnection.setVideoDegradationPreference`); only the
    /// resolution ladder (layer 2, the one that would blur shared text)
    /// is held at whatever tier it was on when the share started.
    public var isScreenSharing: Bool = false

    /// W-BACKPRESSURE-RES (2026-08-26) — the 1:1 WebRTC leg's own CPU-
    /// overuse step count (`QAudionWebRtcCallController.evaluateBackpressure`
    /// via `onCpuBackpressureStepsChanged`, wired by AppState). That ladder
    /// already carries its own hysteresis (6s sustain to engage, 9s to
    /// recover); this class does NOT add a second debounce on top of it —
    /// see `applyCpuBackpressure`'s kdoc for why a step-down applies
    /// immediately but a step-up never forces one.
    private var cpuBackpressureSteps: Int = 0

    // MARK: - Lifecycle

    public init(pipeline: VideoCallPipeline) {
        self.pipeline = pipeline
        // XP-9: the encoder actually starts at pipeline.targetBitrateBps
        // (1.5 Mbps, W574n) not VideoConstants.defaultVideoBitrateBps
        // (800 kbps, the cross-platform wire default). Seeding this
        // controller's belief from the wrong constant meant the first AIMD
        // decrease/increase computed off a base 700 kbps below the real
        // encoder state, and setEncoderBitrate() could silently cut the
        // true bitrate on the very first tick even with clean network
        // conditions.
        self.currentBitrateBps = pipeline.targetBitrateBps
    }

    public func start() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        let interval = DispatchTimeInterval.milliseconds(Int(VideoConstants.abrSampleIntervalMs))
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in
            self?.tick()
        }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Tick

    private func tick() {
        guard let pipeline = pipeline else { return }
        let sample = pipeline.consumeInboundAbrSampleExtended()
        let received = sample.received
        let lost = sample.lost
        // Down-cast to Int once so all the threshold comparisons against
        // VideoConstants (declared as Int to match Android's Kotlin Int)
        // type-check cleanly without per-comparison `Int(…)` noise.
        let avgLatencyMs: Int = Int(sample.avgLatencyMs)
        let jitterMs: Double = sample.jitterMs
        let total = received + lost
        // Skip the window when no frames flowed — keep state stable
        // (matches Android's `if (now - lastSampleTimeMs < interval/2) return`
        // bail-out plus the implicit no-data case).
        guard total > 0 else { return }
        let lossPct = Float(lost) / Float(total)
        let now = Date().timeIntervalSinceReferenceDate

        // ---- Layer 4: video pause (extreme conditions) -----------------

        // Android: latency > 500 && loss > 20 % → pause; resume when
        // latency < 300 && loss < 10 %.
        if avgLatencyMs > 500 && lossPct > 0.20 {
            if !isVideoPaused {
                isVideoPaused = true
                pipeline.setVideoPaused(true)
                let lat: String = avgLatencyMs.description
                let lpct: String = Int(lossPct * 100).description
                let line: String = "[AbrController] PAUSE — latency=" + lat + "ms loss=" + lpct + "%"
                print(line)
            }
            // While paused we hold all the other knobs at their last
            // value — no point churning resolution/fps when nothing is
            // being sent. Matches Android's `return false` early exit.
            // W574o — still surface the paused state on the server timeline.
            emitTune(received: received, lost: lost, lossPct: lossPct,
                     avgLatencyMs: avgLatencyMs, jitterMs: jitterMs)
            return
        } else if isVideoPaused && avgLatencyMs < 300 && lossPct < 0.10 {
            isVideoPaused = false
            pipeline.setVideoPaused(false)
            print("[AbrController] RESUME")
        }

        // ---- Layer 1: bitrate AIMD ------------------------------------

        let newBitrate: Int = {
            // 1a) High latency → drop to minimum (Android line 92-94).
            if avgLatencyMs > VideoConstants.abrHighLatencyThresholdMs {
                return VideoConstants.minVideoBitrateBps
            }
            // 1b) High jitter → 20 % reduction (Android line 95-98).
            if jitterMs > VideoConstants.abrHighJitterThresholdMs {
                return Int(Float(currentBitrateBps) * 0.8)
            }
            // 1c) High loss → multiplicative decrease by abrDecreaseFactor.
            //     **Fix vs old iOS port**: use the factor as a direct
            //     multiplier (0.7 = keep 70 %), NOT as 1−factor.
            if lossPct > VideoConstants.abrLossDecreaseThreshold {
                return Int(Float(currentBitrateBps) * VideoConstants.abrDecreaseFactor)
            }
            // 1d) Low loss → additive increase (only after sustain).
            if lossPct < VideoConstants.abrLossIncreaseThreshold {
                sustainedLowLossCount &+= 1
                if sustainedLowLossCount >= sustainIntervalsForUp {
                    sustainedLowLossCount = 0
                    return currentBitrateBps + VideoConstants.abrIncreaseStepBps
                }
                return currentBitrateBps
            }
            // 1e) Dead band — hold steady.
            sustainedLowLossCount = 0
            return currentBitrateBps
        }()
        // Reset the up-ramp counter on any down-event.
        if lossPct > VideoConstants.abrLossIncreaseThreshold
           || avgLatencyMs > VideoConstants.abrHighLatencyThresholdMs
           || jitterMs > VideoConstants.abrHighJitterThresholdMs {
            sustainedLowLossCount = 0
        }
        let clampedBitrate = max(VideoConstants.minVideoBitrateBps,
                                 min(VideoConstants.maxVideoBitrateBps, newBitrate))
        if clampedBitrate != currentBitrateBps {
            currentBitrateBps = clampedBitrate
            pipeline.setEncoderBitrate(clampedBitrate)
            // Build the diagnostic line in two steps so Swift's type-
            // checker doesn't time out on the combined String(format:) +
            // \(…) + + + print(…) overload set (see CLAUDE.md rule 13).
            let kbps: String = (clampedBitrate / 1000).description
            let lossStr: String = String(format: "%.1f", lossPct * 100)
            let jitStr: String = String(format: "%.1f", jitterMs)
            let lat: String = avgLatencyMs.description
            let line: String = "[AbrController] " + kbps + " kbps "
                + "(loss=" + lossStr + "%, lat=" + lat + "ms, jitter=" + jitStr + "ms)"
            print(line)
        }

        // ---- Layer 2: resolution stepping ------------------------------

        updateResolution(now: now)

        // ---- Layer 3: FPS adjustment -----------------------------------

        // Android (line 122-127):
        //   lat > 300 && loss > 15 % → 10 fps
        //   lat > 200 || loss > 10 % → 15 fps
        //   else → defaultVideoFps (24)
        var newFps: Int
        if avgLatencyMs > 300 && lossPct > 0.15 {
            newFps = 10
        } else if avgLatencyMs > 200 || lossPct > 0.10 {
            newFps = 15
        } else {
            newFps = VideoConstants.defaultVideoFps
        }
        // W-BACKPRESSURE-RES — the CPU ceiling is an ONGOING constraint,
        // not a one-shot nudge: without this clamp, a healthy network
        // reading on THIS tick would let the network ladder above pick a
        // higher fps than `applyCpuBackpressure` last allowed, silently
        // undoing it until the next backpressure step transition fires.
        newFps = min(newFps, Self.fpsCeiling(forCpuBackpressureSteps: cpuBackpressureSteps))
        if newFps != currentFps {
            currentFps = newFps
            pipeline.setEncoderFps(newFps)
            print("[AbrController] FPS → \(newFps)")
        }

        // W574o — emit the full ABR snapshot every tick (~2 s) so video
        // adaptation is visible + loggable server-side, exactly like
        // call.audio.tune. Reveals whether the relay's structural
        // fragment-reassembly latency is making the ABR over-throttle
        // fps/bitrate (the suspected residual-choppiness driver).
        emitTune(received: received, lost: lost, lossPct: lossPct,
                 avgLatencyMs: avgLatencyMs, jitterMs: jitterMs)
    }

    /// W574o — ship one `call.video.tune` event: the inbound metrics this
    /// tick PLUS the resulting ABR knobs (bitrate / resolution / fps /
    /// paused). Mirrors AudioAutoTuner.emitTelemetry so the two adaptive
    /// loops share one server-side timeline shape.
    private func emitTune(received: Int, lost: Int, lossPct: Float,
                          avgLatencyMs: Int, jitterMs: Double) {
        let lossPctRounded: Double = Double((lossPct * 100).rounded())
        let jitterRounded: Int = Int(jitterMs.rounded())
        TelemetryService.shared.emit(
            kind: "call.video.tune",
            callId: callIdProvider?(),
            attrs: [
                "received":       received,
                "lost":           lost,
                "loss_pct":       lossPctRounded,
                "avg_latency_ms": avgLatencyMs,
                "jitter_ms":      jitterRounded,
                "bitrate_kbps":   currentBitrateBps / 1000,
                "width":          currentResolution.width,
                "height":         currentResolution.height,
                "fps":            currentFps,
                "paused":         isVideoPaused
            ]
        )
    }

    // MARK: - Resolution stepping

    private func updateResolution(now: TimeInterval) {
        guard let pipeline = pipeline else { return }
        // W-SCREENPROFILE — never step the resolution ladder while sharing
        // the screen; see `isScreenSharing`'s kdoc. Also clears the
        // sustain-timer state so a step doesn't fire immediately off a
        // stale timer the moment the share ends.
        guard !isScreenSharing else {
            lowBitrateSustainedSince = 0
            highBitrateSustainedSince = 0
            return
        }
        let sustainSec = TimeInterval(VideoConstants.resolutionChangeSustainMs) / 1000.0

        if currentBitrateBps < VideoConstants.resolutionStepDownThresholdBps {
            if lowBitrateSustainedSince == 0 { lowBitrateSustainedSince = now }
            highBitrateSustainedSince = 0
            if now - lowBitrateSustainedSince > sustainSec {
                if let next = stepDown(from: currentResolution) {
                    currentResolution = next
                    lowBitrateSustainedSince = now  // reset for next step
                    pipeline.setEncoderResolution(width: next.width, height: next.height)
                    print("[AbrController] resolution ↓ \(next.width)x\(next.height)")
                }
            }
        } else if currentBitrateBps > VideoConstants.resolutionStepUpThresholdBps {
            if highBitrateSustainedSince == 0 { highBitrateSustainedSince = now }
            lowBitrateSustainedSince = 0
            // Android requires 2× sustain for an up-step (more
            // conservative than down) to avoid resolution oscillation.
            if now - highBitrateSustainedSince > sustainSec * 2 {
                // W-BACKPRESSURE-RES — same ongoing-constraint reasoning as
                // the fps clamp in `tick()`: a healthy bitrate trend must
                // not step PAST what CPU backpressure currently permits.
                // `rawValue` is HIGHER for a MORE constrained tier (hd720=0
                // < sd480=1 < low360=2), so "no higher quality than the
                // ceiling allows" is `next.rawValue >= ceiling.rawValue`.
                let cpuCeiling = Self.resolutionCeiling(forCpuBackpressureSteps: cpuBackpressureSteps)
                if let next = stepUp(from: currentResolution), next.rawValue >= cpuCeiling.rawValue {
                    currentResolution = next
                    highBitrateSustainedSince = now
                    pipeline.setEncoderResolution(width: next.width, height: next.height)
                    print("[AbrController] resolution ↑ \(next.width)x\(next.height)")
                }
            }
        } else {
            lowBitrateSustainedSince = 0
            highBitrateSustainedSince = 0
        }
    }

    private func stepDown(from tier: ResolutionTier) -> ResolutionTier? {
        switch tier {
        case .hd720:  return .sd480
        case .sd480:  return .low360
        case .low360: return nil
        }
    }

    private func stepUp(from tier: ResolutionTier) -> ResolutionTier? {
        switch tier {
        case .low360: return .sd480
        case .sd480:  return .hd720
        case .hd720:  return nil
        }
    }

    // MARK: - W-BACKPRESSURE-RES — CPU-overuse resolution/fps ceiling

    /// Apply (or lift) the CPU-backpressure ceiling. `steps` is the 1:1
    /// WebRTC leg's own `_backpressureSteps` (0...`backpressureMaxSteps`,
    /// currently 3) — see that class's `evaluateBackpressure` kdoc.
    ///
    /// A HIGHER step count only ever pulls resolution/fps DOWN, applied
    /// right away (CPU overuse is the whole point — waiting for the next
    /// `tick()` would keep the encoder doing the expensive work for up to
    /// another `abrSampleIntervalMs`). Recovery (`steps` decreasing) never
    /// forces a step UP here: it only lifts the ceiling, letting the NEXT
    /// scheduled `tick()`'s own network-driven ladder (`updateResolution`
    /// / the fps block) decide whether conditions actually support more —
    /// composing the two ladders any other way would mean this method's
    /// CPU-recovery timing fights the network ladder's OWN sustain/dead-band
    /// hysteresis for the same knobs.
    public func applyCpuBackpressure(steps: Int) {
        cpuBackpressureSteps = max(0, steps)
        guard let pipeline = pipeline else { return }

        // W-SCREENPROFILE parity: resolution ladder is held during a
        // screen share (see `updateResolution`'s own gate + kdoc) — CPU
        // backpressure must respect the same rule, for the same reason
        // (stepping resolution would visibly blur shared text). FPS stays
        // adjustable during a share, matching that same precedent.
        if !isScreenSharing {
            let resCeiling = Self.resolutionCeiling(forCpuBackpressureSteps: cpuBackpressureSteps)
            if resCeiling.rawValue > currentResolution.rawValue {
                currentResolution = resCeiling
                pipeline.setEncoderResolution(width: resCeiling.width, height: resCeiling.height)
                print("[AbrController] resolution ↓ (CPU backpressure) \(resCeiling.width)x\(resCeiling.height)")
            }
        }

        let fpsCeiling = Self.fpsCeiling(forCpuBackpressureSteps: cpuBackpressureSteps)
        if fpsCeiling < currentFps {
            currentFps = fpsCeiling
            pipeline.setEncoderFps(fpsCeiling)
            print("[AbrController] FPS → (CPU backpressure) \(fpsCeiling)")
        }
    }

    /// Pure — testable without a live `VideoCallPipeline`. `steps < 1`
    /// (0, or a defensively-clamped negative) leaves resolution
    /// unconstrained; each step beyond that steps the ceiling down one
    /// `ResolutionTier`, capped at the lowest tier once `steps >= 2` (the
    /// 1:1 ladder's `backpressureMaxSteps` is 3, one more level than this
    /// controller has resolution tiers for — the extra step just holds at
    /// the floor rather than having nowhere to go).
    static func resolutionCeiling(forCpuBackpressureSteps steps: Int) -> ResolutionTier {
        switch steps {
        case ..<1: return .hd720
        case 1:    return .sd480
        default:   return .low360
        }
    }

    /// Pure — same step shape as `resolutionCeiling(forCpuBackpressureSteps:)`,
    /// mirrored against this controller's OWN network-driven fps ladder in
    /// `tick()` (10/15/`defaultVideoFps`) rather than inventing new numbers.
    static func fpsCeiling(forCpuBackpressureSteps steps: Int) -> Int {
        switch steps {
        case ..<1: return VideoConstants.defaultVideoFps
        case 1:    return 15
        default:   return 10
        }
    }

    // MARK: - Reset

    /// Reset to baseline values. Call when starting a new call so the
    /// previous call's bitrate decisions don't bleed into the next one.
    public func reset() {
        // XP-9: same seed fix as init() — reset to the real encoder start
        // value, not the cross-platform wire-default constant.
        currentBitrateBps = pipeline?.targetBitrateBps ?? VideoConstants.defaultVideoBitrateBps
        currentResolution = .hd720
        currentFps = VideoConstants.defaultVideoFps
        isVideoPaused = false
        sustainedLowLossCount = 0
        lowBitrateSustainedSince = 0
        highBitrateSustainedSince = 0
        cpuBackpressureSteps = 0
    }
}
