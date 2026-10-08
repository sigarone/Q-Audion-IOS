import Foundation

/// Watches the time between frames and steps the effect down when the device cannot keep up. It sees nothing but numbers
/// (milliseconds between frames).
///
/// - The average of the last `window` intervals above `averageLimitMs`: one level down, the scene goes on at the lower
///   level.
/// - A single interval above `spikeMs`: the running scene is closed at once (result shown) and one level down.
/// - The cap is restored only by `resetCap`, which the owner calls when the user changes the setting.
public final class EnigmaGovernor {
    public enum Verdict: Equatable, Sendable {
        case ok
        case degraded
        case abortAndDegrade
    }

    /// Frame interval of a 60 Hz display, the scale the limits are written for.
    public static let referenceFrameMs: Double = 1000.0 / 60.0

    /// The highest level the governor currently allows.
    public private(set) var cap: EnigmaLevel = .full

    private let window: Int
    private let averageLimitMs: Double
    private let spikeMs: Double
    private var samples: [Double]
    private var filled = 0
    private var next = 0
    private var sum = 0.0
    private var noticePending = false
    private var noticeShown = false

    public init(window: Int = 20, averageLimitMs: Double = 26.0, spikeMs: Double = 120.0) {
        let w = max(1, window)
        self.window = w
        self.averageLimitMs = averageLimitMs
        self.spikeMs = spikeMs
        self.samples = [Double](repeating: 0.0, count: w)
    }

    /// The display link can run slower than 60 Hz by design (Low Power Mode caps it at 30 Hz) or faster (ProMotion). The
    /// limits are written for 60 Hz, so the interval is judged by how much LATER than the display's own nominal interval
    /// the frame came: a healthy stream reads as 16.7 ms whatever the refresh rate, a dropped frame still reads as slow.
    public static func normalizedInterval(dtMs: Double, nominalMs: Double) -> Double {
        if dtMs.isNaN || dtMs < 0.0 { return 0.0 }
        if nominalMs.isNaN || nominalMs <= 0.0 || nominalMs > 200.0 { return dtMs }
        let value = dtMs - nominalMs + referenceFrameMs
        return value < 0.0 ? 0.0 : value
    }

    /// Feeds one interval between two frames.
    public func onFrameInterval(_ dtMs: Double) -> Verdict {
        if dtMs.isNaN { return .ok }
        if dtMs > spikeMs {
            degrade()
            return .abortAndDegrade
        }
        if filled == window {
            sum -= samples[next]
        } else {
            filled += 1
        }
        samples[next] = dtMs
        sum += dtMs
        next = (next + 1) % window
        if filled == window && sum / Double(window) > averageLimitMs {
            degrade()
            return .degraded
        }
        return .ok
    }

    /// Forgets the measured intervals (a new scene starts, or frames were not being produced).
    public func clearWindow() {
        filled = 0
        next = 0
        sum = 0.0
    }

    /// The user changed the setting: full cap again, and the notice may be shown again.
    public func resetCap() {
        cap = .full
        noticePending = false
        noticeShown = false
        clearWindow()
    }

    /// True once after the first step down since the last `resetCap`: the discreet "reduced effect" notice.
    public func takeNotice() -> Bool {
        if !noticePending { return false }
        noticePending = false
        return true
    }

    private func degrade() {
        cap = cap.lowered()
        clearWindow()
        if !noticeShown {
            noticeShown = true
            noticePending = true
        }
    }
}
