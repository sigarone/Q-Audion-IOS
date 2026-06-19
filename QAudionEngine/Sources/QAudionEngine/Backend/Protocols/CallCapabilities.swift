import Foundation

/// Wire-format capability tags that travel inside `call_offer`/`call_answer`
/// (and their corresponding inbound events) under the `capabilities` field.
/// They let two peers agree at call setup which video/audio frame format to
/// use, without a separate roundtrip.
///
/// **Cross-platform contract:** Swift port of Kotlin
/// `com.bcrypto.qaudion.feature.call.domain.CallCapabilities` (Android) and
/// the equivalent TS constants in `qaudion-desktop`. The wire is plain JSON
/// strings, so any divergence between platforms is a simple string-equality
/// bug — easy to catch in cross-platform smoke tests + the KAT corpus.
///
/// **Design (option A in the cross-platform design):** capabilities live
/// inside the existing call-setup envelope. The bcrypto-server is pure
/// relay and never inspects them — agreement is a pure end-to-end
/// concern. Old clients that predate this field send no `capabilities`
/// key at all, which decodes to `nil` and is interpreted as "legacy peer".
///
/// Forward-compat: more tags can be added in v2 (`sframe-v2`,
/// `simulcast-v1`, etc.) without breaking older clients — they will
/// simply ignore unknown tags during the intersection.
public enum CallCapabilities {
    /// SFrame video frame format v1 (RFC 9605 + Q-Audion deviations §4-§5).
    public static let sframeV1: String = "sframe-v1"

    /// Ratchet v3 messaging support. When both sides advertise this tag the
    /// post-call msg-PSK is wired to the v3 Double-Ratchet chain instead of
    /// the v2 symmetric ratchet. Mirrors `RATCHET_V3` in Android
    /// `CallCapabilities.kt` and `CAP_RATCHET_V3` in the Desktop TS port.
    public static let ratchetV3: String = "ratchet-v3"

    /// Earbud-video phone-level key (`vkey-v1`). When BOTH sides advertise
    /// this tag the video FrameCryptor is keyed off a dedicated K_video
    /// (HKDF of the session key with domain-separation label
    /// `Q-AUDION-PHONE-VIDEO-V1` + transcript binding) instead of the raw
    /// audio/control PQC session key. Mirrors `VKEY_V1` in Android
    /// `CallCapabilities.kt` and the Desktop TS port. The trust level it
    /// grants is "phone-level" (the video key is derived on the phone, not
    /// inside a sovereign HSM) — surfaced to the UI via
    /// `videoKeyIsPhoneLevel`.
    public static let vkeyV1: String = "vkey-v1"

    /// Earbud opaque sealed-audio relay v1 (`earbud-relay-v1`, HW switch).
    /// Advertised by an Android peer whose bonded Q-Audion earbud is the
    /// active media path: the audio key lives in the EARBUD FIRMWARE
    /// (CRUX SPE) and the phone is a zero-knowledge relay. iOS NEVER
    /// advertises this tag (no iOS earbud transport) — it only DETECTS it
    /// on the peer's caps and switches the key exchange from the SW
    /// PqcHandshake to the earbud counterparty handshake
    /// (`EarbudHandshakeResponder` → HSINIT/HSRESP/HSFIN over the
    /// `EARBUDPDU:` opaque piggy-back). Mirrors `EARBUD_RELAY_V1` in
    /// Android `CallCapabilities.kt`.
    public static let earbudRelayV1: String = "earbud-relay-v1"

    /// AES-256-GCM video FrameCryptor upgrade v1 (Phase 2 kill-switch, OFF by default).
    ///
    /// Advertised only when ``v4SFrameAes256Enabled`` is `true`. Mirrors
    /// `SFRAME_AES256_V1` / `"sframe-aes256-v1"` in Android `CallCapabilities.kt`
    /// and `CAP_SFRAME_AES256_V1` in Desktop `CallCapabilities.ts`.
    ///
    /// INTEROP: advertising this tag requires the peer to also run AES-256
    /// FrameCryptor. A mismatch causes the native FrameCryptor `open()` to fail
    /// on every received frame. Only enable once all platforms ship AES-256.
    public static let sframeAes256V1: String = "sframe-aes256-v1"

    /// Phase 2 kill-switch — AES-256 SFrame video path.
    ///
    /// `false` (DEFAULT / OFF): AES-128 LiveKit FrameCryptor active. ``sframeAes256V1``
    ///   is NOT included in ``local``. Legacy Android / Desktop peers can video-call normally.
    ///
    /// `true` (ON): AES-256 path active (LiveKit FrameCryptor with a 32-byte key driving
    ///   AES-256-GCM). ``sframeAes256V1`` IS included in ``local``. A call with a peer
    ///   that does NOT advertise this tag will have video disabled fail-closed inside
    ///   ``QAudionPeerConnection``.
    ///
    /// Mirrors `V4_SFRAME_AES256_ENABLED` in Android `CallCapabilities.kt` and
    /// `V4_SFRAME_AES256_ENABLED` in Desktop `CallCapabilities.ts`.
    /// Cross-platform: ALL three platforms must use the same setting simultaneously.
    public static let v4SFrameAes256Enabled: Bool = true

    /// Capabilities advertised by THIS build of the iOS client.
    ///
    /// NOTE: `vkeyV1` is advertised by default but may be stripped at
    /// send time by the sovereign-only policy (see
    /// `CallsGate.sovereignOnlyEnabled`), enforced at the app layer when
    /// it builds the outgoing `capabilities` array.
    /// `earbudRelayV1` is deliberately ABSENT — detection-only on iOS.
    /// `sframeAes256V1` is included only when `v4SFrameAes256Enabled` is `true`.
    public static let local: [String] = {
        var caps: [String] = [sframeV1, ratchetV3, vkeyV1]
        if v4SFrameAes256Enabled { caps.append(sframeAes256V1) }
        return caps
    }()

    /// #2a gate (Android parity): did the PEER advertise
    /// ``earbudRelayV1`` in its RAW call-setup capability list,
    /// regardless of local caps? Pre-intersection check — the agreed set
    /// (`local ∩ peer`) can never contain the tag because iOS does not
    /// advertise it. Legacy/empty/nil peer → false (safe).
    public static func peerAdvertisedEarbudRelay(_ peer: [String]?) -> Bool {
        guard let peer = peer else { return false }
        return peer.contains(earbudRelayV1)
    }

    /// Outcome of a capability negotiation between local and peer.
    public struct Negotiated: Equatable, Sendable {
        /// True iff both sides advertise ``sframeV1``.
        public let useSFrame: Bool
        /// The intersection of advertised tags (sorted, deduped).
        public let agreedTags: [String]

        public init(useSFrame: Bool, agreedTags: [String]) {
            self.useSFrame = useSFrame
            self.agreedTags = agreedTags
        }

        /// True iff both sides advertise ``ratchetV3``. Derived from
        /// ``agreedTags`` — no wire or init change.
        public var useRatchetV3: Bool { agreedTags.contains(CallCapabilities.ratchetV3) }

        /// True iff both sides advertise ``vkeyV1``. When `true` the video
        /// FrameCryptor must be keyed off the dedicated K_video instead of
        /// the audio/control PQC session key. Derived from ``agreedTags``
        /// — no wire or init change.
        public var useVideoKey: Bool { agreedTags.contains(CallCapabilities.vkeyV1) }

        /// True iff BOTH peers advertised ``sframeAes256V1``. This is the
        /// Phase 2 gate for the AES-256-GCM FrameCryptor path.
        ///
        /// - `true`  → both sides run AES-256 LiveKit FrameCryptor.
        /// - `false` → either side is on AES-128; when ``v4SFrameAes256Enabled``
        ///             is `true` (this build IS AES-256) the video track is
        ///             disabled fail-closed inside ``QAudionPeerConnection``
        ///             rather than silently sending incompatible ciphertext.
        ///
        /// Derived from ``agreedTags`` — no wire or init change.
        public var useSFrameAes256: Bool { agreedTags.contains(CallCapabilities.sframeAes256V1) }
    }

    /// Compute the agreed capability set from the local list and the peer
    /// list. A `nil` peer list (decoded from a legacy client without the
    /// field, or from any older platform build) is treated as the empty
    /// list.
    ///
    /// Pure function — safe to call from any thread, no side effects.
    /// Returns by value (no preconditions / no traps) so XCTest can drive
    /// every edge case without crashing the test runner.
    public static func negotiate(
        local: [String] = local,
        peer: [String]?
    ) -> Negotiated {
        let peerSet = Set(peer ?? [])
        // De-duplicate while preserving the *local* declaration order, then
        // sort — matches Kotlin `local.filter { it in peerSet }.distinct().sorted()`
        // byte-for-byte for any possible input set.
        var seen = Set<String>()
        var intersection: [String] = []
        for tag in local where peerSet.contains(tag) && !seen.contains(tag) {
            seen.insert(tag)
            intersection.append(tag)
        }
        intersection.sort()
        return Negotiated(
            useSFrame: intersection.contains(sframeV1),
            agreedTags: intersection
        )
    }
}
