import Foundation

/// W-MSGOUTBOX (2026-09-01) — pure decision helpers for the durable 1:1
/// message outbox (the drainer itself is `ChatOutboxDrain` in the app
/// target; the persisted queue is `ChatOutboxStore` next to this file).
///
/// Why this exists (audit memory reference_ios_stability_audit_2026_09_01,
/// P1 item 3): a 1:1 text send was one in-memory `Task` — wait ≤5 s for the
/// socket (`ChatMessageSendService.sendEncrypted`), ≤5 s more inside
/// `BCryptoMessageApiImpl.sendMessage`, then `wsUnavailable` → the row
/// flipped to `.failed` and only a manual tap retried it. A process kill in
/// that window left the row `.sending` forever, and nothing ever swept it.
/// The generic fix is a transactional outbox: the row IS the record of
/// intent, the sealed wire bytes are persisted next to it, and a drainer
/// re-sends them with the SAME `client_msg_id` (the idempotency key the
/// server already echoes and the receiver already stores) until the socket
/// accepts them or a hard cap is hit.
///
/// No I/O, no clock, no WebRTC/WebSocket state in here — same discipline as
/// `RestartIceDecisions` / `IceTerminationPolicy` / `DatabaseOpenRecoveryPolicy`,
/// so every number and branch is pinned by `OutboxRetryPolicyTests` and a
/// rollback is a single constant flip.
public enum OutboxRetryPolicy {

    /// Compile-time kill switch (same style as `CallCapabilities
    /// .longAudioSendEnabled` / `DatabaseOpenRecoveryPolicy.enabled`).
    /// `false` restores the pre-2026-09-01 behavior verbatim: a transport
    /// failure marks the row `.failed` immediately, nothing is queued, the
    /// drainer never runs, delivery receipts are never queued. Rows and
    /// queue entries already on disk are left alone — they are inert data.
    public static let enabled: Bool = true

    // MARK: - Backoff constants

    /// First jitter ceiling after one failed attempt.
    public static let baseDelayMs: Int64 = 500

    /// Ceiling the exponential ladder is clamped to. Chosen so a socket
    /// that comes back mid-outage is used within ~30 s worst case, while a
    /// long outage does not spin (the drainer only attempts while the
    /// transport reports authenticated, see `ChatOutboxDrain`).
    public static let maxDelayMs: Int64 = 30_000

    /// Hard cap on REAL send attempts per message. Attempts are only counted
    /// when the transport said it was ready and the send still failed, so
    /// an offline day does not consume them — `maxAgeMs` covers that.
    public static let maxAttempts: Int = 20

    /// Hard cap on the age of a queued message (from its `sentAt`). Past
    /// this the row becomes `.failed` (visible, manual retry as before).
    public static let maxAgeMs: Int64 = 24 * 60 * 60 * 1000

    /// Exponent guard: `2^n` is never evaluated past this, so the ladder can
    /// never overflow even if a caller passes a huge attempt count.
    private static let maxExponent: Int = 20

    // MARK: - Backoff

    /// Upper bound of the jitter window to wait AFTER `attempts` failed
    /// attempts, before the next one: `min(maxDelayMs, baseDelayMs · 2^(attempts-1))`.
    /// Zero failed attempts means "send now" (ceiling 0).
    public static func backoffCeilingMs(afterFailedAttempts attempts: Int) -> Int64 {
        guard attempts > 0 else { return 0 }
        let exponent = min(attempts - 1, maxExponent)
        let raw = baseDelayMs * (Int64(1) << Int64(exponent))
        return min(maxDelayMs, raw)
    }

    /// Full-jitter backoff: a uniform draw in `[0, ceiling]`. Full jitter
    /// (rather than "ceiling ± something") is what keeps a fleet of clients
    /// that all lost the same socket from re-sending in lockstep when it
    /// comes back. `random` is injectable so tests can pin both ends of the
    /// window; the default is the system RNG.
    public static func backoffMs(
        afterFailedAttempts attempts: Int,
        random: (ClosedRange<Int64>) -> Int64 = { Int64.random(in: $0) }
    ) -> Int64 {
        let ceiling = backoffCeilingMs(afterFailedAttempts: attempts)
        guard ceiling > 0 else { return 0 }
        let drawn = random(0...ceiling)
        // Defensive clamp: an injected RNG that misbehaves can never push a
        // wait outside the documented window.
        return min(max(drawn, 0), ceiling)
    }

    // MARK: - Per-row decision

    /// What the drainer should do with one queued message on this pass.
    public enum RowAction: Equatable {
        /// Transport is ready and the backoff window has elapsed: send now.
        case attemptNow
        /// Backoff still running: leave the row alone and wake at `untilMs`.
        case wait(untilMs: Int64)
        /// Attempt cap reached: mark `.failed`, drop the queue entry.
        case giveUpAttempts
        /// Age cap reached: mark `.failed`, drop the queue entry.
        case giveUpAge
    }

    /// Pure per-row verdict. Age is checked before attempts so a row that is
    /// both old and exhausted reports the reason a user would recognise
    /// ("it has been a day"), and both caps are inclusive (`>=`) so
    /// `maxAttempts` failed attempts means no 21st.
    public static func rowAction(
        attempts: Int,
        createdAtMs: Int64,
        nextAttemptAtMs: Int64,
        nowMs: Int64
    ) -> RowAction {
        if nowMs - createdAtMs >= maxAgeMs { return .giveUpAge }
        if attempts >= maxAttempts { return .giveUpAttempts }
        if nextAttemptAtMs > nowMs { return .wait(untilMs: nextAttemptAtMs) }
        return .attemptNow
    }

    /// Which live-send failures are transient enough to queue. Only a
    /// transport failure (socket not authenticated in time, send threw) is
    /// retryable without user action; a missing pairwise key, a crypto
    /// failure or a missing session need the key exchange / login the
    /// existing `.failed` path already triggers, and retrying them blindly
    /// would only burn attempts.
    public static func shouldQueue(isTransportFailure: Bool) -> Bool {
        enabled && isTransportFailure
    }
}

/// W-MSGDEDUP (2026-09-01) — receive-side half of the same audit item
/// (P1 item 4): the 1:1 `msg_receive` path had no server-id dedup and
/// ordered rows by arrival time. The group path (`handleIncomingGroupMessage`
/// → `GroupMessageStore.contains(groupHex:serverMessageId:)`) already did
/// both and is the in-repo reference; this mirrors it for 1:1.
///
/// Dedup matters MORE now that the sender retries: an at-least-once
/// transport (server stores first, relays live, replays via
/// `msg_pending_sync` until a `msg_delivered` lands) will re-deliver, and a
/// re-delivered ratchet frame that reaches the decrypt step fails as a
/// replay and surfaces as "[messaggio cifrato non leggibile]". The check
/// therefore runs BEFORE decrypt, on the two identifiers the row already
/// stores: the server id (server-side replay) and the sender's
/// `client_msg_id` (client-side resend that the server stored twice).
public enum InboundMessagePolicy {

    /// Kill switch for the pre-decrypt dedup lookups. `false` = the
    /// pre-2026-09-01 path (every frame goes to decrypt).
    public static let dedupEnabled: Bool = true

    /// Kill switch for ordering inbound rows by the server timestamp
    /// carried in `msg_receive.server_ts` / `msg_pending_sync[].server_ts`
    /// (RFC3339, stamped by the server at store time). `false` = arrival
    /// time, the pre-2026-09-01 behavior.
    public static let orderByServerTimestampEnabled: Bool = true

    /// The `sentAt` an inbound row should carry: the parsed server
    /// timestamp when the wire had one and the switch is on, otherwise the
    /// local arrival instant (exactly what the row got before). The
    /// fallback is what keeps a peer on an older server, or a frame whose
    /// timestamp failed to parse, indistinguishable from today.
    public static func effectiveSentAt(serverTimestamp: Date?, arrival: Date) -> Date {
        guard orderByServerTimestampEnabled, let ts = serverTimestamp else { return arrival }
        return ts
    }
}
