import CryptoKit
import Foundation

/// KMS Rotation v2 §3.0/§3.4 — server_id is a PROVISIONED CONSTANT.
///
///   server_id = SHA-256("qa-kms-server-id-v1|" || KMS.ServerIdentity)
///
/// Mirror of Android KmsServerIdentity.kt. All 5 surfaces compute the same 32 bytes.
/// TODO(deploy): replace SERVER_IDENTITY with the production `[kms] server_identity` value.
public enum KmsServerIdentity {

    /// The provisioned KMS server identity string (build constant).
    public static let SERVER_IDENTITY = "qa-kms-test-server-2026-06-16"

    private static let PREFIX = "qa-kms-server-id-v1|"

    /// 32-byte server_id = SHA-256(PREFIX || SERVER_IDENTITY).
    /// Computed once at first access and cached.
    public static let serverIdBytes: Data = {
        let input = Data((PREFIX + SERVER_IDENTITY).utf8)
        return Data(SHA256.hash(data: input))
    }()
}
