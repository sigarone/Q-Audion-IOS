import Foundation

/// Dispatcher for the Q-Audion messaging wire-format versions.
///
/// Three coexisting versions ship across the platforms today:
///
///   - **v1 (legacy)**  — no magic byte; the iOS-only path used since the
///                         first internal TestFlight. Still works between
///                         two iOS peers but not interoperable with newer
///                         Android / Desktop builds.
///   - **v2 (0xE2)**    — first cross-platform format. Colon-delimited AAD
///                         string `senderId + ":" + recipientId + ":" +
///                         clientMsgId`. Vulnerable to userId-with-`:`
///                         cross-binding; replaced by v3.1.
///   - **v3.1 (0xE3)**  — current Android / Desktop default. Canonical-CBOR
///                         AAD + HKDF init info, deterministic per-message
///                         nonce derivation, full forward secrecy ratchet.
///                         See `MessageRatchet.kt` / `CanonicalCbor.swift`.
///
/// Until the Swift port of `MessageRatchet` lands (multi-day port — vault,
/// skipped-key cache, KAT verifier), iOS has to at least DETECT v2/v3
/// inbound messages and surface a meaningful error rather than silently
/// dropping them. Without this, an Android peer's first message lands as
/// undecodable bytes and the conversation appears to "just stop working".
public enum MessageWireFormat {

    public static let magicV2: UInt8 = 0xE2
    public static let magicV3: UInt8 = 0xE3
    /// 0xE5 — v4 native PQ ratchet frame. OPAQUE (owned by the Rust core); detected
    /// only by first byte, never parsed here. Mirrors ``MessageRatchet/magicV4``.
    public static let magicV4: UInt8 = 0xE5

    public enum Version: Equatable {
        /// No magic byte (iOS-only legacy path).
        case v1
        /// 0xE2 — first cross-platform Q-Audion format. AAD = colon string.
        case v2
        /// 0xE3 — v3.1 wire (canonical CBOR AAD + nonce derivation).
        case v3
        /// 0xE5 — v4 native PQ ratchet wire (opaque frame, native core owns it).
        /// The dispatcher routes this to `MessageRatchet.decryptV4Routed(peerId:frame:)`
        /// by PEER id only — it MUST NOT attempt to parse the frame.
        case v4
    }

    /// Cheap probe: read the first byte and classify.
    public static func detect(_ wire: Data) -> Version {
        guard !wire.isEmpty else { return .v1 }
        switch wire[wire.startIndex] {
        case magicV2: return .v2
        case magicV3: return .v3
        case magicV4: return .v4
        default:      return .v1
        }
    }

    /// Convenience guard for callers that want to accept v1-only.
    public static func isV1(_ wire: Data) -> Bool { detect(wire) == .v1 }
    public static func isV2(_ wire: Data) -> Bool { detect(wire) == .v2 }
    public static func isV3(_ wire: Data) -> Bool { detect(wire) == .v3 }
    public static func isV4(_ wire: Data) -> Bool { detect(wire) == .v4 }

    // MARK: - Parsed v3 header (no decryption — just structural parsing)

    /// What we can read from a v3.1 wire blob without the chain key.
    /// Useful to surface a meaningful error to the user when the receiver
    /// can't yet decrypt v3.
    ///
    /// Layout (v3.1, see `MessageRatchet.kt`):
    /// ```
    ///   0     1   magic = 0xE3
    ///   1     1   epoch_len  (1..255)
    ///   2     L   epoch (UTF-8)
    ///   2+L   1   direction_flag (0x01 lo->hi, 0x02 hi->lo)
    ///   3+L   8   chain_idx (uint64 BE)
    ///   11+L  N   ciphertext
    ///   11+L+N 16 GCM tag
    /// ```
    public struct V3Header: Equatable {
        public let epoch: String
        public let directionFlag: UInt8
        public let chainIdx: UInt64
        public let ciphertextLength: Int

        public static let directionLoToHi: UInt8 = 0x01
        public static let directionHiToLo: UInt8 = 0x02
    }

    public enum WireError: Error, Equatable {
        case empty
        case notV3
        case truncated(expected: Int, got: Int)
        case epochLenZero
        case badDirection(UInt8)
    }

    /// Parse the v3.1 envelope header. Returns the header fields plus the
    /// length of the ciphertext (so callers can size buffers without
    /// having to redo the math). Throws if the wire is not v3 or is
    /// malformed.
    public static func parseV3Header(_ wire: Data) throws -> V3Header {
        guard !wire.isEmpty else { throw WireError.empty }
        let base = wire.startIndex
        guard wire[base] == magicV3 else { throw WireError.notV3 }
        guard wire.count >= 2 else {
            throw WireError.truncated(expected: 2, got: wire.count)
        }
        let epochLen = Int(wire[base + 1])
        guard epochLen >= 1 else { throw WireError.epochLenZero }

        let headerBeforeDir = 2 + epochLen
        let minLen = headerBeforeDir + 1 + 8 + 16  // dir + chain_idx + GCM tag
        guard wire.count >= minLen else {
            throw WireError.truncated(expected: minLen, got: wire.count)
        }

        let epoch = String(
            data: wire.subdata(in: (base + 2)..<(base + 2 + epochLen)),
            encoding: .utf8) ?? ""

        let dir = wire[base + headerBeforeDir]
        guard dir == V3Header.directionLoToHi || dir == V3Header.directionHiToLo else {
            throw WireError.badDirection(dir)
        }

        let idxOff = base + headerBeforeDir + 1
        var chainIdx: UInt64 = 0
        for i in 0..<8 {
            chainIdx = (chainIdx << 8) | UInt64(wire[idxOff + i])
        }
        let ctOff = idxOff + 8
        // Total wire length = ctOff + ciphertext + 16-byte tag.
        let ctLen = wire.count - (ctOff - base) - 16
        return V3Header(
            epoch: epoch,
            directionFlag: dir,
            chainIdx: chainIdx,
            ciphertextLength: ctLen)
    }
}
