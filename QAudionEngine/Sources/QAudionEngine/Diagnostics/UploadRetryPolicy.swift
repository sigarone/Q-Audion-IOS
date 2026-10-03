import Foundation

/// W-RETRYAFTER (2026-10-03) — what a background uploader does when a request to the
/// server fails, and how long it then stays quiet.
///
/// Field evidence (iPhone + iPad calls of 2026-10-03 ~17:05-17:08 UTC): the server's
/// per-IP rate limiter (60 requests per minute, ONE bucket for every device behind the
/// same home address) answered 429 with `Retry-After: 60`. The telemetry uploader read
/// only the status class: a 4xx other than 401 meant "the batch itself is rejected" and
/// it threw the batch away, so the whole batch of call 6 was lost, and the next flush
/// five seconds later hit the same exhausted bucket again. The header was never read.
///
/// This file is only DECISIONS, pure and testable: no clock (callers pass a monotonic
/// `now` in seconds and, for HTTP-date hints, a wall-clock `Date`), no randomness (the
/// caller passes the jitter draw), no I/O.
///
/// What every uploader that adopts it does, in order:
///   1. On a 2xx the work is done: forget the failure streak and any pause.
///   2. On a status that condemns the payload itself (`rejectedStatuses`) the payload is
///      dropped, once, explicitly, and the drop is counted and logged by the caller.
///   3. On EVERYTHING else (429, 503, any 5xx, 401/402/403/404, a network error) the
///      payload is kept and the uploader is paused until `UploadPause.notBefore`.
///      Nothing else is sent by that uploader before then.
public enum UploadRetryPolicy {

    /// A `Retry-After` shorter than this is raised to it.
    public static let minDelaySeconds: TimeInterval = 1
    /// A longer one (or an exponential step past it) is lowered to it, so a hostile or
    /// broken header cannot silence a diagnostics pump for the rest of the process.
    public static let maxDelaySeconds: TimeInterval = 300
    /// 429/503 without a usable `Retry-After`: the first step of the schedule.
    public static let defaultThrottleSeconds: TimeInterval = 30
    /// Every other kept failure (5xx, network, 401...): the first step of the schedule.
    public static let transientBaseSeconds: TimeInterval = 10
    /// Up to this fraction of the delay is added on top (never taken off), so devices that
    /// were throttled together by the same per-IP bucket do not come back together.
    public static let jitterFraction: Double = 0.2

    /// Statuses that mean "this payload will never be accepted": malformed, too large,
    /// unsupported, unprocessable. Retrying them would burn requests forever.
    public static let rejectedStatuses: Set<Int> = [400, 413, 415, 422]

    public enum Verdict: Equatable, Sendable {
        /// 2xx.
        case success
        /// Drop the payload (and count it): the server will never take it.
        case reject
        /// Keep the payload, pause the uploader, try again after the pause.
        case keep
    }

    /// `status` is nil (or 0) when there was no HTTP response at all: a network error, a
    /// timeout. That is always a `.keep`.
    public static func verdict(status: Int?) -> Verdict {
        guard let code = status, code != 0 else { return .keep }
        if code >= 200 && code <= 299 { return .success }
        if rejectedStatuses.contains(code) { return .reject }
        return .keep
    }

    /// 429 and 503 are the statuses RFC 9110 defines `Retry-After` for in this context.
    public static func isThrottle(status: Int?) -> Bool {
        return status == 429 || status == 503
    }

    /// Parse an HTTP `Retry-After` (delay-seconds or IMF-fixdate HTTP-date) into seconds
    /// from `now`. Nil for a missing, empty, negative, non-finite or unparsable value.
    public static func parseRetryAfter(_ raw: String?, now: Date) -> TimeInterval? {
        return LiveLogBackoff.parseRetryAfter(raw, now: now)
    }

    /// The largest `Retry-After` a log line will print. `parseRetryAfter` only rejects nil,
    /// negative and non-finite values, so a hostile or broken header ("1e300",
    /// "99999999999999999999") comes back as a finite Double far outside Int's range, and
    /// `Int(_: Double)` traps on those. The pause itself is capped by `delay`; this caps what
    /// the LOG converts.
    public static let maxLoggedHintSeconds: TimeInterval = 86_400

    /// The parsed `Retry-After` as the text a log line carries: whole seconds, clamped to
    /// 0...`maxLoggedHintSeconds`, or "none" when there is no usable hint.
    ///
    /// Every uploader's "upload paused" line goes through this instead of converting the
    /// raw hint with `Int(...)`, which crashes the app on a hostile header (and these
    /// uploaders run in the background, always on).
    public static func hintLogSeconds(_ hint: TimeInterval?) -> String {
        guard let hint = hint, hint.isFinite else { return "none" }
        let clamped = min(max(hint, 0), maxLoggedHintSeconds)
        return String(Int(clamped.rounded()))
    }

    /// How long to stay quiet after a kept failure.
    ///
    /// - A parsable `Retry-After` replaces the schedule: floor 1 s, cap 300 s. This holds
    ///   for any status that carries one, not only 429/503.
    /// - 429/503 without a hint: 30 s, doubling per consecutive failure, cap 300 s.
    /// - Any other kept failure: 10 s, doubling per consecutive failure, cap 300 s.
    ///
    /// Jitter is added on top after the cap (so a pause of 300 s becomes 300-360 s) and the
    /// result is therefore never shorter than what the server asked for.
    ///
    /// - Parameters:
    ///   - status: HTTP status, nil when there was none.
    ///   - retryAfterHeader: the raw `Retry-After` header value, if any.
    ///   - now: wall clock, only used to read an HTTP-date hint.
    ///   - consecutiveFailures: failures in a row INCLUDING this one (>= 1).
    ///   - jitterUnit: a draw in 0...1 (values outside are clamped).
    public static func delay(status: Int?,
                             retryAfterHeader: String?,
                             now: Date,
                             consecutiveFailures: Int,
                             jitterUnit: Double) -> TimeInterval {
        let base: TimeInterval
        if let hint = parseRetryAfter(retryAfterHeader, now: now), hint.isFinite {
            base = min(max(hint, minDelaySeconds), maxDelaySeconds)
        } else {
            let first = isThrottle(status: status) ? defaultThrottleSeconds : transientBaseSeconds
            let exponent = min(max(consecutiveFailures, 1), 10)
            base = min(first * pow(2.0, Double(exponent - 1)), maxDelaySeconds)
        }
        let unit = min(max(jitterUnit.isFinite ? jitterUnit : 0, 0), 1)
        return base + base * jitterFraction * unit
    }
}

/// W-RETRYAFTER — one uploader's "do not send before" window plus its failure streak.
///
/// Value type, no clock inside: every call takes the caller's monotonic `now` (seconds,
/// e.g. `ProcessInfo.systemUptime`), so tests drive it without sleeping.
public struct UploadPause: Equatable, Sendable {

    /// Failures in a row since the last success.
    public private(set) var consecutiveFailures: Int = 0

    /// Monotonic instant before which this uploader sends nothing. 0 = no pause.
    public private(set) var notBefore: TimeInterval = 0

    public init() {}

    public func isPaused(now: TimeInterval) -> Bool {
        return now < notBefore
    }

    public func remainingSeconds(now: TimeInterval) -> TimeInterval {
        return max(notBefore - now, 0)
    }

    /// The server took the payload: forget the streak and the pause.
    public mutating func recordSuccess() {
        consecutiveFailures = 0
        notBefore = 0
    }

    /// A kept failure: extend the pause. Never SHORTENS one already in force, so two
    /// answers arriving close together (a shorter hint behind a longer one) cannot cut
    /// the quiet period the server asked for.
    ///
    /// - Returns: the delay this failure asked for (not the remaining time).
    @discardableResult
    public mutating func recordFailure(status: Int?,
                                       retryAfterHeader: String?,
                                       now: TimeInterval,
                                       wallClock: Date,
                                       jitterUnit: Double) -> TimeInterval {
        consecutiveFailures += 1
        let delay = UploadRetryPolicy.delay(status: status,
                                            retryAfterHeader: retryAfterHeader,
                                            now: wallClock,
                                            consecutiveFailures: consecutiveFailures,
                                            jitterUnit: jitterUnit)
        notBefore = max(notBefore, now + delay)
        return delay
    }
}

/// W-RETRYAFTER — a bounded FIFO of upload payloads (telemetry lines, ...) that stay in
/// the queue until the server confirms them, plus the uploader's `UploadPause`.
///
/// * Failure never removes anything: `peekBatch` is a look, `confirm(throughSeq:)` is the
///   only way a payload leaves after a successful upload.
/// * Bounded by `capacity`. When a new payload does not fit, the OLDEST payload goes (the
///   oldest non-priority one if there is any, so rarer, more diagnostic payloads outlive
///   the routine ones), and every drop is counted. The count is reported once, in the
///   next batch the server confirms (`unreportedDrops` / `acknowledgeDropReport`).
/// * Payloads are addressed by an ascending sequence number, not by position, so a
///   confirmation stays right even when older payloads were dropped for room while the
///   request was in flight.
///
/// Pure value type, no clock, no locks, no I/O. Not thread-safe by itself; the owner is
/// the only writer.
public struct RetryBatchBuffer<Element: Sendable>: Sendable {

    public struct Entry: Sendable {
        public let seq: UInt64
        public let element: Element
        public let isPriority: Bool
    }

    /// A prefix of the queue. Nothing is removed by looking at it.
    public struct Batch: Sendable {
        public let elements: [Element]
        /// Sequence number of the last payload in `elements`: the cursor to confirm.
        public let lastSeq: UInt64
        public let totalCost: Int
    }

    public let capacity: Int

    /// The uploader's back-off window. Public so the owner can read `isPaused`.
    public private(set) var pause = UploadPause()

    /// Payloads dropped for want of room (or discarded as rejected) so far.
    public private(set) var droppedTotal: Int = 0

    private var entries: [Entry] = []
    private var nextSeq: UInt64 = 1
    private var droppedUnreported: Int = 0

    public init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    public var count: Int { return entries.count }
    public var isEmpty: Bool { return entries.isEmpty }

    /// Payloads dropped and not yet reported in a confirmed batch.
    public var unreportedDrops: Int { return droppedUnreported }

    // MARK: - Growing

    /// Add one payload at the tail, dropping the oldest (see the type comment) if full.
    ///
    /// - Returns: how many payloads this call dropped (0 or 1).
    @discardableResult
    public mutating func append(_ element: Element, isPriority: Bool = false) -> Int {
        var dropped = 0
        if entries.count >= capacity {
            if let victim = entries.firstIndex(where: { !$0.isPriority }) {
                entries.remove(at: victim)
            } else {
                entries.removeFirst()
            }
            droppedTotal += 1
            droppedUnreported += 1
            dropped = 1
        }
        entries.append(Entry(seq: nextSeq, element: element, isPriority: isPriority))
        nextSeq += 1
        return dropped
    }

    // MARK: - Shipping

    /// The next batch: from the oldest, at most `maxCount` payloads and at most `maxCost`
    /// of summed `cost`. The first payload is always included even if it alone exceeds
    /// the budget, so one oversized payload can never wedge the queue. Nil when empty.
    public func peekBatch(maxCount: Int, maxCost: Int, cost: (Element) -> Int) -> Batch? {
        guard let first = entries.first, maxCount > 0 else { return nil }
        var elements: [Element] = []
        var total = 0
        var lastSeq = first.seq
        for entry in entries {
            if elements.count >= maxCount { break }
            let c = max(cost(entry.element), 0)
            if !elements.isEmpty && total + c > maxCost { break }
            elements.append(entry.element)
            total += c
            lastSeq = entry.seq
        }
        return Batch(elements: elements, lastSeq: lastSeq, totalCost: total)
    }

    /// The server confirmed everything up to and including `seq`.
    @discardableResult
    public mutating func confirm(throughSeq seq: UInt64) -> Int {
        let before = entries.count
        entries.removeAll { $0.seq <= seq }
        return before - entries.count
    }

    /// The server will never take these (see `UploadRetryPolicy.rejectedStatuses`): remove
    /// everything up to `seq` AND count it as dropped, so the loss is visible.
    @discardableResult
    public mutating func discard(throughSeq seq: UInt64) -> Int {
        let removed = confirm(throughSeq: seq)
        droppedTotal += removed
        droppedUnreported += removed
        return removed
    }

    /// A batch that carried a drop report of `count` was confirmed: stop reporting those.
    public mutating func acknowledgeDropReport(_ count: Int) {
        droppedUnreported = max(droppedUnreported - max(count, 0), 0)
    }

    /// Forget everything queued (consent withdrawn) and the drop counters. The pause is
    /// kept: withdrawing and re-granting consent must not be a way around it.
    public mutating func removeAll() {
        entries.removeAll()
        droppedTotal = 0
        droppedUnreported = 0
    }

    // MARK: - Pause

    public func isPaused(now: TimeInterval) -> Bool {
        return pause.isPaused(now: now)
    }

    public mutating func recordSuccess() {
        pause.recordSuccess()
    }

    @discardableResult
    public mutating func recordFailure(status: Int?,
                                       retryAfterHeader: String?,
                                       now: TimeInterval,
                                       wallClock: Date,
                                       jitterUnit: Double) -> TimeInterval {
        return pause.recordFailure(status: status,
                                   retryAfterHeader: retryAfterHeader,
                                   now: now,
                                   wallClock: wallClock,
                                   jitterUnit: jitterUnit)
    }
}
