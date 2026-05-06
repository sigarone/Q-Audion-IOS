import Foundation

/// Canonical CBOR encoder (RFC 8949 §4.2, restricted profile).
///
/// **Purpose:** Q-Audion v3.1 messaging wire format (Android
/// `MessageRatchet.kt`) uses canonical CBOR for both:
///  - per-message AAD: `{"m": clientMsgId, "r": recipientId,
///                       "s": senderId, "v": 3}`
///  - HKDF init `info`: `["v3", direction, lo, hi]`
///
/// Any CBOR byte mismatch breaks AEAD decryption silently, so this
/// encoder must be byte-identical to:
///  - `qaudion-android-new/.../MessageRatchet.kt::CanonicalCbor`
///  - `qaudion-desktop/scripts/ratchet-kat-dump.mjs` (the Node oracle)
///
/// **Restricted profile** — covers v3.1 needs only:
///  - positive integers in [0, 2^32 − 1]      (major type 0)
///  - byte strings                            (major type 2)
///  - text strings (UTF-8)                    (major type 3)
///  - arrays                                  (major type 4)
///  - maps with text-string keys              (major type 5)
///
/// **Canonical rules enforced:**
///  - smallest possible head encoding
///  - definite-length only (no streaming)
///  - map keys sorted by length-then-bytewise-lex on UTF-8
///
/// Floats / tags / negative ints / bool / null are deliberately rejected.
public enum CanonicalCbor {

    /// Tag wrapper for byte strings — `Data` would otherwise be ambiguous
    /// against a `[UInt8]` array. Pass this when you need a CBOR
    /// byte-string (major type 2) instead of an array of integers.
    public struct Bytes: Equatable {
        public let data: Data
        public init(_ data: Data) { self.data = data }
    }

    public enum Value: Equatable {
        case uint(UInt64)
        case text(String)
        case bytes(Data)
        case array([Value])
        case map([(String, Value)])

        public static func == (lhs: Value, rhs: Value) -> Bool {
            switch (lhs, rhs) {
            case (.uint(let a), .uint(let b)): return a == b
            case (.text(let a), .text(let b)): return a == b
            case (.bytes(let a), .bytes(let b)): return a == b
            case (.array(let a), .array(let b)): return a == b
            case (.map(let a), .map(let b)):
                guard a.count == b.count else { return false }
                for (i, e) in a.enumerated() {
                    if e.0 != b[i].0 || e.1 != b[i].1 { return false }
                }
                return true
            default: return false
            }
        }
    }

    public enum CborError: Error, Equatable {
        case unsupportedType(String)
        case negativeInt(Int64)
        case intTooLarge(UInt64)
        case nonStringMapKey
    }

    // MARK: - Public API

    /// Encode a `Value` tree.
    public static func encode(_ value: Value) -> Data {
        switch value {
        case .uint(let n):  return encodeUint(n)
        case .text(let s):  return encodeText(s)
        case .bytes(let b): return encodeBytes(b)
        case .array(let a): return encodeArray(a)
        case .map(let m):   return encodeMap(m)
        }
    }

    /// Convenience — encode a heterogeneous Swift array (Int / UInt / String /
    /// Data / Bytes / [Any] / [String:Any]) by mapping to the typed `Value`.
    /// Throws on unsupported types so callers learn at compile-time-ish
    /// when they pass something the encoder can't handle.
    public static func encodeAny(_ value: Any) throws -> Data {
        return encode(try toValue(value))
    }

    /// Build the v3.1 messaging AAD:
    ///   `{"m": clientMsgId, "r": recipientId, "s": senderId, "v": 3}`
    /// Insertion order is irrelevant — the encoder sorts canonically.
    public static func buildMessageAD(
        senderId: String, recipientId: String, clientMsgId: String
    ) -> Data {
        return encode(.map([
            ("m", .text(clientMsgId)),
            ("r", .text(recipientId)),
            ("s", .text(senderId)),
            ("v", .uint(3)),
        ]))
    }

    /// Build the v3.1 HKDF init `info` array:
    ///   `["v3", direction, lo, hi]` where direction is "lo->hi" or "hi->lo".
    public static func buildInitInfo(direction: String, lo: String, hi: String) -> Data {
        return encode(.array([.text("v3"), .text(direction), .text(lo), .text(hi)]))
    }

    // MARK: - Encoders

    private static func encodeUint(_ n: UInt64) -> Data {
        return head(majorType: 0, arg: n)
    }

    private static func encodeText(_ s: String) -> Data {
        let utf8 = Data(s.utf8)
        var out = head(majorType: 3, arg: UInt64(utf8.count))
        out.append(utf8)
        return out
    }

    private static func encodeBytes(_ b: Data) -> Data {
        var out = head(majorType: 2, arg: UInt64(b.count))
        out.append(b)
        return out
    }

    private static func encodeArray(_ items: [Value]) -> Data {
        var out = head(majorType: 4, arg: UInt64(items.count))
        for v in items { out.append(encode(v)) }
        return out
    }

    private static func encodeMap(_ entries: [(String, Value)]) -> Data {
        // Sort by UTF-8 byte length first, then bytewise-lex (unsigned).
        let sortedEntries: [(Data, Value)] = entries
            .map { (Data($0.0.utf8), $0.1) }
            .sorted { lhs, rhs in
                if lhs.0.count != rhs.0.count { return lhs.0.count < rhs.0.count }
                return compareBytewiseUnsigned(lhs.0, rhs.0) < 0
            }
        var out = head(majorType: 5, arg: UInt64(sortedEntries.count))
        for (kBytes, v) in sortedEntries {
            out.append(head(majorType: 3, arg: UInt64(kBytes.count)))
            out.append(kBytes)
            out.append(encode(v))
        }
        return out
    }

    /// Encode (major type, argument) head with the smallest possible
    /// representation per RFC 8949 §4.2:
    ///   arg ∈ [0..23]           → 1 byte   `mt<<5 | arg`
    ///   arg ∈ [24..255]         → 2 bytes  `mt<<5 | 24, arg`
    ///   arg ∈ [256..65535]      → 3 bytes  `mt<<5 | 25, arg as uint16 BE`
    ///   arg ∈ [65536..2^32-1]   → 5 bytes  `mt<<5 | 26, arg as uint32 BE`
    private static func head(majorType: UInt8, arg: UInt64) -> Data {
        precondition(arg <= 0xFFFFFFFF, "cbor head arg too large: \(arg)")
        let mt = UInt8((majorType & 0x07) << 5)
        if arg <= 23 {
            return Data([mt | UInt8(arg)])
        } else if arg <= 0xFF {
            return Data([mt | 24, UInt8(arg)])
        } else if arg <= 0xFFFF {
            return Data([
                mt | 25,
                UInt8((arg >> 8) & 0xFF),
                UInt8(arg & 0xFF),
            ])
        } else {
            return Data([
                mt | 26,
                UInt8((arg >> 24) & 0xFF),
                UInt8((arg >> 16) & 0xFF),
                UInt8((arg >> 8) & 0xFF),
                UInt8(arg & 0xFF),
            ])
        }
    }

    private static func compareBytewiseUnsigned(_ a: Data, _ b: Data) -> Int {
        let lim = min(a.count, b.count)
        for i in 0..<lim {
            let av = Int(a[a.startIndex + i])
            let bv = Int(b[b.startIndex + i])
            if av != bv { return av - bv }
        }
        return a.count - b.count
    }

    private static func toValue(_ any: Any) throws -> Value {
        switch any {
        case let n as Int:
            if n < 0 { throw CborError.negativeInt(Int64(n)) }
            return .uint(UInt64(n))
        case let n as Int64:
            if n < 0 { throw CborError.negativeInt(n) }
            return .uint(UInt64(n))
        case let n as UInt:
            return .uint(UInt64(n))
        case let n as UInt32:
            return .uint(UInt64(n))
        case let n as UInt64:
            if n > 0xFFFFFFFF { throw CborError.intTooLarge(n) }
            return .uint(n)
        case let s as String:
            return .text(s)
        case let b as Bytes:
            return .bytes(b.data)
        case let d as Data:
            return .bytes(d)
        case let a as [Any]:
            return .array(try a.map(toValue))
        case let m as [(String, Any)]:
            return .map(try m.map { (k, v) -> (String, Value) in
                (k, try toValue(v))
            })
        case let m as [String: Any]:
            // Map → Value entries; canonical sort happens at encode time.
            let entries: [(String, Value)] = try m.map { (k, v) in (k, try toValue(v)) }
            return .map(entries)
        default:
            throw CborError.unsupportedType(String(describing: type(of: any)))
        }
    }
}
