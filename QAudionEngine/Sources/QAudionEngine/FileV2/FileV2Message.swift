import Foundation

/// `{"qa_file_src":2,"id":...,"src":{...}}` (section 12.7.6): adds a source to a transfer (for example the server after
/// a failed direct path). It applies only to a transfer whose descriptor came from the SAME sender ACCOUNT, from
/// any of its devices, in the SAME conversation; otherwise, or when no transfer with that id exists, it is dropped
/// silently. That check depends on the state of the receiver and belongs to the pipeline, not to this library.
public struct FileV2SourceMessage: Equatable, Sendable {
    /// The `id` of the transfer (16 bytes).
    public let fileID: Data
    /// The source being added (`src`, validated like the one of a descriptor).
    public let source: FileV2Descriptor.Source
}

/// `{"qa_file_cancel":2,"id":...}` (section 12.7.6): the sender cancelled; the receiver discards the chunks received.
/// The same account and conversation rule as `FileV2SourceMessage` applies.
public struct FileV2CancelMessage: Equatable, Sendable {
    /// The `id` of the transfer (16 bytes).
    public let fileID: Data
}

/// What a chat message body is (section 12.7.1).
///
/// Recognition is a BYTE-prefix test on the body exactly as decrypted: no decoder that strips a byte order mark,
/// normalises the text or substitutes U+FFFD runs before it, no `hasPrefix` (Swift compares grapheme clusters,
/// so a colon followed by a combining mark would be another character), no JSON parsing. A body is a file message iff
/// its bytes begin with one of the three compact prefixes (`{"qa_file":`, `{"qa_file_src":`, `{"qa_file_cancel":`),
/// whatever version follows; anything else is ordinary chat text, whatever else it contains.
///
/// A recognised body that is rejected, with any code, MUST NOT be displayed as text, ever (`rejected`): a rejected
/// descriptor becomes ONE placeholder in the conversation ('update the app' for `unsupportedVersion`), and its content
/// is never displayed, quoted, put in a notification, indexed for search or written in the clear to backups or logs. A
/// rejected CONTROL message produces no placeholder at all: it is dropped silently and keeps nothing.
public enum FileV2Message: Sendable {

    public enum Kind: Sendable {
        case descriptor, source, cancel
    }

    /// Not a file message: ordinary chat text.
    case text
    /// A valid file descriptor.
    case descriptor(FileV2Descriptor)
    /// A valid `qa_file_src` control message.
    case source(FileV2SourceMessage)
    /// A valid `qa_file_cancel` control message.
    case cancel(FileV2CancelMessage)
    /// A recognised file message that was rejected: `bad_descriptor` (or `bad_header`, `size_mismatch`,
    /// `commit_mismatch` for a descriptor whose header does not match its key or size) or `unsupported_version`.
    case rejected(Kind, FileV2Error)

    // MARK: Prefixes (section 12.7.1)

    static let descriptorPrefix = Array(#"{"qa_file":"#.utf8)
    static let sourcePrefix = Array(#"{"qa_file_src":"#.utf8)
    static let cancelPrefix = Array(#"{"qa_file_cancel":"#.utf8)

    /// `true` iff the bytes of `body` begin with one of the three prefixes: the body is a file message (valid or
    /// not) and MUST NOT be shown as text. Also the test for text the USER supplies through any entry point (typing,
    /// paste, share sheet, intents, dictation): such text that begins with a prefix MUST be refused as an ordinary
    /// message, because only the builders of this library produce such a body.
    public static func hasFileMessagePrefix(_ body: Data) -> Bool {
        let bytes = [UInt8](body)
        return bytes.starts(with: descriptorPrefix) || bytes.starts(with: sourcePrefix)
            || bytes.starts(with: cancelPrefix)
    }

    /// Same as `hasFileMessagePrefix(_:)` for a `String` (compared on its UTF-8 bytes).
    public static func hasFileMessagePrefix(_ text: String) -> Bool {
        hasFileMessagePrefix(Data(text.utf8))
    }

    // MARK: Recognition and validation

    /// Recognises and validates the body of a chat message, as decrypted.
    ///
    /// The version is the text after the prefix up to the first `,`, `}` or JSON whitespace, or up to the end of the
    /// body, read before anything else as ASCII digits. The plain integer 2: the body is validated (sections 12.7.2 to
    /// 12.7.6). Another plain integer (`1`, `3`, `0`, `-1`): `unsupportedVersion` and the rest of the body is not
    /// examined (invalid UTF-8, or a length of 8192 bytes or more, included), because a later version may have another
    /// shape. Anything else (empty, `2.0`, `"2"`, `02`, `1e0`, a magnitude above 2^53 - 1, a Unicode digit):
    /// `badDescriptor`.
    public static func recognize(utf8 body: Data) -> FileV2Message {
        let bytes = [UInt8](body)
        let candidates: [(prefix: [UInt8], kind: Kind)] = [
            (descriptorPrefix, .descriptor), (sourcePrefix, .source), (cancelPrefix, .cancel)
        ]
        for candidate in candidates where bytes.starts(with: candidate.prefix) {
            let versionStart = candidate.prefix.count
            var versionEnd = bytes.count
            for index in versionStart..<bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: ",") || byte == UInt8(ascii: "}") || byte == 0x20 || byte == 0x09
                    || byte == 0x0A || byte == 0x0D {
                    versionEnd = index
                    break
                }
            }
            guard let version = FileV2JSONInteger.parse(Array(bytes[versionStart..<versionEnd])) else {
                return .rejected(candidate.kind, .badDescriptor)
            }
            guard version == FileV2.descriptorVersion else {
                return .rejected(candidate.kind, .unsupportedVersion)
            }
            return validate(bytes, as: candidate.kind)
        }
        return .text
    }

    /// Same as `recognize(utf8:)` for a `String` (its UTF-8 bytes). Prefer the bytes as decrypted: a `String`
    /// that was built by a decoder may already have lost a byte order mark or replaced invalid bytes.
    public static func recognize(_ text: String) -> FileV2Message {
        recognize(utf8: Data(text.utf8))
    }

    private static func validate(_ bytes: [UInt8], as kind: Kind) -> FileV2Message {
        switch kind {
        case .descriptor:
            do {
                return .descriptor(try FileV2Descriptor.parse(utf8: Data(bytes)))
            } catch let error as FileV2Error {
                return .rejected(.descriptor, error)
            } catch {
                return .rejected(.descriptor, .badDescriptor)
            }
        case .source, .cancel:
            guard case .success(let object) = FileV2JSONParser.parse(bytes) else {
                return .rejected(kind, .badDescriptor)
            }
            // The version member is the integer 2 and `id` is canonical base64 of 16 bytes; other members are ignored.
            let versionName = kind == .source ? "qa_file_src" : "qa_file_cancel"
            guard case .number(let versionToken)? = object.value(versionName),
                  FileV2JSONInteger.parse(versionToken) == FileV2.descriptorVersion,
                  case .string(let idText)? = object.value("id"),
                  let fileID = FileV2Base64.decode(idText), fileID.count == 16 else {
                return .rejected(kind, .badDescriptor)
            }
            if kind == .cancel { return .cancel(FileV2CancelMessage(fileID: fileID)) }
            guard case .object(let sourceObject)? = object.value("src"),
                  let source = try? FileV2Descriptor.parseSource(sourceObject) else {
                return .rejected(.source, .badDescriptor)
            }
            return .source(FileV2SourceMessage(fileID: fileID, source: source))
        }
    }
}
