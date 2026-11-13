import Foundation
import CryptoKit

/// Directional per-media frame keys of a call whose peers both carry `frameKeyV6`.
///
///     key[k][d] = HKDF-SHA256(IKM = sessionKey_E, salt = "qaudion-frame-salt-v6",
///                             info = "q-audion-frame-key-v6" || LP16(callIdL) || LP16(k) || LP16(d), L = 32)
///
/// `k` is `audio` or `video`, `d` is `o2a` or `a2o`, ASCII, `callIdL` the ASCII-lower-cased channel id. Each pair is returned as
/// the existing `OneToOneFrameKeys`, so `sendKey` and `receiveKey` are reused as they are.
public struct FrameKeysV6: Equatable {

    public enum Kind: Equatable, Sendable {
        case audio
        case video

        var word: String {
            switch self {
            case .audio: return "audio"
            case .video: return "video"
            }
        }
    }

    public let audio: OneToOneFrameKeys
    public let video: OneToOneFrameKeys

    public func keys(for kind: Kind) -> OneToOneFrameKeys {
        switch kind {
        case .audio: return audio
        case .video: return video
        }
    }

    /// nil for a session key that is not 32 bytes or an empty id.
    public static func derive(sessionKey: Data, callIdL: String) -> FrameKeysV6? {
        guard sessionKey.count == 32, !callIdL.isEmpty, callIdL.utf8.count <= 0xFFFF else { return nil }
        func pair(_ kind: Kind) -> OneToOneFrameKeys {
            OneToOneFrameKeys(
                offererToAcceptor: deriveOne(sessionKey: sessionKey, callIdL: callIdL, kind: kind, direction: "o2a"),
                acceptorToOfferer: deriveOne(sessionKey: sessionKey, callIdL: callIdL, kind: kind, direction: "a2o"))
        }
        return FrameKeysV6(audio: pair(.audio), video: pair(.video))
    }

    private static func lp16(_ text: String) -> Data {
        let bytes = Array(text.utf8)
        var out = Data([UInt8((bytes.count >> 8) & 0xFF), UInt8(bytes.count & 0xFF)])
        out.append(contentsOf: bytes)
        return out
    }

    private static func deriveOne(sessionKey: Data, callIdL: String, kind: Kind, direction: String) -> Data {
        var info = HkdfLabels.frameKeyInfoPrefixV6
        info.append(lp16(callIdL))
        info.append(lp16(kind.word))
        info.append(lp16(direction))
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sessionKey),
            salt: HkdfLabels.frameKeySaltV6,
            info: info,
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }
}

/// A build advertises `frameKeyV6` only when the key material of every FrameCryptor of the call is the session key of the round.
public enum FrameKeyV6Policy {
    public static func keyMaterialIsSessionKeyE(earbudPaired: Bool) -> Bool {
        !earbudPaired
    }
}
