import Foundation

/// Pure-Swift codec for the `qa_ctl:1` **attach_announce** envelope variant.
///
/// Wave 3-3 of `glittery-sleeping-hejlsberg.md`. Companion to
/// Desktop `src/main/messaging/ChatControlEnvelope.ts` (commit `d28686c` on
/// Q-Audion-Desktop) and Android
/// `feature/feature-chat/.../attachments/ChatControlEnvelope.kt` (commit
/// `fddd6a18` on New-Q-Audion-Android). All three produce identical wire
/// JSON for the same input.
///
/// **Wire form** (snake_case per WIRE_SPEC §3.6.3):
/// ```json
/// {
///   "qa_ctl": 1,
///   "t": "attach_announce",
///   "att": {
///     "id":           "<base64 16B>",            // attachment_id (UUIDv4 raw)
///     "mime":         "audio/opus",
///     "byte_length":  12345,                      // plaintext bytes
///     "sha256_b64":   "<base64 32B>",
///     "file_id":      "<server upload id>",       // POST /files/tus result
///     "duration_ms":  5234                        // OPTIONAL, voice notes only
///   },
///   "ts": 1700000000
/// }
/// ```
///
/// The envelope rides INSIDE a normal 1:1 ratchet message, so
/// `from_user_id` is cryptographically authenticated by the AEAD on the
/// outer message. The recipient parses this, downloads the ciphertext via
/// `GET /files/{att.fileId}` (with the X-Download-Token header from
/// ``DownloadTokenClaim``), and decrypts via the
/// `BCryptoFileTransfer` flow.
///
/// **Spoofing protection**: `att.id` is bound into the per-attachment
/// AEAD key derivation (WIRE_SPEC §5.1.3). Server substituting any
/// metadata invalidates the AEAD tag.
///
/// **Replay protection**: recipient deduplicates by `att.id`
/// (UUIDv4 ≥ 122 bits entropy).
public struct AttachAnnounceEnvelope: Equatable {

    public static let typeName = "attach_announce"
    public static let qaCtlVersion: Int = 1

    public let att: AttachAnnounceMeta
    /// Sender-side unix epoch seconds (or unix-ms for parity with Android
    /// — both platforms accept either, the WIRE_SPEC's preferred form is
    /// unix-ms but JS engines historically emit seconds. Decode tolerant,
    /// encode unix-seconds for compactness).
    public let ts: Int64?

    public init(att: AttachAnnounceMeta, ts: Int64? = nil) {
        self.att = att
        self.ts = ts
    }

    // MARK: - Decode

    public enum Error: Swift.Error, LocalizedError {
        case wrongMarker
        case wrongType(String)
        case missingField(String)
        case invalidValue(String)

        public var errorDescription: String? {
            switch self {
            case .wrongMarker: return "qa_ctl != 1"
            case .wrongType(let t): return "expected attach_announce, got \(t)"
            case .missingField(let k): return "missing required field: \(k)"
            case .invalidValue(let k): return "invalid value for: \(k)"
            }
        }
    }

    /// Parse a JSON-encoded plaintext envelope into the typed struct.
    /// Returns `nil` if the JSON is well-formed but doesn't have
    /// `qa_ctl: 1` (caller can fall back to other envelope handlers).
    /// Throws when the envelope IS qa_ctl:1 of type attach_announce
    /// but has malformed inner fields.
    public static func parse(_ jsonText: String) throws -> AttachAnnounceEnvelope? {
        guard let data = jsonText.data(using: .utf8) else { return nil }
        guard let any = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Tolerate missing qa_ctl marker — caller will treat as
        // non-qa_ctl plaintext.
        guard let marker = any["qa_ctl"] as? Int, marker == qaCtlVersion else {
            return nil
        }
        guard let typeStr = any["t"] as? String else {
            return nil
        }
        guard typeStr == typeName else {
            return nil   // a different qa_ctl variant (reaction/edit/delete)
        }
        guard let attDict = any["att"] as? [String: Any] else {
            throw Error.missingField("att")
        }
        let att = try AttachAnnounceMeta.parse(attDict)
        let ts = any["ts"] as? Int64 ?? (any["ts"] as? NSNumber)?.int64Value
        return AttachAnnounceEnvelope(att: att, ts: ts)
    }

    // MARK: - Encode

    /// Build the canonical wire JSON dictionary. Caller passes through
    /// `JSONSerialization.data(withJSONObject:)` to emit bytes.
    public func toJsonDict() -> [String: Any] {
        var dict: [String: Any] = [
            "qa_ctl": Self.qaCtlVersion,
            "t": Self.typeName,
            "att": att.toJsonDict(),
        ]
        if let ts = ts {
            dict["ts"] = ts
        }
        return dict
    }

    public func toJsonString() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: toJsonDict(), options: [.sortedKeys])
        guard let s = String(data: data, encoding: .utf8) else {
            throw Error.invalidValue("encoding utf-8")
        }
        return s
    }
}

/// `att` block inside `attach_announce`. Snake_case wire keys.
public struct AttachAnnounceMeta: Equatable {

    /// 16-byte UUIDv4 raw bytes, base64-encoded (24 chars including padding).
    public let id: String
    public let mime: String
    /// Plaintext byte length (NOT ciphertext).
    public let byteLength: Int64
    /// SHA-256 of plaintext, base64.
    public let sha256B64: String
    /// Server-issued upload id from `POST /files/tus`.
    public let fileId: String
    /// OPTIONAL — voice notes only. Recording duration in milliseconds.
    public let durationMs: Int64?
    /// W447 — per-attachment ephemeral-timer override, mirrors Desktop's
    /// `ex` field (commit `488215b`) and Android's convention for the
    /// same concept. Additive/backward-compatible: absent or 0 = no
    /// override (conversation default applies, today's behavior
    /// unchanged); -1 = view-once; positive N = TTL in seconds. Old
    /// decoders ignore the unknown key; old encoders simply omit it.
    public let ex: Int?

    public init(
        id: String,
        mime: String,
        byteLength: Int64,
        sha256B64: String,
        fileId: String,
        durationMs: Int64? = nil,
        ex: Int? = nil
    ) {
        self.id = id
        self.mime = mime
        self.byteLength = byteLength
        self.sha256B64 = sha256B64
        self.fileId = fileId
        self.durationMs = durationMs
        self.ex = ex
    }

    /// Validate non-empty + non-negative invariants. Throws on malformed.
    public func validate() throws {
        guard !id.isEmpty else { throw AttachAnnounceEnvelope.Error.invalidValue("att.id") }
        guard !mime.isEmpty else { throw AttachAnnounceEnvelope.Error.invalidValue("att.mime") }
        guard byteLength >= 0 else { throw AttachAnnounceEnvelope.Error.invalidValue("att.byte_length") }
        guard !sha256B64.isEmpty else { throw AttachAnnounceEnvelope.Error.invalidValue("att.sha256_b64") }
        guard !fileId.isEmpty else { throw AttachAnnounceEnvelope.Error.invalidValue("att.file_id") }
        if let d = durationMs, d < 0 {
            throw AttachAnnounceEnvelope.Error.invalidValue("att.duration_ms")
        }
        // ex semantics: absent/0 = no override, -1 = view-once, N>0 = TTL
        // seconds. Anything < -1 is not a valid value on the wire.
        if let e = ex, e < -1 {
            throw AttachAnnounceEnvelope.Error.invalidValue("att.ex")
        }
    }

    static func parse(_ dict: [String: Any]) throws -> AttachAnnounceMeta {
        guard let id = dict["id"] as? String, !id.isEmpty else {
            throw AttachAnnounceEnvelope.Error.missingField("att.id")
        }
        guard let mime = dict["mime"] as? String, !mime.isEmpty else {
            throw AttachAnnounceEnvelope.Error.missingField("att.mime")
        }
        let byteLength: Int64
        if let n = dict["byte_length"] as? Int64 {
            byteLength = n
        } else if let n = dict["byte_length"] as? NSNumber {
            byteLength = n.int64Value
        } else {
            throw AttachAnnounceEnvelope.Error.missingField("att.byte_length")
        }
        guard byteLength >= 0 else {
            throw AttachAnnounceEnvelope.Error.invalidValue("att.byte_length")
        }
        guard let sha256B64 = dict["sha256_b64"] as? String, !sha256B64.isEmpty else {
            throw AttachAnnounceEnvelope.Error.missingField("att.sha256_b64")
        }
        guard let fileId = dict["file_id"] as? String, !fileId.isEmpty else {
            throw AttachAnnounceEnvelope.Error.missingField("att.file_id")
        }
        var durationMs: Int64?
        if let n = dict["duration_ms"] as? Int64 {
            durationMs = n
        } else if let n = dict["duration_ms"] as? NSNumber {
            durationMs = n.int64Value
        }
        if let d = durationMs, d < 0 {
            throw AttachAnnounceEnvelope.Error.invalidValue("att.duration_ms")
        }
        // W447: `ex` is a brand-new optional key — absent in every
        // envelope produced before this change. Missing key → nil,
        // exactly like `durationMs`, so old-shape JSON keeps decoding
        // unchanged.
        var ex: Int?
        if let n = dict["ex"] as? Int {
            ex = n
        } else if let n = dict["ex"] as? NSNumber {
            ex = n.intValue
        }
        if let e = ex, e < -1 {
            throw AttachAnnounceEnvelope.Error.invalidValue("att.ex")
        }
        return AttachAnnounceMeta(
            id: id, mime: mime, byteLength: byteLength,
            sha256B64: sha256B64, fileId: fileId, durationMs: durationMs,
            ex: ex
        )
    }

    func toJsonDict() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "mime": mime,
            "byte_length": NSNumber(value: byteLength),
            "sha256_b64": sha256B64,
            "file_id": fileId,
        ]
        if let d = durationMs {
            dict["duration_ms"] = NSNumber(value: d)
        }
        // W447: only emit when explicitly set (non-nil) so the wire
        // shape is byte-identical to today when no override is chosen —
        // 0 is a valid "no override" sentinel too but we still round-trip
        // whatever the caller passed to keep the encode/decode symmetric.
        if let e = ex {
            dict["ex"] = NSNumber(value: e)
        }
        return dict
    }
}
