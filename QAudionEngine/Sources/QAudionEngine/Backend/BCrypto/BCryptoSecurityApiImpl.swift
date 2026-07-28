import Foundation

public final class BCryptoSecurityApiImpl: SecurityApi {
    private let rest: BCryptoRestClient
    public init(rest: BCryptoRestClient) { self.rest = rest }

    // MARK: - Zero-Knowledge Auth

    /// §3.11 — POST /api/v1/security/zk-register
    /// Android wire shape: {zk_commitment, public_params?}
    public func zkRegister(zkCommitment: Data, publicParams: Data?) async throws {
        var dict: [String: Any] = [
            "zk_commitment": zkCommitment.base64EncodedString()
        ]
        if let params = publicParams {
            dict["public_params"] = params.base64EncodedString()
        }
        let body = try JSONSerialization.data(withJSONObject: dict, options: .sortedKeys)
        _ = try await rest.post("/api/v1/security/zk-register", body: body)
    }

    /// §3.12 — POST /api/v1/security/zk-auth
    /// Android wire shape: {challenge, proof}
    /// Returns bearer/session token bytes from the response body.
    public func zkAuth(challenge: Data, proof: Data) async throws -> Data {
        let dict: [String: Any] = [
            "challenge": challenge.base64EncodedString(),
            "proof": proof.base64EncodedString()
        ]
        let body = try JSONSerialization.data(withJSONObject: dict, options: .sortedKeys)
        return try await rest.post("/api/v1/security/zk-auth", body: body)
    }

    // MARK: - Hybrid PQC Relay

    /// §3.13 — POST /api/v1/security/pqc-relay
    /// Android wire shape: {recipient_id, ciphertext, algorithm}
    /// Default algorithm is "ml-kem-1024" (project target; Android default
    /// "ml-kem-768" is wrong for this deployment).
    public func sendPqcKeyExchange(recipientId: String, ciphertext: Data,
                                   algorithm: String = "ml-kem-1024") async throws {
        let dict: [String: Any] = [
            "recipient_id": recipientId,
            "ciphertext": ciphertext.base64EncodedString(),
            "algorithm": algorithm
        ]
        let body = try JSONSerialization.data(withJSONObject: dict, options: .sortedKeys)
        _ = try await rest.post("/api/v1/security/pqc-relay", body: body)
    }

    // MARK: - Threat Reporting

    /// §3.14 — POST /api/v1/security/threat-report
    /// Android wire shape: {category, details, severity}
    /// category: snake_case threat kind string (e.g. "replay_attack")
    /// details: human-readable description
    /// severity: "info" | "warning" | "critical"
    public func reportThreat(category: String, details: String, severity: String) async throws {
        let dict: [String: Any] = [
            "category": category,
            "details": details,
            "severity": severity
        ]
        let body = try JSONSerialization.data(withJSONObject: dict, options: .sortedKeys)
        _ = try await rest.post("/api/v1/security/threat-report", body: body)
    }

    // MARK: - Server Info (iOS-only, no Android counterpart)

    /// iOS-only (no Android counterpart). See audit §2 iOS-only table.
    public func getCertInfo() async throws -> CertPinningInfo {
        let data = try await rest.get("/api/v1/security/cert-info")
        return try JSONDecoder().decode(CertPinningInfo.self, from: data)
    }

    /// iOS-only (no Android counterpart). See audit §2 iOS-only table.
    public func getComplianceInfo() async throws -> ComplianceInfo {
        let data = try await rest.get("/api/v1/security/compliance")
        return try JSONDecoder().decode(ComplianceInfo.self, from: data)
    }

    // MARK: - Remote Wipe

    /// §3.15 — POST /api/v1/security/wipe-confirm
    /// Android wire shape: {wipe_id, confirmed}
    /// Caller MUST supply the wipe_id received from a prior server push.
    /// PushKit handler integration is a follow-on task.
    public func confirmWipe(wipeId: String, confirmed: Bool) async throws {
        let dict: [String: Any] = [
            "wipe_id": wipeId,
            "confirmed": confirmed
        ]
        let body = try JSONSerialization.data(withJSONObject: dict, options: .sortedKeys)
        _ = try await rest.post("/api/v1/security/wipe-confirm", body: body)
    }
}
