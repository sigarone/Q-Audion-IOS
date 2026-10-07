import Foundation

/// W-SIGNERWAIT (2026-10-07) — a bounded wait for the local handshake signer key.
///
/// The responder builds a SIGNED ACCEPT; without the signer key there is no ACCEPT (an unsigned
/// handshake is never an option, WIRE_SPEC §3.4). On a cold start the key can be a few hundred
/// milliseconds away (the Keychain unlocks, the first launch is still creating the identity), and
/// answering "not ready" the instant the OFFER lands used to cost the whole call its handshake:
/// the caller's OFFER retries arrive within ~1 s, all of them inside the window that failed.
/// So the responder waits for the key, for a short, fixed time, then gives up exactly as before.
///
/// Pure: the clock is the sum of the requested sleeps and the sleeper is injected, so the tests
/// run instantly and deterministically.
enum SignerKeyReadiness {

    /// How long a responder waits for the signer key before it gives up (milliseconds). Well under
    /// the ring window, and a retried OFFER that lands after it starts a fresh wait.
    static let maxWaitMs: UInt64 = 6_000
    /// Delay between two reads.
    static let pollMs: UInt64 = 150

    /// What a bounded wait observed.
    struct Outcome: Equatable {
        /// The signer key was readable (a well-formed 32-byte key).
        let ready: Bool
        /// Milliseconds spent waiting (0 when the first read already had the key).
        let waitedMs: UInt64
    }

    /// Read the signer key, retrying every `pollMs` for at most `maxWaitMs`.
    /// - Parameters:
    ///   - read: the lazy key source (`QAudionCallIntegration.localSignerIdentityKey`).
    ///   - sleep: waits `ms` milliseconds; defaults to a cancellable `Task.sleep`. Returns `false`
    ///     when the wait was cancelled, which ends the loop at once (the call is already gone).
    static func waitForKey(
        read: () -> Data?,
        maxWaitMs: UInt64 = SignerKeyReadiness.maxWaitMs,
        pollMs: UInt64 = SignerKeyReadiness.pollMs,
        sleep: (UInt64) async -> Bool = { ms in
            do { try await Task.sleep(nanoseconds: ms * 1_000_000); return true } catch { return false }
        }
    ) async -> Outcome {
        var waited: UInt64 = 0
        let step = max(pollMs, 1)
        while true {
            if let key = read(), key.count == 32 { return Outcome(ready: true, waitedMs: waited) }
            if waited >= maxWaitMs { return Outcome(ready: false, waitedMs: waited) }
            let slice = min(step, maxWaitMs - waited)
            if await sleep(slice) == false { return Outcome(ready: false, waitedMs: waited) }
            waited += slice
        }
    }
}
