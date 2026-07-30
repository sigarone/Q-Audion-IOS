import Foundation

/// Pure-Swift codec for the `qa_ctl:1` **avatar_announce** envelope variant.
///
/// E2EE avatar transport (see
/// `docs/E2EE_AVATAR_TRANSPORT_DESIGN.md` in bcrypto-server) — mirrors
/// `AttachAnnounceEnvelope` exactly (same `qa_ctl:1` control-channel
/// pattern, same per-peer AttachmentEncryption ciphertext-on-the-
/// existing-file-upload-endpoint transport), so an avatar update rides
/// the same encrypted `msg_send` path as any attachment. The server
/// never sees the plaintext avatar and never serves it to anyone who
/// hasn't done a real pairwise key exchange with the sender — see the
/// design doc's §1 for the plaintext-avatar-serving gap this replaces.
///
/// **Wire form** (snake_case, mirrors `attach_announce`):
/// ```json
/// {
///   "qa_ctl": 1,
///   "t": "avatar_announce",
///   "att": {
///     "id":          "<base64 16B>",   // attachment_id (UUIDv4 raw)
///     "mime":        "image/jpeg",
///     "byte_length": 41234,             // plaintext bytes
///     "sha256_b64":  "<base64 32B>",
///     "file_id":     "<server upload id>",
///     "version":     3                  // monotonic per-sender counter
///   },
///   "ts": 1785400000
/// }
/// ```
///
/// `version` lets a receiver that already cached a given (or newer)
/// version skip re-downloading a defensively-resent announce (e.g. one
/// sent again on every call-connect) without a separate round trip.
///
/// This is NOT stored as a chat message row — same treatment as
/// `ephemeral_timer`/`ss_req` control envelopes (`AppState
/// .handleIncomingMessage` routes it before message persistence and
/// returns early); it silently updates the local avatar cache.
public struct AvatarAnnounceEnvelope: Equatable {

    public static let typeName = "avatar_announce"
    public static let qaCtlVersion: Int = 1

    public let att: AvatarAnnounceMeta
    public let ts: Int64?

    public init(att: AvatarAnnounceMeta, ts: Int64? = nil) {
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
            case .wrongType(let t): return "expected avatar_announce, got \(t)"
            case .missingField(let k): return "missing required field: \(k)"
            case .invalidValue(let k): return "invalid value for: \(k)"
            }
        }
    }

    /// Parse a JSON-encoded plaintext envelope into the typed struct.
    /// Returns `nil` if the JSON is well-formed but doesn't have
    /// `qa_ctl: 1` of type `avatar_announce` (caller falls back to
    /// other envelope handlers). Throws when it IS avatar_announce but
    /// has malformed inner fields.
    public static func parse(_ jsonText: String) throws -> AvatarAnnounceEnvelope? {
        guard let data = jsonText.data(using: .utf8) else { return nil }
        guard let any = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let marker = any["qa_ctl"] as? Int, marker == qaCtlVersion else {
            return nil
        }
        guard let typeStr = any["t"] as? String else {
            return nil
        }
        guard typeStr == typeName else {
            return nil   // a different qa_ctl variant
        }
        guard let attDict = any["att"] as? [String: Any] else {
            throw Error.missingField("att")
        }
        let att = try AvatarAnnounceMeta.parse(attDict)
        let ts = any["ts"] as? Int64 ?? (any["ts"] as? NSNumber)?.int64Value
        return AvatarAnnounceEnvelope(att: att, ts: ts)
    }

    // MARK: - Encode

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

/// `att` block inside `avatar_announce`. Snake_case wire keys.
public struct AvatarAnnounceMeta: Equatable {

    /// 16-byte UUIDv4 raw bytes, base64-encoded.
    public let id: String
    public let mime: String
    /// Plaintext byte length (NOT ciphertext).
    public let byteLength: Int64
    /// SHA-256 of plaintext, base64.
    public let sha256B64: String
    /// Server-issued upload id from `POST /files/upload`.
    public let fileId: String
    /// Monotonic per-sender version counter, bumped every time the
    /// sender changes their avatar. Lets a receiver dedupe a
    /// defensively-resent announce (e.g. sent again on every
    /// call-connect) without re-downloading.
    public let version: Int

    public init(
        id: String,
        mime: String,
        byteLength: Int64,
        sha256B64: String,
        fileId: String,
        version: Int
    ) {
        self.id = id
        self.mime = mime
        self.byteLength = byteLength
        self.sha256B64 = sha256B64
        self.fileId = fileId
        self.version = version
    }

    /// Validate non-empty + non-negative invariants. Throws on malformed.
    public func validate() throws {
        guard !id.isEmpty else { throw AvatarAnnounceEnvelope.Error.invalidValue("att.id") }
        guard !mime.isEmpty else { throw AvatarAnnounceEnvelope.Error.invalidValue("att.mime") }
        guard byteLength >= 0 else { throw AvatarAnnounceEnvelope.Error.invalidValue("att.byte_length") }
        guard !sha256B64.isEmpty else { throw AvatarAnnounceEnvelope.Error.invalidValue("att.sha256_b64") }
        guard !fileId.isEmpty else { throw AvatarAnnounceEnvelope.Error.invalidValue("att.file_id") }
        guard version >= 0 else { throw AvatarAnnounceEnvelope.Error.invalidValue("att.version") }
    }

    static func parse(_ dict: [String: Any]) throws -> AvatarAnnounceMeta {
        guard let id = dict["id"] as? String, !id.isEmpty else {
            throw AvatarAnnounceEnvelope.Error.missingField("att.id")
        }
        guard let mime = dict["mime"] as? String, !mime.isEmpty else {
            throw AvatarAnnounceEnvelope.Error.missingField("att.mime")
        }
        let byteLength: Int64
        if let n = dict["byte_length"] as? Int64 {
            byteLength = n
        } else if let n = dict["byte_length"] as? NSNumber {
            byteLength = n.int64Value
        } else {
            throw AvatarAnnounceEnvelope.Error.missingField("att.byte_length")
        }
        guard byteLength >= 0 else {
            throw AvatarAnnounceEnvelope.Error.invalidValue("att.byte_length")
        }
        guard let sha256B64 = dict["sha256_b64"] as? String, !sha256B64.isEmpty else {
            throw AvatarAnnounceEnvelope.Error.missingField("att.sha256_b64")
        }
        guard let fileId = dict["file_id"] as? String, !fileId.isEmpty else {
            throw AvatarAnnounceEnvelope.Error.missingField("att.file_id")
        }
        let version: Int
        if let n = dict["version"] as? Int {
            version = n
        } else if let n = dict["version"] as? NSNumber {
            version = n.intValue
        } else {
            throw AvatarAnnounceEnvelope.Error.missingField("att.version")
        }
        guard version >= 0 else {
            throw AvatarAnnounceEnvelope.Error.invalidValue("att.version")
        }
        return AvatarAnnounceMeta(
            id: id, mime: mime, byteLength: byteLength,
            sha256B64: sha256B64, fileId: fileId, version: version
        )
    }

    func toJsonDict() -> [String: Any] {
        [
            "id": id,
            "mime": mime,
            "byte_length": NSNumber(value: byteLength),
            "sha256_b64": sha256B64,
            "file_id": fileId,
            "version": NSNumber(value: version),
        ]
    }
}
