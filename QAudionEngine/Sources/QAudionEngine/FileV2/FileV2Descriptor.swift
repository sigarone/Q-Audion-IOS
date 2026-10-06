import Foundation

/// The end-to-end descriptor of a v2 file (section 12.7): the JSON that carries the key and every piece of
/// metadata, sealed by the chat channel (the body of a 1:1 chat message, or the group payload 0xE4 with
/// `msg_type = 1`). There is no separate announce and no dedicated signature.
///
/// ```json
/// { "qa_file": 2, "id": "<b64 16 B>", "k": "<b64 32 B>", "h": "<b64 64 B header>", "sz": 1234567,
///   "kind": "file|image|video|voice|avatar|thumb", "nm": "report.pdf", "mt": "application/pdf",
///   "src": { "via": "srv", "obj": "<id>", "tok": { "v": "<hex>", "exp": 0, "max": 0 } },
///   "m": { "w": 1920, "h": 1080, "dur": 5234, "wave": [] }, "pv": "<b64, at most 2048 B>",
///   "th": { "qa_file": 2, "kind": "thumb", "...": "complete descriptor of the thumbnail" },
///   "ex": 0, "xp": 1 }
/// ```
///
/// `parse` runs section 12.9 steps 1 and 2 as the reference receiver does: a parsed descriptor is a VALID
/// one, its header already checked against the key and the size (magic, `file_id == id`, `stream_len` and
/// `total_chunks` coherent, `stream_len == padme(sz)`, commitment equal to the derived one). It never logs
/// or prints the key.
public final class FileV2Descriptor: Sendable, CustomStringConvertible {

    public enum Kind: String, Sendable, CaseIterable {
        case file, image, video, voice, avatar, thumb
    }

    /// The server's download token. Opaque to clients: it is stored and handed back, never interpreted.
    public struct Token: Equatable, Sendable {
        public let v: String
        public let exp: Int64?
        public let max: Int64?
    }

    /// `src.via = "direct"` is the direct path with no copy on the server; `"srv"` carries the server
    /// object and the download token.
    public struct Source: Equatable, Sendable {
        public enum Via: String, Sendable { case srv, direct }
        public let via: Via
        public let obj: String?
        public let token: Token?
    }

    /// The media fields of the descriptor's own `kind` (`m`).
    public struct Media: Equatable, Sendable {
        public let w: Int64?
        public let h: Int64?
        public let dur: Int64?
        public let wave: [Int64]?
    }

    /// `id`: 16 bytes, equal to the header's `file_id`.
    public let fileID: Data
    /// `k`: the 32-byte file key `K`. Secret: never log it.
    public let fileKey: Data
    /// `h`: the 64-byte header, parsed and validated.
    public let header: FileV2Header
    /// `sz`: the plaintext size, `1...maxSize`.
    public let size: UInt64
    public let kind: Kind
    /// `nm`: at most 255 UTF-8 bytes. The receiver still sanitises it (canonical path, no overwriting).
    public let name: String?
    /// `mt`: at most 128 UTF-8 bytes.
    public let mimeType: String?
    public let source: Source
    public let media: Media?
    /// `pv`: a tiny preview, decoded length at most 2048 bytes.
    public let preview: Data?
    /// `th`: the complete descriptor of the thumbnail, itself a v2 file with its own key (`kind: thumb`).
    public let thumbnail: FileV2Descriptor?
    /// `ex`: lifetime of an ephemeral message, as the sender wrote it.
    public let ex: Int64?
    /// `xp`: export permission, as the sender wrote it.
    public let xp: Int64?

    private init(fileID: Data, fileKey: Data, header: FileV2Header, size: UInt64, kind: Kind, name: String?,
                 mimeType: String?, source: Source, media: Media?, preview: Data?,
                 thumbnail: FileV2Descriptor?, ex: Int64?, xp: Int64?) {
        self.fileID = fileID
        self.fileKey = fileKey
        self.header = header
        self.size = size
        self.kind = kind
        self.name = name
        self.mimeType = mimeType
        self.source = source
        self.media = media
        self.preview = preview
        self.thumbnail = thumbnail
        self.ex = ex
        self.xp = xp
    }

    /// Short and key-free, for logs: the first 8 hex characters of the id at most.
    public var description: String {
        let shortID = fileID.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "FileV2Descriptor(id: \(shortID), kind: \(kind.rawValue), size: \(size))"
    }

    // MARK: Parsing

    /// Parses and validates a descriptor from its chat text. Every failure is a `FileV2Error`
    /// (`bad_descriptor`, `bad_header`, `size_mismatch` or `commit_mismatch`).
    public static func parse(_ json: String) throws -> FileV2Descriptor {
        try parse(utf8: Data(json.utf8))
    }

    /// Same as `parse(_:)` for the UTF-8 bytes of the text.
    public static func parse(utf8 data: Data) throws -> FileV2Descriptor {
        // "MUST stay under 8 KiB": the reference receiver rejects 8192 bytes and more.
        guard data.count < FileV2.maxDescriptorBytes else { throw FileV2Error.badDescriptor }
        guard case .object(let members)? = FileV2JSONParser.parse(data) else { throw FileV2Error.badDescriptor }
        return try build(members, isThumbnail: false)
    }

    /// The fields in the order of the reference receiver: version, `id` / `k` / `h`, `sz`, `kind`, `nm`, `mt`,
    /// `pv`, `src`, then (the optional parts the reference does not look at) `m`, `th`, `ex`, `xp`, and
    /// last the header checks of section 12.9 step 2.
    private static func build(_ members: [String: FileV2JSONValue], isThumbnail: Bool) throws -> FileV2Descriptor {
        guard case .int(2)? = members["qa_file"] else { throw FileV2Error.badDescriptor }

        let fileID = try decodeBase64(members["id"], length: 16)
        let fileKey = try decodeBase64(members["k"], length: 32)
        let headerBytes = try decodeBase64(members["h"], length: FileV2.headerLength)

        guard case .int(let rawSize)? = members["sz"], rawSize >= 1,
              UInt64(rawSize) <= FileV2.maxSize else { throw FileV2Error.badDescriptor }
        let size = UInt64(rawSize)

        guard case .string(let kindText)? = members["kind"], let kind = Kind(rawValue: kindText) else {
            throw FileV2Error.badDescriptor
        }
        // A thumbnail is described by a complete descriptor whose kind is "thumb".
        if isThumbnail && kind != .thumb { throw FileV2Error.badDescriptor }

        let name = try optionalString(members["nm"], maxBytes: FileV2.maxNameBytes)
        let mimeType = try optionalString(members["mt"], maxBytes: FileV2.maxMimeBytes)

        var preview: Data?
        if let text = try optionalString(members["pv"], maxBytes: nil) {
            guard let decoded = FileV2Base64.decode(text), decoded.count <= FileV2.maxPreviewBytes else {
                throw FileV2Error.badDescriptor
            }
            preview = decoded
        }

        guard case .object(let sourceMembers)? = members["src"] else { throw FileV2Error.badDescriptor }
        let source = try parseSource(sourceMembers)

        let media = try parseMedia(members["m"])

        var thumbnail: FileV2Descriptor?
        if let value = members["th"], value != .null {
            // One level only: a thumbnail has no thumbnail of its own.
            guard !isThumbnail, case .object(let thumbMembers) = value else { throw FileV2Error.badDescriptor }
            thumbnail = try build(thumbMembers, isThumbnail: true)
        }

        let ex = try optionalNonNegativeInt(members["ex"])
        let xp = try optionalNonNegativeInt(members["xp"])

        let validated = try FileV2Header.validate(headerBytes: headerBytes, fileID: fileID,
                                                  fileKey: fileKey, size: size)
        return FileV2Descriptor(fileID: fileID, fileKey: fileKey, header: validated.header, size: size,
                                kind: kind, name: name, mimeType: mimeType, source: source, media: media,
                                preview: preview, thumbnail: thumbnail, ex: ex, xp: xp)
    }

    private static func parseSource(_ members: [String: FileV2JSONValue]) throws -> Source {
        guard case .string(let viaText)? = members["via"], let via = Source.Via(rawValue: viaText) else {
            throw FileV2Error.badDescriptor
        }
        let obj = try optionalString(members["obj"], maxBytes: nil)
        if via == .srv && (obj ?? "").isEmpty { throw FileV2Error.badDescriptor }
        var token: Token?
        if let value = members["tok"], value != .null {
            guard case .object(let tokenMembers) = value,
                  case .string(let tokenValue)? = tokenMembers["v"] else { throw FileV2Error.badDescriptor }
            token = Token(v: tokenValue,
                          exp: try optionalNonNegativeInt(tokenMembers["exp"]),
                          max: try optionalNonNegativeInt(tokenMembers["max"]))
        }
        return Source(via: via, obj: obj, token: token)
    }

    private static func parseMedia(_ value: FileV2JSONValue?) throws -> Media? {
        guard let value = value, value != .null else { return nil }
        guard case .object(let members) = value else { throw FileV2Error.badDescriptor }
        var wave: [Int64]?
        if let waveValue = members["wave"], waveValue != .null {
            guard case .array(let items) = waveValue else { throw FileV2Error.badDescriptor }
            wave = try items.map { item -> Int64 in
                guard case .int(let sample) = item else { throw FileV2Error.badDescriptor }
                return sample
            }
        }
        return Media(w: try optionalNonNegativeInt(members["w"]),
                     h: try optionalNonNegativeInt(members["h"]),
                     dur: try optionalNonNegativeInt(members["dur"]),
                     wave: wave)
    }

    // MARK: Field helpers

    /// A required base64 field of an exact decoded length.
    private static func decodeBase64(_ value: FileV2JSONValue?, length: Int) throws -> Data {
        guard case .string(let text)? = value, let decoded = FileV2Base64.decode(text),
              decoded.count == length else { throw FileV2Error.badDescriptor }
        return decoded
    }

    /// An optional string: absent or `null` is `nil`, any other type or a string over `maxBytes` UTF-8 bytes fails.
    private static func optionalString(_ value: FileV2JSONValue?, maxBytes: Int?) throws -> String? {
        guard let value = value, value != .null else { return nil }
        guard case .string(let text) = value else { throw FileV2Error.badDescriptor }
        if let maxBytes = maxBytes, text.utf8.count > maxBytes { throw FileV2Error.badDescriptor }
        return text
    }

    /// An optional non-negative integer: absent or `null` is `nil`; a fraction, an exponent, a boolean, a
    /// string or a negative number fails.
    private static func optionalNonNegativeInt(_ value: FileV2JSONValue?) throws -> Int64? {
        guard let value = value, value != .null else { return nil }
        guard case .int(let number) = value, number >= 0 else { throw FileV2Error.badDescriptor }
        return number
    }
}
