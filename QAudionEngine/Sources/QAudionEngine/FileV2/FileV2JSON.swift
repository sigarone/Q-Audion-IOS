import Foundation

/// A parsed JSON value. Integers are kept apart from every other number, because the descriptor's numeric
/// fields are integers on the wire and `1.0`, `1e3` or `true` must never pass for one.
enum FileV2JSONValue: Equatable {
    case null
    case bool(Bool)
    /// A number token with no fraction and no exponent that fits `Int64`.
    case int(Int64)
    /// Any other number token (a fraction, an exponent, or an integer beyond `Int64`).
    case number
    case string(String)
    case array([FileV2JSONValue])
    case object([String: FileV2JSONValue])
}

/// A strict RFC 8259 parser, written for the descriptor so its behaviour is the same on every Foundation:
/// UTF-8 text only, one top-level value and nothing after it, no comments, no trailing commas, no leading
/// zeros, no control characters inside strings, a depth limit. A repeated object key keeps its last value.
/// An invalid escape or a lone surrogate in a string decodes to U+FFFD for the surrogate (the behaviour
/// of the reference receiver); an unknown escape is an error.
struct FileV2JSONParser {
    static let maxDepth = 32

    private let bytes: [UInt8]
    private var position = 0

    /// Parses one JSON document; `nil` for anything that is not valid JSON.
    static func parse(_ data: Data) -> FileV2JSONValue? {
        var parser = FileV2JSONParser(bytes: [UInt8](data))
        return parser.parseDocument()
    }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    private mutating func parseDocument() -> FileV2JSONValue? {
        skipWhitespace()
        guard let value = parseValue(depth: 0) else { return nil }
        skipWhitespace()
        return position == bytes.count ? value : nil
    }

    private mutating func skipWhitespace() {
        while position < bytes.count {
            switch bytes[position] {
            case 0x20, 0x09, 0x0A, 0x0D: position += 1
            default: return
            }
        }
    }

    private mutating func parseValue(depth: Int) -> FileV2JSONValue? {
        guard position < bytes.count, depth <= Self.maxDepth else { return nil }
        switch bytes[position] {
        case UInt8(ascii: "{"): return parseObject(depth: depth)
        case UInt8(ascii: "["): return parseArray(depth: depth)
        case UInt8(ascii: "\""):
            guard let text = parseString() else { return nil }
            return .string(text)
        case UInt8(ascii: "t"): return consumeLiteral("true") ? .bool(true) : nil
        case UInt8(ascii: "f"): return consumeLiteral("false") ? .bool(false) : nil
        case UInt8(ascii: "n"): return consumeLiteral("null") ? .null : nil
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return parseNumber()
        default: return nil
        }
    }

    private mutating func consumeLiteral(_ literal: String) -> Bool {
        let expected = Array(literal.utf8)
        guard position + expected.count <= bytes.count,
              Array(bytes[position..<position + expected.count]) == expected else { return false }
        position += expected.count
        return true
    }

    private mutating func parseObject(depth: Int) -> FileV2JSONValue? {
        position += 1   // {
        var members: [String: FileV2JSONValue] = [:]
        skipWhitespace()
        if position < bytes.count, bytes[position] == UInt8(ascii: "}") {
            position += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard position < bytes.count, bytes[position] == UInt8(ascii: "\""),
                  let key = parseString() else { return nil }
            skipWhitespace()
            guard position < bytes.count, bytes[position] == UInt8(ascii: ":") else { return nil }
            position += 1
            skipWhitespace()
            guard let value = parseValue(depth: depth + 1) else { return nil }
            members[key] = value
            skipWhitespace()
            guard position < bytes.count else { return nil }
            if bytes[position] == UInt8(ascii: ",") { position += 1; continue }
            if bytes[position] == UInt8(ascii: "}") { position += 1; return .object(members) }
            return nil
        }
    }

    private mutating func parseArray(depth: Int) -> FileV2JSONValue? {
        position += 1   // [
        var items: [FileV2JSONValue] = []
        skipWhitespace()
        if position < bytes.count, bytes[position] == UInt8(ascii: "]") {
            position += 1
            return .array(items)
        }
        while true {
            skipWhitespace()
            guard let value = parseValue(depth: depth + 1) else { return nil }
            items.append(value)
            skipWhitespace()
            guard position < bytes.count else { return nil }
            if bytes[position] == UInt8(ascii: ",") { position += 1; continue }
            if bytes[position] == UInt8(ascii: "]") { position += 1; return .array(items) }
            return nil
        }
    }

    private mutating func parseNumber() -> FileV2JSONValue? {
        let start = position
        var negative = false
        if bytes[position] == UInt8(ascii: "-") { negative = true; position += 1 }
        guard position < bytes.count, isDigit(bytes[position]) else { return nil }
        if bytes[position] == UInt8(ascii: "0") {
            position += 1
            // no leading zeros: "01" is invalid
            if position < bytes.count, isDigit(bytes[position]) { return nil }
        } else {
            while position < bytes.count, isDigit(bytes[position]) { position += 1 }
        }
        let digitsEnd = position
        var isInteger = true
        if position < bytes.count, bytes[position] == UInt8(ascii: ".") {
            isInteger = false
            position += 1
            guard position < bytes.count, isDigit(bytes[position]) else { return nil }
            while position < bytes.count, isDigit(bytes[position]) { position += 1 }
        }
        if position < bytes.count, bytes[position] == UInt8(ascii: "e") || bytes[position] == UInt8(ascii: "E") {
            isInteger = false
            position += 1
            if position < bytes.count, bytes[position] == UInt8(ascii: "+") || bytes[position] == UInt8(ascii: "-") {
                position += 1
            }
            guard position < bytes.count, isDigit(bytes[position]) else { return nil }
            while position < bytes.count, isDigit(bytes[position]) { position += 1 }
        }
        guard isInteger else { return .number }
        // integer token: digits only, between `start` (+ sign) and `digitsEnd`
        var magnitude: UInt64 = 0
        let firstDigit = negative ? start + 1 : start
        for index in firstDigit..<digitsEnd {
            let (times, overflowMul) = magnitude.multipliedReportingOverflow(by: 10)
            let (sum, overflowAdd) = times.addingReportingOverflow(UInt64(bytes[index] - UInt8(ascii: "0")))
            if overflowMul || overflowAdd { return .number }
            magnitude = sum
        }
        if negative {
            if magnitude <= UInt64(Int64.max) { return .int(-Int64(magnitude)) }
            if magnitude == UInt64(Int64.max) + 1 { return .int(Int64.min) }
            return .number
        }
        return magnitude <= UInt64(Int64.max) ? .int(Int64(magnitude)) : .number
    }

    private func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }

    private mutating func parseString() -> String? {
        position += 1   // opening quote
        var buffer: [UInt8] = []
        while position < bytes.count {
            let byte = bytes[position]
            switch byte {
            case UInt8(ascii: "\""):
                position += 1
                return String(decoding: buffer, as: UTF8.self)
            case UInt8(ascii: "\\"):
                position += 1
                guard position < bytes.count else { return nil }
                let escape = bytes[position]
                position += 1
                switch escape {
                case UInt8(ascii: "\""): buffer.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): buffer.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): buffer.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    guard let unit = parseHex4() else { return nil }
                    appendUnicodeEscape(unit, to: &buffer)
                default: return nil
                }
            case 0x00..<0x20:
                return nil          // raw control characters are not allowed inside a string
            default:
                buffer.append(byte)
                position += 1
            }
        }
        return nil                  // unterminated string
    }

    private mutating func parseHex4() -> UInt32? {
        guard position + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for index in position..<position + 4 {
            guard let digit = hexValue(bytes[index]) else { return nil }
            value = (value << 4) | UInt32(digit)
        }
        position += 4
        return value
    }

    private func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// A `\uXXXX` escape. A high surrogate followed by a `\uXXXX` low surrogate is one scalar; a lone
    /// surrogate becomes U+FFFD.
    private mutating func appendUnicodeEscape(_ unit: UInt32, to buffer: inout [UInt8]) {
        var scalarValue = unit
        if (0xD800...0xDBFF).contains(unit) {
            let saved = position
            if position + 2 <= bytes.count, bytes[position] == UInt8(ascii: "\\"),
               bytes[position + 1] == UInt8(ascii: "u") {
                position += 2
                if let low = parseHex4(), (0xDC00...0xDFFF).contains(low) {
                    scalarValue = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                } else {
                    position = saved
                    scalarValue = 0xFFFD
                }
            } else {
                scalarValue = 0xFFFD
            }
        } else if (0xDC00...0xDFFF).contains(unit) {
            scalarValue = 0xFFFD
        }
        let scalar = Unicode.Scalar(scalarValue) ?? "\u{FFFD}"
        buffer.append(contentsOf: Array(String(Character(scalar)).utf8))
    }
}

/// Standard base64 (RFC 4648 section 4), strict: the alphabet `A-Za-z0-9+/`, `=` padding to a multiple of
/// four, nothing else (no whitespace, no line breaks, no URL alphabet).
enum FileV2Base64 {
    static func decode(_ text: String) -> Data? {
        let input = Array(text.utf8)
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
