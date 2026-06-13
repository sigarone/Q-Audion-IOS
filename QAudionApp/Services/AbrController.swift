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

    // MARK: - Lifecycle

    public init(pipeline: VideoCallPipeline) {
        self.pipeline = pipeline
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
        let newFps: Int
        if avgLatencyMs > 300 && lossPct > 0.15 {
            newFps = 10
        } else if avgLatencyMs > 200 || lossPct > 0.10 {
            newFps = 15
        } else {
            newFps = VideoConstants.defaultVideoFps
        }
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
                if let next = stepUp(from: currentResolution) {
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

    // MARK: - Reset

    /// Reset to baseline values. Call when starting a new call so the
    /// previous call's bitrate decisions don't bleed into the next one.
    public func reset() {
        currentBitrateBps = VideoConstants.defaultVideoBitrateBps
        currentResolution = .hd720
        currentFps = VideoConstants.defaultVideoFps
        isVideoPaused = false
        sustainedLowLossCount = 0
        lowBitrateSustainedSince = 0
        highBitrateSustainedSince = 0
    }
}
