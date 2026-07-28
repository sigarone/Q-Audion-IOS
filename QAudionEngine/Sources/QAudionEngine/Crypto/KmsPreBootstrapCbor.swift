import Foundation

/// Restricted-profile canonical CBOR encoder/decoder used by
/// `KmsPreBootstrap` to (de)serialize the top-level `qa_kms_prebootstrap:1`
/// envelope map.
///
/// Cross-platform contract: byte-for-byte equal to the Kotlin
/// implementation `qaudion-android-new/qaudion-engine/.../crypto/KmsPreBootstrapCbor.kt`
/// (itself byte-equal to the Desktop TypeScript port). Any drift here
/// will break Android/Desktop <-> iOS interop for the ADR-014a
/// KMS-prebootstrap envelope — the KAT JSON at
/// `qaudion-android-new/qaudion-engine/src/test/resources/kms-prebootstrap-kat.json`
/// (vendored into this target's test resources as
/// `Resources/kat/kms-prebootstrap-kat.json`) is the authoritative
/// interop fence — see `KmsPreBootstrapKatTests.swift`.
///
/// Profile (RFC 8949 §4.2.1 deterministic, restricted):
///   - mt 0 — positive integers in `[0, 2^64-1]`
///   - mt 2 — byte strings
///   - mt 3 — text strings (UTF-8)
///   - mt 5 — maps with text-string keys, sorted length-then-bytewise lex
///
/// NOTE: this is a SEPARATE, uint64-capable encoder from
/// `CanonicalCbor.swift` (which caps integers at 2^32-1 — sufficient for
/// the v3.1 messaging AAD it serves, but NOT for this envelope's `ts`
/// field, a Unix-ms timestamp that already exceeds 2^32 today). Do NOT
/// reuse `CanonicalCbor` here and do NOT modify it to widen its range —
/// other cross-platform wire contracts pin its existing 2^32 cap.
public enum KmsPreBootstrapCbor {

    // MARK: - Value model

    /// Decoded/encodable CBOR value restricted to this profile's four
    /// supported shapes.
    public indirect enum Value: Equatable {
        case uint(UInt64)
        case bytes(Data)
        case text(String)
        case map([(String, Value)])

        public static func == (lhs: Value, rhs: Value) -> Bool {
            switch (lhs, rhs) {
            case (.uint(let a), .uint(let b)): return a == b
            case (.bytes(let a), .bytes(let b)): return a == b
            case (.text(let a), .text(let b)): return a == b
            case (.map(let a), .map(let b)):
                guard a.count == b.count else { return false }
                for (i, e) in a.enumerated() where e.0 != b[i].0 || e.1 != b[i].1 { return false }
                return true
            default: return false
            }
        }
    }

    public enum CborError: Error, Equatable {
        case truncated(String)
        case unsupportedMajorType(Int)
        case unsupportedAdditionalInfo(Int)
        case nonStringMapKey
        case lengthOverflow
        case mapEntryCountExceedsBuffer(Int, Int)
        case trailingBytes(consumed: Int, total: Int)
        case notAMap
        case missingKey(String)
        case wrongType(String)
        case malformedUuid(String)
    }

    // MARK: - Encoding

    /// Encode the canonical CBOR head `(majorType, arg)` with the smallest
    /// possible representation per RFC 8949 §4.2.1. `arg` is an unsigned
    /// 64-bit integer (bit pattern preserved).
    static func head(_ majorType: UInt8, _ arg: UInt64) -> Data {
        let mt = (majorType & 0x07) << 5
        if arg < 24 {
            return Data([mt | UInt8(arg)])
        } else if arg <= 0xFF {
            return Data([mt | 24, UInt8(arg)])
        } else if arg <= 0xFFFF {
            return Data([mt | 25, UInt8((arg >> 8) & 0xFF), UInt8(arg & 0xFF)])
        } else if arg <= 0xFFFF_FFFF {
            return Data([
                mt | 26,
                UInt8((arg >> 24) & 0xFF), UInt8((arg >> 16) & 0xFF),
                UInt8((arg >> 8) & 0xFF), UInt8(arg & 0xFF),
            ])
        } else {
            var out = Data([mt | 27])
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((arg >> UInt64(shift)) & 0xFF))
            }
            return out
        }
    }

    static func encodeUint(_ n: UInt64) -> Data { head(0, n) }

    static func encodeBytes(_ b: Data) -> Data {
        var out = head(2, UInt64(b.count))
        out.append(b)
        return out
    }

    static func encodeText(_ s: String) -> Data {
        let utf8 = Data(s.utf8)
        var out = head(3, UInt64(utf8.count))
        out.append(utf8)
        return out
    }

    public static func encode(_ value: Value) -> Data {
        switch value {
        case .uint(let n): return encodeUint(n)
        case .bytes(let b): return encodeBytes(b)
        case .text(let s): return encodeText(s)
        case .map(let m): return encodeMap(m)
        }
    }

    /// Encode a map as a canonical CBOR mt-5 map. Keys are sorted
    /// length-then-bytewise-unsigned-lex on their UTF-8 bytes (RFC 8949
    /// §4.2.1 "length-first" rule) — insertion order of the input array
    /// is irrelevant.
    public static func encodeMap(_ entries: [(String, Value)]) -> Data {
        let sorted: [(Data, Value)] = entries
            .map { (Data($0.0.utf8), $0.1) }
            .sorted { lhs, rhs in
                if lhs.0.count != rhs.0.count { return lhs.0.count < rhs.0.count }
                return compareBytewiseUnsigned(lhs.0, rhs.0) < 0
            }
        var out = head(5, UInt64(sorted.count))
        for (kBytes, v) in sorted {
            out.append(head(3, UInt64(kBytes.count)))
            out.append(kBytes)
            out.append(encode(v))
        }
        return out
    }

    private static func compareBytewiseUnsigned(_ a: Data, _ b: Data) -> Int {
        let lim = min(a.count, b.count)
        let ab = [UInt8](a), bb = [UInt8](b)
        for i in 0..<lim {
            let av = Int(ab[i]), bv = Int(bb[i])
            if av != bv { return av - bv }
        }
        return a.count - b.count
    }

    // MARK: - Decoding

    private struct Decoded {
        let value: Value
        let consumed: Int
    }

    /// Decode a single CBOR item starting at `offset` in `buf`. Returns
    /// the decoded value and the number of bytes consumed.
    public static func decodeItem(_ buf: [UInt8], offset: Int = 0) throws -> (value: Value, consumed: Int) {
        let r = try decode(buf, offset)
        return (r.value, r.consumed)
    }

    private static func decode(_ buf: [UInt8], _ offset: Int) throws -> Decoded {
        guard offset < buf.count else { throw CborError.truncated("empty input at offset=\(offset)") }
        let ib = Int(buf[offset])
        let mt = ib >> 5
        let ai = ib & 0x1F
        var off = offset + 1
        let arg: UInt64
        switch ai {
        case 0...23:
            arg = UInt64(ai)
        case 24:
            guard off + 1 <= buf.count else { throw CborError.truncated("u8") }
            arg = UInt64(buf[off]); off += 1
        case 25:
            guard off + 2 <= buf.count else { throw CborError.truncated("u16") }
            arg = (UInt64(buf[off]) << 8) | UInt64(buf[off + 1]); off += 2
        case 26:
            guard off + 4 <= buf.count else { throw CborError.truncated("u32") }
            arg = (UInt64(buf[off]) << 24) | (UInt64(buf[off + 1]) << 16)
                | (UInt64(buf[off + 2]) << 8) | UInt64(buf[off + 3])
            off += 4
        case 27:
            guard off + 8 <= buf.count else { throw CborError.truncated("u64") }
            var v: UInt64 = 0
            for i in 0..<8 { v = (v << 8) | UInt64(buf[off + i]) }
            arg = v; off += 8
        default:
            throw CborError.unsupportedAdditionalInfo(ai)
        }

        switch mt {
        case 0:
            return Decoded(value: .uint(arg), consumed: off - offset)
        case 2:
            let len = try lengthAsInt(arg)
            guard off + len <= buf.count else { throw CborError.truncated("bytes") }
            let out = Data(buf[off..<(off + len)])
            return Decoded(value: .bytes(out), consumed: off + len - offset)
        case 3:
            let len = try lengthAsInt(arg)
            guard off + len <= buf.count else { throw CborError.truncated("text") }
            guard let text = String(bytes: buf[off..<(off + len)], encoding: .utf8) else {
                throw CborError.truncated("text not utf8")
            }
            return Decoded(value: .text(text), consumed: off + len - offset)
        case 5:
            let n = try lengthAsInt(arg)
            // DoS guard (wire-neutral): a canonical CBOR map with `n`
            // entries needs at least `n` bytes left in the buffer (every
            // key is a definite-length text string >= 1 byte and every
            // value >= 1 byte). Rejects a malicious oversized-count header
            // before any allocation proportional to `n` happens.
            let remaining = buf.count - off
            guard n <= remaining else { throw CborError.mapEntryCountExceedsBuffer(n, remaining) }
            var map: [(String, Value)] = []
            map.reserveCapacity(n)
            var cursor = off
            for _ in 0..<n {
                let kr = try decode(buf, cursor)
                guard case .text(let k) = kr.value else { throw CborError.nonStringMapKey }
                cursor += kr.consumed
                let vr = try decode(buf, cursor)
                cursor += vr.consumed
                map.append((k, vr.value))
            }
            return Decoded(value: .map(map), consumed: cursor - offset)
        default:
            throw CborError.unsupportedMajorType(mt)
        }
    }

    private static func lengthAsInt(_ arg: UInt64) throws -> Int {
        guard arg <= UInt64(Int32.max) else { throw CborError.lengthOverflow }
        return Int(arg)
    }

    // MARK: - Envelope-level helpers

    /// Top-level envelope keys — verbatim from Android/Desktop's
    /// `buildEnvelopeMap`.
    public static let K_MAGIC = "qa_kms_prebootstrap"
    public static let K_V = "v"
    public static let K_S = "s"
    public static let K_R = "r"
    public static let K_TS = "ts"
    public static let K_NONCE = "nonce"
    public static let K_KEM_CT = "kem_ct"
    public static let K_EPH_X25519_PUB = "eph_x25519_pub"
    public static let K_PAYLOAD_CT = "payload_ct"
    public static let K_AD_BYTES = "ad_bytes"
    public static let K_SIG = "sig"
    public static let K_ONE_TIME_PREKEY_ID = "one_time_prekey_id"

    /// Build the canonical CBOR encoding of the whole envelope. Map keys
    /// are sorted internally by `encodeMap`; insertion order below is
    /// irrelevant to the wire bytes.
    ///
    /// NOTE (intentional, matches Android's `encodeEnvelope` exactly):
    /// `K_MAGIC`'s value is just `envelopeVersion` again (same integer as
    /// `K_V`) — this looks redundant but is exactly what the Android and
    /// Desktop ports also do. Do not "fix" it.
    public static func encodeEnvelope(
        envelopeVersion: Int,
        senderUuidStr: String,
        receiverUuidStr: String,
        ts: Int64,
        nonce: Data,
        kemCt: Data,
        ephX25519Pub: Data,
        oneTimePrekeyId: UInt32?,
        payloadCt: Data,
        adBytes: Data,
        sig: Data
    ) -> Data {
        var entries: [(String, Value)] = [
            (K_MAGIC, .uint(UInt64(envelopeVersion))),
            (K_V, .uint(UInt64(envelopeVersion))),
            (K_S, .text(senderUuidStr)),
            (K_R, .text(receiverUuidStr)),
            (K_TS, .uint(UInt64(bitPattern: ts))),
            (K_NONCE, .bytes(nonce)),
            (K_KEM_CT, .bytes(kemCt)),
            (K_EPH_X25519_PUB, .bytes(ephX25519Pub)),
            (K_PAYLOAD_CT, .bytes(payloadCt)),
            (K_AD_BYTES, .bytes(adBytes)),
            (K_SIG, .bytes(sig)),
        ]
        if let id = oneTimePrekeyId {
            entries.append((K_ONE_TIME_PREKEY_ID, .uint(UInt64(id))))
        }
        return encodeMap(entries)
    }

    /// Parsed envelope map — mirrors Android's `KmsPreBootstrapCbor.ParsedEnvelope`.
    public struct ParsedEnvelope {
        public let magic: UInt64
        public let v: UInt64
        public let s: String
        public let r: String
        public let ts: Int64
        public let nonce: Data
        public let kemCt: Data
        public let ephX25519Pub: Data
        public let oneTimePrekeyId: UInt32?
        public let payloadCt: Data
        public let adBytes: Data
        public let sig: Data
    }

    public static func decodeEnvelope(_ envelopeBytes: Data) throws -> ParsedEnvelope {
        let buf = [UInt8](envelopeBytes)
        let (top, consumed) = try decodeItem(buf, offset: 0)
        guard consumed == buf.count else {
            throw CborError.trailingBytes(consumed: consumed, total: buf.count)
        }
        guard case .map(let entries) = top else { throw CborError.notAMap }
        var m: [String: Value] = [:]
        m.reserveCapacity(entries.count)
        for (k, v) in entries { m[k] = v }

        func req(_ k: String) throws -> Value {
            guard let v = m[k] else { throw CborError.missingKey(k) }
            return v
        }
        func reqUint(_ k: String) throws -> UInt64 {
            guard case .uint(let n) = try req(k) else { throw CborError.wrongType("\(k) not uint") }
            return n
        }
        func reqText(_ k: String) throws -> String {
            guard case .text(let s) = try req(k) else { throw CborError.wrongType("\(k) not text") }
            return s
        }
        func reqBytes(_ k: String) throws -> Data {
            guard case .bytes(let b) = try req(k) else { throw CborError.wrongType("\(k) not bytes") }
            return b
        }

        let magic = try reqUint(K_MAGIC)
        let v = try reqUint(K_V)
        let s = try reqText(K_S)
        let r = try reqText(K_R)
        let tsU = try reqUint(K_TS)
        let nonce = try reqBytes(K_NONCE)
        let kemCt = try reqBytes(K_KEM_CT)
        let ephX25519Pub = try reqBytes(K_EPH_X25519_PUB)
        let payloadCt = try reqBytes(K_PAYLOAD_CT)
        let adBytes = try reqBytes(K_AD_BYTES)
        let sig = try reqBytes(K_SIG)

        var otp: UInt32?
        if let v = m[K_ONE_TIME_PREKEY_ID] {
            guard case .uint(let n) = v else { throw CborError.wrongType("\(K_ONE_TIME_PREKEY_ID) not uint") }
            // Android/Desktop take the low 32 bits (their wire contract is
            // a 32-bit prekey id even though the CBOR uint can be wider).
            otp = UInt32(truncatingIfNeeded: n)
        }

        return ParsedEnvelope(
            magic: magic, v: v, s: s, r: r, ts: Int64(bitPattern: tsU),
            nonce: nonce, kemCt: kemCt, ephX25519Pub: ephX25519Pub,
            oneTimePrekeyId: otp, payloadCt: payloadCt, adBytes: adBytes, sig: sig
        )
    }

    // MARK: - UUID helpers

    private static let hexLower: [Character] = Array("0123456789abcdef")

    /// Convert a 16-byte raw UUID into the canonical hyphenated lowercase
    /// 8-4-4-4-12 string form. The receiver side does NOT canonicalize on
    /// parse, so anything other than this exact hyphenated lowercase form
    /// would fail to round-trip against Android/Desktop.
    public static func uuidRawToCanonicalString(_ raw: Data) -> String {
        precondition(raw.count == 16, "uuid raw must be 16B (got \(raw.count))")
        let bytes = [UInt8](raw)
        var out = ""
        out.reserveCapacity(36)
        for i in 0..<16 {
            let b = Int(bytes[i])
            out.append(hexLower[(b >> 4) & 0xF])
            out.append(hexLower[b & 0xF])
            if i == 3 || i == 5 || i == 7 || i == 9 { out.append("-") }
        }
        return out
    }

    /// Parse a UUID string in either canonical hyphenated form or
    /// unhyphenated 32-hex form (mirrors Android's `uuidStringToRaw` /
    /// Desktop's `uuidStringToRawBytes`, which strip hyphens and
    /// lowercase). Throws on malformed input.
    public static func uuidStringToRaw(_ uuidStr: String) throws -> Data {
        let stripped = uuidStr.replacingOccurrences(of: "-", with: "").lowercased()
        guard stripped.count == 32 else { throw CborError.malformedUuid(uuidStr) }
        var out = Data(capacity: 16)
        let chars = Array(stripped)
        for i in 0..<16 {
            guard let hi = hexNibble(chars[i * 2]), let lo = hexNibble(chars[i * 2 + 1]) else {
                throw CborError.malformedUuid(uuidStr)
            }
            out.append(UInt8((hi << 4) | lo))
        }
        return out
    }

    // force-unwraps below are safe: `"0"`/`"a"` are literal ASCII
    // characters (.asciiValue always non-nil), and the `"0"..."9"` /
    // `"a"..."f"` case ranges only match `c` when it is itself a
    // single ASCII scalar in that range, so `c.asciiValue` is
    // guaranteed non-nil too.
    private static func hexNibble(_ c: Character) -> Int? {
        switch c {
        // swiftlint:disable:next force_unwrapping
        case "0"..."9": return Int(c.asciiValue! - Character("0").asciiValue!)
        // swiftlint:disable:next force_unwrapping
        case "a"..."f": return Int(c.asciiValue! - Character("a").asciiValue!) + 10
        default: return nil
        }
    }
}
