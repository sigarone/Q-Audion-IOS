import Foundation
#if canImport(WebRTC)
import WebRTC
#endif

/// W-MEDIAATACCEPT (option b) — §4.8 (G2/iOS-10): LOCAL-ONLY prewarm during
/// RING for a `mode == 1` incoming call, so the accept-time media-plane
/// build (`AppState.startIncomingMediaPlane` → `buildIncomingWebRtcMediaPlane`)
/// finds this device's two slowest one-time setup costs already paid:
///
/// 1. This device's own TURN/STUN credentials (`RelayCredentialsProvider
///    .currentOrRefresh()`) — a REST round-trip to OUR OWN server
///    (`/api/v1/calling/relays`), never the peer.
/// 2. The process-wide `RTCPeerConnectionFactory`
///    (`QAudionPeerConnectionFactory.shared.sharedFactory()`) — one-time
///    audio/video codec + encoder/decoder setup, pure local CPU work, built
///    at most once per process regardless of how many calls prewarm it.
///
/// **Forbidden here, and never done:** no `RTCPeerConnection` is created, no
/// ICE candidate is gathered, no signaling envelope goes out, no
/// `AVAudioSession` is activated. Both calls above are read/build-only
/// operations against resources this device already owns or already talks
/// to for unrelated reasons (relay credentials are fetched from our own
/// backend the same way a live call already does) — nothing here discloses
/// this device's existence, IP, or intent to the CALLER before the human
/// decides to accept.
///
/// **Deliberately scoped down from the full spec §4.8 ask,** which also
/// adds a `RelayProbeCache` that measures STUN round-trip time to each
/// relay candidate and wires that cache into
/// `QAudionWebRtcCallController.fetchIceServers`'s private ordering logic.
/// That half sends UDP STUN probes — spec-scoped to this app's own relay
/// fleet only, never the peer — and reaches into a private method this task
/// did not verify end to end without a Swift toolchain. What is implemented
/// here already removes the two costs most likely to dominate the
/// accept→audio latency budget (network RTT for credentials, and one-time
/// codec/encoder factory construction) without adding any new network
/// destination or any traffic at all beyond the credentials fetch every
/// call already makes anyway, just earlier.
public enum RingMediaPlanePrewarm {

    /// Fire-and-forget from `call_incoming` when `mode == 1` (AppState wires
    /// this — see `AppState.latchIncomingNativeSrtpSnapshot`). Safe to call
    /// more than once per call (e.g. a duplicate `call_incoming`, or the
    /// same call also going through the legacy OFFER path): both
    /// `RelayCredentialsProvider` (single in-flight refresh, coalesced) and
    /// `QAudionPeerConnectionFactory` (built once per process) are
    /// idempotent on their own, so a second concurrent prewarm just awaits
    /// the same underlying work rather than duplicating it.
    ///
    /// `.utility` priority: this is a nice-to-have that should never
    /// compete with the human-visible ring UI or (once accepted) the real
    /// media-plane build for CPU/QoS.
    public static func prewarm(relayProvider: RelayCredentialsProvider?) {
        Task.detached(priority: .utility) {
            _ = await relayProvider?.currentOrRefresh()
            #if canImport(WebRTC)
            _ = await QAudionPeerConnectionFactory.shared.sharedFactory()
            #endif
        }
    }
}
