import Foundation
import CryptoKit

/// W374 — v2 (0xE2) wire-format decoder. Parity with Android's
/// `MessageCrypto.decryptV2` in `qaudion-engine/.../crypto/
/// MessageCrypto.kt`.
///
/// **Wire layout:**
/// ```
///   magic(1) = 0xE2
///   epoch_len(1)
///   epoch(N) UTF-8
///   salt(32)
///   nonce(12)
///   ciphertext
///   tag(16)
/// ```
///
/// **Key derivation:**
///   key = HKDF-SHA256(IKM = psk, salt = wire.salt, info = "q-audion-msg-key", L = 32)
///
/// **AAD:** caller passes `"msg:{senderId}:{recipientId}:{msgId}"` —
/// same shape as v1 since v2 was a transitional format that kept the
/// v1 AAD but added an explicit epoch header so the receiver could
/// route to the right PSK.
///
/// **Why this exists:** the v3.1 path (W337/W351) is the production
/// chat envelope today, but a peer running an older Android client
/// may still emit v2 frames. Without this decoder, every v2 inbound
/// triggers `auto-rekey on AEAD failure` (W77b path) which works but
/// is slow and noisy. This decoder lets us open v2 cleanly so the
/// older peer's messages land directly.
public enum MessageCryptoV2 {

    public static let magicV2: UInt8 = 0xE2
    public static let saltSize = 32
    public static let nonceSize = 12
    public static let tagSize = 16
    public static let keySize = 32

    /// Same HKDF info string MessageCrypto v1/v2 use. Cross-platform
    /// ground truth: see `MessageCrypto.kt` `MSG_KEY_INFO` constant.
    private static let msgKeyInfo = Data("q-audion-msg-key".utf8)

    public enum DecodeError: Error, Equatable {
        case wrongMagic
        case truncated(Int, expected: Int)
        case epochLenZero
        case aeadFailed
    }

    public struct ParsedV2 {
        public let epoch: String
        public let salt: Data
        public let nonce: Data
        public let ciphertext: Data
        public let tag: Data
    }

    /// Cheap structural parse. Doesn't open the AEAD — caller picks a
    /// PSK and calls `openWithPsk` after.
    public static func parse(_ wire: Data) throws -> ParsedV2 {
        guard !wire.isEmpty else { throw DecodeError.truncated(0, expected: 2) }
        let base = wire.startIndex
        guard wire[base] == magicV2 else { throw DecodeError.wrongMagic }
        guard wire.count >= 2 else { throw DecodeError.truncated(wire.count, expected: 2) }
        let epochLen = Int(wire[base + 1])
        guard epochLen >= 1 else { throw DecodeError.epochLenZero }
        let headerSize = 2 + epochLen
        let minLen = headerSize + saltSize + nonceSize + tagSize
        guard wire.count >= minLen else {
            throw DecodeError.truncated(wire.count, expected: minLen)
        }
        let epoch = String(data: wire.subdata(in: (base + 2)..<(base + 2 + epochLen)),
                            encoding: .utf8) ?? ""
        let saltOff = base + headerSize
        let nonceOff = saltOff + saltSize
        let ctOff = nonceOff + nonceSize
        let salt = wire.subdata(in: saltOff..<nonceOff)
        let nonce = wire.subdata(in: nonceOff..<ctOff)
        let ctPlusTag = wire.subdata(in: ctOff..<wire.endIndex)
        let tagOffset = ctPlusTag.count - tagSize
        let ciphertext = ctPlusTag.prefix(tagOffset)
        let tag = ctPlusTag.suffix(tagSize)
        return ParsedV2(epoch: epoch, salt: salt, nonce: nonce,
                        ciphertext: Data(ciphertext), tag: Data(tag))
    }

    /// Open the AEAD with the supplied PSK. Returns nil on AEAD
    /// failure (caller's signal to try the next PSK candidate).
    ///
    /// SECURITY M-22: callers iterate this over a list of candidate PSKs
    /// ("PSK trial"). It MUST present a single, uniform failure path so a
    /// peer cannot use it as an oracle for which derivation/AEAD step
    /// failed (which would leak whether a given PSK is bound):
    ///  - exactly one HKDF derive + one AES-GCM open, no early branching
    ///    that depends on the PSK before the single `catch`;
    ///  - every failure class (bad nonce, malformed box, auth failure)
    ///    collapses to the same `nil`;
    ///  - the trial index / which candidate failed is NEVER logged here
    ///    (no timing-variable logging). Keep this function side-effect and
    ///    log free; the caller decides how many PSKs to try and must not
    ///    leak the count or order over the wire/timing either.
    public static func openWithPsk(parsed: ParsedV2, psk: Data, aad: Data) -> Data? {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: psk),
            salt: parsed.salt,
            info: msgKeyInfo,
            outputByteCount: keySize
        )
        do {
            let aesNonce = try AES.GCM.Nonce(data: parsed.nonce)
            let box = try AES.GCM.SealedBox(nonce: aesNonce,
                                              ciphertext: parsed.ciphertext,
                                              tag: parsed.tag)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            // Uniform failure path — do not distinguish the failing step.
            return nil
        }
    }

    /// One-shot helper. Returns plaintext on success, nil on AEAD
    /// failure or wire-format error.
    public static func decrypt(wire: Data, psk: Data, aad: Data) -> Data? {
        guard let parsed = try? parse(wire) else { return nil }
        return openWithPsk(parsed: parsed, psk: psk, aad: aad)
    }

    public static func isV2Wire(_ wire: Data) -> Bool {
        return !wire.isEmpty && wire[wire.startIndex] == magicV2
    }
}
