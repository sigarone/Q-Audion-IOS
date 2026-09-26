import Foundation

/// W-NATIVESRTPDIAG (this task) — rate-limits repeated identical
/// `(role, state)` native `RTCFrameCryptor` transitions before they reach
/// the remote-shipped log, while never suppressing a REAL transition: a
/// different role (`"tx"`/`"rx"`) or a different state than the last one
/// actually logged always passes through immediately, regardless of timing.
/// Only REPEATS of the identical pair — e.g. a flapping cryptor oscillating
/// between two states faster than ``minRepeatIntervalMs`` — are throttled.
///
/// Pure decision logic, no WebRTC/Foundation types beyond `Int64` timestamps
/// the caller supplies — unit-testable without the WebRTC binary target,
/// same discipline as `AudioSdpPolicy` / `NackResendRateLimiter` in this
/// directory. `NativeAudioFrameCryptor` is the one caller today, holding an
/// instance under its own lock (mutating value type, not thread-safe on its
/// own).
public struct FrameCryptorStateChangeLogGate {
    public let minRepeatIntervalMs: Int64

    private var lastRole: String?
    private var lastStateRawValue: Int?
    private var lastLoggedAtMs: Int64 = 0

    public init(minRepeatIntervalMs: Int64 = 2_000) {
        self.minRepeatIntervalMs = minRepeatIntervalMs
    }

    /// Returns `true` iff this `(role, stateRawValue)` transition should be
    /// logged NOW, and records it as the last-logged pair when it does.
    /// `stateRawValue` is the raw enum value (`Int`) rather than the enum
    /// itself so this type never has to know about `RTCFrameCryptorState`.
    public mutating func shouldLog(role: String, stateRawValue: Int, nowMs: Int64) -> Bool {
        let isRepeat = lastRole == role && lastStateRawValue == stateRawValue
        if isRepeat, nowMs - lastLoggedAtMs < minRepeatIntervalMs {
            return false
        }
        lastRole = role
        lastStateRawValue = stateRawValue
        lastLoggedAtMs = nowMs
        return true
    }
}
