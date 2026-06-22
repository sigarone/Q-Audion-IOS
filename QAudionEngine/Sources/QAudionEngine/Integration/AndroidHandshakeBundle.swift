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
/// - `pskFingerprints`: [String]?  — OFFER only, full SHA-256 hex (64 chars)
/// - `selectedPskFingerprint`: String?  — ACCEPT only
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
        /// path). Additive + omit-when-false (Codable nil → key absent), so the
        /// signed transcript (which folds only ratchetV3/sframeV1/vkeyV1) is
        /// unaffected and old peers stay byte-compatible. Both peers must
        /// advertise `true` for the pair to use directional sealer keys.
        public let srtpDirKeyV1: Bool?

        public init(
            ratchetV3: Bool?,
            sframeV1: Bool? = nil,
            vkeyV1: Bool? = nil,
            sessionKdfV3: Bool? = nil,
            ratchetV4: Bool? = nil,
            srtpDirKeyV1: Bool? = nil
        ) {
            self.ratchetV3 = ratchetV3
            self.sframeV1 = sframeV1
            self.vkeyV1 = vkeyV1
            self.sessionKdfV3 = sessionKdfV3
            self.ratchetV4 = ratchetV4
            self.srtpDirKeyV1 = srtpDirKeyV1
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

    // Phase-10b handshake signing (§1 of HANDSHAKE-SIGNING-SPEC.md) — TWO OPTIONAL fields,
    // appended LAST to mirror Android's additive `HandshakeBundleCodec` change. Both default
    // to nil; `JSONEncoder` omits nil keys, so a bundle that doesn't carry them is byte-wire-
    // identical to the legacy unsigned bundle (no break for already-deployed peers).
    //
    // The signature is computed over the explicit §3 length-prefixed `HandshakeTranscript`
    // (NOT this JSON), so JSON canonicalization is irrelevant to cross-platform parity.
    public let signerIdentityKey: String?   // base64 (no-wrap, padded) of the 32-byte Ed25519 long-term identity pubkey
    public let signature: String?           // base64 (no-wrap, padded) of the 64-byte Ed25519 detached signature

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
        signerIdentityKey: String? = nil,
        signature: String? = nil
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
        self.signerIdentityKey = signerIdentityKey
        self.signature = signature
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
///   - `HANGUP:<reason>` — peer hangup piggy-back (reserved, not
///     consumed by iOS yet — the regular `call_hangup` WS envelope is
///     authoritative; silently dropped).
public enum CallPiggyBack: Equatable {

    /// `<callId>|SCREEN_SHARE:<state>` — peer toggled screen sharing.
    case screenShare(callId: String, active: Bool)

    /// `<callId>|CAPS:<csv>` — capability announce. Carried for
    /// completeness so the parser sink can log/ignore it instead of
    /// printing "unrecognised envelope".
    case caps(callId: String, raw: String)

    /// `<callId>|HANGUP:<reason>` — secondary hangup signal. The
    /// authoritative teardown still arrives on the `call_hangup` WS
    /// envelope; this branch exists so the parser doesn't classify the
    /// piggy-back as malformed.
    case hangup(callId: String, reason: String)

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
        if let v = stripPrefix(payload, "HANGUP:") {
            return .hangup(callId: callId, reason: v)
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
}
