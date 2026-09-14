import Foundation

/// W-MEDIADEAD (2026-08-25) — the per-tick decision of the 90 s inbound-audio
/// liveness backstop, parity plan Fase B item B6.
///
/// Invariant (identical on every platform, mechanism free): a Connected call
/// whose inbound audio has been COMPLETELY absent for `timeoutMs` ends itself
/// (reason `"media-lost"`, peer notified best-effort) instead of sitting in a
/// phantom forever. It is the last line of defense for the case where the
/// peer died with every hangup channel lost — envelope, opaque piggy-back,
/// and in-band control frame all missed.
///
/// ## The non-negotiable porting caveat (inherited from Android)
///
/// Liveness MUST come from frames really DECODED — never from a tap that
/// includes concealment, because concealment produces "audio" forever from a
/// dead peer. On iOS the caller feeds `lastRealDecodeAtMs` from the RX site
/// that sits BEHIND the AEAD open + Opus decode (`CallService
/// .noteRealInboundDecode`), which PLC can never reach.
///
/// W-MEDIADEADSRTP (2026-08-29) — that decode stamp is now only HALF the
/// picture, and relying on it alone was a real, call-ending bug: an
/// `audio-srtp-v1` call never reaches that decode site at all. See
/// `rtpBytesGrew` on `evaluate` for the second source, and for why byte
/// growth honours the same no-concealment caveat.
///
/// ## Constants
///
/// Byte-for-byte Android's (`CallController` companion): poll 15 s, timeout
/// 90 s. The timeout sits deliberately ABOVE the server's 60 s
/// disconnect-grace ceiling and the client's own 45 s hangup-park budget, so
/// the backstop can only fire after every genuine recovery mechanism has
/// already had its full window and lost. The freshness window is 2× the poll,
/// mirroring Android's `now - lastRealRxFrameAtMs < MEDIA_DEAD_POLL_MS * 2`.
///
/// Pure function so the invariant is unit-testable without an audio stack.
public enum MediaDeadDecisions {

    /// Poll cadence, ms. Android `MEDIA_DEAD_POLL_MS`.
    public static let pollMs: Int64 = 15_000

    /// Zero-inbound-audio span after which a Connected call is declared
    /// phantom, ms. Android `MEDIA_DEAD_TIMEOUT_MS`.
    public static let timeoutMs: Int64 = 90_000

    /// One poll tick's verdict.
    public enum Verdict: Equatable {
        /// A real decode happened within the freshness window — the call is
        /// alive; the caller refreshes its baseline to now.
        case alive
        /// No fresh decode, but the silent span is still under the
        /// threshold — keep counting, do not touch the baseline.
        case counting
        /// Silent for the full threshold — end the phantom call.
        case dead
    }

    /// - Parameters:
    ///   - nowMs: current wall clock, ms.
    ///   - lastAliveAtMs: the caller's baseline — the last tick that saw the
    ///     call alive (or the moment the watchdog armed / the gate reopened).
    ///   - lastRealDecodeAtMs: wall clock of the last REALLY-decoded inbound
    ///     frame; 0 = never this call.
    ///   - rtpBytesGrew: W-MEDIADEADSRTP (2026-08-29) — the audio
    ///     `inbound-rtp.bytesReceived` counter INCREASED since the previous
    ///     tick. The second liveness source, and the one that matters on an
    ///     `audio-srtp-v1` call: there the peer's audio arrives as real SRTP
    ///     and `processIncomingAudio` — the only writer of
    ///     `lastRealDecodeAtMs` — is never called for the whole call, so that
    ///     stamp stays 0 forever and this watchdog killed a perfectly healthy
    ///     call at exactly `timeoutMs`. Confirmed live 2026-08-29 (call
    ///     50d86a9f, iOS<->Android): audio working in both directions, call
    ///     ended at 95 s with `reason=media-lost`.
    ///
    ///     Byte growth is the right signal rather than the PCM tap, and that
    ///     is exactly why the caveat above is not violated: NetEQ concealment
    ///     keeps producing samples from a dead peer, but it cannot invent
    ///     RECEIVED BYTES. No growth means nothing arrived from the network,
    ///     whatever the speaker happens to be playing. Mirrors Android's
    ///     `rtpAlive` (`CallController` mediaDeadWatchdogJob), which reads the
    ///     same counter for the same reason.
    ///
    ///     Defaults to `false`, so a caller with no RTP leg — and every
    ///     existing test — behaves exactly as before.
    public static func evaluate(
        nowMs: Int64,
        lastAliveAtMs: Int64,
        lastRealDecodeAtMs: Int64,
        rtpBytesGrew: Bool = false
    ) -> Verdict {
        if rtpBytesGrew {
            return .alive
        }
        if lastRealDecodeAtMs > 0 && nowMs - lastRealDecodeAtMs < pollMs * 2 {
            return .alive
        }
        return nowMs - lastAliveAtMs >= timeoutMs ? .dead : .counting
    }
}
