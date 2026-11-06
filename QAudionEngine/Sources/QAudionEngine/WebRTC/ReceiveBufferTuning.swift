import Foundation

/// Receive-side playout buffer tuning for the native audio path.
///
/// The buffer sizes its target from a histogram of recent packet delays. That histogram is aged every
/// `resampleIntervalMs` by `forgetFactor`; a single late burst therefore keeps the target raised until the
/// entry has aged out. With the stock factor that takes tens of seconds, during which every listener-side
/// pause carries the extra delay. A smaller factor ages the entry out sooner while a new burst still raises
/// the target immediately.
enum ReceiveBufferTuning {

    static let trialName = "WebRTC-Audio-NetEqDelayManagerConfig"

    /// Stock value is 0.983 (half-life about 20 s at the stock interval).
    static let forgetFactor: Double = 0.96

    /// Histogram ageing period of the buffer, in milliseconds (stock value, kept explicit for the maths).
    static let resampleIntervalMs: Double = 500

    /// Time for an entry's weight to halve.
    static var halfLifeSeconds: Double {
        resampleIntervalMs / 1000.0 * (log(0.5) / log(forgetFactor))
    }

    /// Trial value, `key:value` pairs.
    static var trialValue: String {
        "forget_factor:" + String(format: "%.3f", forgetFactor)
    }

    /// Joins trials into the single `Key/Value/Key/Value/` string the factory expects.
    static func fieldTrialString(_ trials: [String: String]) -> String {
        trials.keys.sorted().map { "\($0)/\(trials[$0] ?? "")/" }.joined()
    }

    /// The trials this app sets, including the buffer tuning above.
    static var fieldTrials: [String: String] {
        [
            "WebRTC-Network-UseNWPathMonitor": "Enabled",
            trialName: trialValue,
        ]
    }
}
