import Foundation
import CryptoKit

/// Directional 1:1 frame keys (transcript v5, owner decision O1; WIRE_SPEC §11).
///
/// For each 1:1 key round (the initial ACCEPT and every re-key round) the call derives TWO
/// FrameCryptor keys from that round's transcript-bound session key, one per direction:
///
/// ```
/// frameKey_o2a = HKDF-SHA256(IKM = sessionKey, salt = "qaudion-frame-salt-v5",
///                            info = "q-audion-frame-key-v5:" || callId || ":o2a", L = 32)
/// frameKey_a2o = same with ":a2o"
/// ```
///
/// `o` is the OFFERER (the signer of `OFFER_v5`, i.e. the caller), `a` the ACCEPTOR. ASCII
/// strings, no NUL, `callId` exactly as in the transcript. These keys REPLACE the single key both
/// directions used to share (the raw session key, audio and video alike): with one key per
/// direction a peer's own frames reflected back at it can no longer authenticate. The native
/// FrameCryptors run in per-participant mode: the SENDER cryptors use a local participant id that
/// holds the own-direction key, the RECEIVER cryptors use the remote participant id that holds the
/// peer-direction key; the ring slot is `epoch % 16` as before.
public struct OneToOneFrameKeys: Equatable {
    /// Key for frames the OFFERER sends (the ACCEPTOR receives).
    public let offererToAcceptor: Data
    /// Key for frames the ACCEPTOR sends (the OFFERER receives).
    public let acceptorToOfferer: Data

    public init(offererToAcceptor: Data, acceptorToOfferer: Data) {
        self.offererToAcceptor = offererToAcceptor
        self.acceptorToOfferer = acceptorToOfferer
    }

    /// The key THIS side encrypts its outbound frames with.
    public func sendKey(isOfferer: Bool) -> Data {
        return isOfferer ? offererToAcceptor : acceptorToOfferer
    }

    /// The key THIS side decrypts the peer's frames with.
    public func receiveKey(isOfferer: Bool) -> Data {
        return isOfferer ? acceptorToOfferer : offererToAcceptor
    }

    /// Derive both directional keys. Returns `nil` for a session key that is not exactly 32 bytes
    /// or for an empty `callId` (never traps: both come from the handshake, not from the wire).
    public static func derive(sessionKey: Data, callId: String) -> OneToOneFrameKeys? {
        guard sessionKey.count == 32, !callId.isEmpty else { return nil }
        let o2a = deriveOne(sessionKey: sessionKey, callId: callId, direction: "o2a")
        let a2o = deriveOne(sessionKey: sessionKey, callId: callId, direction: "a2o")
        return OneToOneFrameKeys(offererToAcceptor: o2a, acceptorToOfferer: a2o)
    }

    private static func deriveOne(sessionKey: Data, callId: String, direction: String) -> Data {
        var info = HkdfLabels.frameKeyInfoPrefixV5
        info.append(Data(callId.utf8))
        info.append(Data((":" + direction).utf8))
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sessionKey),
            salt: HkdfLabels.frameKeySaltV5,
            info: info,
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }
}

/// Participant ids of the 1:1 native FrameCryptors (per-participant key mode). They are purely
/// local labels - never on the wire, never a real id: the SENDER cryptors use `local` (holding the
/// own-direction key), the RECEIVER cryptors use `remote` (holding the peer-direction key).
public enum OneToOneFrameParticipant {
    public static let local = "local"
    public static let remote = "remote"
}
