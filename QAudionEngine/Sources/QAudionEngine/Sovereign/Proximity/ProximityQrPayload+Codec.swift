import Foundation

// Proximity pairing v1 — QR payload codec (spec §5).
//
//   qrBytes = u8(0x01) ‖ sessionId[16] ‖ commitment[32] ‖ u32be(frameIndex) ‖ frameKey[32]   (85 B)
//   QR text = "qaudion://pair/" ‖ base64url_nopad(qrBytes)                                    (114 chars)
//
// The decoder is deliberately strict and does NOT go through URL /
// URLComponents (which normalise, percent-decode and accept far more than
// the spec allows): it works on the raw UTF-8 bytes of the trimmed string,
// so any non-ASCII byte is rejected by construction. It also re-encodes
// the decoded bytes and requires byte equality with the scanned text, so
// exactly one textual form of each payload is accepted (no non-canonical
// trailing bits, no padding, no alternate alphabet).

extension ProximityQrPayload {

    /// The exact 85-byte QR payload (spec §5).
    public var encodedBytes: Data {
        let index: UInt32 = frameIndex
        let b0: UInt8 = UInt8(truncatingIfNeeded: index >> 24)
        let b1: UInt8 = UInt8(truncatingIfNeeded: index >> 16)
        let b2: UInt8 = UInt8(truncatingIfNeeded: index >> 8)
        let b3: UInt8 = UInt8(truncatingIfNeeded: index)
        let indexBytes: [UInt8] = [b0, b1, b2, b3]
        let versionBytes: [UInt8] = [version]

        var out = Data(capacity: ProximityPairing.qrPayloadBytes)
        out.append(contentsOf: versionBytes)
        out.append(sessionId)
        out.append(commitment)
        out.append(contentsOf: indexBytes)
        out.append(frameKey)
        return out
    }

    /// `"qaudion://pair/"` followed by the 114-character unpadded base64url
    /// encoding of `encodedBytes`.
    public var qrText: String {
        var bytes: Data = encodedBytes
        defer { CryptoConstants.zeroize(&bytes) }
        let encoded: String = ProximityQrBase64Url.encode(bytes)
        let text: String = ProximityPairing.urlPrefix + encoded
        return text
    }

    /// Strict decode of the raw 85-byte payload. Accepts a `Data` slice with a
    /// non-zero `startIndex`.
    public static func decode(bytes: Data) throws -> ProximityQrPayload {
        var raw: Data = Data(bytes)
        defer { CryptoConstants.zeroize(&raw) }

        guard raw.count == ProximityPairing.qrPayloadBytes else {
            throw ProximityPairingError.invalidQrCode("payload length")
        }
        let versionByte: UInt8 = raw[0]
        guard versionByte == ProximityPairing.protocolVersion else {
            throw ProximityPairingError.invalidQrCode("unsupported version")
        }

        let sessionIdStart: Int = 1
        let commitmentStart: Int = sessionIdStart + ProximityPairing.sessionIdBytes
        let frameIndexStart: Int = commitmentStart + ProximityPairing.commitmentBytes
        let frameKeyStart: Int = frameIndexStart + 4
        let frameKeyEnd: Int = frameKeyStart + ProximityPairing.frameKeyBytes
        guard frameKeyEnd == raw.count else {
            throw ProximityPairingError.invalidQrCode("payload layout")
        }

        let sessionId: Data = raw.subdata(in: sessionIdStart..<commitmentStart)
        let commitment: Data = raw.subdata(in: commitmentStart..<frameIndexStart)
        var frameKey: Data = raw.subdata(in: frameKeyStart..<frameKeyEnd)
        defer { CryptoConstants.zeroize(&frameKey) }

        let i0: UInt32 = UInt32(raw[frameIndexStart]) << 24
        let i1: UInt32 = UInt32(raw[frameIndexStart + 1]) << 16
        let i2: UInt32 = UInt32(raw[frameIndexStart + 2]) << 8
        let i3: UInt32 = UInt32(raw[frameIndexStart + 3])
        let frameIndex: UInt32 = i0 | i1 | i2 | i3

        // The initializer re-validates every length and copies the fields.
        return try ProximityQrPayload(sessionId: sessionId,
                                      commitment: commitment,
                                      frameIndex: frameIndex,
                                      frameKey: frameKey)
    }

    /// Strict decode of a scanned QR string (spec §5). Leading/trailing
    /// whitespace and newlines are trimmed; the scheme and host are matched
    /// ASCII-case-insensitively; everything else must be exact.
    public static func decode(text: String) throws -> ProximityQrPayload {
        let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let scanned: [UInt8] = Array(trimmed.utf8)
        let prefix: [UInt8] = Array(ProximityPairing.urlPrefix.utf8)

        guard scanned.count >= prefix.count else {
            throw ProximityPairingError.invalidQrCode("not a pairing code")
        }
        guard ProximityQrBase64Url.hasAsciiCaseInsensitivePrefix(scanned, prefix: prefix) else {
            throw ProximityPairingError.invalidQrCode("not a pairing code")
        }

        let remainder: [UInt8] = Array(scanned[prefix.count...])
        guard remainder.count == ProximityPairing.qrBase64Characters else {
            throw ProximityPairingError.invalidQrCode("payload length")
        }
        guard ProximityQrBase64Url.isAlphabetOnly(remainder) else {
            throw ProximityPairingError.invalidQrCode("payload alphabet")
        }
        guard var decoded: Data = ProximityQrBase64Url.decode(remainder) else {
            throw ProximityPairingError.invalidQrCode("payload encoding")
        }
        defer { CryptoConstants.zeroize(&decoded) }
        guard decoded.count == ProximityPairing.qrPayloadBytes else {
            throw ProximityPairingError.invalidQrCode("payload length")
        }

        // Canonical form only: the one encoding we would have produced.
        let reencoded: [UInt8] = Array(ProximityQrBase64Url.encode(decoded).utf8)
        guard reencoded == remainder else {
            throw ProximityPairingError.invalidQrCode("non-canonical encoding")
        }

        return try ProximityQrPayload.decode(bytes: decoded)
    }

    /// Cheap routing hint for a scanner that sees many kinds of QR codes:
    /// trimmed, ASCII-lowercased prefix check only. It does NOT validate the
    /// payload; `decode(text:)` is the only acceptance test.
    public static func looksLikeProximityPairing(_ text: String) -> Bool {
        let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix: [UInt8] = Array(ProximityPairing.urlPrefix.utf8)
        let head: [UInt8] = Array(trimmed.utf8.prefix(prefix.count))
        guard head.count == prefix.count else { return false }
        return ProximityQrBase64Url.hasAsciiCaseInsensitivePrefix(head, prefix: prefix)
    }
}

/// RFC 4648 §5 base64url without padding, strict. File-private on purpose:
/// the module-wide `Data(base64UrlEncodedNoPadding:)` in DeviceLinkBinaryQR
/// is lenient (accepts padding and non-canonical trailing bits) and must not
/// be used for this payload.
private enum ProximityQrBase64Url {

    private static let alphabet: [UInt8] =
        Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    static func encode(_ data: Data) -> String {
        let bytes: [UInt8] = [UInt8](data)
        let fullGroups: Int = bytes.count / 3
        let tail: Int = bytes.count - fullGroups * 3
        var out: [UInt8] = []
        out.reserveCapacity(fullGroups * 4 + 3)

        var i: Int = 0
        while i + 3 <= bytes.count {
            let n0: UInt32 = UInt32(bytes[i]) << 16
            let n1: UInt32 = UInt32(bytes[i + 1]) << 8
            let n2: UInt32 = UInt32(bytes[i + 2])
            let n: UInt32 = n0 | n1 | n2
            out.append(symbol(n >> 18))
            out.append(symbol(n >> 12))
            out.append(symbol(n >> 6))
            out.append(symbol(n))
            i += 3
        }
        if tail == 1 {
            let n: UInt32 = UInt32(bytes[i]) << 16
            out.append(symbol(n >> 18))
            out.append(symbol(n >> 12))
        } else if tail == 2 {
            let n0: UInt32 = UInt32(bytes[i]) << 16
            let n1: UInt32 = UInt32(bytes[i + 1]) << 8
            let n: UInt32 = n0 | n1
            out.append(symbol(n >> 18))
            out.append(symbol(n >> 12))
            out.append(symbol(n >> 6))
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Decodes unpadded base64url. Returns nil on any character outside the
    /// alphabet or an impossible length (`count % 4 == 1`). Trailing bits are
    /// NOT checked here; the caller enforces canonical form by re-encoding.
    static func decode(_ chars: [UInt8]) -> Data? {
        if chars.count % 4 == 1 { return nil }
        var out = Data(capacity: (chars.count * 3) / 4)
        var accumulator: UInt32 = 0
        var bitCount: Int = 0
        for c in chars {
            guard let value = sextet(c) else { return nil }
            accumulator = (accumulator << 6) | UInt32(value)
            bitCount += 6
            if bitCount >= 8 {
                bitCount -= 8
                let byte: UInt8 = UInt8(truncatingIfNeeded: accumulator >> UInt32(bitCount))
                let one: [UInt8] = [byte]
                out.append(contentsOf: one)
                let mask: UInt32 = (UInt32(1) << UInt32(bitCount)) - 1
                accumulator &= mask
            }
        }
        return out
    }

    static func isAlphabetOnly(_ chars: [UInt8]) -> Bool {
        for c in chars where sextet(c) == nil {
            return false
        }
        return true
    }

    /// ASCII-only case folding: bytes >= 0x80 are never folded, so a
    /// non-ASCII string can never match the (ASCII) prefix.
    static func hasAsciiCaseInsensitivePrefix(_ bytes: [UInt8], prefix: [UInt8]) -> Bool {
        guard bytes.count >= prefix.count else { return false }
        var i: Int = 0
        while i < prefix.count {
            let folded: UInt8 = asciiLower(bytes[i])
            let expected: UInt8 = asciiLower(prefix[i])
            if folded != expected { return false }
            i += 1
        }
        return true
    }

    private static func asciiLower(_ c: UInt8) -> UInt8 {
        if c >= 0x41 && c <= 0x5A { return c + 0x20 }
        return c
    }

    private static func symbol(_ value: UInt32) -> UInt8 {
        let index: Int = Int(value & 0x3F)
        return alphabet[index]
    }

    private static func sextet(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x41...0x5A: return c - 0x41          // A-Z → 0...25
        case 0x61...0x7A: return c - 0x61 + 26     // a-z → 26...51
        case 0x30...0x39: return c - 0x30 + 52     // 0-9 → 52...61
        case 0x2D: return 62                       // '-'
        case 0x5F: return 63                       // '_'
        default: return nil
        }
    }
}
