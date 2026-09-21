import Foundation

/// W-LIVELOGOFFMAIN (2026-09-21) — when the opt-in log shipper (`LiveLogStreamer`,
/// W417) must stop hitting the server, and for how long.
///
/// Field evidence (call 4da935fd, 2026-09-20, iPhone, perfect network): every one of
/// the shipper's 15 TUS uploads was answered HTTP 429 (the server caps concurrent
/// uploads per user), the read cursor never advanced, and each retry re-processed the
/// whole unshipped backlog on the main thread. Five main-thread stalls of 0.7-4.5 s
/// followed, each starting right before an upload attempt. The old back-off (3 s
/// doubling, 60 s cap, no `Retry-After`) only spaced the attempts; it did not make an
/// attempt cheap, and it ignored the server's own hint.
///
/// This type is only the DECISION: pure, no clock (the caller passes a monotonic
/// `now`, in seconds), no randomness (the caller passes the jitter draw), no I/O, so
/// every path is unit-testable without sleeping.
///
/// Classes of failure:
///   * `.throttle`    HTTP 429 or 503. Honours `Retry-After` when the response carried
///                    one; otherwise 5 s doubling to a 120 s cap, plus up to 20% jitter.
///   * `.serverError` any other 5xx. Kept on the schedule the shipper already used for
///                    every 5xx (3 s doubling, exponent capped at 5, 60 s cap, 20%
///                    jitter), and `Retry-After` is not consulted: nothing about how
///                    those statuses are handled changes.
///   * `.other`       network error, 401, 404, ... : no back-off, the streak resets,
///                    exactly as before.
public struct LiveLogBackoff: Equatable, Sendable {

    public enum FailureClass: Equatable, Sendable {
        case throttle
        case serverError
        case other
    }

    public static let throttleBaseSeconds: TimeInterval = 5
    public static let throttleCapSeconds: TimeInterval = 120
    static let throttleMaxExponent: Int = 10

    public static let serverErrorBaseSeconds: TimeInterval = 3
    public static let serverErrorCapSeconds: TimeInterval = 60
    static let serverErrorMaxExponent: Int = 5

    /// A `Retry-After` shorter than this is raised to it, one longer than
    /// `retryAfterMaxSeconds` is lowered to it: a hostile or broken header must not be
    /// able to silence a diagnostics pump for the rest of the process lifetime.
    public static let retryAfterMinSeconds: TimeInterval = 1
    public static let retryAfterMaxSeconds: TimeInterval = 600

    /// Up to this fraction of the scheduled delay is added on top, so devices that were
    /// throttled together do not come back together.
    public static let jitterFraction: Double = 0.2

    /// Consecutive back-off-worthy failures since the last success or unrelated failure.
    public private(set) var consecutiveFailures: Int = 0

    /// Monotonic instant (same unit as the `now` the caller passes) before which no new
    /// upload may start. 0 = no back-off in force.
    public private(set) var notBefore: TimeInterval = 0

    public init() {}

    // MARK: - Classification

    public static func classify(status: Int?) -> FailureClass {
        guard let code = status else { return .other }
        if code == 429 || code == 503 { return .throttle }
        if code >= 500 && code <= 599 { return .serverError }
        return .other
    }

    // MARK: - State

    public func isBackingOff(now: TimeInterval) -> Bool {
        return now < notBefore
    }

    public func remainingSeconds(now: TimeInterval) -> TimeInterval {
        return max(notBefore - now, 0)
    }

    /// A chunk was confirmed by the server: forget the streak and any back-off.
    public mutating func recordSuccess() {
        consecutiveFailures = 0
        notBefore = 0
    }

    /// Register a failed upload.
    ///
    /// - Parameters:
    ///   - status: the HTTP status, or nil when the failure had none (network drop, ...).
    ///   - retryAfterSeconds: the parsed `Retry-After` (see `parseRetryAfter`), if any.
    ///   - now: monotonic clock, seconds.
    ///   - jitterUnit: a draw in 0...1 (values outside are clamped).
    /// - Returns: the delay now in force, or nil when this failure does not back off.
    @discardableResult
    public mutating func recordFailure(status: Int?,
                                       retryAfterSeconds: TimeInterval?,
                                       now: TimeInterval,
                                       jitterUnit: Double) -> TimeInterval? {
        let kind = LiveLogBackoff.classify(status: status)
        if kind == .other {
            // Same as before: a failure that is not a throttle ends the streak and
            // leaves the normal cadence alone.
            consecutiveFailures = 0
            return nil
        }
        consecutiveFailures += 1
        var delay: TimeInterval
        if kind == .throttle, let hint = retryAfterSeconds, hint.isFinite, hint >= 0 {
            delay = min(max(hint, LiveLogBackoff.retryAfterMinSeconds), LiveLogBackoff.retryAfterMaxSeconds)
        } else {
            delay = LiveLogBackoff.scheduledDelay(kind: kind,
                                                  failures: consecutiveFailures,
                                                  jitterUnit: jitterUnit)
        }
        if !delay.isFinite || delay < 0 { delay = 0 }
        notBefore = now + delay
        return delay
    }

    /// The exponential schedule, jitter included.
    static func scheduledDelay(kind: FailureClass, failures: Int, jitterUnit: Double) -> TimeInterval {
        let base: TimeInterval
        let cap: TimeInterval
        let maxExponent: Int
        switch kind {
        case .throttle:
            base = throttleBaseSeconds
            cap = throttleCapSeconds
            maxExponent = throttleMaxExponent
        case .serverError:
            base = serverErrorBaseSeconds
            cap = serverErrorCapSeconds
            maxExponent = serverErrorMaxExponent
        case .other:
            return 0
        }
        let exponent = min(max(failures, 1), maxExponent)
        let raw = base * pow(2.0, Double(exponent - 1))
        let capped = min(raw, cap)
        let unit = min(max(jitterUnit, 0), 1)
        return capped + capped * jitterFraction * unit
    }

    // MARK: - Retry-After

    /// Parse an HTTP `Retry-After` value (RFC 9110 section 10.2.3) into a number of
    /// seconds from `now`.
    ///
    /// Accepts the delay-seconds form ("120") and the IMF-fixdate HTTP-date form
    /// ("Sun, 06 Nov 1994 08:49:37 GMT"). A date in the past yields 0. Anything else
    /// (nil, empty, negative, non-finite, the obsolete date forms) yields nil, which the
    /// caller reads as "no hint": the exponential schedule applies.
    public static func parseRetryAfter(_ raw: String?, now: Date) -> TimeInterval? {
        guard let text = raw else { return nil }
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let seconds = Double(trimmed) {
            if seconds.isFinite && seconds >= 0 { return seconds }
            return nil
        }
        if let date = parseHttpDate(trimmed) {
            return max(date.timeIntervalSince(now), 0)
        }
        return nil
    }

    private static let monthNumbers: [String: Int] = [
        "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
        "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12
    ]

    /// IMF-fixdate only ("Sun, 06 Nov 1994 08:49:37 GMT"), parsed by hand so the result
    /// cannot depend on the device locale or calendar.
    static func parseHttpDate(_ text: String) -> Date? {
        let parts: [String] = text.split(separator: " ", omittingEmptySubsequences: true).map { String($0) }
        guard parts.count == 6, parts[0].hasSuffix(","), parts[5] == "GMT" else { return nil }
        guard let day = Int(parts[1]),
              let month = monthNumbers[parts[2]],
              let year = Int(parts[3]) else { return nil }
        let clock: [String] = parts[4].split(separator: ":", omittingEmptySubsequences: false).map { String($0) }
        guard clock.count == 3,
              let hour = Int(clock[0]),
              let minute = Int(clock[1]),
              let second = Int(clock[2]) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        if let utc = TimeZone(secondsFromGMT: 0) {
            calendar.timeZone = utc
        }
        return calendar.date(from: components)
    }
}
