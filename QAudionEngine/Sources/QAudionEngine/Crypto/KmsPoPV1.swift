import Foundation
import CryptoKit

/// §3.4 Proof-of-Possession — scheme `qa-kms-pop-v1`.
///
/// Keyed on the per-delivery WRAP SECRET, never on K, so a `shared`-class
/// relay phone that also holds K cannot forge another participant's PoP.
/// For the earbud the wrap secret (ss_pq||ss_x) is computed INSIDE the SE
/// and never leaves it, so the phone relays the SE-computed MAC verbatim.
///
///   pop_key = HKDF-SHA256(wrap_secret,
///                 salt="qa-kms-pop-salt-v1",
///                 info="qa-kms-pop-v1" || device_id(16), L=32)
///   pop = HMAC-SHA256(pop_key,
///                 "qa-kms-pop-v1"        # 13 B
///              || server_id(32)
///              || txn_id(16) || key_id(16) || device_id(16)
///              || key_epoch(8 BE) || server_nonce(16))
///
/// `server_id` is the provisioned constant
/// SHA-256("qa-kms-server-id-v1|" || KMS.ServerIdentity) (§3.0); it is
/// supplied by the caller and never echoed on the wire.
public enum KmsPoPV1 {
    private static let LABEL = Data("qa-kms-pop-v1".utf8)               // 13 B
    private static let SALT  = Data("qa-kms-pop-salt-v1".utf8)

    public static func deriveKey(wrapSecret: Data, deviceId: UUID) -> Data {
        var info = Data()
        info.append(LABEL)
        info.append(KmsTransport.uuidBytes(deviceId))
        let k = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: wrapSecret),
            salt: SALT, info: info, outputByteCount: 32)
        return k.withUnsafeBytes { Data($0) }
    }

    public static func compute(
        wrapSecret: Data, deviceId: UUID, serverId: Data,
        txnId: UUID, keyId: UUID, keyEpoch: UInt64, serverNonce: Data
    ) -> Data {
        precondition(serverId.count == 32, "server_id must be 32B SHA-256")
        precondition(serverNonce.count == 16, "server_nonce must be 16B")
        let popKey = SymmetricKey(data: deriveKey(wrapSecret: wrapSecret, deviceId: deviceId))
        var msg = Data()
        msg.append(LABEL)
        msg.append(serverId)
        msg.append(KmsTransport.uuidBytes(txnId))
        msg.append(KmsTransport.uuidBytes(keyId))
        msg.append(KmsTransport.uuidBytes(deviceId))
        msg.append(KmsTransport.epochBE(keyEpoch))
        msg.append(serverNonce)
        let mac = HMAC<SHA256>.authenticationCode(for: msg, using: popKey)
        return Data(mac)
    }
}
