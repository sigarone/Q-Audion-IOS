import Foundation

/// Pure decisions for bringing Voice-Processing back after it was bypassed
/// because enabling it raised an error (for example on a low-rate Bluetooth
/// hands-free route). Kept free of AVFoundation so it runs under `swift test`.
public enum VpioRetryPolicy {
    /// Delays before the 1st, 2nd and 3rd timed attempt; every later one uses `steadyDelayMs`.
    public static let rampDelaysMs: [Int] = [2_000, 5_000, 15_000]
    public static let steadyDelayMs: Int = 30_000
    /// Timed attempts per call (2 s, 5 s, 15 s, 30 s, 30 s); a route-driven restart starts a fresh budget.
    public static let maxTimedAttempts: Int = 5

    /// May another timed attempt be armed after `attemptsMade` attempts?
    public static func hasBudget(attemptsMade: Int) -> Bool {
        attemptsMade < maxTimedAttempts
    }

    /// Attempt counter after a restart: a route-driven one starts a fresh budget.
    public static func attemptsAfterRestart(current: Int, routeDriven: Bool) -> Int {
        routeDriven ? 0 : current
    }

    /// Delay before timed attempt number `attempt` (0-based).
    public static func delayMs(attempt: Int) -> Int {
        guard attempt >= 0 else { return rampDelaysMs[0] }
        return attempt < rampDelaysMs.count ? rampDelaysMs[attempt] : steadyDelayMs
    }

    /// Should a timer be armed after an engine start?
    public static func shouldArm(vpioActive: Bool, degradedByError: Bool, attemptsMade: Int) -> Bool {
        guard !vpioActive, degradedByError else { return false }
        return hasBudget(attemptsMade: attemptsMade)
    }

    /// What the hardware looks like right before Voice-Processing is enabled.
    public struct HardwareFormat: Equatable, Sendable {
        public let sessionRate: Double
        public let inputRate: Double
        public let inputChannels: Int
        public init(sessionRate: Double, inputRate: Double, inputChannels: Int) {
            self.sessionRate = sessionRate
            self.inputRate = inputRate
            self.inputChannels = inputChannels
        }
    }

    public struct Selection: Equatable, Sendable {
        /// False when the input side has no usable format yet; enabling would raise.
        public let ready: Bool
        /// The rate the nodes really run at (0 when not ready).
        public let sampleRate: Double
        public let channels: Int
        /// True when the session should be asked for `sampleRate` instead of the fixed preferred rate.
        public let alignSessionPreference: Bool
    }

    private static let validRates: ClosedRange<Double> = 8_000...96_000

    /// Choose the format from what the hardware reports, never from a fixed 48 kHz.
    public static func selectFormat(_ hw: HardwareFormat, preferredRate: Double) -> Selection {
        guard hw.inputChannels > 0, validRates.contains(hw.inputRate) else {
            return Selection(ready: false, sampleRate: 0, channels: 0, alignSessionPreference: false)
        }
        let rate = hw.inputRate
        let align = validRates.contains(hw.sessionRate)
            && hw.sessionRate != preferredRate
            && abs(hw.sessionRate - rate) < 1
        return Selection(ready: true, sampleRate: rate, channels: hw.inputChannels,
                         alignSessionPreference: align)
    }

    // MARK: - Log lines (shapes accepted by scripts/ship-ios-logs.py)

    public static func formatLine(gen: Int, hw: HardwareFormat, ready: Bool) -> String {
        "audioVp ev=cfg gen=\(gen) sess_hz=\(Int(hw.sessionRate)) in_hz=\(Int(hw.inputRate)) ch=\(hw.inputChannels) ok=\(ready ? 1 : 0)"
    }

    public static func armLine(gen: Int, attempt: Int, delayMs: Int) -> String {
        "audioVp ev=arm gen=\(gen) retry=1 n=\(attempt) delay_ms=\(delayMs)"
    }

    public enum Result: String { case ok, fail, skip, stop }

    public static func fireLine(gen: Int, attempt: Int, result: Result) -> String {
        "audioVp ev=fire gen=\(gen) retry=1 n=\(attempt) res=\(result.rawValue)"
    }
}
