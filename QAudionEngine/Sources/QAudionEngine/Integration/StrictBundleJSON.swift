import Foundation

/// A strict RFC 8259 grammar check for the text of a handshake bundle, on UTF-8 bytes, without Foundation JSON.
///
/// Rules (WIRE_SPEC 3.1): whitespace between tokens is space, tab, LF and CR and nothing else; the root is an object and only
/// those four bytes may follow its closing brace; numbers follow `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`; strings carry
/// no raw control byte and only the escapes of the grammar. Nesting is capped and scanned with an explicit stack, so a deeply
/// nested input returns `invalid` instead of exhausting the stack. Duplicate members are not an error here: the member list keeps
/// every top-level member in document order, so a caller that needs "exactly one" can count them itself.
public enum StrictBundleJSON {

    /// One top-level member: the decoded name (UTF-16 units), whether the name holds a lone surrogate escape (it can then never
    /// equal a real name) and the bytes of the value token (no surrounding whitespace).
    public struct Member: Equatable {
        public let nameUnits: [UInt16]
        public let badName: Bool
        public let valueBytes: ArraySlice<UInt8>

        public var name: String { String(decoding: nameUnits, as: UTF16.self) }
    }

    /// Closed set of failure kinds, numbers only (no text of the input).
    public enum Code: Int, Equatable {
        case notObject = 1
        case syntax = 2
        case number = 3
        case string = 4
        case depth = 5
        case trailing = 6
        case truncated = 7
    }

    public enum Result: Equatable {
        case valid(topLevel: [Member])
        case invalid(code: Code)
    }

    /// Deepest nesting accepted, the root object counting as depth 1.
    public static let maxDepth = 64

    public static func validate(_ text: String) -> Result {
        validate(bytes: Array(text.utf8))
    }

    public static func validate(bytes: [UInt8]) -> Result {
        var scanner = Scanner(bytes)
        return scanner.run()
    }

    // MARK: - Scanner

    private enum Phase {
        case value
        case valueOrEnd
        case afterValue
        case keyOrEnd
        case key
    }

    private struct Scanner {
        let b: [UInt8]
        var i: Int = 0

        init(_ bytes: [UInt8]) {
            self.b = bytes
        }

        var atEnd: Bool { i >= b.count }

        mutating func skipWhitespace() {
            while i < b.count {
                let c = b[i]
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                    i += 1
                } else {
                    return
                }
            }
        }

        private func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

        private func hexValue(_ c: UInt8) -> UInt16? {
            switch c {
            case 0x30...0x39: return UInt16(c - 0x30)
            case 0x41...0x46: return UInt16(c - 0x41 + 10)
            case 0x61...0x66: return UInt16(c - 0x61 + 10)
            default: return nil
            }
        }

        /// `i` is at the opening quote. On success `i` is after the closing quote. `units` are filled only when `collect`.
        mutating func scanString(collect: Bool) -> (units: [UInt16], bad: Bool)? {
            var units: [UInt16] = []
            i += 1
            while true {
                if i >= b.count { return nil }
                let c = b[i]
                if c == 0x22 {
                    i += 1
                    return (units, collect ? Scanner.hasLoneSurrogate(units) : false)
                }
                if c < 0x20 { return nil }
                if c == 0x5C {
                    if i + 1 >= b.count { return nil }
                    let e = b[i + 1]
                    switch e {
                    case 0x22: if collect { units.append(0x22) }; i += 2
                    case 0x5C: if collect { units.append(0x5C) }; i += 2
                    case 0x2F: if collect { units.append(0x2F) }; i += 2
                    case 0x62: if collect { units.append(0x08) }; i += 2
                    case 0x66: if collect { units.append(0x0C) }; i += 2
                    case 0x6E: if collect { units.append(0x0A) }; i += 2
                    case 0x72: if collect { units.append(0x0D) }; i += 2
                    case 0x74: if collect { units.append(0x09) }; i += 2
                    case 0x75:
                        if i + 5 >= b.count { return nil }
                        var value: UInt16 = 0
                        for k in 2...5 {
                            guard let h = hexValue(b[i + k]) else { return nil }
                            value = value &* 16 &+ h
                        }
                        if collect { units.append(value) }
                        i += 6
                    default:
                        return nil
                    }
                    continue
                }
                if c < 0x80 {
                    if collect { units.append(UInt16(c)) }
                    i += 1
                    continue
                }
                // A multi-byte UTF-8 scalar (the text came from a Swift String, so it is well formed).
                var length = 0
                var scalar: UInt32 = 0
                if c & 0xE0 == 0xC0 {
                    length = 2
                    scalar = UInt32(c & 0x1F)
                } else if c & 0xF0 == 0xE0 {
                    length = 3
                    scalar = UInt32(c & 0x0F)
                } else if c & 0xF8 == 0xF0 {
                    length = 4
                    scalar = UInt32(c & 0x07)
                } else {
                    return nil
                }
                if i + length > b.count { return nil }
                for k in 1..<length {
                    let cc = b[i + k]
                    if cc & 0xC0 != 0x80 { return nil }
                    scalar = (scalar << 6) | UInt32(cc & 0x3F)
                }
                if collect {
                    if scalar >= 0x10000 {
                        let v = scalar - 0x10000
                        units.append(UInt16(0xD800 + (v >> 10)))
                        units.append(UInt16(0xDC00 + (v & 0x3FF)))
                    } else {
                        units.append(UInt16(scalar))
                    }
                }
                i += length
            }
        }

        static func hasLoneSurrogate(_ units: [UInt16]) -> Bool {
            var k = 0
            while k < units.count {
                let u = units[k]
                if u >= 0xD800 && u <= 0xDBFF {
                    if k + 1 < units.count, units[k + 1] >= 0xDC00, units[k + 1] <= 0xDFFF {
                        k += 2
                        continue
                    }
                    return true
                }
                if u >= 0xDC00 && u <= 0xDFFF { return true }
                k += 1
            }
            return false
        }

        /// `i` is at `-` or a digit. On success `i` is after the number.
        mutating func scanNumber() -> Bool {
            if b[i] == 0x2D { i += 1 }
            if i >= b.count { return false }
            if b[i] == 0x30 {
                i += 1
            } else if b[i] >= 0x31 && b[i] <= 0x39 {
                while i < b.count && isDigit(b[i]) { i += 1 }
            } else {
                return false
            }
            if i < b.count && b[i] == 0x2E {
                i += 1
                if i >= b.count || !isDigit(b[i]) { return false }
                while i < b.count && isDigit(b[i]) { i += 1 }
            }
            if i < b.count && (b[i] == 0x65 || b[i] == 0x45) {
                i += 1
                if i < b.count && (b[i] == 0x2B || b[i] == 0x2D) { i += 1 }
                if i >= b.count || !isDigit(b[i]) { return false }
                while i < b.count && isDigit(b[i]) { i += 1 }
            }
            return true
        }

        mutating func scanLiteral(_ literal: [UInt8]) -> Bool {
            if i + literal.count > b.count { return false }
            for k in 0..<literal.count where b[i + k] != literal[k] { return false }
            i += literal.count
            return true
        }

        mutating func run() -> Result {
            skipWhitespace()
            if atEnd || b[i] != 0x7B { return .invalid(code: .notObject) }
            var stack: [UInt8] = []
            var members: [Member] = []
            var phase = Phase.value
            var name: [UInt16] = []
            var bad = false
            var valueStart = 0
            while true {
                skipWhitespace()
                if atEnd { return .invalid(code: .truncated) }
                let c = b[i]
                var completed = false
                switch phase {
                case .value, .valueOrEnd:
                    if phase == .valueOrEnd && c == 0x5D {
                        stack.removeLast()
                        i += 1
                        completed = true
                        break
                    }
                    if stack.count == 1 { valueStart = i }
                    switch c {
                    case 0x7B, 0x5B:
                        if stack.count >= StrictBundleJSON.maxDepth { return .invalid(code: .depth) }
                        stack.append(c)
                        i += 1
                        phase = (c == 0x7B) ? .keyOrEnd : .valueOrEnd
                    case 0x22:
                        if scanString(collect: false) == nil { return .invalid(code: .string) }
                        completed = true
                    case 0x2D, 0x30...0x39:
                        if !scanNumber() { return .invalid(code: .number) }
                        completed = true
                    case 0x74:
                        if !scanLiteral([0x74, 0x72, 0x75, 0x65]) { return .invalid(code: .syntax) }
                        completed = true
                    case 0x66:
                        if !scanLiteral([0x66, 0x61, 0x6C, 0x73, 0x65]) { return .invalid(code: .syntax) }
                        completed = true
                    case 0x6E:
                        if !scanLiteral([0x6E, 0x75, 0x6C, 0x6C]) { return .invalid(code: .syntax) }
                        completed = true
                    default:
                        return .invalid(code: .syntax)
                    }
                case .afterValue:
                    let top = stack[stack.count - 1]
                    if c == 0x2C {
                        i += 1
                        phase = (top == 0x7B) ? .key : .value
                    } else if c == 0x7D && top == 0x7B {
                        stack.removeLast()
                        i += 1
                        completed = true
                    } else if c == 0x5D && top == 0x5B {
                        stack.removeLast()
                        i += 1
                        completed = true
                    } else {
                        return .invalid(code: .syntax)
                    }
                case .keyOrEnd, .key:
                    if phase == .keyOrEnd && c == 0x7D {
                        stack.removeLast()
                        i += 1
                        completed = true
                        break
                    }
                    if c != 0x22 { return .invalid(code: .syntax) }
                    guard let key = scanString(collect: stack.count == 1) else { return .invalid(code: .string) }
                    if stack.count == 1 {
                        name = key.units
                        bad = key.bad
                    }
                    skipWhitespace()
                    if atEnd { return .invalid(code: .truncated) }
                    if b[i] != 0x3A { return .invalid(code: .syntax) }
                    i += 1
                    phase = .value
                }
                if completed {
                    if stack.isEmpty { break }
                    if stack.count == 1 {
                        members.append(Member(nameUnits: name, badName: bad, valueBytes: b[valueStart ..< i]))
                    }
                    phase = .afterValue
                }
            }
            skipWhitespace()
            if !atEnd { return .invalid(code: .trailing) }
            return .valid(topLevel: members)
        }
    }
}
