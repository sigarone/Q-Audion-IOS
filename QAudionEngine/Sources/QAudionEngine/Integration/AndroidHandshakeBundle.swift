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

    // OFFER-only fields. Optional so the ACCEPT JSON omits them
    // entirely (rather than emitting `"pqcPublicKey":""`); some
    // peer parsers tolerate the empty-string form, others may
    // interpret it as a missing field that should fail base64
    // decoding. Optional + nil-skip is the unambiguous wire shape.
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
