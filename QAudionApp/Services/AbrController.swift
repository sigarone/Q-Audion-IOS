import Foundation
import QAudionEngine

/// W398 — Adaptive Bit Rate (ABR) controller for the video pipeline.
///
/// Mirrors the Android `AbrController.kt` decision policy from
/// `VideoConstants.kt`:
///   - sample every `abrSampleIntervalMs` (2000ms)
///   - if last-window loss > `abrLossDecreaseThreshold` (5%):
///       new_bps = current_bps * (1 - abrDecreaseFactor) = current * 0.7
///   - else if loss < `abrLossIncreaseThreshold` (2%) for SUSTAIN
///     (5 sustained intervals = 10s):
///       new_bps = current_bps + abrIncreaseStepBps (50_000)
///   - else: hold steady
///
/// Bounded to `[minVideoBitrateBps, maxVideoBitrateBps]` by the
/// HevcEncoder.setBitrate clamp so any rate is safe to apply.
///
/// **Feedback path:** the local fragmenter exposes
/// `consumeAbrSample()` returning (received, lost) since the last
/// sample. The controller uses LOCAL inbound loss as the signal
/// because the WS transport doesn't have RTCP feedback. This
/// reasonably approximates remote uplink quality assuming the path
/// is symmetric (typical for cellular and home Wi-Fi).
@MainActor
public final class AbrController {

    /// Bitrate the controller currently asks the encoder to use.
    /// Initialised to `defaultVideoBitrateBps` (800 kbps).
    public private(set) var currentBitrateBps: Int = VideoConstants.defaultVideoBitrateBps

    /// Sustained-low-loss interval counter. When this reaches the
    /// threshold below, we step up the bitrate.
    private var sustainedLowLossCount: Int = 0
    private let sustainIntervalsForUp: Int = 5

    private weak var pipeline: VideoCallPipeline?
    private var timer: DispatchSourceTimer?

    public init(pipeline: VideoCallPipeline) {
        self.pipeline = pipeline
    }

    /// Start the periodic sample loop. Idempotent.
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

    private func tick() {
        guard let pipeline = pipeline else { return }
        // Read + reset the per-window loss counters from the inbound
        // fragmenter. Available via the public consumeAbrSample API
        // we added in W398 to QAudionEngine.VideoFrameFragmenter.
        let (received, lost) = pipeline.consumeInboundAbrSample()
        let total = received + lost
        guard total > 0 else { return }
        let lossPct = Float(lost) / Float(total)

        let decreaseThr = VideoConstants.abrLossDecreaseThreshold
        let increaseThr = VideoConstants.abrLossIncreaseThreshold

        if lossPct > decreaseThr {
            sustainedLowLossCount = 0
            let factor = 1.0 - VideoConstants.abrDecreaseFactor
            // Decrease step: drop by abrDecreaseFactor * current.
            // Example: 0.7 * 800k = 560k step; new = 240k.
            let newBps = max(
                VideoConstants.minVideoBitrateBps,
                Int(Float(currentBitrateBps) * factor))
            applyBitrate(newBps, reason: "loss \(Int(lossPct * 100))% > \(Int(decreaseThr * 100))%")
        } else if lossPct < increaseThr {
            sustainedLowLossCount &+= 1
            if sustainedLowLossCount >= sustainIntervalsForUp {
                sustainedLowLossCount = 0
                let newBps = min(
                    VideoConstants.maxVideoBitrateBps,
                    currentBitrateBps + VideoConstants.abrIncreaseStepBps)
                if newBps != currentBitrateBps {
                    applyBitrate(newBps, reason: "low loss \(Int(lossPct * 100))% sustained")
                }
            }
        } else {
            // In the dead band — neither up nor down. Reset the
            // sustain counter so a single bad interval doesn't crush
            // the next ramp-up.
            sustainedLowLossCount = 0
        }
    }

    private func applyBitrate(_ newBps: Int, reason: String) {
        guard let pipeline = pipeline else { return }
        currentBitrateBps = newBps
        pipeline.setEncoderBitrate(newBps)
        print("[AbrController] \(currentBitrateBps / 1000) kbps — \(reason)")
    }
}
