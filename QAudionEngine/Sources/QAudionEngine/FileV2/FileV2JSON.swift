import Foundation

// The JSON profile of a file message (WIRE_SPEC section 12.7.2 and 12.7.3): one behaviour for every point where
// a lenient JSON library and a strict one would disagree. Nothing here goes through `String`, `JSONSerialization`
// or `Foundation` text decoding: the text is a sequence of BYTES (the UTF-8 text exactly as decrypted), member
// names and values are compared as bytes, numbers stay tokens until a field asks for an integer. That is what
// makes the answer the same on every platform: Swift compares `String`s by canonical equivalence (the Kelvin sign
// U+212A would equal `K`, a precomposed letter would equal its decomposed form), and a `[String: _]` dictionary
// would then collapse two different names into one.

/// Why the JSON profile rejected a text. Internal diagnostic: every one of them is `bad_descriptor` on the wire.
enum FileV2JSONFailure: Error, Equatable {
    /// 8192 bytes or more (section 12.7.2 rule 1).
    case tooLarge
    /// Not valid UTF-8: an invalid byte, an overlong form, an encoded surrogate, above U+10FFFF, a truncated sequence.
    case invalidUTF8
    /// Not RFC 8259 (a comment, a trailing comma, data after the object, a byte order mark, ...).
    case syntax
    /// Valid JSON, but not one object.
    case notAnObject
    /// More than `FileV2.maxDescriptorDepth` nested containers.
    case depth
    /// A member name repeated within one object (any depth, known or unknown member).
    case duplicateMember
    /// A `\u` escape that denotes a lone surrogate.
    case loneSurrogate
}

/// A parsed JSON value of the profile.
enum FileV2JSONValue {
    case null
    case bool(Bool)
    /// A number token exactly as written (RFC 8259 grammar); never converted here (`FileV2JSONInteger` does it,
    /// for the fields that read an integer). `1e400`, `-0` and an integer of 400 digits are tokens like any other.
    case number([UInt8])
    /// The decoded text as UTF-8 bytes (valid by construction: the whole text was validated first and escapes
    /// that denote a lone surrogate are rejected).
    case string([UInt8])
    case array([FileV2JSONValue])
    case object(FileV2JSONObject)
}

/// A JSON object: the members in document order, names unique (compared as UTF-8 bytes, which is the same as
/// comparing code point sequences without any normalisation or case folding).
struct FileV2JSONObject {
    struct Member {
        let name: [UInt8]
        let value: FileV2JSONValue
    }

    fileprivate(set) var members: [Member] = []

    /// The value of the member called `name` (ASCII), compared byte for byte; `nil` when absent.
    func value(_ name: String) -> FileV2JSONValue? {
        let wanted = Array(name.utf8)
        for member in members where member.name == wanted { return member.value }
        return nil
    }
}

/// UTF-8 validation (RFC 3629) on bytes: no decoder that strips a byte order mark or substitutes U+FFFD.
enum FileV2UTF8 {

    /// `true` iff `bytes` is well-formed UTF-8: no overlong form, no encoded surrogate (U+D800...U+DFFF), nothing
    /// above U+10FFFF, no stray or truncated sequence. A byte order mark is the ordinary scalar U+FEFF.
    static func isValid(_ bytes: [UInt8]) -> Bool {
        var index = 0
        let count = bytes.count
        while index < count {
            let lead = bytes[index]
            if lead < 0x80 {
                index += 1
                continue
            }
            let needed: Int
            var low: UInt8 = 0x80      // allowed range of the first continuation byte
            var high: UInt8 = 0xBF
            switch lead {
            case 0xC2...0xDF: needed = 1
            case 0xE0: needed = 2; low = 0xA0
            case 0xE1...0xEC, 0xEE...0xEF: needed = 2
            case 0xED: needed = 2; high = 0x9F          // U+D800...U+DFFF are not scalar values
            case 0xF0: needed = 3; low = 0x90
            case 0xF1...0xF3: needed = 3
            case 0xF4: needed = 3; high = 0x8F          // nothing above U+10FFFF
            default: return false                        // 0x80...0xC1 and 0xF5...0xFF never start a sequence
            }
            // The continuation bytes are bytes[index + 1] ... bytes[index + needed]: all of them must exist.
            guard index + needed < count else { return false }
            let first = bytes[index + 1]
            guard first >= low, first <= high else { return false }
            if needed >= 2 {
                guard bytes[index + 2] >= 0x80, bytes[index + 2] <= 0xBF else { return false }
            }
            if needed == 3 {
                guard bytes[index + 3] >= 0x80, bytes[index + 3] <= 0xBF else { return false }
            }
            index += needed + 1
        }
        return true
    }

    /// Appends the UTF-8 form of the scalar value `scalar` (which must be a valid Unicode scalar value).
    static func append(scalar: UInt32, to out: inout [UInt8]) {
        switch scalar {
        case 0..<0x80:
            out.append(UInt8(scalar))
        case 0x80..<0x800:
            out.append(UInt8(0xC0 | (scalar >> 6)))
            out.append(UInt8(0x80 | (scalar & 0x3F)))
        case 0x800..<0x10000:
            out.append(UInt8(0xE0 | (scalar >> 12)))
            out.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
            out.append(UInt8(0x80 | (scalar & 0x3F)))
        default:
            out.append(UInt8(0xF0 | (scalar >> 18)))
            out.append(UInt8(0x80 | ((scalar >> 12) & 0x3F)))
            out.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
            out.append(UInt8(0x80 | (scalar & 0x3F)))
        }
    }
}

/// Integers of the format (section 12.7.3), read from a number token.
enum FileV2JSONInteger {

    /// `0`, or an optional minus sign followed by a digit 1 to 9 and zero or more digits 0 to 9, with a magnitude of
    /// at most 2^53 - 1. A fraction, an exponent, a plus sign, a leading zero, `-0`, any non-ASCII digit and a
    /// larger magnitude are not integers of the format (`nil`). Bytes only: the digits are the ASCII characters
    /// 0 to 9, never a Unicode digit.
    static func parse(_ token: [UInt8]) -> Int64? {
        if token == [0x30] { return 0 }
        var index = 0
        var negative = false
        if index < token.count, token[index] == UInt8(ascii: "-") {
            negative = true
            index += 1
        }
        guard index < token.count, token[index] >= UInt8(ascii: "1"), token[index] <= UInt8(ascii: "9") else {
            return nil
        }
        var magnitude: Int64 = 0
        while index < token.count {
            let byte = token[index]
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            let digit = Int64(byte - UInt8(ascii: "0"))
            // magnitude * 10 + digit must stay within 2^53 - 1 (and well before Int64 can overflow).
            if magnitude > (FileV2.maxJSONInteger - digit) / 10 { return nil }
            magnitude = magnitude * 10 + digit
            index += 1
        }
        return negative ? -magnitude : magnitude
    }
}

/// The strict parser of section 12.7.2: the text is valid UTF-8 and shorter than 8192 bytes, exactly one JSON
/// object (RFC 8259, JSON whitespace allowed around it), member names unique at every depth, at most 4 nested
/// containers, no lone surrogate escape. Unknown members are parsed like every other and counted for the size.
struct FileV2JSONParser {

    private let bytes: [UInt8]
    private var position = 0

    /// Parses `bytes` with the profile; the object, or the reason it was rejected.
    static func parse(_ bytes: [UInt8]) -> Result<FileV2JSONObject, FileV2JSONFailure> {
        guard bytes.count < FileV2.maxDescriptorBytes else { return .failure(.tooLarge) }
        guard FileV2UTF8.isValid(bytes) else { return .failure(.invalidUTF8) }
        var parser = FileV2JSONParser(bytes: bytes)
        do {
            parser.skipWhitespace()
            let value = try parser.parseValue(depth: 0)
            parser.skipWhitespace()
            guard parser.position == bytes.count else { return .failure(.syntax) }
            guard case .object(let object) = value else { return .failure(.notAnObject) }
            return .success(object)
        } catch let failure as FileV2JSONFailure {
            return .failure(failure)
        } catch {
            return .failure(.syntax)
        }
    }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    // MARK: Tokens

    private mutating func skipWhitespace() {
        while position < bytes.count {
            switch bytes[position] {
            case 0x20, 0x09, 0x0A, 0x0D: position += 1
            default: return
            }
        }
    }

    /// `depth` is the number of containers open around the value being read.
    private mutating func parseValue(depth: Int) throws -> FileV2JSONValue {
        guard position < bytes.count else { throw FileV2JSONFailure.syntax }
        switch bytes[position] {
        case UInt8(ascii: "{"): return try parseObject(level: depth + 1)
        case UInt8(ascii: "["): return try parseArray(level: depth + 1)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"):
            try consume("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try consume("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try consume("null")
            return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return try parseNumber()
        default:
            throw FileV2JSONFailure.syntax
        }
    }

    private mutating func consume(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard position + expected.count <= bytes.count,
              Array(bytes[position..<position + expected.count]) == expected else { throw FileV2JSONFailure.syntax }
        position += expected.count
    }

    /// One RFC 8259 number token, kept as written. Whether it is an integer of the format is decided by the field
    /// that reads it.
    private mutating func parseNumber() throws -> FileV2JSONValue {
        let start = position
        if bytes[position] == UInt8(ascii: "-") { position += 1 }
        guard position < bytes.count else { throw FileV2JSONFailure.syntax }
        switch bytes[position] {
        case UInt8(ascii: "0"):
            position += 1
        case UInt8(ascii: "1")...UInt8(ascii: "9"):
            while position < bytes.count, isDigit(bytes[position]) { position += 1 }
        default:
            throw FileV2JSONFailure.syntax
        }
        if position < bytes.count, bytes[position] == UInt8(ascii: ".") {
            position += 1
            var digits = 0
            while position < bytes.count, isDigit(bytes[position]) {
                position += 1
                digits += 1
            }
            guard digits > 0 else { throw FileV2JSONFailure.syntax }
        }
        if position < bytes.count, bytes[position] == UInt8(ascii: "e") || bytes[position] == UInt8(ascii: "E") {
            position += 1
            if position < bytes.count, bytes[position] == UInt8(ascii: "+") || bytes[position] == UInt8(ascii: "-") {
                position += 1
            }
            var digits = 0
            while position < bytes.count, isDigit(bytes[position]) {
                position += 1
                digits += 1
            }
            guard digits > 0 else { throw FileV2JSONFailure.syntax }
        }
        return .number(Array(bytes[start..<position]))
    }

    private func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }

    // MARK: Strings

    /// A JSON string. The text was validated as UTF-8 as a whole, so raw bytes are copied; an escape is decoded,
    /// and an escape that denotes a lone surrogate is an error (a library that keeps it and one that replaces it
    /// with U+FFFD would count different UTF-8 lengths).
    private mutating func parseString() throws -> [UInt8] {
        position += 1   // the opening quote
        var out: [UInt8] = []
        while true {
            guard position < bytes.count else { throw FileV2JSONFailure.syntax }
            let byte = bytes[position]
            switch byte {
            case UInt8(ascii: "\""):
                position += 1
                return out
            case UInt8(ascii: "\\"):
                position += 1
                guard position < bytes.count else { throw FileV2JSONFailure.syntax }
                let escape = bytes[position]
                position += 1
                switch escape {
                case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): out.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"): try parseUnicodeEscape(into: &out)
                default: throw FileV2JSONFailure.syntax
                }
            case 0x00..<0x20:
                throw FileV2JSONFailure.syntax      // a raw control character is not allowed inside a string
            default:
                out.append(byte)
                position += 1
            }
        }
    }

    /// Four hex digits at `position` (either case); `nil`, with the position unchanged, if there are not four.
    private mutating func parseHex4() -> UInt32? {
        guard position + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for index in position..<position + 4 {
            let digit: UInt32
            switch bytes[index] {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(bytes[index] - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(bytes[index] - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(bytes[index] - UInt8(ascii: "A")) + 10
            default: return nil
            }
            value = (value << 4) | digit
        }
        position += 4
        return value
    }

    /// The part of a `\uXXXX` escape after the `u`. A high surrogate MUST be followed by a `\uXXXX` low surrogate
    /// (together one scalar); a low surrogate on its own, and a high one that is not followed by a low one, are
    /// rejected.
    private mutating func parseUnicodeEscape(into out: inout [UInt8]) throws {
        guard let unit = parseHex4() else { throw FileV2JSONFailure.syntax }
        switch unit {
        case 0xD800...0xDBFF:
            guard position + 2 <= bytes.count, bytes[position] == UInt8(ascii: "\\"),
                  bytes[position + 1] == UInt8(ascii: "u") else { throw FileV2JSONFailure.loneSurrogate }
            position += 2
            guard let low = parseHex4(), low >= 0xDC00, low <= 0xDFFF else { throw FileV2JSONFailure.loneSurrogate }
            FileV2UTF8.append(scalar: 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00), to: &out)
        case 0xDC00...0xDFFF:
            throw FileV2JSONFailure.loneSurrogate
        default:
            FileV2UTF8.append(scalar: unit, to: &out)
        }
    }

    // MARK: Containers

    private mutating func parseArray(level: Int) throws -> FileV2JSONValue {
        guard level <= FileV2.maxDescriptorDepth else { throw FileV2JSONFailure.depth }
        position += 1   // [
        var items: [FileV2JSONValue] = []
        skipWhitespace()
        if position < bytes.count, bytes[position] == UInt8(ascii: "]") {
            position += 1
            return .array(items)
        }
        while true {
            skipWhitespace()
            items.append(try parseValue(depth: level))
            skipWhitespace()
            guard position < bytes.count else { throw FileV2JSONFailure.syntax }
            switch bytes[position] {
            case UInt8(ascii: ","): position += 1
            case UInt8(ascii: "]"):
                position += 1
                return .array(items)
            default: throw FileV2JSONFailure.syntax
            }
        }
    }

    private mutating func parseObject(level: Int) throws -> FileV2JSONValue {
        guard level <= FileV2.maxDescriptorDepth else { throw FileV2JSONFailure.depth }
        position += 1   // {
        var object = FileV2JSONObject()
        var seen = Set<[UInt8]>()
        skipWhitespace()
        if position < bytes.count, bytes[position] == UInt8(ascii: "}") {
            position += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") else { throw FileV2JSONFailure.syntax }
            let name = try parseString()
            // Names are byte strings of valid UTF-8, so equal bytes are equal code point sequences and different
            // bytes are different names: no normalisation, no case folding.
            guard seen.insert(name).inserted else { throw FileV2JSONFailure.duplicateMember }
            skipWhitespace()
            guard position < bytes.count, bytes[position] == UInt8(ascii: ":") else { throw FileV2JSONFailure.syntax }
            position += 1
            skipWhitespace()
            let value = try parseValue(depth: level)
            object.members.append(FileV2JSONObject.Member(name: name, value: value))
            skipWhitespace()
            guard position < bytes.count else { throw FileV2JSONFailure.syntax }
            switch bytes[position] {
            case UInt8(ascii: ","): position += 1
            case UInt8(ascii: "}"):
                position += 1
                return .object(object)
            default: throw FileV2JSONFailure.syntax
            }
        }
    }
}

/// Standard base64 (RFC 4648 section 4) in the canonical form of section 12.7.3: the alphabet `A-Za-z0-9+/`, the
/// mandatory `=` padding, no CR, LF or other whitespace, no URL-safe character, no missing or surplus padding, and
/// zero in the unused trailing bits of the last character. One byte string has exactly one accepted text.
enum FileV2Base64 {

    static func decode(_ text: String) -> Data? { decode(Array(text.utf8)) }

    static func decode(_ input: [UInt8]) -> Data? {
        guard input.count % 4 == 0 else { return nil }
        var output = [UInt8]()
        output.reserveCapacity(input.count / 4 * 3)
        var index = 0
        while index < input.count {
            let isLastGroup = index + 4 == input.count
            var values = [UInt8](repeating: 0, count: 4)
            var padding = 0
            for offset in 0..<4 {
                let character = input[index + offset]
                if character == UInt8(ascii: "=") {
                    guard isLastGroup, offset >= 2 else { return nil }
                    padding += 1
                } else {
                    guard padding == 0, let value = sextet(character) else { return nil }
                    values[offset] = value
                }
            }
            // Canonical: the bits that do not belong to a byte are zero ("Zh==" and "Zm9=" decode like "Zg==" and
            // "Zm8=" under a lenient decoder, but they are another text for the same bytes).
            if padding == 2 && values[1] & 0x0F != 0 { return nil }
            if padding == 1 && values[2] & 0x03 != 0 { return nil }
            let produced = 3 - padding
            let combined = (UInt32(values[0]) << 18) | (UInt32(values[1]) << 12)
                | (UInt32(values[2]) << 6) | UInt32(values[3])
            output.append(UInt8(truncatingIfNeeded: combined >> 16))
            if produced > 1 { output.append(UInt8(truncatingIfNeeded: combined >> 8)) }
            if produced > 2 { output.append(UInt8(truncatingIfNeeded: combined)) }
            index += 4
        }
        return Data(output)
    }

    /// The canonical text of `data`: standard alphabet, `=` padding, no line breaks.
    static func encode(_ data: Data) -> String { data.base64EncodedString() }

    private static func sextet(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return character - UInt8(ascii: "A")
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return character - UInt8(ascii: "a") + 26
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return character - UInt8(ascii: "0") + 52
        case UInt8(ascii: "+"): return 62
        case UInt8(ascii: "/"): return 63
        default: return nil
        }
    }
}
