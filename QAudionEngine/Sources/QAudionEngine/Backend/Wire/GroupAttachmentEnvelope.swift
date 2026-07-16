import Foundation

/// Fase-1B — codec for the GROUP-attachment descriptor.
///
/// Unlike the 1:1 ``AttachAnnounceEnvelope`` (which rides a normal 1:1
/// ratchet message and derives the blob key from the per-pair chain
/// key), the group descriptor travels INSIDE the shared GroupSenderKey
/// 0xE4 payload — the same envelope group TEXT already uses. Because the
/// whole descriptor is 0xE4-sealed to every member, it is safe to carry
/// the RANDOM per-file content key (`key_b64`) in cleartext here: the
/// server + SFU only ever see opaque ciphertext.
///
/// **Transport routing:** the descriptor is packed as the UTF-8 plaintext
/// of a `group_msg_send` frame with `msg_type == 1` (attachment). A
/// `msg_type == 0` frame stays raw-UTF-8 text exactly as before, so every
/// already-shipped text message keeps decoding through the untouched
/// text path. The receiver branches on the transport `msg_type`, NEVER on
/// speculative JSON-sniffing of a text message.
///
/// **Cross-platform contract (verbatim — all 3 clients interoperate):**
/// ```json
/// {
///   "v": 1,
///   "kind": "image",            // "image" | "file"
///   "caption": "optional text",  // optional
///   "attachment": {
///     "id":           "<base64 16B>",   // attachment UUIDv4 raw (blob AAD binder)
///     "file_id":      "<tus upload id>",
///     "mime":         "image/jpeg",
///     "byte_length":  12345,            // plaintext size
///     "sha256_b64":   "<base64 32B>",   // sha256 of plaintext
///     "key_b64":      "<base64 32B>",   // RANDOM per-file content key
///     "filename":     "photo.jpg",
///     "chunk_size":   262144,
///     "total_chunks": 1,
///     "width":        1920,             // image-only
///     "height":       1080,            // image-only
///     "blurhash":     "LEHV6nWB..."    // image-only, optional
///     // "duration_ms": 5234           // file-only optional (audio/video)
///     // "ex":  -1                     // OPTIONAL per-attachment TTL override
///     // "xp":  0                      // OPTIONAL export-permission override
///   },
///   "dl": {                            // §4 PATH 1 — per-member capability tokens
///     "<memberUuid>": { "tok":"<hex>", "exp":<expiresAtMs>, "max":<maxUses> }
///   }
/// }
/// ```
public struct GroupAttachmentEnvelope: Equatable {

    public static let version: Int = 1
    public static let kindImage = "image"
    public static let kindFile = "file"

    public let v: Int
    public let kind: String
    public let caption: String?
    public let attachment: GroupAttachmentMeta
    /// memberUuid → capability token the recipient presents on GET
    /// `/files/tus/{file_id}` (see ``BCryptoDownloadTokenClient``).
    public let dl: [String: GroupDownloadEntry]

    public init(kind: String,
                caption: String?,
                attachment: GroupAttachmentMeta,
                dl: [String: GroupDownloadEntry],
                v: Int = GroupAttachmentEnvelope.version) {
        self.v = v
        self.kind = kind
        self.caption = caption
        self.attachment = attachment
        self.dl = dl
    }

    public enum Error: Swift.Error, LocalizedError {
        case notJson
        case wrongVersion(Int)
        case missingField(String)
        case invalidValue(String)

        public var errorDescription: String? {
            switch self {
            case .notJson: return "descriptor is not a JSON object"
            case .wrongVersion(let v): return "unsupported descriptor version \(v)"
            case .missingField(let k): return "missing required field: \(k)"
            case .invalidValue(let k): return "invalid value for: \(k)"
            }
        }
    }

    /// Whether the sealed group plaintext is an attachment descriptor,
    /// decided by the transport `msg_type` (NOT by parsing). Kept next to
    /// the codec so callers agree on the one authoritative integer.
    public static let msgTypeText: Int = 0
    public static let msgTypeAttachment: Int = 1

    // MARK: - Decode

    /// Parse the descriptor from the decrypted 0xE4 plaintext string.
    /// Throws when the JSON is malformed or a required field is absent.
    public static func parse(_ jsonText: String) throws -> GroupAttachmentEnvelope {
        guard let data = jsonText.data(using: .utf8),
              let any = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Error.notJson
        }
        let v = (any["v"] as? Int) ?? (any["v"] as? NSNumber)?.intValue ?? 0
        guard v == version else { throw Error.wrongVersion(v) }
        guard let kind = any["kind"] as? String, !kind.isEmpty else {
            throw Error.missingField("kind")
        }
        guard let attDict = any["attachment"] as? [String: Any] else {
            throw Error.missingField("attachment")
        }
        let att = try GroupAttachmentMeta.parse(attDict)
        let caption = any["caption"] as? String
        var dl: [String: GroupDownloadEntry] = [:]
        if let dlDict = any["dl"] as? [String: Any] {
            for (uid, raw) in dlDict {
                guard let entryDict = raw as? [String: Any],
                      let entry = GroupDownloadEntry.parse(entryDict) else { continue }
                dl[uid] = entry
            }
        }
        return GroupAttachmentEnvelope(kind: kind, caption: caption, attachment: att, dl: dl, v: v)
    }

    // MARK: - Encode

    public func toJsonDict() -> [String: Any] {
        var dict: [String: Any] = [
            "v": v,
            "kind": kind,
            "attachment": attachment.toJsonDict(),
        ]
        if let caption = caption, !caption.isEmpty { dict["caption"] = caption }
        if !dl.isEmpty {
            var dlOut: [String: Any] = [:]
            for (uid, e) in dl { dlOut[uid] = e.toJsonDict() }
            dict["dl"] = dlOut
        }
        return dict
    }

    public func toJsonString() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: toJsonDict(), options: [.sortedKeys])
        guard let s = String(data: data, encoding: .utf8) else {
            throw Error.invalidValue("utf-8 encoding")
        }
        return s
    }
}

/// The `attachment` block. Snake_case wire keys (VERBATIM).
public struct GroupAttachmentMeta: Equatable {
    /// base64 of 16 raw bytes — attachment UUIDv4, reused as the blob AAD
    /// binder (parity with the 1:1 `att.id`).
    public let id: String
    public let fileId: String
    public let mime: String
    /// Plaintext byte length (NOT ciphertext).
    public let byteLength: Int64
    /// base64 of sha256(plaintext).
    public let sha256B64: String
    /// base64 of the RANDOM 32-byte per-file content key.
    public let keyB64: String
    public let filename: String
    public let chunkSize: Int
    public let totalChunks: Int
    // image-only
    public let width: Int?
    public let height: Int?
    public let blurhash: String?
    // file-only optional
    public let durationMs: Int64?
    /// Per-attachment ephemeral-timer override — GROUP counterpart of the
    /// 1:1 ``AttachAnnounceMeta/ex``. IDENTICAL semantics/encoding
    /// (mirrored verbatim, not a parallel implementation): absent or 0 =
    /// no TTL (message persists); -1 = view-once; positive N = TTL in
    /// seconds. Brand-new optional key — group had NO TTL/view-once
    /// concept before this field. Old decoders ignore the unknown key;
    /// old encoders simply omit it, which this decoder maps to `nil`.
    /// Resolve with the SAME ``AttachmentTimerResolver`` the 1:1 path
    /// uses (no group-specific reimplementation of the precedence rule).
    public let ex: Int?
    /// Export-permission override — GROUP counterpart of the 1:1
    /// ``AttachAnnounceMeta/xp``. IDENTICAL semantics/encoding: absent or
    /// 1 = export allowed (today's behavior, unchanged); 0 = export
    /// blocked. Client-side/UI honor-system signal only — no server-side
    /// enforcement, same caveat as the 1:1 field.
    public let xp: Int?

    public init(id: String, fileId: String, mime: String, byteLength: Int64,
                sha256B64: String, keyB64: String, filename: String,
                chunkSize: Int, totalChunks: Int,
                width: Int? = nil, height: Int? = nil, blurhash: String? = nil,
                durationMs: Int64? = nil,
                ex: Int? = nil, xp: Int? = nil) {
        self.id = id
        self.fileId = fileId
        self.mime = mime
        self.byteLength = byteLength
        self.sha256B64 = sha256B64
        self.keyB64 = keyB64
        self.filename = filename
        self.chunkSize = chunkSize
        self.totalChunks = totalChunks
        self.width = width
        self.height = height
        self.blurhash = blurhash
        self.durationMs = durationMs
        self.ex = ex
        self.xp = xp
    }

    static func int64(_ any: Any?) -> Int64? {
        if let n = any as? Int64 { return n }
        if let n = any as? NSNumber { return n.int64Value }
        if let n = any as? Int { return Int64(n) }
        return nil
    }

    static func int(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }

    static func parse(_ dict: [String: Any]) throws -> GroupAttachmentMeta {
        guard let id = dict["id"] as? String, !id.isEmpty else {
            throw GroupAttachmentEnvelope.Error.missingField("attachment.id")
        }
        guard let fileId = dict["file_id"] as? String, !fileId.isEmpty else {
            throw GroupAttachmentEnvelope.Error.missingField("attachment.file_id")
        }
        guard let mime = dict["mime"] as? String, !mime.isEmpty else {
            throw GroupAttachmentEnvelope.Error.missingField("attachment.mime")
        }
        guard let byteLength = int64(dict["byte_length"]), byteLength >= 0 else {
            throw GroupAttachmentEnvelope.Error.missingField("attachment.byte_length")
        }
        guard let sha256B64 = dict["sha256_b64"] as? String, !sha256B64.isEmpty else {
            throw GroupAttachmentEnvelope.Error.missingField("attachment.sha256_b64")
        }
        guard let keyB64 = dict["key_b64"] as? String, !keyB64.isEmpty else {
            throw GroupAttachmentEnvelope.Error.missingField("attachment.key_b64")
        }
        // filename is best-effort; default to a neutral name if absent.
        let filename = (dict["filename"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "attachment.bin"
        let chunkSize = int(dict["chunk_size"]) ?? 262144
        let totalChunks = int(dict["total_chunks"]) ?? 1
        // `ex`/`xp` are brand-new optional keys, same backward-compat
        // contract as the 1:1 `AttachAnnounceMeta` counterparts — absent
        // in every descriptor produced before this change. Missing key →
        // nil, so old-shape JSON keeps decoding unchanged.
        let ex = int(dict["ex"])
        if let e = ex, e < -1 {
            throw GroupAttachmentEnvelope.Error.invalidValue("attachment.ex")
        }
        let xp = int(dict["xp"])
        if let x = xp, x != 0 && x != 1 {
            throw GroupAttachmentEnvelope.Error.invalidValue("attachment.xp")
        }
        return GroupAttachmentMeta(
            id: id, fileId: fileId, mime: mime, byteLength: byteLength,
            sha256B64: sha256B64, keyB64: keyB64, filename: filename,
            chunkSize: chunkSize, totalChunks: totalChunks,
            width: int(dict["width"]), height: int(dict["height"]),
            blurhash: dict["blurhash"] as? String,
            durationMs: int64(dict["duration_ms"]),
            ex: ex, xp: xp)
    }

    func toJsonDict() -> [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "file_id": fileId,
            "mime": mime,
            "byte_length": NSNumber(value: byteLength),
            "sha256_b64": sha256B64,
            "key_b64": keyB64,
            "filename": filename,
            "chunk_size": NSNumber(value: chunkSize),
            "total_chunks": NSNumber(value: totalChunks),
        ]
        if let w = width { d["width"] = NSNumber(value: w) }
        if let h = height { d["height"] = NSNumber(value: h) }
        if let b = blurhash, !b.isEmpty { d["blurhash"] = b }
        if let dm = durationMs { d["duration_ms"] = NSNumber(value: dm) }
        // Only emit when explicitly set (non-nil) — same contract as the
        // 1:1 `ex`/`xp` fields — so the wire shape is byte-identical to
        // today when no override is chosen.
        if let e = ex { d["ex"] = NSNumber(value: e) }
        if let x = xp { d["xp"] = NSNumber(value: x) }
        return d
    }
}

/// One entry of the `dl` per-member capability map. Wire keys `tok`/`exp`/
/// `max` (VERBATIM — deliberately terser than the server's
/// `token_hex`/`expires_at_ms`/`max_uses` so N of these stay small inside
/// the sealed payload).
public struct GroupDownloadEntry: Equatable {
    public let tok: String
    public let exp: Int64
    public let max: Int32

    public init(tok: String, exp: Int64, max: Int32) {
        self.tok = tok
        self.exp = exp
        self.max = max
    }

    static func parse(_ dict: [String: Any]) -> GroupDownloadEntry? {
        guard let tok = dict["tok"] as? String, !tok.isEmpty else { return nil }
        let exp = GroupAttachmentMeta.int64(dict["exp"]) ?? 0
        let max = Int32(GroupAttachmentMeta.int(dict["max"]) ?? 0)
        return GroupDownloadEntry(tok: tok, exp: exp, max: max)
    }

    func toJsonDict() -> [String: Any] {
        return [
            "tok": tok,
            "exp": NSNumber(value: exp),
            "max": NSNumber(value: max),
        ]
    }

    /// Adapt to the ``DownloadTokenClaim`` the recipient presents as the
    /// three `X-Download-*` headers.
    public func claim(fileId: String) -> DownloadTokenClaim {
        DownloadTokenClaim(fileId: fileId, expiresAtMs: exp, maxUses: max, tokenHex: tok)
    }
}
