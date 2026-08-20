import CryptoKit
import Foundation

/// KMS Rotation v2 §3.0/§3.4 — server_id is a PROVISIONED CONSTANT.
///
///   server_id = SHA-256("qa-kms-server-id-v1|" || KMS.ServerIdentity)
///
/// Mirror of Android KmsServerIdentity.kt. All 5 surfaces compute the same 32 bytes.
/// Production identity (2026-08-20): "qa-kms-prod-server-v1", matching
/// bcrypto-server's config.production.toml `[kms] server_identity` and the
/// identical Android/Desktop constants. The KAT/test identity
/// ("qa-kms-test-server-2026-06-16", frozen by gen_kms_v2_kat.py) stays
/// frozen forever for KAT reproducibility — it is a different string from
/// this production value and never needs to change alongside it.
public enum KmsServerIdentity {

    /// The provisioned KMS server identity string (build constant).
    // swiftlint:disable:next identifier_name
    public static let SERVER_IDENTITY = "qa-kms-prod-server-v1"

    private static let PREFIX = "qa-kms-server-id-v1|"

    /// 32-byte server_id = SHA-256(PREFIX || identity).
    public static func serverId(identity: String) -> Data {
        let input = Data((PREFIX + identity).utf8)
        return Data(SHA256.hash(data: input))
    }

    /// 32-byte server_id = SHA-256(PREFIX || SERVER_IDENTITY).
    /// Computed once at first access and cached.
    public static let serverIdBytes: Data = serverId(identity: SERVER_IDENTITY)
}
