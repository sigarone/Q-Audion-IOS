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

        public init(ratchetV3: Bool?) {
            self.ratchetV3 = ratchetV3
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
        selectedPskFingerprint: String? = nil
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
}
