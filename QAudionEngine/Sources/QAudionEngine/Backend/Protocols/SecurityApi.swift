import Foundation

/// Security API matching server endpoints:
/// - ZK auth register/verify
/// - Hybrid PQC key exchange relay
/// - Threat reporting
/// - Cert pinning info
/// - Compliance info
/// - Remote wipe confirmation
public protocol SecurityApi {
    // MARK: - Zero-Knowledge Auth

    /// §3.11 — POST /api/v1/security/zk-register
    /// Body: {zk_commitment, public_params?}
    func zkRegister(zkCommitment: Data, publicParams: Data?) async throws

    /// §3.12 — POST /api/v1/security/zk-auth
    /// Body: {challenge, proof}
    /// Returns bearer/session token bytes.
    func zkAuth(challenge: Data, proof: Data) async throws -> Data

    // MARK: - Hybrid PQC Relay

    /// §3.13 — POST /api/v1/security/pqc-relay
    /// Body: {recipient_id, ciphertext (base64), algorithm}
    /// Default algorithm is "ml-kem-1024" (project target; Android default 768
    /// is wrong for this deployment).
    func sendPqcKeyExchange(recipientId: String, ciphertext: Data,
                            algorithm: String) async throws

    // MARK: - Threat Reporting

    /// §3.14 — POST /api/v1/security/threat-report
    /// Body: {category, details, severity}
    func reportThreat(category: String, details: String, severity: String) async throws

    // MARK: - Server Info (iOS-only, no Android counterpart)

    func getCertInfo() async throws -> CertPinningInfo
    func getComplianceInfo() async throws -> ComplianceInfo

    // MARK: - Remote Wipe

    /// §3.15 — POST /api/v1/security/wipe-confirm
    /// Body: {wipe_id, confirmed}
    /// Caller MUST supply the wipe_id received from a prior server push.
    /// PushKit handler integration is a follow-on task.
    func confirmWipe(wipeId: String, confirmed: Bool) async throws
}

public struct CertPinningInfo: Codable {
    public let certSha256: String?
    public let certSha256B64: String?
    public let spkiSha256: String?
    public let spkiSha256B64: String?
    public let validFrom: String?
    public let validTo: String?
    public let issuer: String?
    public let subject: String?
    public let pinningEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case certSha256 = "cert_sha256"
        case certSha256B64 = "cert_sha256_b64"
        case spkiSha256 = "spki_sha256"
        case spkiSha256B64 = "spki_sha256_b64"
        case validFrom = "valid_from"
        case validTo = "valid_to"
        case issuer, subject
        case pinningEnabled = "pinning_enabled"
    }
}

public struct ComplianceInfo: Codable {
    public let pqcStandard: String
    public let aeadStandard: String
    public let kdfStandard: String
    public let classicalKex: String
    public let hybridKex: String
    public let securityLevel: String
    public let forwardSecrecy: String
    public let fipsMode: String
    public let hybridPqc: String
    public let serverVersion: String
    public let protocolVersion: String
    public let hkdfParams: HkdfParams

    enum CodingKeys: String, CodingKey {
        case pqcStandard = "pqc_standard"
        case aeadStandard = "aead_standard"
        case kdfStandard = "kdf_standard"
        case classicalKex = "classical_kex"
        case hybridKex = "hybrid_kex"
        case securityLevel = "security_level"
        case forwardSecrecy = "forward_secrecy"
        case fipsMode = "fips_mode"
        case hybridPqc = "hybrid_pqc"
        case serverVersion = "server_version"
        case protocolVersion = "protocol_version"
        case hkdfParams = "hkdf_params"
    }
}

public struct HkdfParams: Codable {
    public let hybridSalt: String
    public let sessionKey: String
    public let frameKey: String
    public let rootRatchet: String
    public let pskMix: String
    public let nextChain: String
    public let zkAuth: String
    public let pwBlind: String
    public let hashAlgorithm: String

    enum CodingKeys: String, CodingKey {
        case hybridSalt = "hybrid_salt"
        case sessionKey = "session_key"
        case frameKey = "frame_key"
        case rootRatchet = "root_ratchet"
        case pskMix = "psk_mix"
        case nextChain = "next_chain"
        case zkAuth = "zk_auth"
        case pwBlind = "pw_blind"
        case hashAlgorithm = "hash_algorithm"
    }
}
