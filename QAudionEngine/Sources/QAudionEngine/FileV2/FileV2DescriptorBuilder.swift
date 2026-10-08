import Foundation

/// What the sender knows about ONE file when it builds a descriptor (a file, or its thumbnail): the key material and
/// header of its `FileV2Encryptor`, its metadata and where it can be fetched. Plain values: the builder reads them
/// and never keeps them.
public struct FileV2FileInput: Sendable {
    /// `file_id`, 16 bytes.
    public var fileID: Data
    /// `K`, 32 bytes. Secret: it goes into the descriptor (end-to-end encrypted by the channel) and nowhere else.
    public var fileKey: Data
    /// The 64-byte header of the blob.
    public var header: Data
    /// The plaintext size, `1...maxSize`.
    public var size: UInt64
    public var kind: FileV2Descriptor.Kind
    /// Cut to at most 255 UTF-8 bytes at a character boundary; empty counts as absent.
    public var name: String?
    /// Cut to at most 128 UTF-8 bytes at a character boundary; empty counts as absent.
    public var mimeType: String?
    /// `src.obj` and `src.tok.v` are written exactly as the server returned them.
    public var source: FileV2Descriptor.Source
    /// Written only when at least one member is set.
    public var media: FileV2Descriptor.Media?
    /// At most 2048 bytes; empty counts as absent.
    public var preview: Data?
    /// Written only when the sender set it (`-1` view once, `0` no timer, `N` seconds).
    public var ex: Int64?
    /// Written only when the sender set it (`0` export blocked, `1` allowed).
    public var xp: Int64?

    public init(fileID: Data, fileKey: Data, header: Data, size: UInt64, kind: FileV2Descriptor.Kind,
                source: FileV2Descriptor.Source, name: String? = nil, mimeType: String? = nil,
                media: FileV2Descriptor.Media? = nil, preview: Data? = nil, ex: Int64? = nil, xp: Int64? = nil) {
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
        self.ex = ex
        self.xp = xp
    }

    /// The input for the file of `encryptor` (its id, key, header and size).
    public init(encryptor: FileV2Encryptor, kind: FileV2Descriptor.Kind, source: FileV2Descriptor.Source,
                name: String? = nil, mimeType: String? = nil, media: FileV2Descriptor.Media? = nil,
                preview: Data? = nil, ex: Int64? = nil, xp: Int64? = nil) {
        self.init(fileID: encryptor.fileID, fileKey: encryptor.fileKey, header: encryptor.header.bytes,
                  size: encryptor.plaintextSize, kind: kind, source: source, name: name, mimeType: mimeType,
                  media: media, preview: preview, ex: ex, xp: xp)
    }
}

/// The input of `FileV2DescriptorBuilder.build`: the file and, optionally, its thumbnail (a separate v2 file of kind
/// `thumb`, with its own key, described by a complete descriptor of its own that carries no `th`).
public struct FileV2DescriptorInput: Sendable {
    public var file: FileV2FileInput
    public var thumbnail: FileV2FileInput?

    public init(file: FileV2FileInput, thumbnail: FileV2FileInput? = nil) {
        self.file = file
        self.thumbnail = thumbnail
    }
}

/// The canonical builders of section 12.7.1: the ONLY way a file message body is produced, so that every platform is
/// testable byte for byte against the `builder_cases` of the vector file.
///
///  - compact JSON (no whitespace outside strings), the members in the fixed order `qa_file`, `id`, `k`, `h`, `sz`,
///    `kind`, `nm`, `mt`, `src` (`via`, `obj`, `tok` (`v`, `exp`, `max`)), `m` (`w`, `h`, `dur`, `wave`), `pv`, `th`,
///    `ex`, `xp`; the thumbnail is built by the same rules;
///  - an absent optional member is omitted and `null` is NEVER written; an empty `nm`, `mt` or `pv` counts as absent, `m`
///    is omitted when none of its members is set, `ex` and `xp` are written only when the sender set them;
///  - integers in plain decimal form; `id`, `k`, `h` and `pv` in canonical base64;
///  - `nm` and `mt` are cut to at most 255 and 128 UTF-8 bytes at a character boundary, a Unicode scalar value never
///    being split (a Swift `String` cannot hold an unpaired surrogate, so there is none to replace);
///  - escaping: only the quote, the backslash and the C0 controls are escaped, with the short forms `\b`, `\f`, `\n`,
///    `\r`, `\t` and `\u00xx` with lowercase hex for the others; `/` is not escaped and every other character (DEL,
///    U+2028, all non-ASCII) is written raw as UTF-8. `JSONEncoder` and `JSONSerialization` are NOT used: they escape
///    `/` and may escape more;
///  - `src.obj` and `src.tok.v` are written exactly as given (as the server returned them), never re-formatted through
///    a `UUID` (`uuidString` is upper case);
///  - size: if the text would reach 8192 bytes the builder drops `m.wave`, then `pv`, then `th`, of the file
///    descriptor, in that order, stopping as soon as it fits; the thumbnail is dropped whole, never trimmed. If the text
///    still does not fit it refuses (`FileV2Error.invalidArgument`);
///  - a value outside section 12.7.4 is refused, not written.
///
/// The output is accepted by `FileV2Message.recognize` and begins with `{"qa_file":2,"id":`.
public enum FileV2DescriptorBuilder {

    /// The body of a file message for `input`, as a UTF-8 `String`.
    public static func build(_ input: FileV2DescriptorInput) throws -> String {
        try validate(input.file, isThumbnail: false)
        if let thumbnail = input.thumbnail {
            try validate(thumbnail, isThumbnail: true)
            guard input.file.kind != .thumb else {
                throw FileV2Error.invalidArgument("a thumbnail carries no thumbnail of its own")
            }
            guard thumbnail.fileID != input.file.fileID else {
                throw FileV2Error.invalidArgument("the thumbnail is another file: its id must differ")
            }
        }

        var candidate = input
        func serializeIfItFits() -> String? {
            let bytes = serialize(candidate.file, thumbnail: candidate.thumbnail)
            return bytes.count < FileV2.maxDescriptorBytes ? String(decoding: bytes, as: UTF8.self) : nil
        }
        if let text = serializeIfItFits() { return text }
        if candidate.file.media?.wave != nil {                       // 1. m.wave
            candidate.file.media?.wave = nil
            if let text = serializeIfItFits() { return text }
        }
        if candidate.file.preview != nil {                           // 2. pv
            candidate.file.preview = nil
            if let text = serializeIfItFits() { return text }
        }
        if candidate.thumbnail != nil {                              // 3. th, whole
            candidate.thumbnail = nil
            if let text = serializeIfItFits() { return text }
        }
        throw FileV2Error.invalidArgument("the descriptor does not fit in 8 KiB")
    }

    /// `{"qa_file_src":2,"id":...,"src":{...}}` (section 12.7.6): adds `source` to the transfer `fileID`.
    public static func buildSource(fileID: Data, source: FileV2Descriptor.Source) throws -> String {
        guard fileID.count == 16 else { throw FileV2Error.invalidArgument("id length") }
        try validate(source)
        var out: [UInt8] = []
        raw(&out, #"{"qa_file_src":2,"id":"#)
        string(&out, FileV2Base64.encode(fileID))
        raw(&out, #","src":"#)
        serialize(source, into: &out)
        raw(&out, "}")
        return String(decoding: out, as: UTF8.self)
    }

    /// `{"qa_file_cancel":2,"id":...}` (section 12.7.6): the sender cancelled the transfer `fileID`.
    public static func buildCancel(fileID: Data) throws -> String {
        guard fileID.count == 16 else { throw FileV2Error.invalidArgument("id length") }
        var out: [UInt8] = []
        raw(&out, #"{"qa_file_cancel":2,"id":"#)
        string(&out, FileV2Base64.encode(fileID))
        raw(&out, "}")
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Refusals (values outside section 12.7.4)

    private static func validate(_ file: FileV2FileInput, isThumbnail: Bool) throws {
        guard file.fileID.count == 16, file.fileKey.count == 32, file.header.count == FileV2.headerLength else {
            throw FileV2Error.invalidArgument("id, key or header length")
        }
        guard file.size >= 1, file.size <= FileV2.maxSize else { throw FileV2Error.invalidArgument("size out of range") }
        if isThumbnail && file.kind != .thumb { throw FileV2Error.invalidArgument("a thumbnail has kind thumb") }
        // The receiver checks the header against the key and the size (section 12.9 step 2): do not send a descriptor
        // it would reject.
        do {
            _ = try FileV2Header.validate(headerBytes: file.header, fileID: file.fileID, fileKey: file.fileKey,
                                          size: file.size)
        } catch {
            throw FileV2Error.invalidArgument("the header does not match the key, the id and the size")
        }
        if let preview = file.preview, preview.count > FileV2.maxPreviewBytes {
            throw FileV2Error.invalidArgument("preview over 2048 bytes")
        }
        try validate(file.source)
        if let media = file.media {
            let numbers = [media.w, media.h, media.dur].compactMap { $0 } + (media.wave ?? [])
            guard numbers.allSatisfy({ $0 >= -FileV2.maxJSONInteger && $0 <= FileV2.maxJSONInteger }) else {
                throw FileV2Error.invalidArgument("media integer out of range")
            }
        }
        if let ex = file.ex, ex < FileV2.minEx || ex > FileV2.maxEx { throw FileV2Error.invalidArgument("ex out of range") }
        if let xp = file.xp, xp != 0 && xp != 1 { throw FileV2Error.invalidArgument("xp out of range") }
    }

    private static func validate(_ source: FileV2Descriptor.Source) throws {
        if let obj = source.obj, !FileV2Descriptor.isValidObjectID(Array(obj.utf8)) {
            throw FileV2Error.invalidArgument("src.obj is not an object id")
        }
        if source.via == .srv && source.obj == nil { throw FileV2Error.invalidArgument("a server source needs src.obj") }
        if let token = source.token {
            let hex = Array(token.v.utf8)
            guard hex.count == FileV2.tokenValueHexLength,
                  hex.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else {
                throw FileV2Error.invalidArgument("src.tok.v is not 64 lowercase hex characters")
            }
            guard token.exp >= 0, token.exp <= FileV2.maxJSONInteger, token.max >= 0, token.max <= FileV2.maxTokenMax else {
                throw FileV2Error.invalidArgument("src.tok integer out of range")
            }
        }
    }

    // MARK: Canonical serialisation

    /// The canonical text of a file descriptor, as UTF-8 bytes.
    private static func serialize(_ file: FileV2FileInput, thumbnail: FileV2FileInput?) -> [UInt8] {
        var out: [UInt8] = []
        raw(&out, #"{"qa_file":2"#)
        member(&out, "id"); string(&out, FileV2Base64.encode(file.fileID))
        member(&out, "k"); string(&out, FileV2Base64.encode(file.fileKey))
        member(&out, "h"); string(&out, FileV2Base64.encode(file.header))
        member(&out, "sz"); raw(&out, String(file.size))
        member(&out, "kind"); string(&out, file.kind.rawValue)
        if let name = cut(file.name, maxBytes: FileV2.maxNameBytes) {
            member(&out, "nm"); string(&out, name)
        }
        if let mimeType = cut(file.mimeType, maxBytes: FileV2.maxMimeBytes) {
            member(&out, "mt"); string(&out, mimeType)
        }
        member(&out, "src"); serialize(file.source, into: &out)
        if let media = file.media, media.w != nil || media.h != nil || media.dur != nil || media.wave != nil {
            member(&out, "m")
            raw(&out, "{")
            var first = true
            func integerMember(_ name: String, _ value: Int64?) {
                guard let value = value else { return }
                if !first { raw(&out, ",") }
                first = false
                raw(&out, "\"\(name)\":\(value)")
            }
            integerMember("w", media.w)
            integerMember("h", media.h)
            integerMember("dur", media.dur)
            if let wave = media.wave {
                if !first { raw(&out, ",") }
                first = false
                raw(&out, "\"wave\":[")
                raw(&out, wave.map { String($0) }.joined(separator: ","))
                raw(&out, "]")
            }
            raw(&out, "}")
        }
        if let preview = file.preview, !preview.isEmpty {
            member(&out, "pv"); string(&out, FileV2Base64.encode(preview))
        }
        if let thumbnail = thumbnail {
            member(&out, "th"); out.append(contentsOf: serialize(thumbnail, thumbnail: nil))
        }
        if let ex = file.ex { member(&out, "ex"); raw(&out, String(ex)) }
        if let xp = file.xp { member(&out, "xp"); raw(&out, String(xp)) }
        raw(&out, "}")
        return out
    }

    /// `{"via":...,"obj":...,"tok":{"v":...,"exp":...,"max":...}}`, absent members omitted.
    private static func serialize(_ source: FileV2Descriptor.Source, into out: inout [UInt8]) {
        raw(&out, #"{"via":"#)
        string(&out, source.via.rawValue)
        if let obj = source.obj, !obj.isEmpty {
            raw(&out, #","obj":"#)
            string(&out, obj)
        }
        if let token = source.token {
            raw(&out, #","tok":{"v":"#)
            string(&out, token.v)
            raw(&out, #","exp":\#(token.exp),"max":\#(token.max)}"#)
        }
        raw(&out, "}")
    }

    /// `value` cut to at most `maxBytes` UTF-8 bytes at a character boundary (a Unicode scalar value is never split);
    /// `nil` when it is absent or empty.
    static func cut(_ value: String?, maxBytes: Int) -> String? {
        guard let value = value else { return nil }
        let bytes = Array(value.utf8)
        var end = bytes.count
        if end > maxBytes {
            // `bytes[end]` is the first byte that does not fit: while it is a continuation byte (10xxxxxx) the cut
            // would fall inside a character, so move back to the start of that character.
            end = maxBytes
            while end > 0 && (bytes[end] & 0xC0) == 0x80 { end -= 1 }
        }
        guard end > 0 else { return nil }
        return String(decoding: bytes[0..<end], as: UTF8.self)
    }

    // MARK: Bytes

    private static func raw(_ out: inout [UInt8], _ text: String) {
        out.append(contentsOf: Array(text.utf8))
    }

    /// `,"name":`
    private static func member(_ out: inout [UInt8], _ name: String) {
        out.append(UInt8(ascii: ","))
        out.append(UInt8(ascii: "\""))
        out.append(contentsOf: Array(name.utf8))
        out.append(UInt8(ascii: "\""))
        out.append(UInt8(ascii: ":"))
    }

    /// A JSON string literal in the canonical form. Iterates the Unicode scalars: no grapheme or normalisation
    /// logic can alter what is written.
    static func string(_ out: inout [UInt8], _ value: String) {
        out.append(UInt8(ascii: "\""))
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: raw(&out, "\\\"")
            case 0x5C: raw(&out, "\\\\")
            case 0x08: raw(&out, "\\b")
            case 0x0C: raw(&out, "\\f")
            case 0x0A: raw(&out, "\\n")
            case 0x0D: raw(&out, "\\r")
            case 0x09: raw(&out, "\\t")
            case 0x00..<0x20:
                let digits = Array("0123456789abcdef".utf8)
                raw(&out, "\\u00")
                out.append(digits[Int(scalar.value >> 4)])
                out.append(digits[Int(scalar.value & 0x0F)])
            default:
                FileV2UTF8.append(scalar: scalar.value, to: &out)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}
