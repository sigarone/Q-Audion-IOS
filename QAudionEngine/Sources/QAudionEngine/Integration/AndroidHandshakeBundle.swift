import Foundation

/// Android-compatible JSON HandshakeBundle parser + emitter.
///
/// ## Why this exists
///
/// Android's `apps/qaudion-android-new/feature/feature-call/src/main/java/com/bcrypto/qaudion/
/// feature/call/domain/PqcHandshake.kt` and Desktop's
/// `apps/qaudion-desktop/src/main/calling/CallController.ts:handleAndroidBundle`
/// speak a JSON wire format for the per-call PQC handshake that iOS's
/// `QAudionCapabilityExchange` (QUAD binary) cannot consume.
///
/// On the wire the JSON HandshakeBundle is wrapped in a literal UTF-8
/// string of the form `"<callId>|<json>"` placed verbatim in the
/// `data` field of an `opaque_message` (NOT base64 encoded). The
/// JSON shape carries SPLIT public keys (`pqcPublicKey` +
/// `x25519PublicKey` + optional `dualCurvePublicKey`) instead of the
/// QUAD's single combined `kemPublicKey` field.
///
/// Without an iOS parser for this format, every Android↔iOS call
/// fails: the iOS responder cannot read the inbound OFFER and never
/// emits ACCEPT, the Android initiator hits its 35 s
/// `HANDSHAKE_TIMEOUT` and the user sees nothing happen.
///
/// ## Wire format (must match Android byte-for-byte)
///
/// ```
/// data field of opaque_message  =  "<callId>|<JSON>"
/// ```
///
/// JSON keys (alphabetical):
/// - `callId`: String, the WS callId.
/// - `capabilities`: { `ratchetV3`: Bool? }
/// - `ciphertext`: { `pqc`: B64, `x25519`: B64, `strongBox`: B64?, `dualCurve`: B64? }  — ACCEPT only
/// - `dualCurvePublicKey`: B64 X448 pub  — OPTIONAL, OFFER only
/// - `kind`: "OFFER" | "ACCEPT"
/// - `pqcPublicKey`: B64 ML-KEM-1024 pub (1568 bytes raw) — OFFER only
/// - `pskFingerprints`: [String]?  — OFFER and ACCEPT (W-NFCCOMMON, 2026-07-24: the
///   ACCEPT side is what the OFFER-side's mutual-NFC-in-common signal reads), full
///   SHA-256 hex (64 chars)
/// - `selectedPskFingerprint`: String?  — ACCEPT only
/// - `sigV2`: String?  — W-TRANSCRIPTV2 (ship step 4), b64 Ed25519 sig over transcript v2
/// - `strongBoxPublicKey`: B64?  — OFFER only, Android StrongBox-bound P-256
/// - `x25519PublicKey`: B64 X25519 pub (32 bytes raw) — OFFER only
///
/// The OFFER omits `ciphertext` and the ACCEPT omits the public-key
/// fields. The Codable model below makes every "this-side-only" field
/// optional and validates per-kind at parse time.
///
/// See WIRE_SPEC.md §3.1 for the canonical contract.
public struct AndroidHandshakeBundle: Codable, Equatable {

    public enum Kind: String, Codable {
        case offer = "OFFER"
        case accept = "ACCEPT"
    }

    public struct Capabilities: Codable, Equatable {
        public let ratchetV3: Bool?
        // Phase-10b handshake-signing (§5b / §6 of HANDSHAKE-SIGNING-SPEC.md): the signed
        // CAPS byte triplet is `ratchetV3,sframeV1,vkeyV1`. iOS previously modelled only
        // `ratchetV3`; the verifier MUST reconstruct CAPS from the SAME received bundle the
        // signer encoded, so all three are needed. Both new fields are OPTIONAL → an inbound
        // bundle that omits them decodes fine (absent → nil → CAPS byte 0, matching Android's
        // "absent OR null capabilities → 0" rule), and JSONEncoder omits nil so the existing
        // wire bytes for legacy peers are unchanged.
        public let sframeV1: Bool?
        public let vkeyV1: Bool?

        // KMS-rotation-v2 Phase-1 (D6) — schema:3 session-KDF capability. OPTIONAL
        // → absent (nil) decodes fine and JSONEncoder omits it, so a legacy bundle
        // is byte-wire-identical. A peer that sets this true is treated as
        // v3-capable; both legs must set it (else mixed-fleet falls back to v2).
        public let sessionKdfV3: Bool?

        // Phase 18 / WIRE-FORMAT §4 — whether this peer supports the v4 PQ Double
        // Ratchet messaging wire format (magic=0xE5, ML-KEM-768 ⊕ X25519 X-Wing
        // advance braid, Model A bootstrap). Negotiated as the AND of both peers'
        // advertisements (see ``negotiate(self:peer:)`` on Android / the iOS
        // equivalent): BOTH must advertise `true` for the dispatcher to switch to
        // the v4 engine; otherwise the pair stays on v3 (0xE3) or v2.
        //
        // OPTIONAL, appended LAST, default-omitted: a peer that doesn't carry the
        // field decodes to nil → treated as `false` (conservative fallback), and
        // `JSONEncoder` omits a nil key, so the OFFER/ACCEPT bytes stay
        // byte-IDENTICAL to the pre-Phase-18 wire for any peer not yet advertising
        // v4. iOS only advertises this `true` once ``MessageRatchet/v4NativeRatchetEnabled``
        // is set AND the real native core is linked (``RatchetNative/available``) —
        // matching Android's `@EncodeDefault(NEVER) ratchetV4` field exactly. The
        // key appears on the wire ONLY at the coordinated cross-platform go-live.
        //
        // NOTE (iOS deviation, intentional): Android omits the field via
        // `@EncodeDefault(NEVER)` even at its `false` default. On iOS the same
        // "omit when not advertising" behaviour falls out naturally because the
        // field is `Bool?` and `JSONEncoder` skips `nil` — so the SENDER must pass
        // `nil` (not `false`) for a non-v4 build. Use the convenience initializer
        // default (`ratchetV4: nil`) for that; pass `true` only when live.
        public let ratchetV4: Bool?
        /// W574x — whether this peer derives DIRECTIONAL per-direction PQC RTP
        /// sealer keys (fixes the bidirectional AES-GCM nonce reuse on the relay
        /// path). Additive + omit-when-false (Codable nil → key absent), so old
        /// peers stay byte-compatible. Both peers must advertise `true` for the
        /// pair to use directional sealer keys. XC-4: this bit is now SIGNED as
        /// the 6th CAPS byte of the handshake transcript (absent/nil → 0x00), so a
        /// relay can no longer strip it to force the nonce-reusing single-key
        /// sealer without breaking the signature.
        public let srtpDirKeyV1: Bool?

        // PSK-mix ship-step-2 (parse-only) — capability bit for a future PSK
        // mixing negotiation (multiple PSK candidates, including NFC-derived
        // ones, folded into the session key). OPTIONAL, appended LAST, same
        // "omit when not advertising" convention as `ratchetV4`/`srtpDirKeyV1`
        // above: a peer that doesn't carry the field decodes to nil (treated
        // as `false`), and `JSONEncoder` omits a nil key, so the OFFER/ACCEPT
        // bytes stay byte-IDENTICAL to today's wire for every peer — nobody
        // sets this `true` yet; that's a later ship step. Mirrors Android's
        // `@EncodeDefault(NEVER) pskMixV1` field exactly.
        public let pskMixV1: Bool?

        // CALL-3/CALL-4 (HSID-002 remainder, 2026-09-02 protocol audit) —
        // capability bit for the combined transcript-bound session-key
        // KDF/SAS fix (CALL-4) and the signed re-key round-freshness fix
        // (CALL-3): both new signed transcript fields (`domainV3` — see
        // `HandshakeTranscript.offerV3`/`acceptV3`) are computed/verified
        // ONLY when both peers advertise this bit. OPTIONAL, appended LAST,
        // same "omit when not advertising" convention as `pskMixV1`/
        // `ratchetV4`/`srtpDirKeyV1` above: a peer that doesn't carry the
        // field decodes to nil (treated as `false`), and `JSONEncoder` omits
        // a nil key, so the OFFER/ACCEPT bytes stay byte-IDENTICAL to today's
        // wire for every peer that has not shipped this fix.
        public let transcriptBindV1: Bool?

        // MEDIA-3/MEDIA-4/MEDIA-5 (2026-09-02 protocol audit, backlog item 4)
        // — capability bit for the inner sealed-audio wire's per-direction
        // keys + AAD + replay window (see `QAudionEngine.initSession`'s
        // `innerAudioAadV1` param and `QAudionCallIntegration
        // .innerAudioAadV1Enabled`). OPTIONAL, appended LAST, same "omit
        // when not advertising" convention as `pskMixV1`/`transcriptBindV1`
        // above: a peer that doesn't carry the field decodes to nil (treated
        // as `false`), and `JSONEncoder` omits a nil key, so the OFFER/ACCEPT
        // bytes stay byte-IDENTICAL to today's wire until this ships on
        // every platform and the kill switch flips on. NOT bound into the
        // signed transcript CAPS tuple (like `pskMixV1`) — only gates local
        // behaviour, never authenticated.
        public let innerAudioAadV1: Bool?

        public init(
            ratchetV3: Bool?,
            sframeV1: Bool? = nil,
            vkeyV1: Bool? = nil,
            sessionKdfV3: Bool? = nil,
            ratchetV4: Bool? = nil,
            srtpDirKeyV1: Bool? = nil,
            pskMixV1: Bool? = nil,
            transcriptBindV1: Bool? = nil,
            innerAudioAadV1: Bool? = nil
        ) {
            self.ratchetV3 = ratchetV3
            self.sframeV1 = sframeV1
            self.vkeyV1 = vkeyV1
            self.sessionKdfV3 = sessionKdfV3
            self.ratchetV4 = ratchetV4
            self.srtpDirKeyV1 = srtpDirKeyV1
            self.pskMixV1 = pskMixV1
            self.transcriptBindV1 = transcriptBindV1
            self.innerAudioAadV1 = innerAudioAadV1
        }
    }

    public struct Ciphertext: Codable, Equatable {
        public let pqc: String        // base64 ML-KEM ciphertext
        public let x25519: String     // base64 ephemeral X25519 pub
        public let strongBox: String?
        public let dualCurve: String?

        public init(pqc: String, x25519: String, strongBox: String? = nil, dualCurve: String? = nil) {
            self.pqc = pqc
            self.x25519 = x25519
            self.strongBox = strongBox
            self.dualCurve = dualCurve
        }
    }

    public let kind: Kind
    public let callId: String

    // OFFER-required, ACCEPT-empty-string fields.
    //
    // W527 correction to the original W?-era comment: Android's
    // kotlinx.serialization HandshakeBundle data class declares these
    // as non-nullable `String` with NO default value — kotlinx-
    // serialization treats them as REQUIRED at parse time and throws
    // `MissingFieldException` if they're absent from the JSON.
    // Android's own ACCEPT-side construction sets them to `""`
    // (see PqcHandshake.kt, the `respond` path). iOS callers MUST
    // emit `""` (not nil) for ACCEPT bundles so the JSON contains
    // the keys with empty-string values. They remain Optional here
    // only so iOS can still decode legacy-format inbound OFFERs
    // that omitted the fields entirely.
    public let pqcPublicKey: String?
    public let x25519PublicKey: String?
    public let strongBoxPublicKey: String?
    public let dualCurvePublicKey: String?

    public let ciphertext: Ciphertext?
    public let capabilities: Capabilities?
    public let pskFingerprints: [String]?
    public let selectedPskFingerprint: String?

    // PSK-mix ship-step-2 — parallel array to `pskFingerprints`, same
    // length/order: per-candidate key class, 0 = ordinary PSK, 1 =
    // NFC-derived, 2 = QR-scan-derived. Absent/nil ⇒ treat as all-zero
    // (ordinary). Populated on BOTH OFFER and ACCEPT (W-NFCVISIBLE go-live +
    // W-NFCCOMMON, 2026-07-24 — the ACCEPT side was a real gap: an ACCEPT
    // that omits it makes the OFFER-side's mutual-NFC-in-common signal go
    // permanently false whenever iOS answers, even when the NFC secret is
    // genuinely held by both sides). OPTIONAL, JSONEncoder omits nil, so a
    // legacy peer's bundle stays byte-wire-identical.
    public let pskRoles: [Int]?

    // Phase-10b handshake signing (§1 of HANDSHAKE-SIGNING-SPEC.md) — TWO OPTIONAL fields,
    // appended LAST to mirror Android's additive `HandshakeBundleCodec` change. Both default
    // to nil; `JSONEncoder` omits nil keys, so a bundle that doesn't carry them is byte-wire-
    // identical to the legacy unsigned bundle (no break for already-deployed peers).
    //
    // The signature is computed over the explicit §3 length-prefixed `HandshakeTranscript`
    // (NOT this JSON), so JSON canonicalization is irrelevant to cross-platform parity.
    public let signerIdentityKey: String?   // base64 (no-wrap, padded) of the 32-byte Ed25519 long-term identity pubkey
    public let signature: String?           // base64 (no-wrap, padded) of the 64-byte Ed25519 detached signature

    // W-TRANSCRIPTV2 (multi-PSK-mixing SYNTHESIS.md ship step 4) — dual-signed transcript
    // rollout. base64 (no-wrap, padded) of the 64-byte Ed25519 detached signature over
    // `HandshakeTranscript`'s NEW v2 transcript (`offerV2`/`acceptV2`), computed by the SAME
    // signer alongside (never instead of) `signature`. `nil` on legacy builds (pre-this-step)
    // and on the unsigned path — verification prefers `sigV2` when present and falls back to
    // verifying `signature` against the v1 transcript exactly as before when absent, so a
    // peer that hasn't shipped this step yet is never rejected. APPENDED LAST so existing
    // peers' wire bytes are unchanged (`JSONEncoder` omits nil keys via `encodeIfPresent`),
    // same convention as `signerIdentityKey`/`signature`/`pskRoles` above. Mirrors Android
    // `HandshakeBundleCodec.HandshakeBundle.sigV2` (commit d3244418) / Desktop
    // `AndroidOfferBundle.sigV2`/`AndroidAcceptBundle.sigV2` (commit c6bf155).
    public let sigV2: String?

    // CALL-3/CALL-4 (HSID-002 remainder, 2026-09-02 protocol audit) — v3
    // dual-signature rollout, mirroring `sigV2`'s own additive introduction.
    // base64 (no-wrap, padded) of the 64-byte Ed25519 detached signature over
    // `HandshakeTranscript`'s NEW v3 transcript (`offerV3`/`acceptV3`),
    // computed by the SAME signer ALONGSIDE (never instead of) `signature`
    // and `sigV2`. `nil` on any build that hasn't shipped this fix and on the
    // unsigned path — verification only attempts v3 when this AND
    // `capabilities.transcriptBindV1` are both present; a peer that hasn't
    // shipped it is verified exactly as before (v2-then-v1), never rejected.
    // APPENDED LAST so existing peers' wire bytes are unchanged.
    public let sigV3: String?

    /// CALL-3 — the call's own random 64-bit freshness nonce (raw 8 bytes,
    /// base64 no-wrap/padded), present ONLY on round 1's OFFER (the call's
    /// first handshake) — `nil` on every re-key round's OFFER and on every
    /// ACCEPT (the nonce is never retransmitted once established). OPTIONAL,
    /// JSONEncoder omits nil, so a bundle that doesn't carry it is
    /// byte-wire-identical to a peer that hasn't shipped this fix.
    public let rekeyNonce: String?

    /// CALL-3 — this bundle's 1-based re-key round ordinal (1 = the call's
    /// first handshake, 2.. = re-key rounds), present on EVERY OFFER and
    /// ACCEPT once this fix is live for the pair (mirrors `sigV3`'s presence
    /// exactly — both are set together or both stay nil). `nil` on any build
    /// that hasn't shipped this fix.
    public let rekeyRound: Int?

    public init(
        kind: Kind,
        callId: String,
        pqcPublicKey: String? = nil,
        x25519PublicKey: String? = nil,
        strongBoxPublicKey: String? = nil,
        dualCurvePublicKey: String? = nil,
        ciphertext: Ciphertext? = nil,
        capabilities: Capabilities? = nil,
        pskFingerprints: [String]? = nil,
        selectedPskFingerprint: String? = nil,
        pskRoles: [Int]? = nil,
        signerIdentityKey: String? = nil,
        signature: String? = nil,
        sigV2: String? = nil,
        sigV3: String? = nil,
        rekeyNonce: String? = nil,
        rekeyRound: Int? = nil
    ) {
        self.kind = kind
        self.callId = callId
        self.pqcPublicKey = pqcPublicKey
        self.x25519PublicKey = x25519PublicKey
        self.strongBoxPublicKey = strongBoxPublicKey
        self.dualCurvePublicKey = dualCurvePublicKey
        self.ciphertext = ciphertext
        self.capabilities = capabilities
        self.pskFingerprints = pskFingerprints
        self.selectedPskFingerprint = selectedPskFingerprint
        self.pskRoles = pskRoles
        self.signerIdentityKey = signerIdentityKey
        self.signature = signature
        self.sigV2 = sigV2
        self.sigV3 = sigV3
        self.rekeyNonce = rekeyNonce
        self.rekeyRound = rekeyRound
    }
}

/// Envelope helpers for the `"<callId>|<JSON>"` wire wrapping.
public enum AndroidHandshakeEnvelope {

    public struct Parsed: Equatable {
        public let callId: String
        public let bundle: AndroidHandshakeBundle
    }

    /// Parse `"<callId>|<JSON HandshakeBundle>"`.
    /// Returns nil for any shape that is not a valid Android envelope —
    /// callers can then fall through to other parsers (e.g. QUAD, hangup
    /// piggy-back, video CAPS announce) without throwing.
    public static func parse(_ raw: String) -> Parsed? {
        guard let pipeIdx = raw.firstIndex(of: "|") else { return nil }
        let callId = String(raw[raw.startIndex ..< pipeIdx])
        let payload = String(raw[raw.index(after: pipeIdx)...])
        guard !callId.isEmpty, payload.hasPrefix("{") else { return nil }
        guard let bundleData = payload.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        guard let bundle = try? decoder.decode(AndroidHandshakeBundle.self, from: bundleData) else {
            return nil
        }
        // Sanity: kind-specific field shape.
        switch bundle.kind {
        case .offer:
            guard let pqc = bundle.pqcPublicKey, !pqc.isEmpty,
                  let x25 = bundle.x25519PublicKey, !x25.isEmpty else { return nil }
        case .accept:
            guard bundle.ciphertext != nil else { return nil }
        }
        return Parsed(callId: callId, bundle: bundle)
    }

    /// Build the wire string `"<callId>|<JSON>"`.
    public static func serialize(callId: String, bundle: AndroidHandshakeBundle) -> String {
        let encoder = JSONEncoder()
        // Match Android's kotlinx.serialization defaults — alphabetical key
        // ordering is NOT guaranteed but parsers ignore order. We omit
        // null fields explicitly where Android does (encodeDefaults=false
        // for nullable Kotlin properties).
        encoder.outputFormatting = []
        let data = (try? encoder.encode(bundle)) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return "\(callId)|\(json)"
    }
}

/// Lightweight `<callId>|<TAG>:<value>` piggy-back framing shared with
/// Android (`AndroidBundleHandshake.kt`) and Desktop
/// (`apps/qaudion-desktop/src/main/calling/CallController.ts`).
///
/// These travel in the SAME `opaque_message.data` UTF-8 string slot as
/// the JSON HandshakeBundle but use a flat `KEY:value` payload after the
/// pipe instead of a JSON object. The pipe-prefixed callId lets the
/// receiver match against its current call before reacting.
///
/// Known tags (extend as needed — forward-compat: unknown tags fall
/// through to `nil` and the caller silently drops the envelope, exactly
/// like an unknown JSON shape):
///
///   - `SCREEN_SHARE:<state>` — peer announces start/stop of a screen
///     share on the existing video transceiver. `<state>` is
///     `start` / `on` / `true` (active) or `stop` / `off` / `false`
///     (inactive). Case-insensitive. See
///     `apps/qaudion-desktop/docs/SCREEN_SHARE_PROTOCOL.md`.
///   - `CAPS:<csv>` — peer capability announce (reserved, not consumed
///     by iOS yet — silently dropped).
///   - `HANGUP:<reason>` — peer hangup piggy-back. Consumed since
///     2026-08-25 (W-HANGUPECHO): an id-matched HANGUP runs the same
///     definitive teardown as the `call_hangup` WS envelope, and is
///     echoed to the server as `call_hangup {reason:"peer-acknowledged"}`
///     so its books close. Also EMITTED alongside every outbound
///     `call_hangup` envelope (hangup-opaque-piggyback — bcrypto-lite in
///     certain paths drops the envelope silently, the opaque survives).
///   - `PLP:<int percent>` — W-PLPFEEDBACK (2026-08-25): sender's periodic
///     measured inbound-audio loss, consumed to drive this receiver's own
///     TX encoder loss-hint via `PlpPolicy`.
///   - `KCMAC:<payload>` — PSK-mix ship-step-2: reserved for a future
///     key-confirmation MAC tied to PSK mixing. Recognised-and-ignored
///     for now (logged, then dropped) — no handler logic yet. The point
///     of recognising it HERE, before the JSON HandshakeBundle branch,
///     is that a `"KCMAC:..."` payload must never fall through to
///     `AndroidHandshakeEnvelope.parse` and corrupt/desync unrelated
///     handshake-bundle parsing for the call.
public enum CallPiggyBack: Equatable {

    /// `<callId>|SCREEN_SHARE:<state>` — peer toggled screen sharing.
    case screenShare(callId: String, active: Bool)

    /// `<callId>|CAPS:<csv>` — capability announce. Carried for
    /// completeness so the parser sink can log/ignore it instead of
    /// printing "unrecognised envelope".
    case caps(callId: String, raw: String)

    /// `<callId>|VOICE_KEY:<state>` — "voce come chiave" cross-device
    /// attestation: the peer announces whether Voice-as-Key is enrolled on
    /// THEIR OWN device (self-declared, never a crypto proof on its own —
    /// see `AppState.routeInboundCallPiggyBack`'s `.voiceKey` case and
    /// `AppState.announceVoiceKeyEnrollment`). Symmetric and role-agnostic:
    /// both the caller and the callee send their own announce and listen
    /// for the peer's. `<state>` is `1` / `true` / `on` → `enrolled=true`,
    /// anything else → `false`. Mirrors Android's
    /// `WsCallSignaller.VOICE_KEY_PAYLOAD_PREFIX` / `VoiceKeyAnnounce` byte
    /// for byte.
    case voiceKey(callId: String, enrolled: Bool)

    /// `<callId>|OWNER_CONT:<level>` — "voce storica" live cross-device
    /// signal (2026-08-01 3-tier voice-auth design). Piggy-backed like
    /// `.voiceKey`, but where that one is a static "did they enroll"
    /// boolean sent once, this one carries the SENDER's own
    /// `OwnerContinuityMonitor` tri-state (does the sender's live TX voice
    /// still match their own historical Voice-as-Key enrollment) and is
    /// only ever sent on a real state TRANSITION — never polled/periodic,
    /// so the wire cost is near zero for the overwhelming majority of
    /// calls where nobody ever hands off the phone. `level` is one of
    /// `unknown`/`verified`/`uncertain`/`mismatch` (lowercased) — anything
    /// unrecognized parses as `unknown`. Mirrors Android's
    /// `WsCallSignaller.OWNER_CONTINUITY_PAYLOAD_PREFIX`/
    /// `OwnerContinuityAnnounce` byte for byte.
    case ownerContinuity(callId: String, level: String)

    /// `<callId>|SPKCHG:<0|1>` — "interlocutore cambiato" live cross-device
    /// signal (2026-08-29). Carries the SENDER's own receive-side verdict
    /// that the voice it is hearing — which is THIS device's user — is no
    /// longer the voice the call started with. Sent only on a real
    /// transition of that verdict, like `.ownerContinuity` and for the same
    /// reason, so the wire cost is zero on the overwhelming majority of
    /// calls.
    ///
    /// It exists for the half of the scenario a receive-only design cannot
    /// see: the device whose user just handed their handset over hears no
    /// change, because the new voice is on its microphone rather than in its
    /// received audio, so without this message that user's screen would stay
    /// silent while the other side's lit up.
    ///
    /// The receiver treats it as an input to its display and never as proof
    /// — a claim from across the trust boundary can raise that side's state
    /// to "suspected" but never to "confirmed". `1`/`true`/`on` parse as
    /// true, anything else as false, so a malformed payload can only ever
    /// clear an alert rather than raise one. Mirrors Android's
    /// `WsCallSignaller.SPEAKER_CHANGE_PAYLOAD_PREFIX` /
    /// `SpeakerChangeAnnounce` byte for byte.
    case speakerChange(callId: String, changed: Bool)

    /// `<callId>|HANGUP:<reason>` — secondary hangup signal. Exists because
    /// bcrypto-lite in certain paths drops `call_hangup` envelopes silently
    /// while forwarding opaques — so this is NOT redundancy theatre: it is
    /// the channel that survives exactly when the envelope does not. The
    /// receiver treats an id-matched HANGUP as definitive teardown (same
    /// semantics as the envelope, W-CALLHANGUP-SEMANTICS id gate applied)
    /// and echoes `call_hangup {reason:"peer-acknowledged"}` to the server
    /// (W-HANGUPECHO). Byte-for-byte matches Android
    /// `WsCallSignaller.HANGUP_PAYLOAD_PREFIX` framing.
    case hangup(callId: String, reason: String)

    /// `<callId>|PLP:<int percent>` — W-PLPFEEDBACK (2026-08-25): the
    /// sender's periodic report of ITS OWN measured inbound-audio loss over
    /// the last window, 0-100. Consumed to drive the RECEIVER's own TX
    /// encoder's `OPUS_SET_PACKET_LOSS_PERC` knob (via `PlpPolicy`) so the
    /// FEC redundancy budget tracks what the peer is actually experiencing
    /// on this link, rather than a fixed provisioning constant. Mirrors
    /// Android's `WsCallSignaller.PLP_PAYLOAD_PREFIX` byte for byte.
    case plp(callId: String, percent: Int)

    /// `<callId>|EARBUDPDU:<base64>` — opaque earbud-firmware handshake
    /// PDU (earbud-relay-v1). The earbud-side phone relays HSRESP
    /// fragments from the firmware; iOS (always the SW counterparty)
    /// replies with HSINIT / HSFIN through the same framing. Bytes are
    /// opaque ciphertext fragments — decoded from base64 here, never
    /// parsed beyond `EarbudFwPduCodec`. Mirrors Android
    /// `WsCallSignaller.EARBUD_PDU_PAYLOAD_PREFIX`.
    case earbudPdu(callId: String, pdu: Data)

    /// `<callId>|EARBUDMKD:<base64>` — Phase 6 sealed PQ media key
    /// package (exactly 60 bytes: nonce[12] || AES-256-GCM[48]).
    case earbudMkd(callId: String, pkg: Data)

    /// `<callId>|FPSET:<base64(fp_adv[32])>` — Phase B fp_adv exchange.
    /// Both sides send their local fp_adv (from the earbud GATT c8 READ)
    /// so each can compute neg_digest = SHA-256(fpSetInit || fpSetResp).
    /// If no earbud: fp_adv = 32 zero bytes (keyClass falls back to 0).
    case fpSet(callId: String, fpAdv: Data)

    /// `<callId>|KCMAC:<payload>` — PSK-mix ship-step-2 reserved tag.
    /// Recognised so it is consumed HERE (never reaching the JSON
    /// HandshakeBundle decoder) but carries no logic yet beyond a log-
    /// and-drop; `raw` is the undecoded payload after the tag.
    case kcmac(callId: String, raw: String)

    /// `<callId>|VNACK:<frameId>:<idx1>,<idx2>,...` — W-VNACK (2026-08-16)
    /// fragment-level NACK/retransmission for the WS-relay video fallback.
    /// The receiver's reassembler asks the sender to resend specific
    /// missing fragments of a stalled in-flight frame BEFORE giving up on
    /// it — recovers real data, unlike PLC which only conceals damage
    /// after the fact. Mirrors Android's `WsCallSignaller
    /// .VIDEO_NACK_PAYLOAD_PREFIX` / `VideoNack` byte for byte:
    /// `frameId` is the fragmenter's 16-bit frame counter, `missing` the
    /// list of 0-based fragment indices not yet received.
    case vnack(callId: String, frameId: Int, missing: [Int])

    /// `<callId>|VBWCAP:<int bps>` — W-BWCAP (2026-08-25) receiver-driven
    /// video bitrate cap: the peer's OWN local downlink decision, reported
    /// so THIS side can clamp its outbound video sender to it. Mirrors
    /// Android's `WsCallSignaller.VBWCAP_PAYLOAD_PREFIX` /
    /// `VideoBwCapReport` byte for byte. Event-driven (sent only on a
    /// route-tier transition, never polled) — see
    /// `QAudionWebRtcCallController.resolveAndApplyRouteTier`.
    case videoBwCap(callId: String, bps: Int)

    /// Parse the literal `opaque_message.data` UTF-8 string.
    ///
    /// Returns `nil` for shapes that are NOT a `<callId>|<TAG>:...`
    /// piggy-back (e.g. JSON HandshakeBundle starting with `{`, or
    /// base64 QUAD binary). Callers should fall through to other
    /// parsers in that case — this method MUST NOT throw.
    public static func parse(_ raw: String) -> CallPiggyBack? {
        guard let pipeIdx = raw.firstIndex(of: "|") else { return nil }
        let callId = String(raw[raw.startIndex ..< pipeIdx])
        let payload = String(raw[raw.index(after: pipeIdx)...])
        guard !callId.isEmpty, !payload.isEmpty else { return nil }
        // JSON HandshakeBundle path — not our concern.
        if payload.hasPrefix("{") { return nil }

        // SCREEN_SHARE:<state>
        if let v = stripPrefix(payload, "SCREEN_SHARE:") {
            let lower = v.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Active aliases (case-insensitive) — matches Desktop +
            // Android receiver. Everything else (including the empty
            // string) is treated as inactive so a malformed payload
            // can't trick the UI into a stuck "active" state.
            let active = (lower == "start" || lower == "on" || lower == "true")
            return .screenShare(callId: callId, active: active)
        }
        if let v = stripPrefix(payload, "CAPS:") {
            return .caps(callId: callId, raw: v)
        }
        // VOICE_KEY:<state> — same case-insensitive active-alias set as
        // SCREEN_SHARE above, plus the bare "1"/"0" Android also accepts.
        if let v = stripPrefix(payload, "VOICE_KEY:") {
            let lower = v.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let enrolled = (lower == "1" || lower == "start" || lower == "on" || lower == "true")
            return .voiceKey(callId: callId, enrolled: enrolled)
        }
        // OWNER_CONT:<level> — sender's own live tri-state; unrecognized
        // text parses as "unknown" rather than failing the whole envelope,
        // matching Android's receive-side fallback.
        if let v = stripPrefix(payload, "OWNER_CONT:") {
            let lower = v.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let level = ["unknown", "verified", "uncertain", "mismatch"].contains(lower) ? lower : "unknown"
            return .ownerContinuity(callId: callId, level: level)
        }
        // SPKCHG:<0|1> — the peer's receive-side "the voice changed" verdict
        // about US. Permissive boolean parse, deliberately one-directional:
        // anything that is not an explicit affirmative clears the flag, so a
        // truncated or corrupted payload can only ever remove an alert.
        if let v = stripPrefix(payload, "SPKCHG:") {
            let lower = v.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let changed = (lower == "1" || lower == "true" || lower == "on")
            return .speakerChange(callId: callId, changed: changed)
        }
        if let v = stripPrefix(payload, "HANGUP:") {
            return .hangup(callId: callId, reason: v)
        }
        // PLP:<int percent> — malformed (non-numeric, out of range) drops
        // the whole envelope fail-closed, same discipline as VNACK: a stale
        // loss knob is harmless, a corrupt one applied blind is not.
        if let v = stripPrefix(payload, "PLP:") {
            guard let pct = Int(v.trimmingCharacters(in: .whitespacesAndNewlines)),
                  pct >= 0, pct <= 100
            else { return nil }
            return .plp(callId: callId, percent: pct)
        }
        // EARBUDPDU:<base64> — earbud-relay-v1 handshake PDU. Malformed
        // base64 is dropped fail-closed (handshake simply won't complete),
        // mirroring the Android receive site.
        if let v = stripPrefix(payload, "EARBUDPDU:") {
            guard let bytes = Data(base64Encoded: v) else { return nil }
            return .earbudPdu(callId: callId, pdu: bytes)
        }
        // EARBUDMKD:<base64> — Phase 6 sealed PQ media key package (60 bytes).
        if let v = stripPrefix(payload, "EARBUDMKD:") {
            guard let bytes = Data(base64Encoded: v), bytes.count == 60 else { return nil }
            return .earbudMkd(callId: callId, pkg: bytes)
        }
        // FPSET:<base64(fp_adv[32])> — Phase B fp_adv exchange.
        if let v = stripPrefix(payload, "FPSET:") {
            guard let bytes = Data(base64Encoded: v), bytes.count == 32 else { return nil }
            return .fpSet(callId: callId, fpAdv: bytes)
        }
        // KCMAC:<payload> — PSK-mix ship-step-2, recognised-and-ignored.
        // Consuming it here (instead of falling through) is the whole point:
        // it must never reach AndroidHandshakeEnvelope.parse.
        if let v = stripPrefix(payload, "KCMAC:") {
            return .kcmac(callId: callId, raw: v)
        }
        // VNACK:<frameId>:<idx1>,<idx2>,... — malformed (non-numeric
        // frameId, missing colon, non-numeric index) drops the whole
        // envelope fail-closed: a NACK is a best-effort optimisation, a
        // half-parsed one that resent the wrong fragments would be worse
        // than dropping it. Mirrors Android's receive-side parse, which
        // has the same "if any piece fails, ignore the whole frame" shape.
        if let v = stripPrefix(payload, "VNACK:") {
            let parts = v.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let frameId = Int(parts[0]) else { return nil }
            let missing = parts[1].split(separator: ",").compactMap { Int($0) }
            guard !missing.isEmpty else { return nil }
            return .vnack(callId: callId, frameId: frameId, missing: missing)
        }
        // VBWCAP:<int bps> — malformed (non-numeric, <= 0) drops the whole
        // envelope, mirrors Android's `toIntOrNull()` + `bps > 0` receive guard.
        if let v = stripPrefix(payload, "VBWCAP:") {
            guard let bps = Int(v), bps > 0 else { return nil }
            return .videoBwCap(callId: callId, bps: bps)
        }
        return nil
    }

    private static func stripPrefix(_ s: String, _ prefix: String) -> String? {
        guard s.hasPrefix(prefix) else { return nil }
        return String(s.dropFirst(prefix.count))
    }

    /// Build a wire string for a SCREEN_SHARE announce — the inverse of
    /// `parse`. Used by the sender side (future iOS screen-share UI
    /// hook) so AppState doesn't have to know the framing details.
    public static func serializeScreenShare(callId: String, active: Bool) -> String {
        return "\(callId)|SCREEN_SHARE:\(active ? "start" : "stop")"
    }

    /// Build a wire string for a VOICE_KEY announce — the inverse of the
    /// `.voiceKey` parse branch. `"1"`/`"0"` byte-for-byte matches Android's
    /// `WsCallSignaller.sendVoiceKeyAnnounce`.
    public static func serializeVoiceKey(callId: String, enrolled: Bool) -> String {
        return "\(callId)|VOICE_KEY:\(enrolled ? "1" : "0")"
    }

    /// Build a wire string for a HANGUP piggy-back — the inverse of the
    /// `.hangup` parse branch. Byte-for-byte matches Android
    /// `WsCallSignaller.sendHangup`'s opaque leg
    /// (`"$callId|HANGUP:$reason"`): plain UTF-8 string, NOT base64 —
    /// it must ship via `sendOpaqueMessageString`, never via the
    /// base64-wrapping `sendOpaqueMessage(payload: Data)` overload
    /// (the pipe would vanish inside the base64 alphabet and every
    /// receiver would drop the envelope as malformed).
    public static func serializeHangup(callId: String, reason: String) -> String {
        return "\(callId)|HANGUP:\(reason)"
    }

    /// Build a wire string for a VNACK request — the inverse of the
    /// `.vnack` parse branch. Byte-for-byte matches Android's
    /// `WsCallSignaller.sendVideoNack` payload shape.
    public static func serializeVnack(callId: String, frameId: Int, missing: [Int]) -> String {
        let missingCsv = missing.map(String.init).joined(separator: ",")
        return "\(callId)|VNACK:\(frameId):\(missingCsv)"
    }

    /// Build a wire string for a PLP announce — the inverse of the `.plp`
    /// parse branch. `percent` is clamped to `0...100` here too, so a caller
    /// that skips its own clamping still cannot ship an out-of-contract
    /// value the PEER's parser would then have to reject.
    public static func serializePlp(callId: String, percent: Int) -> String {
        "\(callId)|PLP:\(min(max(percent, 0), 100))"
    }

    /// Build a wire string for an OWNER_CONT announce — the inverse of the
    /// `.ownerContinuity` parse branch. `level` should already be one of
    /// `unknown`/`verified`/`uncertain`/`mismatch` (lowercased) — callers
    /// map from `OwnerContinuityMonitor.State` before calling this, see
    /// `AppState`'s send-side wiring.
    public static func serializeOwnerContinuity(callId: String, level: String) -> String {
        return "\(callId)|OWNER_CONT:\(level)"
    }

    /// Build a wire string for a SPKCHG announce — the inverse of the
    /// `.speakerChange` parse branch. Byte-identical framing to Android's
    /// `WsCallSignaller.sendSpeakerChangeAnnounce`.
    public static func serializeSpeakerChange(callId: String, changed: Bool) -> String {
        return "\(callId)|SPKCHG:\(changed ? "1" : "0")"
    }

    /// Build a wire string for an earbud handshake PDU — the inverse of
    /// the `.earbudPdu` parse branch. Byte-identical framing to Android
    /// `WsCallSignaller.sendEarbudPdu` (`"<callId>|EARBUDPDU:<base64>"`).
    public static func serializeEarbudPdu(callId: String, pdu: Data) -> String {
        return "\(callId)|EARBUDPDU:\(pdu.base64EncodedString())"
    }

    public static func serializeEarbudMkd(callId: String, pkg: Data) -> String {
        return "\(callId)|EARBUDMKD:\(pkg.base64EncodedString())"
    }

    public static func serializeFpSet(callId: String, fpAdv: Data) -> String {
        precondition(fpAdv.count == 32, "fpAdv must be 32 bytes")
        return "\(callId)|FPSET:\(fpAdv.base64EncodedString())"
    }

    /// Build a wire string for a VBWCAP report — the inverse of the
    /// `.videoBwCap` parse branch. Byte-for-byte matches Android's
    /// `WsCallSignaller.VBWCAP_PAYLOAD_PREFIX + bps` (`CallController
    /// .reportLocalVideoCapBps`).
    public static func serializeVideoBwCap(callId: String, bps: Int) -> String {
        return "\(callId)|VBWCAP:\(bps)"
    }

    /// W-KCMAC (ship step 5) — build the wire string for a key-confirmation MAC:
    /// `"<callId>|KCMAC:" + base64(role(1) || mac(32))`, the inverse of the
    /// `.kcmac` parse branch above (which still hands back the undecoded `raw`
    /// payload — decoding/validating the `role||mac` shape is the CONSUMER's
    /// job, same "recognised-and-ignored at parse time" contract `.caps`/
    /// `.hangup` already use, so a malformed peer payload here can never desync
    /// the piggy-back parser itself). `role` is `0x01` (initiator) or `0x02`
    /// (responder) — mirrors Android `WsCallSignaller`'s `KCMAC_PAYLOAD_PREFIX`
    /// framing byte-for-byte.
    public static func serializeKcMac(callId: String, role: UInt8, mac: Data) -> String {
        precondition(mac.count == 32, "mac must be 32 bytes")
        var payload = Data(capacity: 33)
        payload.append(role)
        payload.append(mac)
        return "\(callId)|KCMAC:\(payload.base64EncodedString())"
    }
}
