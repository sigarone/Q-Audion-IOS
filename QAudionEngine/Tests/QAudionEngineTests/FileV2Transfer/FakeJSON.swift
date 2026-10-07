import Foundation

/// A small JSON value for the tests of the transfer layer: the transcript, the bodies the fake receives and the answers it
/// gives. It exists (instead of `JSONSerialization`) for three reasons: an integer stays an exact 64-bit integer, an object
/// keeps its members in document order, and nothing here compares text with `String ==` where bytes are meant (a `Dictionary`
/// keyed by `String` would merge two keys that Swift calls canonically equivalent).
enum FakeJSON: Equatable {
    struct Member: Equatable {
        let key: String
        let value: FakeJSON
    }

    case null
    case bool(Bool)
    /// A number written as an integer that fits an `Int64`.
    case int(Int64)
    /// Any other number, as written (a fraction, an exponent, an integer too large for `Int64`).
    case number(String)
    case string(String)
    case array([FakeJSON])
    case object([Member])

    // MARK: Access

    /// The value of the member called `key` (compared as UTF-8 bytes); the last one wins when a name repeats, as in
    /// the standard decoders.
    func member(_ key: String) -> FakeJSON? {
        guard case .object(let members) = self else { return nil }
        let wanted = Array(key.utf8)
        for member in members.reversed() where Array(member.key.utf8) == wanted { return member.value }
        return nil
    }

    var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    var intValue: Int64? {
        if case .int(let number) = self { return number }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let flag) = self { return flag }
        return nil
    }

    var arrayValue: [FakeJSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var objectMembers: [Member]? {
        if case .object(let members) = self { return members }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// A scalar as the text a placeholder or a header takes: a string as is, an integer in decimal.
    var scalarText: String? {
        switch self {
        case .string(let text): return text
        case .int(let number): return String(number)
        case .number(let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        default: return nil
        }
    }

    static func obj(_ pairs: [(String, FakeJSON)]) -> FakeJSON {
        .object(pairs.map { Member(key: $0.0, value: $0.1) })
    }

    // MARK: Serialisation

    /// Compact UTF-8 text.
    func serialized() -> Data {
        var out = [UInt8]()
        write(into: &out)
        return Data(out)
    }

    private func write(into out: inout [UInt8]) {
        switch self {
        case .null: out.append(contentsOf: Array("null".utf8))
        case .bool(let flag): out.append(contentsOf: Array((flag ? "true" : "false").utf8))
        case .int(let number): out.append(contentsOf: Array(String(number).utf8))
        case .number(let text): out.append(contentsOf: Array(text.utf8))
        case .string(let text): FakeJSON.writeString(text, into: &out)
        case .array(let items):
            out.append(0x5B)
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(0x2C) }
                item.write(into: &out)
            }
            out.append(0x5D)
        case .object(let members):
            out.append(0x7B)
            for (index, member) in members.enumerated() {
                if index > 0 { out.append(0x2C) }
                FakeJSON.writeString(member.key, into: &out)
                out.append(0x3A)
                member.value.write(into: &out)
            }
            out.append(0x7D)
        }
    }

    private static func writeString(_ text: String, into out: inout [UInt8]) {
        out.append(0x22)
        for byte in text.utf8 {
            switch byte {
            case 0x22: out.append(contentsOf: [0x5C, 0x22])
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
            case 0x00..<0x20:
                let hex = Array("0123456789abcdef".utf8)
                out.append(contentsOf: Array("\\u00".utf8))
                out.append(hex[Int(byte >> 4)])
                out.append(hex[Int(byte & 0x0F)])
            default: out.append(byte)
            }
        }
        out.append(0x22)
    }

    // MARK: Parsing

    enum ParseFailure: Error, Equatable {
        case syntax
        case depth
    }

    /// The whole document: one value, then only whitespace.
    static func parse(_ bytes: [UInt8]) throws -> FakeJSON {
        let (value, end) = try parseFirstValue(bytes)
        var index = end
        while index < bytes.count, isSpace(bytes[index]) { index += 1 }
        guard index == bytes.count else { throw ParseFailure.syntax }
        return value
    }

    static func parse(_ data: Data) throws -> FakeJSON { try parse(Array(data)) }

    /// The first value of `bytes` and the offset just after it (what a streaming decoder reads first). Leading whitespace is
    /// skipped; an empty input or anything that is not a value is `syntax`.
    static func parseFirstValue(_ bytes: [UInt8]) throws -> (FakeJSON, Int) {
        var parser = Parser(bytes: bytes)
        parser.skipSpace()
        let value = try parser.value(depth: 0)
        return (value, parser.position)
    }

    fileprivate static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private struct Parser {
        let bytes: [UInt8]
        var position = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipSpace() {
            while position < bytes.count, FakeJSON.isSpace(bytes[position]) { position += 1 }
        }

        mutating func value(depth: Int) throws -> FakeJSON {
            guard depth < 200 else { throw ParseFailure.depth }
            guard position < bytes.count else { throw ParseFailure.syntax }
            switch bytes[position] {
            case 0x7B: return try object(depth: depth)
            case 0x5B: return try array(depth: depth)
            case 0x22: return .string(try string())
            case 0x74: try literal("true"); return .bool(true)
            case 0x66: try literal("false"); return .bool(false)
            case 0x6E: try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ text: String) throws {
            let wanted = Array(text.utf8)
            guard position + wanted.count <= bytes.count, Array(bytes[position..<position + wanted.count]) == wanted else {
                throw ParseFailure.syntax
            }
            position += wanted.count
        }

        mutating func object(depth: Int) throws -> FakeJSON {
            position += 1
            var members = [Member]()
            skipSpace()
            if position < bytes.count, bytes[position] == 0x7D {
                position += 1
                return .object(members)
            }
            while true {
                skipSpace()
                guard position < bytes.count, bytes[position] == 0x22 else { throw ParseFailure.syntax }
                let key = try string()
                skipSpace()
                guard position < bytes.count, bytes[position] == 0x3A else { throw ParseFailure.syntax }
                position += 1
                skipSpace()
                let member = try value(depth: depth + 1)
                members.append(Member(key: key, value: member))
                skipSpace()
                guard position < bytes.count else { throw ParseFailure.syntax }
                if bytes[position] == 0x2C {
                    position += 1
                    continue
                }
                guard bytes[position] == 0x7D else { throw ParseFailure.syntax }
                position += 1
                return .object(members)
            }
        }

        mutating func array(depth: Int) throws -> FakeJSON {
            position += 1
            var items = [FakeJSON]()
            skipSpace()
            if position < bytes.count, bytes[position] == 0x5D {
                position += 1
                return .array(items)
            }
            while true {
                skipSpace()
                items.append(try value(depth: depth + 1))
                skipSpace()
                guard position < bytes.count else { throw ParseFailure.syntax }
                if bytes[position] == 0x2C {
                    position += 1
                    continue
                }
                guard bytes[position] == 0x5D else { throw ParseFailure.syntax }
                position += 1
                return .array(items)
            }
        }

        mutating func string() throws -> String {
            position += 1
            var out = [UInt8]()
            while true {
                guard position < bytes.count else { throw ParseFailure.syntax }
                let byte = bytes[position]
                position += 1
                switch byte {
                case 0x22:
                    return String(decoding: out, as: UTF8.self)
                case 0x5C:
                    guard position < bytes.count else { throw ParseFailure.syntax }
                    let escape = bytes[position]
                    position += 1
                    switch escape {
                    case 0x22, 0x5C, 0x2F: out.append(escape)
                    case 0x62: out.append(0x08)
                    case 0x66: out.append(0x0C)
                    case 0x6E: out.append(0x0A)
                    case 0x72: out.append(0x0D)
                    case 0x74: out.append(0x09)
                    case 0x75: try unicodeEscape(into: &out)
                    default: throw ParseFailure.syntax
                    }
                case 0x00..<0x20:
                    throw ParseFailure.syntax
                default:
                    out.append(byte)
                }
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard position + 4 <= bytes.count else { throw ParseFailure.syntax }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[position]
                position += 1
                let digit: UInt32
                switch byte {
                case 0x30...0x39: digit = UInt32(byte - 0x30)
                case 0x61...0x66: digit = UInt32(byte - 0x61 + 10)
                case 0x41...0x46: digit = UInt32(byte - 0x41 + 10)
                default: throw ParseFailure.syntax
                }
                value = value * 16 + digit
            }
            return value
        }

        mutating func unicodeEscape(into out: inout [UInt8]) throws {
            var scalar = try hex4()
            if scalar >= 0xD800 && scalar < 0xDC00 {
                // a high surrogate must be followed by `\u` and a low one; anything else is the replacement character
                if position + 1 < bytes.count, bytes[position] == 0x5C, bytes[position + 1] == 0x75 {
                    let saved = position
                    position += 2
                    let low = try hex4()
                    if low >= 0xDC00 && low < 0xE000 {
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        position = saved
                        scalar = 0xFFFD
                    }
                } else {
                    scalar = 0xFFFD
                }
            } else if scalar >= 0xDC00 && scalar < 0xE000 {
                scalar = 0xFFFD
            }
            guard let valid = Unicode.Scalar(scalar) else { throw ParseFailure.syntax }
            out.append(contentsOf: Array(String(Character(valid)).utf8))
        }

        mutating func number() throws -> FakeJSON {
            let start = position
            if position < bytes.count, bytes[position] == 0x2D { position += 1 }
            guard position < bytes.count else { throw ParseFailure.syntax }
            if bytes[position] == 0x30 {
                position += 1
            } else if bytes[position] >= 0x31 && bytes[position] <= 0x39 {
                while position < bytes.count, bytes[position] >= 0x30 && bytes[position] <= 0x39 { position += 1 }
            } else {
                throw ParseFailure.syntax
            }
            var integral = true
            if position < bytes.count, bytes[position] == 0x2E {
                integral = false
                position += 1
                let digits = position
                while position < bytes.count, bytes[position] >= 0x30 && bytes[position] <= 0x39 { position += 1 }
                guard position > digits else { throw ParseFailure.syntax }
            }
            if position < bytes.count, bytes[position] == 0x65 || bytes[position] == 0x45 {
                integral = false
                position += 1
                if position < bytes.count, bytes[position] == 0x2B || bytes[position] == 0x2D { position += 1 }
                let digits = position
                while position < bytes.count, bytes[position] >= 0x30 && bytes[position] <= 0x39 { position += 1 }
                guard position > digits else { throw ParseFailure.syntax }
            }
            let text = String(decoding: bytes[start..<position], as: UTF8.self)
            if integral, let number = Int64(text) { return .int(number) }
            return .number(text)
        }
    }
}
