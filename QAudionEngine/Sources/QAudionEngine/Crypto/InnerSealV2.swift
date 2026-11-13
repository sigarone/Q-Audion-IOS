import Foundation
import CryptoKit

/// The pure part of the per-round inner audio seal (spec B2): key derivation, nonce, associated data, the envelope and the routing
/// of a first byte. No state, no clock, no logging. The state of a call (the round slots, the send pointer, the counter and the
/// replay window) belongs to `InnerSealV2Session`.
///
///     key[k][d] = HKDF-SHA256(IKM = sessionKey_E, salt, info = prefix || LP16(callIdL) || LP16(k) || LP16(d), L = 32)
///     nonce     = 0x02 || dirTag || kindTag || 0x00 || BE64(ctr)                    (never sent)
///     aad       = prefix || LP16(callIdL) || dirTag || kindTag || BE32(E) || BE64(ctr)
///     envelope  = 0x04 || (E mod 256) || BE64(ctr) || BE16(ctLen) || ciphertext || tag16           (ctLen counts the tag)
///
/// `k` is `audio` or `video`, `d` is `o2a` or `a2o`. `callIdL` is the ASCII-lower-cased id of the round-1 channel
/// (`RekeyChain.asciiLower`): input of the derivation and of the AAD only, never a lookup key.
public enum InnerSealV2 {

    public enum Kind: Equatable, Sendable {
        case audio
        case video

        var tag: UInt8 { self == .audio ? 1 : 2 }
        var word: String { self == .audio ? "audio" : "video" }
    }

    public enum Direction: Equatable, Sendable {
        case offererToAcceptor
        case acceptorToOfferer

        var tag: UInt8 { self == .offererToAcceptor ? 1 : 2 }
        var word: String { self == .offererToAcceptor ? "o2a" : "a2o" }
    }

    /// What a first byte means in a call that negotiated the seal. Anything that is not one of the first four is dropped.
    public enum Route: Equatable, Sendable {
        case audio
        case video
        case control
        case envelope
        case drop
    }

    public enum Parsed: Equatable {
        /// `ciphertext` is the `ct || tag16` that follows the 12-byte header.
        case envelope(eByte: UInt8, ctr: UInt64, ciphertext: Data)
        case unknownType
        case malformed
    }

    /// The type byte of the envelope.
    public static let envelopeType: UInt8 = 0x04
    /// `0x04 || E byte || ctr(8) || ctLen(2)`.
    public static let headerBytes = 12
    public static let tagBytes = 16
    /// A sender never seals with a counter above this value and a receiver treats a larger one as malformed.
    public static let maxCounter: UInt64 = (UInt64(1) << 63) - 1

    // MARK: - Keys

    /// The HKDF `info` of one key.
    public static func keyInfo(callIdL: String, kind: Kind, direction: Direction) -> Data? {
        guard callIdL.utf8.count <= 0xFFFF else { return nil }
        var info = HkdfLabels.innerSealInfoPrefixV2
        info.append(lp16(Array(callIdL.utf8)))
        info.append(lp16(Array(kind.word.utf8)))
        info.append(lp16(Array(direction.word.utf8)))
        return info
    }

    /// nil for a session key that is not 32 bytes or a `callIdL` longer than 65535 bytes. An empty `callIdL` is valid input.
    public static func deriveKey(sessionKey: Data, callIdL: String, kind: Kind, direction: Direction) -> Data? {
        guard sessionKey.count == 32, let info = keyInfo(callIdL: callIdL, kind: kind, direction: direction) else { return nil }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sessionKey), salt: HkdfLabels.innerSealSaltV2, info: info, outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    /// The same key in a buffer of its own; the transient `Data` is zeroed.
    static func deriveKeyBuffer(sessionKey: Data, callIdL: String, kind: Kind, direction: Direction) -> ChainKeyBuffer? {
        guard var bytes = deriveKey(sessionKey: sessionKey, callIdL: callIdL, kind: kind, direction: direction) else { return nil }
        let buffer = ChainKeyBuffer(copying: bytes)
        CryptoConstants.zeroize(&bytes)
        return buffer
    }

    // MARK: - Nonce and associated data

    public static func nonce(direction: Direction, kind: Kind, ctr: UInt64) -> Data {
        var out = Data([0x02, direction.tag, kind.tag, 0x00])
        out.append(contentsOf: be64(ctr))
        return out
    }

    /// nil for a `callIdL` longer than 65535 bytes or a negative epoch.
    public static func aad(callIdL: String, direction: Direction, kind: Kind, epoch: Int32, ctr: UInt64) -> Data? {
        guard callIdL.utf8.count <= 0xFFFF, epoch >= 0 else { return nil }
        var out = HkdfLabels.innerSealAadPrefixV2
        out.append(lp16(Array(callIdL.utf8)))
        out.append(direction.tag)
        out.append(kind.tag)
        out.append(contentsOf: be32(UInt32(epoch)))
        out.append(contentsOf: be64(ctr))
        return out
    }

    // MARK: - Seal and open

    /// The whole envelope, or nil for a counter outside `1 ... maxCounter`, a negative epoch, a plaintext whose ciphertext does
    /// not fit 16 bits or a cipher failure. The caller owns the counter.
    public static func seal(
        key: SymmetricKey, callIdL: String, direction: Direction, kind: Kind, epoch: Int32, ctr: UInt64, plaintext: Data
    ) -> Data? {
        guard ctr >= 1, ctr <= maxCounter, epoch >= 0 else { return nil }
        let ctLen = plaintext.count + tagBytes
        guard ctLen <= 0xFFFF,
              let associated = aad(callIdL: callIdL, direction: direction, kind: kind, epoch: epoch, ctr: ctr),
              let gcmNonce = try? AES.GCM.Nonce(data: nonce(direction: direction, kind: kind, ctr: ctr)),
              let box = try? AES.GCM.seal(plaintext, using: key, nonce: gcmNonce, authenticating: associated) else { return nil }
        var out = Data(capacity: headerBytes + ctLen)
        out.append(envelopeType)
        out.append(UInt8(truncatingIfNeeded: epoch))
        out.append(contentsOf: be64(ctr))
        out.append(UInt8(truncatingIfNeeded: ctLen >> 8))
        out.append(UInt8(truncatingIfNeeded: ctLen))
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    /// The plaintext of `ct || tag16` under the nonce and the AAD this layer rebuilds, or nil on any failure.
    public static func open(
        key: SymmetricKey, callIdL: String, direction: Direction, kind: Kind, epoch: Int32, ctr: UInt64, ciphertextAndTag: Data
    ) -> Data? {
        guard ctr >= 1, ctr <= maxCounter, epoch >= 0, ciphertextAndTag.count >= tagBytes,
              let associated = aad(callIdL: callIdL, direction: direction, kind: kind, epoch: epoch, ctr: ctr),
              let gcmNonce = try? AES.GCM.Nonce(data: nonce(direction: direction, kind: kind, ctr: ctr)) else { return nil }
        let start = ciphertextAndTag.startIndex
        let split = ciphertextAndTag.endIndex - tagBytes
        guard let box = try? AES.GCM.SealedBox(
                nonce: gcmNonce, ciphertext: ciphertextAndTag[start ..< split], tag: ciphertextAndTag[split ..< ciphertextAndTag.endIndex]),
              let plain = try? AES.GCM.open(box, using: key, authenticating: associated) else { return nil }
        return plain
    }

    // MARK: - Envelope

    private enum HeaderFailure: Error {
        case unknownType
        case malformed
    }

    /// The header of a well-formed envelope. Indexes from `startIndex`, so a slice is read like a whole value.
    private static func checkedHeader(_ wire: Data) -> Result<(eByte: UInt8, ctr: UInt64), HeaderFailure> {
        guard let first = wire.first else { return .failure(.malformed) }
        guard first == envelopeType else { return .failure(.unknownType) }
        guard wire.count >= headerBytes + tagBytes else { return .failure(.malformed) }
        let base = wire.startIndex
        let ctLen = (Int(wire[base + 10]) << 8) | Int(wire[base + 11])
        guard ctLen >= tagBytes, ctLen == wire.count - headerBytes else { return .failure(.malformed) }
        var ctr: UInt64 = 0
        for offset in 2 ..< 10 { ctr = (ctr << 8) | UInt64(wire[base + offset]) }
        guard ctr >= 1, ctr <= maxCounter else { return .failure(.malformed) }
        return .success((eByte: wire[base + 1], ctr: ctr))
    }

    /// `unknownType`: the first byte is not `0x04`. `malformed`: nothing, shorter than header and tag, `ctLen` below 16 or not
    /// equal to the bytes that follow (trailing bytes included), or a counter of 0 or above `maxCounter`.
    public static func parse(_ wire: Data) -> Parsed {
        switch checkedHeader(wire) {
        case .failure(.unknownType): return .unknownType
        case .failure(.malformed): return .malformed
        case .success(let header):
            return .envelope(eByte: header.eByte, ctr: header.ctr, ciphertext: Data(wire.dropFirst(headerBytes)))
        }
    }

    /// The clear header of a well-formed envelope, nil otherwise.
    public static func header(ofWire wire: Data) -> (eByte: UInt8, ctr: UInt64)? {
        if case .success(let header) = checkedHeader(wire) { return header }
        return nil
    }

    public static func route(firstByte: UInt8) -> Route {
        switch firstByte {
        case 0x01: return .audio
        case 0x02: return .video
        case 0x03: return .control
        case envelopeType: return .envelope
        default: return .drop
        }
    }

    public static func route(ofWire wire: Data) -> Route? {
        guard let first = wire.first else { return nil }
        return route(firstByte: first)
    }

    /// The binary relay shape of one video fragment: `0x02 || BE16(fragIdx) || BE16(totalFrags) || u8(isKey) || envelope`.
    public static func fragmentWire(fragIdx: UInt16, totalFrags: UInt16, isKey: Bool, envelope: Data) -> Data {
        var out = Data(capacity: 6 + envelope.count)
        out.append(0x02)
        out.append(UInt8(truncatingIfNeeded: fragIdx >> 8))
        out.append(UInt8(truncatingIfNeeded: fragIdx))
        out.append(UInt8(truncatingIfNeeded: totalFrags >> 8))
        out.append(UInt8(truncatingIfNeeded: totalFrags))
        out.append(isKey ? 1 : 0)
        out.append(envelope)
        return out
    }

    /// The key of the NACK cache and of the duplicate guard for an inner frame. On a call that negotiated the seal it is the
    /// counter in the clear header (nil for any other frame, which then reaches the engine and is dropped there); on any other
    /// call it is exactly what the two legacy containers give.
    public static func nackSeq(inner: Data, innerV2: Bool, androidAudioWireCompat: Bool) -> Int64? {
        if innerV2 {
            guard let parsed = header(ofWire: inner) else { return nil }
            return Int64(parsed.ctr)
        }
        if androidAudioWireCompat {
            return (try? WireRelayFrameCodec.decode(inner)).map { Int64($0.frame.sequenceNumber) }
        }
        return (try? FrameEncoder.deserialize(inner)).map { Int64($0.sequenceNumber) }
    }

    // MARK: - Big-endian helpers

    private static func lp16(_ bytes: [UInt8]) -> Data {
        var out = Data([UInt8(truncatingIfNeeded: bytes.count >> 8), UInt8(truncatingIfNeeded: bytes.count)])
        out.append(contentsOf: bytes)
        return out
    }

    private static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    private static func be64(_ value: UInt64) -> [UInt8] {
        (0 ..< 8).map { UInt8(truncatingIfNeeded: value >> UInt64(56 - 8 * $0)) }
    }
}
