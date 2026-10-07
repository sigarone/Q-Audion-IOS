import XCTest
import CryptoKit
@testable import QAudionEngine

/// Helpers shared by the tests of the file transfer v2 server layer.
enum XferSupport {

    // MARK: Hashing and encoding

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(data.count * 2)
        for byte in data {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func sha256Hex(_ data: Data) -> String { hex(sha256(data)) }

    /// Standard base64 (RFC 4648 section 4), padding required, `\r` and `\n` ignored, anything else outside the alphabet
    /// refused; the unused bits of the last character are not checked. The behaviour of the server's decoder.
    static func base64Decode(_ text: String) -> Data? {
        var symbols = [UInt8]()
        for byte in text.utf8 where byte != 0x0A && byte != 0x0D { symbols.append(byte) }
        guard symbols.count % 4 == 0 else { return nil }
        func value(_ byte: UInt8) -> UInt32? {
            switch byte {
            case 0x41...0x5A: return UInt32(byte - 0x41)
            case 0x61...0x7A: return UInt32(byte - 0x61 + 26)
            case 0x30...0x39: return UInt32(byte - 0x30 + 52)
            case 0x2B: return 62
            case 0x2F: return 63
            default: return nil
            }
        }
        var out = [UInt8]()
        var index = 0
        while index < symbols.count {
            let last = index + 4 == symbols.count
            var padding = 0
            var group: UInt32 = 0
            for offset in 0..<4 {
                let byte = symbols[index + offset]
                if byte == 0x3D {
                    guard last, offset >= 2 else { return nil }
                    padding += 1
                } else {
                    guard padding == 0, let digit = value(byte) else { return nil }
                    group = group << 6 | digit
                    continue
                }
            }
            switch padding {
            case 0:
                out.append(UInt8(group >> 16 & 0xFF))
                out.append(UInt8(group >> 8 & 0xFF))
                out.append(UInt8(group & 0xFF))
            case 1:
                out.append(UInt8(group >> 10 & 0xFF))
                out.append(UInt8(group >> 2 & 0xFF))
            default:
                out.append(UInt8(group >> 4 & 0xFF))
            }
            index += 4
        }
        return Data(out)
    }

    static func base64(_ data: Data) -> String { data.base64EncodedString() }
}

/// A clock the test moves by hand: the wall clock (epoch milliseconds) and the monotonic one, which are two different
/// readings of the same time passing until the test sets the wall clock by hand.
final class XferManualClock: FileV2Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var now: Int64
    private var monotonic: Int64

    init(startMs: Int64 = 1_700_000_000_000, monotonicStartMs: Int64 = 5_000) {
        now = startMs
        monotonic = monotonicStartMs
    }

    func nowMs() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return now
    }

    func monotonicMs() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return monotonic
    }

    /// Time passes: both clocks move forward.
    func advance(ms: Int64) {
        lock.lock()
        now += ms
        monotonic += ms
        lock.unlock()
    }

    /// The wall clock is set by hand, back or forward (a user, the network time service): the monotonic clock does not
    /// notice.
    func stepWall(byMs ms: Int64) {
        lock.lock()
        now += ms
        lock.unlock()
    }
}

/// A user, group or object name compared and hashed as bytes: a `Dictionary` keyed by `String` merges names that
/// Swift calls canonically equivalent, the server does not.
struct XferName: Hashable, Comparable {
    let bytes: [UInt8]

    init(_ text: String) { bytes = Array(text.utf8) }

    var text: String { String(decoding: bytes, as: UTF8.self) }

    static func < (lhs: XferName, rhs: XferName) -> Bool { lhs.bytes.lexicographicallyPrecedes(rhs.bytes) }
}
