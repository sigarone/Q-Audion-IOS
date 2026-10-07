import Foundation

/// The retry loop of one request of the parts protocol, for the send and the receive pipelines.
///
/// It applies, and does not restate, the rules of the transfer base: `fileV2TransportDisposition` says what a failure means
/// for the operation `op`, `FileV2RetryPolicy` says how long to wait and when the attempts are spent (backoff 1, 2, 4, 8 s
/// plus jitter, `Retry-After` when the server gives one, at most `maxAttempts` tries, and a `Retry-After` above 300 s is not
/// waited for at all).
///
/// - a 425 (`wait`) is not a failure and is not counted as an attempt; it waits the `Retry-After` of the server (at least
///   1 s), and gives up after `maxWaits` of them so that a stuck object cannot hold a transfer for ever;
/// - 429, 5xx, a digest or short-body answer and any transport error (a reset, a timeout) are retried;
/// - 4xx is final. A final failure, or spent attempts, is thrown as a `FileV2Failure`;
/// - `Task` cancellation is never a failure of the request and is rethrown as it is.
///
/// The closure is called again for every try, so the caller decides what a try sends: the sender passes the SAME already
/// sealed bytes every time (a retried part is never sealed again).
public enum FileV2Retry {

    /// The real sleeper: `Task.sleep`, cancellable.
    public static let realSleep: @Sendable (Int64) async throws -> Void = { milliseconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
    }

    /// Longest sequence of 425 answers one request waits through.
    public static let defaultMaxWaits = 120

    public static func run<T>(
        op: FileV2Op,
        policy: FileV2RetryPolicy = FileV2RetryPolicy(),
        maxWaits: Int = FileV2Retry.defaultMaxWaits,
        sleep: @Sendable (Int64) async throws -> Void = FileV2Retry.realSleep,
        _ attempt: () async throws -> T
    ) async throws -> T {
        var failures = 0
        var waits = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await attempt()
            } catch {
                let server = error as? FileV2ServerError
                switch try fileV2TransportDisposition(error, op: op) {
                case .retry(let onExhausted):
                    failures += 1
                    guard let delay = policy.nextDelayMs(failedAttempts: failures, retryAfterSeconds: server?.retryAfter) else {
                        throw FileV2Failure.transfer(onExhausted, server: server)
                    }
                    try await sleep(delay)
                case .wait:
                    waits += 1
                    guard waits <= maxWaits else { throw FileV2Failure.transfer(.network, server: server) }
                    let seconds = min(max(server?.retryAfter ?? 1, 1), FileV2Wire.maxRetryAfterSeconds)
                    try await sleep(Int64(seconds) * 1000)
                case .refreshAuth:
                    // The HTTP client already refreshed the session once and asked again: a 401 that is left is final.
                    throw FileV2Failure.transfer(.auth, server: server)
                case .recreate:
                    throw FileV2Failure(.objectGone, server: server)
                case .unavailable:
                    throw FileV2Failure(.unavailable, server: server)
                case .sendMissing, .done:
                    // Not an answer this pipeline can act on (the pipelines send every part before `complete`, and `done` is
                    // the answer of a delete, which they do not retry).
                    throw FileV2Failure.transfer(.badRequest, server: server)
                case .userRemedy(let reason), .fail(let reason):
                    throw FileV2Failure.transfer(reason, server: server)
                }
            }
        }
    }
}
