import Foundation

/// Pure rules for the signalling socket's reconnect backoff and for the log line written on every
/// drop. Kept free of any socket state so the rules can be tested on their own.
///
/// The attempt counter used to go back to zero as soon as a socket authenticated. A connection that
/// was torn down a few seconds after every authentication therefore always reconnected after about a
/// second. The counter now goes back to zero only once a socket has held for `stabilityWindowSec`.
enum WebSocketReconnectPolicy {

    /// How long an authenticated socket must stay up before the backoff starts over.
    static let stabilityWindowSec: TimeInterval = 60

    /// Longest wait between two automatic attempts.
    static let maxDelaySec: TimeInterval = 30

    /// The attempt count to use for the drop that is happening now. `authenticatedAt` is when the
    /// socket that just dropped authenticated (nil when it never did); `now` uses the same clock.
    static func attemptAfterDrop(current: Int,
                                 authenticatedAt: TimeInterval?,
                                 now: TimeInterval,
                                 stabilityWindow: TimeInterval = stabilityWindowSec) -> Int {
        guard let at = authenticatedAt, now - at >= stabilityWindow else { return current }
        return 0
    }

    /// Wait before automatic attempt number `attempt` (1 = first retry): 1 s doubling up to
    /// `maxDelaySec`, with `jitterFraction` (-0.25...0.25) applied, never below half a second.
    static func delay(forAttempt attempt: Int, jitterFraction: Double) -> TimeInterval {
        let base = min(maxDelaySec, pow(2.0, Double(min(max(attempt, 1) - 1, 5))))
        return max(0.5, base + base * jitterFraction)
    }

    /// Number for an error domain: 0 none, 1 URL loading, 2 POSIX, 3 CFNetwork, 4 Cocoa, 9 anything else.
    /// The shipped log keeps only structured, low-entropy tokens, so the domain is a digit and not a name.
    static func domainKind(_ domain: String) -> Int {
        switch domain {
        case NSURLErrorDomain: return 1
        case NSPOSIXErrorDomain: return 2
        case "kCFErrorDomainCFNetwork": return 3
        case NSCocoaErrorDomain: return 4
        default: return 9
        }
    }

    /// One line per drop: error domain number and code, close frame status (0 when none arrived),
    /// seconds the socket was open, and the attempt count in force. The keys are ones the log shipper
    /// already knows, with numbers only, so the line is kept as it is.
    static func disconnectLine(domain: String?,
                               code: Int,
                               closeCode: Int,
                               socketAgeSec: TimeInterval,
                               attempt: Int) -> String {
        let kind = domain.map(domainKind) ?? 0
        let age = max(0, Int(socketAgeSec.rounded()))
        return "[BCryptoWS] ws drop kind=\(kind) code=\(code) status=\(closeCode) age=\(age)s attempts=\(attempt)"
    }
}

/// Minimum spacing between two full post-authentication refreshes of server data.
public struct ReconnectRefreshDebounce {

    /// A refresh that completed less than this long ago is not repeated on a reconnect.
    public static let minIntervalSec: TimeInterval = 60

    public private(set) var lastCompletedAt: TimeInterval?

    public init(lastCompletedAt: TimeInterval? = nil) { self.lastCompletedAt = lastCompletedAt }

    public func isDue(now: TimeInterval, minInterval: TimeInterval = ReconnectRefreshDebounce.minIntervalSec) -> Bool {
        guard let last = lastCompletedAt else { return true }
        return now - last >= minInterval || now < last
    }

    public mutating func markCompleted(at now: TimeInterval) { lastCompletedAt = now }
}
