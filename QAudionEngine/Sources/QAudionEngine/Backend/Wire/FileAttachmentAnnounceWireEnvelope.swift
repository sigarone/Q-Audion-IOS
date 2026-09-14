import Foundation

/// SEC-WIREUNIFY (2026-08-03) — pure-Swift codec for the `qa_fa_announce:1`
/// cross-platform file-attachment envelope. Byte-shape mirror of Android
/// `core/core-data/.../fileattach/FileAttachmentAnnouncePublisherImpl.kt`
/// (`WireEnvelope`/`WireDeviceWrap`).
///
/// **Wire shape**: unlike `AttachAnnounceEnvelope` (`qa_ctl:1`, which rides
/// the normal encrypted `msg_send` channel as plaintext), this envelope
/// travels over the raw `opaque_message` WS channel — it is
/// self-authenticating (the per-device X25519+AESGCM wrap IS the crypto),
/// so it needs no outer ratchet. The `data` field of the opaque_message is
/// the base64 encoding of this envelope's compact JSON:
///
/// ```json
/// {
///   "t":"qa_fa_announce:1","f":"<uuid>","s":"<uuid>","eph":"<b64 32B>",
///   "tu":"<tus fileId>","nc":2,"cs":65536,"tb":120,"mi":"image/jpeg",
///   "fn":"photo.jpg","w":[{"d":"<b64 16B>","k":"<b64 48B>"}],
///   "dt":"<hex>?","de":123?,"du":10?,"ex":300?,"xp":0?,"sg":"<b64 64B>?"
/// }
/// ```
///
/// Compact single-char keys — same philosophy as Android's publisher, so a
/// cross-platform parser only needs a small mapping table. `dt`/`de`/`du`
/// (download-capability token), `ex` (disappearing-message TTL), and `xp`
/// (export-permission) are OPTIONAL and backward-tolerant: absent on the
/// wire (older sender) decodes to `nil` / owner-direct / no-TTL / export-
/// allowed, matching Android's documented defaults exactly.
///
/// ATT-1 (`CRYPTO_PROTOCOL_AUDIT_2026-09-01.md` backlog item 1) — `sg` is a
/// NEW OPTIONAL field: the base64 detached Ed25519 signature over
/// `FileAttachmentAnnounceSig.canon(...)`, signed with the sender's
/// long-term device-identity key. Absent on the wire (older sender, or a
/// not-yet-updated platform) decodes to `nil` and the receiver accepts the
/// envelope unsigned exactly as before — no capability negotiation needed.
/// Present-but-invalid is a receiver-side concern (never accept/install on a
/// bad or unresolvable signature); this codec only carries the bytes.
public struct FileAttachmentAnnounceWireEnvelope: Equatable {

    public static let wireType = "qa_fa_announce:1"

    public struct DeviceWrap: Equatable {
        public let deviceIdB64: String
        public let wrappedContentKeyB64: String

        public init(deviceIdB64: String, wrappedContentKeyB64: String) {
            self.deviceIdB64 = deviceIdB64
            self.wrappedContentKeyB64 = wrappedContentKeyB64
        }
    }

    public let fileId: String
    public let senderId: String
    public let senderEphPubB64: String
    public let tusFileId: String
    public let totalChunks: Int
    public let chunkSize: Int
    public let totalSizeBytes: Int64
    public let mime: String
    public let filename: String
    public let wraps: [DeviceWrap]
    public let downloadTokenHex: String?
    public let downloadTokenExpiresMs: Int64?
    public let downloadTokenMaxUses: Int?
    public let ephemeralSpecSec: Int64?
    public let xp: Int?
    /// ATT-1 — base64 detached Ed25519 signature (64B) over
    /// `FileAttachmentAnnounceSig.canon(...)`, or `nil` for an unsigned
    /// (legacy-compatible) envelope. See the type doc's `sg` field note.
    public let sigB64: String?

    public init(
        fileId: String, senderId: String, senderEphPubB64: String, tusFileId: String,
        totalChunks: Int, chunkSize: Int, totalSizeBytes: Int64, mime: String, filename: String,
        wraps: [DeviceWrap], downloadTokenHex: String? = nil, downloadTokenExpiresMs: Int64? = nil,
        downloadTokenMaxUses: Int? = nil, ephemeralSpecSec: Int64? = nil, xp: Int? = nil,
        sigB64: String? = nil
    ) {
        self.fileId = fileId
        self.senderId = senderId
        self.senderEphPubB64 = senderEphPubB64
        self.tusFileId = tusFileId
        self.totalChunks = totalChunks
        self.chunkSize = chunkSize
        self.totalSizeBytes = totalSizeBytes
        self.mime = mime
        self.filename = filename
        self.wraps = wraps
        self.downloadTokenHex = downloadTokenHex
        self.downloadTokenExpiresMs = downloadTokenExpiresMs
        self.downloadTokenMaxUses = downloadTokenMaxUses
        self.ephemeralSpecSec = ephemeralSpecSec
        self.xp = xp
        self.sigB64 = sigB64
    }

    public enum Error: Swift.Error, LocalizedError {
        case notThisType
        case missingField(String)
        case invalidValue(String)

        public var errorDescription: String? {
            switch self {
            case .notThisType: return "not a qa_fa_announce:1 envelope"
            case .missingField(let k): return "missing field: \(k)"
            case .invalidValue(let k): return "invalid value: \(k)"
            }
        }
    }

    // MARK: - Decode

    /// Reverse of `toWirePayload()`. Returns `nil` when the payload doesn't
    /// claim `wireType` or is malformed — mirrors Android's
    /// `decodeWirePayload` tolerant-null contract exactly (caller falls
    /// through to other opaque_message consumers on `nil`).
    public static func parse(wirePayloadB64: String) -> FileAttachmentAnnounceWireEnvelope? {
        guard let raw = Data(base64Encoded: wirePayloadB64) else { return nil }
        guard let any = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return nil }
        guard let t = any["t"] as? String, t == wireType else { return nil }
        guard let fileId = any["f"] as? String, !fileId.isEmpty else { return nil }
        guard let senderId = any["s"] as? String, !senderId.isEmpty else { return nil }
        guard let eph = any["eph"] as? String, !eph.isEmpty else { return nil }
        guard let tu = any["tu"] as? String, !tu.isEmpty else { return nil }
        guard let nc = (any["nc"] as? Int) ?? (any["nc"] as? NSNumber)?.intValue else { return nil }
        guard let cs = (any["cs"] as? Int) ?? (any["cs"] as? NSNumber)?.intValue else { return nil }
        guard let tb = (any["tb"] as? Int64) ?? (any["tb"] as? NSNumber)?.int64Value else { return nil }
        guard let mi = any["mi"] as? String, !mi.isEmpty else { return nil }
        guard let fn = any["fn"] as? String, !fn.isEmpty else { return nil }
        guard let wArr = any["w"] as? [[String: Any]], !wArr.isEmpty else { return nil }
        let wraps: [DeviceWrap] = wArr.compactMap { w in
            guard let d = w["d"] as? String, let k = w["k"] as? String, !d.isEmpty, !k.isEmpty else { return nil }
            return DeviceWrap(deviceIdB64: d, wrappedContentKeyB64: k)
        }
        guard !wraps.isEmpty else { return nil }

        // Backward-tolerant download-token reconstruction — same
        // all-or-nothing contract as Android's decodeWirePayload.
        let dtHex = any["dt"] as? String
        let deMs = (any["de"] as? Int64) ?? (any["de"] as? NSNumber)?.int64Value
        let duUses = (any["du"] as? Int) ?? (any["du"] as? NSNumber)?.intValue
        let downloadTokenHex: String?
        let downloadTokenExpiresMs: Int64?
        let downloadTokenMaxUses: Int?
        if let dtHex, !dtHex.isEmpty, let deMs, deMs > 0, let duUses, duUses > 0 {
            downloadTokenHex = dtHex
            downloadTokenExpiresMs = deMs
            downloadTokenMaxUses = duUses
        } else {
            downloadTokenHex = nil
            downloadTokenExpiresMs = nil
            downloadTokenMaxUses = nil
        }
        let ex = (any["ex"] as? Int64) ?? (any["ex"] as? NSNumber)?.int64Value
        let xp = (any["xp"] as? Int) ?? (any["xp"] as? NSNumber)?.intValue
        // ATT-1: optional signature. A present-but-empty string is treated
        // the same as absent (nil) — the verifier's contract is "present and
        // well-formed => must verify", and an empty string can never be a
        // well-formed 64-byte signature, so folding it to nil here just
        // means the receiver's own length check catches it uniformly with
        // "field omitted" rather than needing a second empty-string branch.
        let sgRaw = any["sg"] as? String
        let sg: String? = (sgRaw?.isEmpty ?? true) ? nil : sgRaw

        return FileAttachmentAnnounceWireEnvelope(
            fileId: fileId, senderId: senderId, senderEphPubB64: eph, tusFileId: tu,
            totalChunks: nc, chunkSize: cs, totalSizeBytes: tb, mime: mi, filename: fn,
            wraps: wraps, downloadTokenHex: downloadTokenHex, downloadTokenExpiresMs: downloadTokenExpiresMs,
            downloadTokenMaxUses: downloadTokenMaxUses, ephemeralSpecSec: ex, xp: xp, sigB64: sg
        )
    }

    // MARK: - Encode

    /// Build the base64-of-JSON wire payload for the `opaque_message`
    /// `data` field.
    public func toWirePayload() throws -> String {
        var dict: [String: Any] = [
            "t": Self.wireType,
            "f": fileId,
            "s": senderId,
            "eph": senderEphPubB64,
            "tu": tusFileId,
            "nc": totalChunks,
            "cs": chunkSize,
            "tb": NSNumber(value: totalSizeBytes),
            "mi": mime,
            "fn": filename,
            "w": wraps.map { ["d": $0.deviceIdB64, "k": $0.wrappedContentKeyB64] },
        ]
        if let dt = downloadTokenHex, let de = downloadTokenExpiresMs, let du = downloadTokenMaxUses {
            dict["dt"] = dt
            dict["de"] = NSNumber(value: de)
            dict["du"] = du
        }
        if let ex = ephemeralSpecSec { dict["ex"] = NSNumber(value: ex) }
        if let xp = xp { dict["xp"] = xp }
        if let sg = sigB64 { dict["sg"] = sg }
        let jsonData = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return jsonData.base64EncodedString()
    }
}
