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

    /// `call_upgrade_intent` receive-support tag (2026-07-07 cross-platform
    /// matrix audit — GAP-1/GAP-2). Mirrors Android `UPGRADE_INTENT_RECV_V1`
    /// / Desktop `CAP_UPGRADE_INTENT_RECV_V1`. iOS handles incoming
    /// `call_upgrade_intent` (see `BCryptoWebSocketClient.onCallUpgradeIntent`
    /// / `AppState.handleIncomingUpgradeIntent`) — this tag lets a peer
    /// (Desktop) know it's safe to send one instead of falling back to a
    /// direct `call_upgrade_request` real-offer.
    public static let upgradeIntentRecvV1: String = "upgrade-intent-recv-v1"

    // ── W-LONGAUDIO (2026-08-10): the negotiated 60 ms / 256-byte profile ──
    //
    // Two tags, byte-exact, identical on Android, iOS, Desktop. They are
    // compared as plain strings by every platform, so a rename, a re-case or a
    // platform prefix is a silent interop break — copy them, never retype them.

    /// `aprof-60x256-recv-v1` — RECEIVE support.
    ///
    /// Means exactly: this endpoint can decrypt a sealed frame whose plaintext
    /// block is 256 bytes, decode the 60 ms Opus payload inside it at full
    /// length, and play it at the correct rate. It says NOTHING about what this
    /// endpoint sends.
    ///
    /// Advertised from the receive-support release onward and never withdrawn —
    /// with one exception, the earbud gate in ``localCaps(earbudActive:sovereignOnly:earbudPaired:)``.
    public static let aprof60x256RecvV1: String = "aprof-60x256-recv-v1"

    /// `aprof-60x256-v1` — SEND support: "I will use this profile".
    ///
    /// Means exactly ONE tuple and never anything else: 60 ms Opus frames, a
    /// 256-byte plaintext block, 32 kbps CBR, VBR off, DTX off, one frame per
    /// packet. Any future profile is a NEW string; reinterpreting this one is
    /// forbidden, because the two ends of a live call would then disagree about
    /// what they had agreed to.
    public static let aprof60x256V1: String = "aprof-60x256-v1"

    /// Kill switch for ADVERTISING receive support.
    ///
    /// Not part of the cross-platform contract — an iOS-local gate that makes
    /// the rollout ordering enforceable in code instead of by memory. The
    /// contract's own rule is that a platform must not advertise
    /// ``aprof60x256RecvV1`` until its receive path has shipped AND been
    /// confirmed in the field, because advertising receive support you do not
    /// have is the one way this design hurts a real user: the peer starts
    /// sending 60 ms frames and there is no negotiation left to fall back to.
    ///
    /// The receive path landed in the same change as this flag and has NOT been
    /// exercised on a device or against another platform, so it ships `false`.
    /// Flip it — alone, with the send switch still `false` — once a 60 ms frame
    /// has been decoded end to end on iOS hardware.
    public static let longAudioRecvAdvertiseEnabled: Bool = false

    /// Kill switch for SENDING the long profile, and for advertising
    /// ``aprof60x256V1``. Ships `false` on every platform.
    ///
    /// Compile-time by design: there is no runtime toggle, no remote config and
    /// no debug-menu entry that reaches a user build, because a profile that can
    /// change is a profile that can change MID-CALL, and the constant-rate
    /// property is only provable if the block is latched once and terminal.
    ///
    /// Rollback is this flag going back to `false`: the tag leaves the next
    /// call's advertisement, the peer's intersection empties at the same
    /// instant, and calls already in progress are untouched because the latch is
    /// per-call. There is no half-rolled-back state and nothing to coordinate
    /// with the peer.
    ///
    /// Mirrors `LONG_AUDIO_SEND_ENABLED` in Android `CallCapabilities.kt` and
    /// Desktop `CallCapabilities.ts`.
    public static let longAudioSendEnabled: Bool = false

    // MARK: - Binary WS relay framing (hop-by-hop, NOT a peer capability)

    /// Kill switch for ASKING the server to speak binary on our socket, i.e.
    /// for putting `bin_relay: 1` in the `authenticate` frame.
    ///
    /// Deliberately NOT a capability tag, and deliberately not in ``local``:
    /// the binary relay framing is a property of ONE WebSocket connection
    /// between this device and one server node. It is hop-by-hop. The
    /// capability array is end-to-end and the server's blindness to it is
    /// pinned by a server-side test — putting framing in there would make the
    /// server read an array it must not read, and would key the wire form by
    /// user or by call instead of by socket, which is exactly how a second
    /// device of the same user (a watch, with no binary receive arm at all)
    /// goes mute with no error anywhere.
    ///
    /// Gating the ASK separately from the SEND is what makes the rollout
    /// ordering enforceable in code rather than by memory: the receive-side
    /// release turns this on alone, so the client can *receive* binary while
    /// still *sending* text. That direction is asymmetric-safe — it costs
    /// nothing and breaks nothing.
    ///
    /// Ships `false`. While it is `false` this build never sends the field, so
    /// the server never echoes it, ``BCryptoWebSocketClient`` can never latch a
    /// socket to binary, and every byte on the wire is identical to the build
    /// before this feature existed.
    public static let binRelayReceiveEnabled: Bool = false

    /// Kill switch for SENDING `audio_frame` in the binary form.
    ///
    /// Compile-time by design, for the same reason as
    /// ``longAudioSendEnabled``: there is no runtime toggle, no remote config
    /// and no debug-menu entry that reaches a user build, because a wire form
    /// that can change is a wire form that can change MID-CALL, and the
    /// constant-rate property is only provable if it is latched once per call
    /// and terminal.
    ///
    /// This flag being `true` is NEVER sufficient on its own. A frame goes out
    /// binary only when the socket carrying it received `bin_relay: 1` in its
    /// own `authenticated` payload — no build flag alone, no server version
    /// sniff, no cached value from a previous socket, no inference from a peer.
    ///
    /// Mirrors `BIN_RELAY_SEND_ENABLED` in Android `CallCapabilities.kt` and
    /// Desktop `CallCapabilities.ts`.
    public static let binRelaySendEnabled: Bool = false

    /// Capabilities advertised by THIS build of the iOS client.
    ///
    /// NOTE: `vkeyV1` is advertised by default but may be stripped at
    /// send time by the sovereign-only policy (see
    /// `CallsGate.sovereignOnlyEnabled`), enforced at the app layer when
    /// it builds the outgoing `capabilities` array.
    /// `earbudRelayV1` is deliberately ABSENT — detection-only on iOS.
    /// `sframeAes256V1` is included only when `v4SFrameAes256Enabled` is `true`.
    /// **This is an INTERNAL base list, not something to put on the wire.**
    /// Every outgoing `capabilities` array must come from
    /// ``localCaps(earbudActive:sovereignOnly:earbudPaired:)``, which applies
    /// the gates. Sending this raw bypasses the earbud filter — see that
    /// method's notes for what that costs.
    public static let local: [String] = {
        var caps: [String] = [sframeV1, ratchetV3, vkeyV1, upgradeIntentRecvV1]
        if v4SFrameAes256Enabled { caps.append(sframeAes256V1) }
        // W-LONGAUDIO — receive support, then send support. Both gated; both
        // ship absent. See the two kill switches above for why the RECEIVE one
        // is gated too, which is an iOS-local addition to the contract.
        if longAudioRecvAdvertiseEnabled { caps.append(aprof60x256RecvV1) }
        if longAudioSendEnabled { caps.append(aprof60x256V1) }
        return caps
    }()

    /// The capability list to actually ADVERTISE, with every gate applied.
    ///
    /// W-LONGAUDIO (2026-08-10) — every advertisement site goes through here.
    /// The reason is the earbud gate below, and the reason THAT is not optional
    /// is that on an earbud call the phone is a zero-knowledge relay: it forwards
    /// the sealed frame without ever opening it. The thing that decodes the audio
    /// is the earbud firmware, which has a 960-sample decode buffer and a speaker
    /// path that truncates at 960, and cannot do 60 ms at all — the nRF54LM20B
    /// has 2716 bytes of RAM free against the 5760 a 60 ms accumulator needs.
    /// Advertising receive support on its behalf invites the peer to send frames
    /// that arrive as silence, reported nowhere.
    ///
    /// So BOTH tags are withheld, including the receive one, and the gate keys on
    /// PAIRED rather than ACTIVE: an earbud adopted after the advertisement went
    /// out would turn a statement that was true when we made it into a lie, and
    /// the peer has already latched by then.
    ///
    /// - Parameters:
    ///   - earbudActive: the bonded earbud is the active media path. Appends
    ///     `earbud-relay-v1` on platforms that relay; iOS never does (it only
    ///     DETECTS the peer's tag), so this defaults to `false` here.
    ///   - sovereignOnly: strip `vkey-v1` (phone-level video key refused).
    ///   - earbudPaired: a sovereign earbud is bonded for this call. Defaults to
    ///     `earbudActive`, matching Android.
    public static func localCaps(earbudActive: Bool = false,
                                 sovereignOnly: Bool = false,
                                 earbudPaired: Bool? = nil) -> [String] {
        applyAdvertisementGates(to: local,
                                earbudActive: earbudActive,
                                sovereignOnly: sovereignOnly,
                                earbudPaired: earbudPaired)
    }

    /// The gates, as a pure function of an arbitrary base list.
    ///
    /// Split out from ``localCaps(earbudActive:sovereignOnly:earbudPaired:)`` so
    /// the gate logic is testable on its own. Without this, every earbud test
    /// would pass vacuously in a shipped build: both audio tags are absent from
    /// ``local`` while the kill switches are `false`, so "the earbud filter
    /// removed them" and "they were never there" are indistinguishable — and the
    /// filter would be untested precisely until the release that starts relying
    /// on it.
    static func applyAdvertisementGates(to base: [String],
                                        earbudActive: Bool = false,
                                        sovereignOnly: Bool = false,
                                        earbudPaired: Bool? = nil) -> [String] {
        let paired = earbudPaired ?? earbudActive
        var caps = sovereignOnly ? base.filter { $0 != vkeyV1 } : base
        if paired {
            caps = caps.filter { $0 != aprof60x256V1 && $0 != aprof60x256RecvV1 }
        }
        return earbudActive ? caps + [earbudRelayV1] : caps
    }

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

        /// W-LONGAUDIO (2026-08-10) — the peer's RAW advertised list, exactly as
        /// it arrived, before intersection.
        ///
        /// Additive: no wire change, no new field on any message, and the
        /// default keeps every existing construction site compiling. It exists
        /// because an intersection cannot answer "did the peer say it can
        /// RECEIVE this?" — the receive tag is in the intersection only when WE
        /// advertise it too, and the two questions have to stay separable for
        /// the send gate to mean what it says.
        public let peerRawTags: [String]

        public init(useSFrame: Bool, agreedTags: [String], peerRawTags: [String] = []) {
            self.useSFrame = useSFrame
            self.agreedTags = agreedTags
            self.peerRawTags = peerRawTags
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

        /// W-LONGAUDIO — did the peer advertise that it can RECEIVE the long
        /// profile? Read from ``peerRawTags``, not from the intersection.
        public var peerAcceptsLongAudio: Bool {
            peerRawTags.contains(CallCapabilities.aprof60x256RecvV1)
        }

        /// W-LONGAUDIO — did BOTH sides advertise SEND support? Read from the
        /// intersection, which is what makes activation symmetric: both ends
        /// compute the same set from the same two lists, so either both send
        /// long or neither does.
        public var bothAdvertiseLongAudioSend: Bool {
            agreedTags.contains(CallCapabilities.aprof60x256V1)
        }
    }

    /// W-LONGAUDIO (2026-08-10) — the audio profile to SEND on this call.
    ///
    /// The normative rule, and the only place it is written down on iOS. Returns
    /// ``AudioProfile/long60x256`` if and only if ALL of the following hold:
    ///
    ///   1. ``longAudioSendEnabled`` is `true`;
    ///   2. a negotiation result exists for this call;
    ///   3. `aprof-60x256-v1` is in the intersection — i.e. BOTH ends advertised
    ///      send support, which is what makes the decision symmetric;
    ///   4. `aprof-60x256-recv-v1` is in the peer's RAW list — it can actually
    ///      decode what clause 3 permits us to send;
    ///   5. no sovereign earbud is in this call.
    ///
    /// Anything else — a missing field, a `nil` peer list, a malformed entry, an
    /// unparsed event, a lost race, the kill switch, an earbud — is
    /// ``AudioProfile/standard``, silently and completely. There is no partial
    /// state and no retry: if the negotiation result has not arrived by the time
    /// this is called, the call runs STANDARD for its whole life, and that is
    /// correct behaviour rather than a bug to paper over.
    ///
    /// RECEIVE has no equivalent and needs none: every endpoint decodes whatever
    /// arrives, regardless of what it latched, forever.
    ///
    /// - Parameters:
    ///   - negotiated: this call's negotiation result, or `nil` if the peer has
    ///     not been heard from.
    ///   - earbudInCall: a sovereign earbud is party to this call. On iOS this
    ///     is the PEER's `earbud-relay-v1` (there is no iOS earbud transport):
    ///     that peer's phone is relaying to firmware that cannot do 60 ms. Its
    ///     own gate already withholds both tags, so clause 3 would fail anyway —
    ///     this is the second, independent check, and it can only ever push the
    ///     answer toward STANDARD.
    public static func resolveAudioProfile(
        negotiated: Negotiated?,
        earbudInCall: Bool
    ) -> AudioProfile {
        guard longAudioSendEnabled else { return .standard }
        guard !earbudInCall else { return .standard }
        guard let negotiated else { return .standard }
        guard negotiated.bothAdvertiseLongAudioSend else { return .standard }
        guard negotiated.peerAcceptsLongAudio else { return .standard }
        return .long60x256
    }

    /// W-LONGAUDIO (2026-08-10) — §1.6 clause 2, "a negotiation result exists
    /// for THIS call", as a pure function.
    ///
    /// The peer's advertised list is captured by a signalling handler and read
    /// later by the audio-profile latch. Between those two moments a whole call
    /// can end and another can start, so the list has to carry the id of the
    /// call it arrived for and the latch has to refuse it otherwise. Without
    /// this the latch enforces "a negotiation result exists for SOME call",
    /// which is how a peer we spoke to five minutes ago can decide the wire
    /// format of a call to somebody else.
    ///
    /// Returns `capturedList` only when both ids are present and equal; `nil`
    /// in every other case, which negotiates to an empty intersection and
    /// therefore resolves to ``AudioProfile/standard``. "Not captured yet" is
    /// deliberately indistinguishable from "captured for another call": both
    /// mean we cannot prove ownership, and the answer to that is STANDARD, not
    /// a wait or a retry.
    ///
    /// Compared case-insensitively: outgoing ids are lowercase UUIDs minted
    /// locally and incoming ones are whatever string the server sent. Folding
    /// case can only ever make a match of the SAME call more likely — two
    /// different calls carry different UUIDs, so it cannot create a match
    /// across calls.
    ///
    /// - Parameters:
    ///   - wantedCallId: the wire call id the caller is latching for.
    ///   - capturedCallId: the wire call id the list was captured for.
    ///   - capturedList: the peer's raw advertised list, as captured.
    public static func peerCapabilities(
        forCallId wantedCallId: String?,
        capturedForCallId capturedCallId: String?,
        capturedList: [String]?
    ) -> [String]? {
        guard let wanted = wantedCallId, !wanted.isEmpty,
              let captured = capturedCallId, !captured.isEmpty,
              captured.caseInsensitiveCompare(wanted) == .orderedSame
        else { return nil }
        return capturedList
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
            agreedTags: intersection,
            // W-LONGAUDIO — carry the peer's raw list through untouched. It is
            // already `[String]` here: a malformed JSON array such as
            // `[42, null]` never reaches this function, because the decode site
            // casts to `[String]?` and a mixed array fails that cast whole,
            // yielding nil — which is the legacy-peer case and therefore
            // STANDARD. That is the desired outcome; this note exists so nobody
            // "fixes" the cast into an element-wise one that would let a
            // half-parsed array through.
            peerRawTags: peer ?? []
        )
    }
}
