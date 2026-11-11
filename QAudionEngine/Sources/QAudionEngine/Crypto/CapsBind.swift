import Foundation
import CryptoKit

/// What the key confirmation needs from one handshake bundle (`capsBindV1`).
public struct BundleCapsBind: Equatable, Sendable {
    /// The raw `capabilities` object has a `capsBindV1` member whose value is the literal `true`.
    public let hasTag: Bool
    /// The raw `capabilities` object repeats a member name (after unescaping), or a member name carries an invalid
    /// escape or a lone surrogate. Only judged when `ext_r` would be true (`CapsBind.peerCapabilitiesMalformed`).
    public let duplicate: Bool
    /// `u8(n) || LP(name_1) || ... || LP(name_n)`.
    public let capsx: Data
    /// 32-byte digest of the optional key-carrying members.
    public let extx: Data
    /// The normalised `capsWithdrawn` list: valid names, deduplicated, sorted bytewise, at most 16.
    public let withdrawn: [String]
}

/// `capsBindV1` (WIRE_SPEC 3.7.1 extension): the unsigned capability members and the optional key-carrying members of a bundle
/// are bound into the key-confirmation MAC of the round when both bundles carry the tag.
///
///     CAPSX = u8(n) || LP(name_1) || ... || LP(name_n)
///     EXTX  = SHA-256("qa-extx-v1" || LP(relayKem.mlkem|empty) || LP(relayKem.x25519|empty) || LP(mldsaKeyId|empty) || LP(capsWithdrawn|empty))
///     kc_transcript_x = SHA-256("qa-kc-transcript-v2" || kc_transcript || LP(CAPSX(OFFER)) || LP(CAPSX(ACCEPT)) || EXTX(OFFER) || EXTX(ACCEPT))
///
/// Pure functions, no I/O, nothing here can fail on peer input: every value that cannot be used counts as absent. The raw JSON text
/// is scanned (a typed decoder drops unknown members and hides repeated ones). The vectors are the sections `capsx`, `extx` and
/// `kcmacExt` of the shared known-answer file.
public enum CapsBind {

    /// The capability tag of this feature.
    public static let tag = "capsBindV1"

    /// The nine names of the signed CAPS9 block: never part of CAPSX.
    public static let caps9Names: [String] = [
        "ratchetV3", "sframeV1", "vkeyV1", "sessionKdfV3", "ratchetV4", "srtpDirKeyV1", "pskMixV1", "hsTranscriptBindV1", "ratchetV5"
    ]
    private static let caps9Set: Set<String> = Set(caps9Names)

    private static let maxCapsxNames = 64
    private static let maxWithdrawn = 16
    /// Longest canonical base64 text whose decoded value fits one LP field (65535 bytes), rounded up to a whole group of four characters.
    private static let maxBase64Chars = 87_384
    private static let extxLabel = Data("qa-extx-v1".utf8)
    private static let kcTranscriptV2Label = Data("qa-kc-transcript-v2".utf8)
    private static let capabilitiesKey: [UInt16] = Array("capabilities".utf16)

    // MARK: - Small encoders

    private static func lp(_ bytes: Data) -> Data {
        let n = min(bytes.count, 0xFFFF)
        var out = Data([UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
        out.append(bytes.prefix(n))
        return out
    }

    private static func bytewiseLess(_ a: String, _ b: String) -> Bool {
        Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8))
    }

    /// `^[A-Za-z][A-Za-z0-9]{0,63}$` over UTF-16 code units.
    private static func matchesTagPattern(_ units: [UInt16]) -> Bool {
        guard !units.isEmpty, units.count <= 64 else { return false }
        func isLetter(_ c: UInt16) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
        func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
        guard isLetter(units[0]) else { return false }
        for c in units.dropFirst() where !(isLetter(c) || isDigit(c)) { return false }
        return true
    }

    private static func matchesTagPattern(_ s: String) -> Bool {
        matchesTagPattern(Array(s.utf16))
    }

    // MARK: - Raw JSON scanning

    private struct RawMember {
        let name: [UInt16]
        let valueBytes: [UInt8]
        let badName: Bool
    }

    private static func skipWhitespace(_ s: [UInt8], _ start: Int) -> Int {
        var i = start
        while i < s.count {
            let c = s[i]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1 } else { break }
        }
        return i
    }

    /// Index just after the string that starts at `i` (which must hold a quote), or nil.
    private static func endOfString(_ s: [UInt8], _ i: Int) -> Int? {
        guard i < s.count, s[i] == 0x22 else { return nil }
        var j = i + 1
        while j < s.count {
            let c = s[j]
            if c == 0x5C { j += 2; continue }
            if c == 0x22 { return j + 1 }
            j += 1
        }
        return nil
    }

    /// Index just after the JSON value that starts at `i`, or nil.
    private static func endOfValue(_ s: [UInt8], _ i: Int) -> Int? {
        guard i < s.count else { return nil }
        let c = s[i]
        if c == 0x22 { return endOfString(s, i) }
        if c == 0x7B || c == 0x5B {
            var depth = 0
            var j = i
            while j < s.count {
                let d = s[j]
                if d == 0x22 {
                    guard let e = endOfString(s, j) else { return nil }
                    j = e
                    continue
                }
                if d == 0x7B || d == 0x5B {
                    depth += 1
                } else if d == 0x7D || d == 0x5D {
                    depth -= 1
                    if depth == 0 { return j + 1 }
                }
                j += 1
            }
            return nil
        }
        var j = i
        while j < s.count {
            let d = s[j]
            if d == 0x2C || d == 0x7D || d == 0x5D || d == 0x20 || d == 0x09 || d == 0x0D || d == 0x0A { break }
            j += 1
        }
        return j > i ? j : nil
    }

    private static func hexValue(_ c: UInt8) -> UInt16? {
        switch c {
        case 0x30...0x39: return UInt16(c - 0x30)
        case 0x41...0x46: return UInt16(c - 0x41 + 10)
        case 0x61...0x66: return UInt16(c - 0x61 + 10)
        default: return nil
        }
    }

    private static func hasLoneSurrogate(_ units: [UInt16]) -> Bool {
        var i = 0
        while i < units.count {
            let c = units[i]
            if c >= 0xD800 && c <= 0xDBFF {
                if i + 1 < units.count, units[i + 1] >= 0xDC00, units[i + 1] <= 0xDFFF { i += 2; continue }
                return true
            }
            if c >= 0xDC00 && c <= 0xDFFF { return true }
            i += 1
        }
        return false
    }

    /// The member name of the string token `token` (quotes included), unescaped into UTF-16 code units (RFC 8259 section 7).
    /// An invalid escape, a raw control character or a lone surrogate marks the name bad; a bad name keeps its raw text, so it can
    /// never equal a real tag.
    private static func decodeName(_ token: ArraySlice<UInt8>) -> (units: [UInt16], bad: Bool) {
        let rawUnits = Array(String(decoding: token, as: UTF8.self).utf16)
        let body = Array(token.dropFirst().dropLast())
        var units: [UInt16] = []
        var literal: [UInt8] = []
        func flushLiteral() {
            if !literal.isEmpty {
                units.append(contentsOf: Array(String(decoding: literal, as: UTF8.self).utf16))
                literal.removeAll()
            }
        }
        var i = 0
        while i < body.count {
            let c = body[i]
            if c < 0x20 { return (rawUnits, true) }
            if c != 0x5C {
                literal.append(c)
                i += 1
                continue
            }
            flushLiteral()
            guard i + 1 < body.count else { return (rawUnits, true) }
            let e = body[i + 1]
            switch e {
            case 0x22: units.append(0x22); i += 2
            case 0x5C: units.append(0x5C); i += 2
            case 0x2F: units.append(0x2F); i += 2
            case 0x62: units.append(0x08); i += 2
            case 0x66: units.append(0x0C); i += 2
            case 0x6E: units.append(0x0A); i += 2
            case 0x72: units.append(0x0D); i += 2
            case 0x74: units.append(0x09); i += 2
            case 0x75:
                guard i + 5 < body.count,
                      let h1 = hexValue(body[i + 2]), let h2 = hexValue(body[i + 3]),
                      let h3 = hexValue(body[i + 4]), let h4 = hexValue(body[i + 5]) else { return (rawUnits, true) }
                units.append((h1 << 12) | (h2 << 8) | (h3 << 4) | h4)
                i += 6
            default:
                return (rawUnits, true)
            }
        }
        flushLiteral()
        return (units, hasLoneSurrogate(units))
    }

    /// The members of the JSON object that starts at `s[start]`, in document order, or nil when the text is not an object.
    private static func objectMembers(_ s: [UInt8], _ start: Int) -> [RawMember]? {
        var i = skipWhitespace(s, start)
        guard i < s.count, s[i] == 0x7B else { return nil }
        i = skipWhitespace(s, i + 1)
        var out: [RawMember] = []
        if i < s.count, s[i] == 0x7D { return out }
        while true {
            guard let keyEnd = endOfString(s, i) else { return nil }
            let decoded = decodeName(s[i..<keyEnd])
            i = skipWhitespace(s, keyEnd)
            guard i < s.count, s[i] == 0x3A else { return nil }
            i = skipWhitespace(s, i + 1)
            guard let valueEnd = endOfValue(s, i) else { return nil }
            out.append(RawMember(name: decoded.units, valueBytes: Array(s[i..<valueEnd]), badName: decoded.bad))
            i = skipWhitespace(s, valueEnd)
            if i < s.count, s[i] == 0x2C {
                i = skipWhitespace(s, i + 1)
                continue
            }
            return (i < s.count && s[i] == 0x7D) ? out : nil
        }
    }

    // MARK: - CAPSX

    private struct CapsMember {
        let name: [UInt16]
        let isTrue: Bool
        let bad: Bool
    }

    private static func capsx(of members: [CapsMember]) -> Data {
        var names = Set<String>()
        for m in members where m.isTrue && !m.bad && matchesTagPattern(m.name) {
            let name = String(decoding: m.name, as: UTF16.self)
            if !caps9Set.contains(name) { names.insert(name) }
        }
        let sorted = names.sorted(by: bytewiseLess).prefix(maxCapsxNames)
        var out = Data([UInt8(sorted.count)])
        for n in sorted { out.append(lp(Data(n.utf8))) }
        return out
    }

    private static func tagAndDuplicates(_ members: [CapsMember]) -> (hasTag: Bool, duplicate: Bool) {
        var seen = Set<[UInt16]>()
        var duplicate = false
        var hasTag = false
        let tagUnits = Array(tag.utf16)
        for m in members {
            if m.bad { duplicate = true }
            if !seen.insert(m.name).inserted { duplicate = true }
            if m.name == tagUnits && m.isTrue && !m.bad { hasTag = true }
        }
        return (hasTag, duplicate)
    }

    // MARK: - EXTX

    /// Canonical base64, RFC 4648 section 4, checked explicitly (a platform decoder is lenient): standard alphabet, padding required,
    /// no other character, zero pad bits, a decoded size that fits one LP field. Anything else, or a value that is not a string, is nil.
    static func strictBase64(_ value: Any?) -> Data? {
        guard let text = value as? String else { return nil }
        let chars = Array(text.utf8)
        guard !chars.isEmpty, chars.count % 4 == 0, chars.count <= maxBase64Chars else { return nil }
        var pad = 0
        if chars.count >= 2, chars[chars.count - 1] == 0x3D, chars[chars.count - 2] == 0x3D { pad = 2 } else if chars[chars.count - 1] == 0x3D { pad = 1 }
        let body = chars.dropLast(pad)
        var values: [UInt8] = []
        values.reserveCapacity(body.count)
        for c in body {
            switch c {
            case 0x41...0x5A: values.append(c - 0x41)
            case 0x61...0x7A: values.append(c - 0x61 + 26)
            case 0x30...0x39: values.append(c - 0x30 + 52)
            case 0x2B: values.append(62)
            case 0x2F: values.append(63)
            default: return nil
            }
        }
        guard let last = values.last else { return nil }
        if pad == 2 && (last & 0x0F) != 0 { return nil }
        if pad == 1 && (last & 0x03) != 0 { return nil }
        var out = Data()
        var acc: UInt32 = 0
        var bits = 0
        for v in values {
            acc = (acc << 6) | UInt32(v)
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((acc >> UInt32(bits)) & 0xFF))
                acc &= (UInt32(1) << UInt32(bits)) - 1
            }
        }
        return out.count > 0xFFFF ? nil : out
    }

    /// The normalised `capsWithdrawn` list: string elements that match the tag pattern, deduplicated, sorted bytewise, the first 16.
    /// A value that is not an array, or has no such element, is the empty list.
    public static func normaliseWithdrawn(_ value: Any?) -> [String] {
        guard let items = value as? [Any] else { return [] }
        var set = Set<String>()
        for item in items {
            if let s = item as? String, matchesTagPattern(s) { set.insert(s) }
        }
        return Array(set.sorted(by: bytewiseLess).prefix(maxWithdrawn))
    }

    /// EXTX from the optional members of one parsed bundle object (`relayKem`, `mldsaKeyId`, `capsWithdrawn`).
    public static func extx(ofBundleObject object: [String: Any]?) -> (extx: Data, withdrawn: [String]) {
        var mlkem: Data?
        var x25519: Data?
        if let kem = object?["relayKem"] as? [String: Any] {
            mlkem = strictBase64(kem["mlkem"])
            x25519 = strictBase64(kem["x25519"])
        }
        var keyId = strictBase64(object?["mldsaKeyId"])
        if let k = keyId, k.count != 32 { keyId = nil }
        let withdrawn = normaliseWithdrawn(object?["capsWithdrawn"])
        var preimage = extxLabel
        preimage.append(lp(mlkem ?? Data()))
        preimage.append(lp(x25519 ?? Data()))
        preimage.append(lp(keyId ?? Data()))
        preimage.append(lp(Data(withdrawn.joined(separator: ",").utf8)))
        return (Data(SHA256.hash(data: preimage)), withdrawn)
    }

    // MARK: - Analysis of a bundle

    /// Analyse a bundle from its raw JSON text (the part after `<callId>|`). Text that cannot be scanned counts as a bundle without
    /// the tag. Used for the bundle a peer sent (its bytes as received) and for the one this side sent (its bytes as sent).
    public static func analyze(json: String) -> BundleCapsBind {
        let bytes = Array(json.utf8)
        var members: [CapsMember] = []
        if let top = objectMembers(bytes, 0) {
            // JSON decoders keep the LAST of repeated top-level members; follow them.
            var capsBytes: [UInt8]?
            for m in top where m.name == capabilitiesKey && !m.badName { capsBytes = m.valueBytes }
            if let capsBytes, let inner = objectMembers(capsBytes, 0) {
                members = inner.map { CapsMember(name: $0.name, isTrue: $0.valueBytes == Array("true".utf8), bad: $0.badName) }
            }
        }
        let flags = tagAndDuplicates(members)
        let parsed = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any]
        let ext = extx(ofBundleObject: parsed)
        return BundleCapsBind(hasTag: flags.hasTag, duplicate: flags.duplicate, capsx: capsx(of: members),
                              extx: ext.extx, withdrawn: ext.withdrawn)
    }

    /// Analyse a typed bundle by encoding it exactly as it goes on the wire.
    public static func analyze(bundle: AndroidHandshakeBundle) -> BundleCapsBind {
        analyze(json: AndroidHandshakeEnvelope.jsonPayload(of: bundle))
    }

    // MARK: - KCMAC extension

    /// `ext_r`: both bundles of the round carry the tag.
    public static func isActive(own: BundleCapsBind, peer: BundleCapsBind) -> Bool {
        own.hasTag && peer.hasTag
    }

    /// The duplicate rule: only for a round whose `ext_r` would be true, a repeated member name (or an unusable name) in the peer's
    /// `capabilities` makes the bundle malformed (`handshake_malformed`). A bundle without the tag, and a receiver that does not
    /// advertise it, are never checked: the bundle is decoded exactly as before.
    public static func peerCapabilitiesMalformed(ownAdvertises: Bool, peer: BundleCapsBind) -> Bool {
        ownAdvertises && peer.hasTag && peer.duplicate
    }

    /// `kc_transcript_x`, or nil when `kcTranscript` is not 32 bytes.
    public static func kcTranscriptX(kcTranscript: Data, offer: BundleCapsBind, accept: BundleCapsBind) -> Data? {
        guard kcTranscript.count == 32 else { return nil }
        var preimage = kcTranscriptV2Label
        preimage.append(kcTranscript)
        preimage.append(lp(offer.capsx))
        preimage.append(lp(accept.capsx))
        preimage.append(offer.extx)
        preimage.append(accept.extx)
        return Data(SHA256.hash(data: preimage))
    }
}
