import Foundation

/// Security API matching server endpoints:
/// - ZK auth register/verify
/// - Hybrid PQC key exchange relay
/// - Threat reporting
/// - Cert pinning info
/// - Compliance info
public protocol SecurityApi {
    // MARK: - Zero-Knowledge Auth
    func zkRegister(salt: Data, verifierV: Data, publicBlind: Data) async throws
    func zkAuth(clientPublic: Data, proof: Data, nonce: Data) async throws -> ZKAuthResult

    // MARK: - Hybrid PQC Relay
    func sendPqcKeyExchange(targetUserId: String, pqcCiphertext: Data, x25519PublicKey: Data,
                            enclavePublicKey: Data?, messageType: String) async throws

    // MARK: - Threat Reporting
    func reportThreat(kind: ThreatKind, severity: ThreatSeverity, detail: String, sessionId: String?) async throws

    // MARK: - Server Info
    func getCertInfo() async throws -> CertPinningInfo
    func getComplianceInfo() async throws -> ComplianceInfo

    // MARK: - Remote Wipe
    func confirmWipe(deviceId: String) async throws
}

public struct ZKAuthResult: Codable {
    public let verified: Bool
    public let sessionId: String?
    enum CodingKeys: String, CodingKey {
        case verified
        case sessionId = "session_id"
    }
}

public enum ThreatKind: String, Codable {
    case replayAttack = "replay_attack"
    case outOfOrderInjection = "out_of_order_injection"
    case timingAnomaly = "timing_anomaly"
    case keyReuse = "key_reuse"
    case frameRateAnomaly = "frame_rate_anomaly"
    case sequenceGap = "sequence_gap"
}

public enum ThreatSeverity: String, Codable {
    case info, warning, critical
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
