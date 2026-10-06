import Foundation

/// The end-to-end descriptor of a v2 file (section 12.7): the JSON that carries the key and every piece of
/// metadata, sealed by the chat channel (the body of a 1:1 chat message, or the group payload 0xE4 with
/// `msg_type = 1`). There is no separate announce and no dedicated signature.
///
/// ```json
/// {"qa_file":2,"id":"<b64 16 B>","k":"<b64 32 B>","h":"<b64 64 B header>","sz":1234567,
///  "kind":"file|image|video|voice|avatar|thumb","nm":"report.pdf","mt":"application/pdf",
///  "src":{"via":"srv","obj":"<lowercase UUID>","tok":{"v":"<64 lowercase hex>","exp":0,"max":0}},
///  "m":{"w":1920,"h":1080,"dur":5234,"wave":[]},"pv":"<b64, at most 2048 B>",
///  "th":{"qa_file":2,"kind":"thumb","...":"complete descriptor of the thumbnail"},"ex":0,"xp":1}
/// ```
///
/// `parse` is the validator of sections 12.7.2 to 12.7.5 and 12.9 steps 1 and 2, as the reference receiver of the
/// vector generator runs them, WITHOUT the recognition step of 12.7.1 (see `FileV2Message.recognize`, which a
/// receiver of chat messages uses). A parsed descriptor is a VALID one: the profile (UTF-8, under 8192 bytes, one
/// object, unique member names, depth 4, no lone surrogate), the integers and the canonical base64, every typed
/// field, and its header already checked against the key and the size (magic, `file_id == id`, `stream_len` and
/// `total_chunks` coherent, `stream_len == padme(sz)`, commitment equal to the derived one). It never logs or
/// prints the key.
///
/// The thumbnail (`th`) is judged on its own and never changes the result of the file: an invalid `th` leaves the
/// file valid with `thumbnail == nil` and `thumbnailStatus == .invalid` (the receiver then neither downloads nor
/// displays the thumbnail and reports `bad_descriptor` for the thumbnail only).
public final class FileV2Descriptor: Sendable, CustomStringConvertible {

    public enum Kind: String, Sendable, CaseIterable {
        case file, image, video, voice, avatar, thumb
    }

    /// The server's download token. Opaque to clients: it is stored and handed back, never interpreted.
    public struct Token: Equatable, Sendable {
        /// 64 lowercase hex characters (an HMAC-SHA-256), exactly as the server returned them.
        public let v: String
        /// Epoch milliseconds, `0...2^53 - 1`.
        public let exp: Int64
        /// `0...2^31 - 1`.
        public let max: Int64

        public init(v: String, exp: Int64, max: Int64) {
            self.v = v
            self.exp = exp
            self.max = max
        }
    }

    /// `src.via = "direct"` is the direct path with no copy on the server; `"srv"` carries the server
    /// object and the download token.
    public struct Source: Equatable, Sendable {
        public enum Via: String, Sendable { case srv, direct }
        public let via: Via
        /// The server's object id (a lowercase UUID, exactly as the server returned it). Required for `srv`;
        /// checked the same way and not used on a `direct` source.
        public let obj: String?
        /// A `srv` source without a token is valid but unusable: the receiver never requests the object without a
        /// token, it keeps the transfer pending until a `qa_file_src` message brings a usable source (12.7.4, 12.7.6).
        public let token: Token?

        public init(via: Via, obj: String? = nil, token: Token? = nil) {
            self.via = via
            self.obj = obj
            self.token = token
        }
    }

    /// The display hints of the descriptor's own `kind` (`m`). Cosmetic: the ranges are not checked by the
    /// format, so the user interface MUST clamp whatever it draws or allocates from them.
    public struct Media: Equatable, Sendable {
        public var w: Int64?
        public var h: Int64?
        public var dur: Int64?
        public var wave: [Int64]?

        public init(w: Int64? = nil, h: Int64? = nil, dur: Int64? = nil, wave: [Int64]? = nil) {
            self.w = w
            self.h = h
            self.dur = dur
            self.wave = wave
        }
    }

    /// What the descriptor said about `th`.
    public enum ThumbnailStatus: Equatable, Sendable {
        /// No `th` member.
        case absent
        /// A complete, valid thumbnail descriptor: see `thumbnail`.
        case valid
        /// `th` is present and invalid (including its header checks, `null`, another type, a nested `th`, the id of
        /// the file): the file is valid, the thumbnail MUST NOT be used, and `bad_descriptor` is reported for the
        /// thumbnail only.
        case invalid
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
    /// `m` when it is present and well typed; `nil` when absent or malformed (a malformed `m` is ignored, the file
    /// is kept).
    public let media: Media?
    /// `pv`: a tiny preview, decoded length at most 2048 bytes.
    public let preview: Data?
    /// `th` when it is valid: the complete descriptor of the thumbnail, itself a v2 file with its own key
    /// (`kind: thumb`). `nil` when absent or invalid (see `thumbnailStatus`).
    public let thumbnail: FileV2Descriptor?
    public let thumbnailStatus: ThumbnailStatus
    /// `ex`: lifetime of an ephemeral message, as the sender wrote it (`-1` view once, `0` no timer, `N` seconds);
    /// `nil` means no timer.
    public let ex: Int64?
    /// `xp`: export permission, as the sender wrote it (`0` blocked, `1` allowed); `nil` means allowed.
    public let xp: Int64?

    private init(fileID: Data, fileKey: Data, header: FileV2Header, size: UInt64, kind: Kind, name: String?,
                 mimeType: String?, source: Source, media: Media?, preview: Data?,
                 thumbnail: FileV2Descriptor?, thumbnailStatus: ThumbnailStatus, ex: Int64?, xp: Int64?) {
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
        self.thumbnailStatus = thumbnailStatus
        self.ex = ex
        self.xp = xp
    }

    /// Short and key-free, for logs: the first 8 hex characters of the id at most.
    public var description: String {
        let shortID = fileID.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "FileV2Descriptor(id: \(shortID), kind: \(kind.rawValue), size: \(size))"
    }

    // MARK: Parsing

    /// Parses and validates a descriptor from its chat text (its UTF-8 bytes). Every failure is a `FileV2Error`
    /// (`bad_descriptor`, `bad_header`, `size_mismatch` or `commit_mismatch`).
    ///
    /// A `String` cannot hold an invalid UTF-8 sequence or a BOM-stripped prefix, so a receiver of chat messages
    /// MUST NOT go through a `String` first: it calls `FileV2Message.recognize(utf8:)` with the bytes as decrypted.
    public static func parse(_ json: String) throws -> FileV2Descriptor {
        try parse(utf8: Data(json.utf8))
    }

    /// Same as `parse(_:)` for the UTF-8 bytes of the text, exactly as decrypted.
    public static func parse(utf8 data: Data) throws -> FileV2Descriptor {
        switch FileV2JSONParser.parse([UInt8](data)) {
        case .failure: throw FileV2Error.badDescriptor
        case .success(let object): return try build(object, isThumbnail: false)
        }
    }

    /// The fields in the order of the reference receiver: version, `id` / `k` / `h`, `sz`, `kind`, `nm`, `mt`, `pv`,
    /// `src`, `m`, the nesting of `th`, `ex`, `xp`, then the header checks of section 12.9 step 2 and last the
    /// judgement of `th` on its own.
    private static func build(_ object: FileV2JSONObject, isThumbnail: Bool) throws -> FileV2Descriptor {
        guard case .number(let versionToken)? = object.value("qa_file"),
              FileV2JSONInteger.parse(versionToken) == FileV2.descriptorVersion else {
            throw FileV2Error.badDescriptor
        }

        let fileID = try base64Field(object, "id", length: 16)
        let fileKey = try base64Field(object, "k", length: 32)
        let headerBytes = try base64Field(object, "h", length: FileV2.headerLength)

        guard case .number(let sizeToken)? = object.value("sz"),
              let rawSize = FileV2JSONInteger.parse(sizeToken), rawSize >= 1,
              UInt64(rawSize) <= FileV2.maxSize else { throw FileV2Error.badDescriptor }
        let size = UInt64(rawSize)

        guard case .string(let kindBytes)? = object.value("kind"),
              let kind = Kind.allCases.first(where: { Array($0.rawValue.utf8) == kindBytes }) else {
            throw FileV2Error.badDescriptor
        }
        // A thumbnail is described by a complete descriptor whose kind is "thumb".
        if isThumbnail && kind != .thumb { throw FileV2Error.badDescriptor }

        let name = try optionalText(object.value("nm"), maxBytes: FileV2.maxNameBytes)
        let mimeType = try optionalText(object.value("mt"), maxBytes: FileV2.maxMimeBytes)

        var preview: Data?
        if let previewBytes = try optionalText(object.value("pv"), maxBytes: nil) {
            guard let decoded = FileV2Base64.decode(Array(previewBytes.utf8)),
                  decoded.count <= FileV2.maxPreviewBytes else { throw FileV2Error.badDescriptor }
            preview = decoded
        }

        guard case .object(let sourceObject)? = object.value("src") else { throw FileV2Error.badDescriptor }
        let source = try parseSource(sourceObject)

        // `m` is cosmetic: a malformed one is ignored, never an error.
        var media: Media?
        if let mediaValue = object.value("m") { media = parseMedia(mediaValue) }

        // A thumbnail carries no `th` of its own: a nested one makes the thumbnail unusable (and is reported by the
        // caller of this recursion), and a top-level descriptor of kind `thumb` that has one is rejected.
        let thumbValue = object.value("th")
        if thumbValue != nil && (isThumbnail || kind == .thumb) { throw FileV2Error.badDescriptor }

        var ex: Int64?
        if let exValue = object.value("ex") {
            guard case .number(let token) = exValue, let number = FileV2JSONInteger.parse(token),
                  number >= FileV2.minEx, number <= FileV2.maxEx else { throw FileV2Error.badDescriptor }
            ex = number
        }
        var xp: Int64?
        if let xpValue = object.value("xp") {
            guard case .number(let token) = xpValue, let number = FileV2JSONInteger.parse(token),
                  number == 0 || number == 1 else { throw FileV2Error.badDescriptor }
            xp = number
        }

        // Section 12.9 step 2, with its own codes.
        let validated = try FileV2Header.validate(headerBytes: headerBytes, fileID: fileID,
                                                  fileKey: fileKey, size: size)

        // `th` is judged on its own and never changes the result of the file.
        var thumbnail: FileV2Descriptor?
        var thumbnailStatus = ThumbnailStatus.absent
        if let thumbValue = thumbValue {
            thumbnailStatus = .invalid
            if case .object(let thumbObject) = thumbValue,
               let candidate = try? build(thumbObject, isThumbnail: true),
               candidate.fileID != fileID {     // a thumbnail is another file: its id MUST differ
                thumbnail = candidate
                thumbnailStatus = .valid
            }
        }

        return FileV2Descriptor(fileID: fileID, fileKey: fileKey, header: validated.header, size: size,
                                kind: kind, name: name, mimeType: mimeType, source: source, media: media,
                                preview: preview, thumbnail: thumbnail, thumbnailStatus: thumbnailStatus,
                                ex: ex, xp: xp)
    }

    /// `src` (section 12.7.4). Used by the descriptor and by the `qa_file_src` control message.
    static func parseSource(_ object: FileV2JSONObject) throws -> Source {
        guard case .string(let viaBytes)? = object.value("via"),
              let via = [Source.Via.srv, Source.Via.direct].first(where: { Array($0.rawValue.utf8) == viaBytes }) else {
            throw FileV2Error.badDescriptor
        }
        var obj: String?
        if let objValue = object.value("obj") {
            guard case .string(let objBytes) = objValue, isValidObjectID(objBytes) else {
                throw FileV2Error.badDescriptor
            }
            obj = String(decoding: objBytes, as: UTF8.self)
        } else if via == .srv {
            throw FileV2Error.badDescriptor
        }
        var token: Token?
        if let tokValue = object.value("tok") {
            guard case .object(let tokObject) = tokValue else { throw FileV2Error.badDescriptor }
            // The members of `tok` are scalars, so that `th.src.tok` stays at depth 4: an object or an array
            // (known member or unknown one) is invalid.
            for member in tokObject.members {
                switch member.value {
                case .object, .array: throw FileV2Error.badDescriptor
                default: break
                }
            }
            guard case .string(let hex)? = tokObject.value("v"), hex.count == FileV2.tokenValueHexLength,
                  hex.allSatisfy(isLowerHexDigit),
                  case .number(let expToken)? = tokObject.value("exp"),
                  let exp = FileV2JSONInteger.parse(expToken), exp >= 0,
                  case .number(let maxToken)? = tokObject.value("max"),
                  let max = FileV2JSONInteger.parse(maxToken), max >= 0, max <= FileV2.maxTokenMax else {
                throw FileV2Error.badDescriptor
            }
            token = Token(v: String(decoding: hex, as: UTF8.self), exp: exp, max: max)
        }
        return Source(via: via, obj: obj, token: token)
    }

    /// `m` (section 12.7.4): well typed, or `nil` (ignored).
    private static func parseMedia(_ value: FileV2JSONValue) -> Media? {
        guard case .object(let object) = value else { return nil }
        /// An integer member that may be absent: `(false, nil)` when it is present and not an integer.
        func integer(_ name: String) -> (valid: Bool, value: Int64?) {
            guard let field = object.value(name) else { return (true, nil) }
            guard case .number(let token) = field, let number = FileV2JSONInteger.parse(token) else { return (false, nil) }
            return (true, number)
        }
        let w = integer("w"), h = integer("h"), dur = integer("dur")
        guard w.valid, h.valid, dur.valid else { return nil }
        var media = Media(w: w.value, h: h.value, dur: dur.value)
        if let waveValue = object.value("wave") {
            guard case .array(let items) = waveValue else { return nil }
            var wave: [Int64] = []
            for item in items {
                guard case .number(let token) = item, let number = FileV2JSONInteger.parse(token) else { return nil }
                wave.append(number)
            }
            media.wave = wave
        }
        return media
    }

    // MARK: Field helpers

    /// A required base64 field of an exact decoded length, in canonical form.
    private static func base64Field(_ object: FileV2JSONObject, _ name: String, length: Int) throws -> Data {
        guard case .string(let text)? = object.value(name), let decoded = FileV2Base64.decode(text),
              decoded.count == length else { throw FileV2Error.badDescriptor }
        return decoded
    }

    /// An optional string: absent or `null` is `nil`, any other type, or a string over `maxBytes` UTF-8 bytes,
    /// fails. Returns the text (valid UTF-8 by construction).
    private static func optionalText(_ value: FileV2JSONValue?, maxBytes: Int?) throws -> String? {
        guard let value = value else { return nil }
        switch value {
        case .null: return nil
        case .string(let bytes):
            if let maxBytes = maxBytes, bytes.count > maxBytes { throw FileV2Error.badDescriptor }
            return String(decoding: bytes, as: UTF8.self)
        default: throw FileV2Error.badDescriptor
        }
    }

    private static func isLowerHexDigit(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
    }

    /// The server's object id: 36 bytes, lowercase hex with hyphens at 8, 13, 18 and 23
    /// (`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`, no version check).
    static func isValidObjectID(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == FileV2.objectIDLength else { return false }
        for (index, byte) in bytes.enumerated() {
            if index == 8 || index == 13 || index == 18 || index == 23 {
                if byte != UInt8(ascii: "-") { return false }
            } else if !isLowerHexDigit(byte) {
                return false
            }
        }
        return true
    }
}
