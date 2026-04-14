import Foundation

public final class BCryptoSecurityApiImpl: SecurityApi {
    private let rest: BCryptoRestClient
    public init(rest: BCryptoRestClient) { self.rest = rest }

    // MARK: - Zero-Knowledge Auth

    public func zkRegister(salt: Data, verifierV: Data, publicBlind: Data) async throws {
        let dict: [String: Any] = [
            "salt": salt.base64EncodedString(),
            "verifier_v": verifierV.base64EncodedString(),
            "public_blind": publicBlind.base64EncodedString()
        ]
        let body = try JSONSerialization.data(withJSONObject: dict)
        _ = try await rest.post("/api/v1/security/zk-register", body: body)
    }

    public func zkAuth(clientPublic: Data, proof: Data, nonce: Data) async throws -> ZKAuthResult {
        let dict: [String: Any] = [
            "client_public": clientPublic.base64EncodedString(),
            "proof": proof.base64EncodedString(),
            "nonce": nonce.base64EncodedString()
        ]
        let body = try JSONSerialization.data(withJSONObject: dict)
        let data = try await rest.post("/api/v1/security/zk-auth", body: body)
        return try JSONDecoder().decode(ZKAuthResult.self, from: data)
    }

    // MARK: - Hybrid PQC Relay

    public func sendPqcKeyExchange(targetUserId: String, pqcCiphertext: Data,
                                    x25519PublicKey: Data, enclavePublicKey: Data?,
                                    messageType: String) async throws {
        var dict: [String: Any] = [
            "target_user_id": targetUserId,
            "pqc_ciphertext": pqcCiphertext.base64EncodedString(),
            "x25519_public_key": x25519PublicKey.base64EncodedString(),
            "message_type": messageType
        ]
        if let enclave = enclavePublicKey {
            dict["enclave_public_key"] = enclave.base64EncodedString()
        }
        let body = try JSONSerialization.data(withJSONObject: dict)
        _ = try await rest.post("/api/v1/security/pqc-relay", body: body)
    }

    // MARK: - Threat Reporting

    public func reportThreat(kind: ThreatKind, severity: ThreatSeverity,
                              detail: String, sessionId: String?) async throws {
        var dict: [String: Any] = [
            "threat_kind": kind.rawValue,
            "severity": severity.rawValue,
            "detail": detail,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        if let sid = sessionId { dict["session_id"] = sid }
        let body = try JSONSerialization.data(withJSONObject: dict)
        _ = try await rest.post("/api/v1/security/threat-report", body: body)
    }

    // MARK: - Server Info

    public func getCertInfo() async throws -> CertPinningInfo {
        let data = try await rest.get("/api/v1/security/cert-info")
        return try JSONDecoder().decode(CertPinningInfo.self, from: data)
    }

    public func getComplianceInfo() async throws -> ComplianceInfo {
        let data = try await rest.get("/api/v1/security/compliance")
        return try JSONDecoder().decode(ComplianceInfo.self, from: data)
    }

    // MARK: - Remote Wipe

    public func confirmWipe(deviceId: String) async throws {
        let dict = ["device_id": deviceId]
        let body = try JSONSerialization.data(withJSONObject: dict)
        _ = try await rest.post("/api/v1/security/wipe-confirm", body: body)
    }
}
