import Foundation

/// Self-echo guard for the `opaque_message` call-signaling PIGGY-BACK
/// channel (`CallPiggyBack` — SCREEN_SHARE / VOICE_KEY / OWNER_CONT / CAPS /
/// HANGUP / KCMAC / …, see `AndroidHandshakeBundle.swift`). Mirrors Android's
/// `WsSelfEchoFilter` (`core-data/.../ws/WsSelfEchoFilter.kt`) 1:1 for the
/// self-echo half of its job.
///
/// WHY the server needs this at all: bcrypto-lite bounces every
/// `opaque_message` frame back to its own original sender, with
/// `sender_id` rewritten to look like it came from the recipient — so on
/// the wire a self-echo is INDISTINGUISHABLE by identity from a genuine
/// inbound (the bounced copy's `sender_id` legitimately equals the real
/// peer's id, exactly as it would for an actual message from them).
/// Identity-based dedup (`senderId == myOwnId`) therefore CANNOT work on
/// this channel — contrast `AppState`'s `msg_receive` self-echo handling
/// (`wireIncomingChatHandlers`), where the server does NOT rewrite the id
/// and a plain identity comparison is exactly right. Content-fingerprint
/// matching is the only usable signal here — same conclusion Android's
/// kdoc reaches for the same reason.
///
/// SCOPE (deliberate, see the 5-item InCallScreen Android→iOS port task
/// this file was added for): wired ONLY at the `CallPiggyBack`
/// (`<callId>|<TAG>:…`) parse boundary in `AppState.dispatchInboundOpaque`
/// (Path B0), never at the QUAD binary OFFER/ACCEPT or JSON HandshakeBundle
/// branches above it in that function. Those carry fresh, effectively-
/// unique key material per send — a genuine content collision between two
/// DIFFERENT sends is astronomically unlikely there — so content-
/// fingerprint dedup adds no value on that path, and touching that
/// security-critical handshake code is out of scope for this pass.
///
/// W-SELFECHOSYMMETRIC parity — the failure mode a NAIVE content filter (no
/// TTL, or a TTL as long as the resend cadence) hits: two peers
/// independently announcing the SAME fact on their own periodic timer (e.g.
/// both sides' `VOICE_KEY:1`) produce byte-identical payloads, so a
/// long-lived "have I sent this exact string recently" entry can swallow
/// the PEER's genuinely different message as a false self-echo — confirmed
/// live on Android (see `WsSelfEchoFilter`'s kdoc: one device's own
/// `VOICE_KEY:1` shadowed the peer's independently-timed `VOICE_KEY:1` for
/// the same call). The fix is keeping the match window SHORT: comfortably
/// above the real server bounce-back round-trip (so it still always
/// catches a genuine self-echo) but comfortably BELOW the shortest resend
/// cadence any current piggy-back sender uses, so a device's own pending
/// entry always fully expires before its NEXT send could collide with a
/// peer's independently-timed announce.
@MainActor
final class OpaqueSelfEchoFilter {
    static let shared = OpaqueSelfEchoFilter()

    /// Self-echo MATCH window. A genuine server bounce-back of our own send
    /// arrives almost immediately (~1.3s observed live on Android); 2s
    /// stays comfortably above that while staying well below the shortest
    /// resend cadence any current piggy-back sender uses on iOS (VOICE_KEY's
    /// fast-burst retry is 3s — see `AppState.voiceKeyAnnounceRetryIntervalMs`),
    /// matching Android's `WsSelfEchoFilter.SELF_ECHO_TTL_MS` exactly.
    private static let selfEchoTtl: TimeInterval = 2.0

    /// Keyed on the raw wire string (`"<callId>|<TAG>:…"`) — the whole
    /// content is the fingerprint, no per-tag decomposition needed, mirrors
    /// Android's `opaqueFingerprint(data) = "opaque|$data"`.
    private var pending: [String: [Date]] = [:]

    private init() {}

    /// Record an outgoing wire string so a later bounce-back can be matched
    /// and dropped. Call this right before sending it.
    func markSent(_ wire: String) {
        guard !wire.isEmpty else { return }
        let now = Date()
        var list = pending[wire] ?? []
        list.removeAll { now.timeIntervalSince($0) > Self.selfEchoTtl }
        list.append(now)
        pending[wire] = list
    }

    /// Returns true if `wire` should be dropped as a self-echo — i.e. it
    /// matches a `markSent` call within the last `selfEchoTtl` seconds.
    /// Consumes (removes) the matched entry so a genuinely repeated inbound
    /// arriving after the window is treated as a new message, never
    /// silently eaten forever.
    func shouldDropInbound(_ wire: String) -> Bool {
        guard !wire.isEmpty else { return false }
        let now = Date()
        guard var list = pending[wire] else { return false }
        list.removeAll { now.timeIntervalSince($0) > Self.selfEchoTtl }
        guard !list.isEmpty else {
            pending.removeValue(forKey: wire)
            return false
        }
        list.removeFirst()
        if list.isEmpty {
            pending.removeValue(forKey: wire)
        } else {
            pending[wire] = list
        }
        return true
    }
}
