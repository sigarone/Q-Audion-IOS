import Foundation

/// CALL-METRICS (2026-10-04) -- an ECHO-SUSPECT PROXY for the native-SRTP audio path. NOT an ERLE and NOT an echo
/// return loss: iOS exposes no per-frame echo-cancellation figure through a public API, and on this path the echo
/// canceller is the one inside WebRTC's Voice-Processing I/O unit, opaque to the app.
///
/// WHAT IS MEASURED. Two WebRTC audio-processing hooks that already exist on every native call see 10 ms frames:
///  * the capture post-processing hook (`NativeAudioCaptureTap`): the microphone signal AFTER the hardware echo
///    canceller / noise suppression, i.e. what is encoded and sent to the peer;
///  * the render pre-processing hook (`NativeAudioPlayoutInjector`): the far-end signal about to be played.
/// Each capture frame is graded `active` when a loud far-end frame (RMS >= 0.01 of full scale, about -40 dBFS) was
/// played within the last 200 ms, otherwise `idle`. The RMS of each bucket is the root of the mean squared level
/// over the bucket. This is the same method as the legacy engine's `echo_active_*` / `echo_idle_*` buckets
/// (`AudioCapture.EchoBucketTotals`), moved to the native path, so both read the same way.
///
/// THE PROXY. A window is `echo_suspect` when both buckets hold at least 50 frames (0.5 s), the active bucket is
/// audible (RMS >= 0.01) and is at least 3 times louder (about +9.5 dB) than the idle bucket, whose RMS is floored at
/// 0.002 (-54 dBFS) so digital silence cannot make a trivial ratio. When a canceller works, the microphone level
/// should not depend on whether the far end is playing, so a clearly louder active bucket is residual echo reaching
/// the encoder.
///
/// HONEST LIMITS. (1) Double talk: when the near-end person speaks over the far end, the active bucket is louder for a
/// reason that is not echo, so a flagged window is a suspicion to be read next to `rxlvl` / `mslvl` of hb=1 and the
/// route, never a verdict. (2) An earpiece route has no acoustic path from loudspeaker to microphone at all.
/// (3) No sample alignment: only "some far-end energy was recently audible" is known. (4) If the render hook did not
/// fire, `echo_far_frames` is 0 and every capture frame is `idle`: the proxy is blind, and says so.
public struct NativeEchoProxy: Equatable, Sendable {

    /// Same level threshold as the legacy `AudioCapture.echoRefLoudRms`.
    public static let loudFarRms: Float = 0.01
    /// Same hold as the legacy `AudioCapture.echoRefHoldMs` (and the Android one).
    public static let holdMs: Int64 = 200
    /// Minimum 10 ms frames in EACH bucket for a window to be judged.
    public static let minFramesPerBucket: Int64 = 50
    /// The active bucket must be at least this loud (about -40 dBFS) to be called echo.
    public static let minActiveRms: Double = 0.01
    /// The active bucket must be at least this many times the (floored) idle bucket.
    public static let ratio: Double = 3
    /// Floor of the idle RMS used in the ratio (about -54 dBFS).
    public static let idleFloorRms: Double = 0.002

    public struct Buckets: Equatable, Sendable {
        public var activeSumSq: Double = 0
        public var activeFrames: Int64 = 0
        public var idleSumSq: Double = 0
        public var idleFrames: Int64 = 0
        /// Render callbacks seen (loud or not): 0 means the far-end hook did not run.
        public var farCallbacks: Int64 = 0
        public init() {}
    }

    /// One closed window (one heartbeat interval).
    public struct WindowReport: Equatable, Sendable {
        public var activeFrames: Int64 = 0
        public var idleFrames: Int64 = 0
        public var farCallbacks: Int64 = 0
        /// RMS of the bucket as a fraction of full scale; nil when the bucket is empty.
        public var activeRms: Double?
        public var idleRms: Double?
        /// Both buckets are large enough to judge.
        public var evaluated: Bool = false
        public var suspect: Bool = false
        public init() {}
    }

    /// The whole call, including every closed window.
    public struct CallReport: Equatable, Sendable {
        public var activeFrames: Int64 = 0
        public var idleFrames: Int64 = 0
        public var farCallbacks: Int64 = 0
        public var activeRms: Double?
        public var idleRms: Double?
        public var windowsEvaluated: Int = 0
        public var windowsSuspect: Int = 0
        public init() {}
    }

    private var window = Buckets()
    private var call = Buckets()
    private var lastLoudFarMs: Int64 = 0
    private var evaluatedWindows = 0
    private var suspectWindows = 0

    public init() {}

    /// A render (far-end) frame. `countCallback` false = only refresh the "recently audible" stamp (a second look at the
    /// same callback after the fallback injector overwrote the buffer).
    public mutating func noteFar(rms: Float, nowMs: Int64, countCallback: Bool = true) {
        if countCallback { window.farCallbacks += 1 }
        if rms.isFinite, rms >= Self.loudFarRms, nowMs > 0 { lastLoudFarMs = nowMs }
    }

    /// A capture (near-end, after the hardware canceller) frame.
    public mutating func noteNear(rms: Float, nowMs: Int64) {
        guard rms.isFinite, rms >= 0 else { return }
        let sq = Double(rms) * Double(rms)
        if Self.isFarActive(lastLoudFarMs: lastLoudFarMs, nowMs: nowMs) {
            window.activeSumSq += sq
            window.activeFrames += 1
        } else {
            window.idleSumSq += sq
            window.idleFrames += 1
        }
    }

    /// Closes the open window: judges it, folds it into the call totals, starts a new one.
    public mutating func closeWindow() -> WindowReport {
        var report = WindowReport()
        report.activeFrames = window.activeFrames
        report.idleFrames = window.idleFrames
        report.farCallbacks = window.farCallbacks
        report.activeRms = Self.rms(sumSq: window.activeSumSq, frames: window.activeFrames)
        report.idleRms = Self.rms(sumSq: window.idleSumSq, frames: window.idleFrames)
        report.evaluated = window.activeFrames >= Self.minFramesPerBucket && window.idleFrames >= Self.minFramesPerBucket
        report.suspect = Self.isSuspect(activeRms: report.activeRms, idleRms: report.idleRms,
                                        activeFrames: window.activeFrames, idleFrames: window.idleFrames)
        if report.evaluated { evaluatedWindows += 1 }
        if report.suspect { suspectWindows += 1 }
        call.activeSumSq += window.activeSumSq
        call.activeFrames += window.activeFrames
        call.idleSumSq += window.idleSumSq
        call.idleFrames += window.idleFrames
        call.farCallbacks += window.farCallbacks
        window = Buckets()
        return report
    }

    /// The call so far, including the still-open window (the call ended between two heartbeats).
    public func callReport() -> CallReport {
        var total = call
        total.activeSumSq += window.activeSumSq
        total.activeFrames += window.activeFrames
        total.idleSumSq += window.idleSumSq
        total.idleFrames += window.idleFrames
        total.farCallbacks += window.farCallbacks
        var report = CallReport()
        report.activeFrames = total.activeFrames
        report.idleFrames = total.idleFrames
        report.farCallbacks = total.farCallbacks
        report.activeRms = Self.rms(sumSq: total.activeSumSq, frames: total.activeFrames)
        report.idleRms = Self.rms(sumSq: total.idleSumSq, frames: total.idleFrames)
        report.windowsEvaluated = evaluatedWindows
        report.windowsSuspect = suspectWindows
        return report
    }

    // MARK: - Pure rules

    public static func isFarActive(lastLoudFarMs: Int64, nowMs: Int64, holdMs: Int64 = holdMs) -> Bool {
        guard lastLoudFarMs > 0 else { return false }
        let age = nowMs - lastLoudFarMs
        return age >= 0 && age <= holdMs
    }

    /// Root of the mean square over the bucket, as a fraction of full scale; nil for an empty bucket.
    public static func rms(sumSq: Double, frames: Int64) -> Double? {
        guard frames > 0, sumSq.isFinite, sumSq >= 0 else { return nil }
        return (sumSq / Double(frames)).squareRoot()
    }

    /// The proxy rule (see the type's doc).
    public static func isSuspect(activeRms: Double?, idleRms: Double?, activeFrames: Int64, idleFrames: Int64) -> Bool {
        guard activeFrames >= minFramesPerBucket, idleFrames >= minFramesPerBucket,
              let active = activeRms, let idle = idleRms else { return false }
        guard active >= minActiveRms else { return false }
        return active >= ratio * max(idle, idleFloorRms)
    }

    /// Level in whole dBFS (0 = full scale, negative below), nil when the level is nil or zero.
    public static func dbfs(_ rms: Double?) -> Int? {
        guard let rms, rms.isFinite, rms > 0 else { return nil }
        let db = 20 * log10(rms)
        guard db.isFinite else { return nil }
        return Int(max(-200, min(0, db)).rounded())
    }

    /// RMS of one audio-processing frame in WebRTC's FloatS16 scale ([-32768, 32768]), as a fraction of full scale.
    /// Allocation-free, safe on the audio thread.
    public static func rmsOfFloatS16(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard samples.count > 0 else { return 0 }
        var sum: Double = 0
        for sample in samples {
            let v = Double(sample)
            sum += v * v
        }
        let rms = (sum / Double(samples.count)).squareRoot() / 32768.0
        return Float(min(rms, 1.5))
    }
}

/// The process-wide probe the two audio-processing hooks write into. The audio threads only ever TRY the lock and skip
/// the frame when it is held (a statistic must never block audio); the main-side reads take it normally.
public final class NativeEchoProbe: @unchecked Sendable {
    public static let shared = NativeEchoProbe()

    private let lock = NSLock()
    private var core = NativeEchoProxy()

    public init() {}

    /// Monotonic milliseconds (not wall clock: an NTP step must not fake an "audible within 200 ms").
    public static func nowMs() -> Int64 {
        return Int64(ProcessInfo.processInfo.systemUptime * 1000)
    }

    /// Far-end frame, from the render hook. Never blocks.
    public func noteFar(rms: Float, countCallback: Bool = true) {
        guard lock.try() else { return }
        core.noteFar(rms: rms, nowMs: Self.nowMs(), countCallback: countCallback)
        lock.unlock()
    }

    /// Near-end frame, from the capture hook. Never blocks.
    public func noteNear(rms: Float) {
        guard lock.try() else { return }
        core.noteNear(rms: rms, nowMs: Self.nowMs())
        lock.unlock()
    }

    /// Closes the heartbeat window (main side).
    public func closeWindow() -> NativeEchoProxy.WindowReport {
        lock.lock(); defer { lock.unlock() }
        return core.closeWindow()
    }

    /// The call so far (main side).
    public func callReport() -> NativeEchoProxy.CallReport {
        lock.lock(); defer { lock.unlock() }
        return core.callReport()
    }

    /// New call: forget everything.
    public func resetForNewCall() {
        lock.lock(); defer { lock.unlock() }
        core = NativeEchoProxy()
    }
}
