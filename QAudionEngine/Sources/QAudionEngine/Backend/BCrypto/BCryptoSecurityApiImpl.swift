import Foundation

public final class BCryptoSecurityApiImpl: SecurityApi {
    private let rest: BCryptoRestClient
    public init(rest: BCryptoRestClient) { self.rest = rest }

    // MARK: - Zero-Knowledge Auth

    /// TODO(parity, PHASE1_REST_AUDIT §3.11): wire schema disagrees with
    /// Android `ZkRegisterRequest { zk_commitment, public_params? }`. iOS
    /// currently sends `{salt, verifier_v, public_blind}` (an SRP-style
    /// verifier). Neither shape is self-evidently correct — the server
    /// team must confirm the intended ZK protocol before this is
    /// normalised. DO NOT auto-rewrite to match Android without a server
    /// contract confirmation.
    public func zkRegister(salt: Data, verifierV: Data, publicBlind: Data) async throws {
        let dict: [String: Any] = [
            "salt": salt.base64EncodedString(),
            "verifier_v": verifierV.base64EncodedString(),
            "public_blind": publicBlind.base64EncodedString()
        ]
        let body = try JSONSerialization.data(withJSONObject: dict)
        _ = try await rest.post("/api/v1/security/zk-register", body: body)
    }

    /// TODO(parity, PHASE1_REST_AUDIT §3.12): wire schema disagrees with
    /// Android `ZkAuthRequest { challenge, proof }`. iOS sends
    /// `{client_public, proof, nonce}`. Pending server-team
    /// clarification.
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

    /// TODO(parity, PHASE1_REST_AUDIT §3.13): wire schema disagrees with
    /// Android `PqcRelayRequest { recipient_id, ciphertext, algorithm }`.
    /// iOS sends a more structured hybrid-handshake payload
    /// (`target_user_id`, `pqc_ciphertext`, `x25519_public_key`,
    /// `enclave_public_key?`, `message_type`). The Android shape is a
    /// thin opaque relay envelope — the server team should confirm
    /// whether the hybrid-handshake metadata is expected in-band or
    /// negotiated out-of-band.
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

    /// TODO(parity, PHASE1_REST_AUDIT §3.14): wire schema disagrees with
    /// Android `ThreatReportRequest { category, details, severity }`.
    /// iOS sends `{threat_kind, severity, detail, timestamp, session_id?}`.
    /// `detail` vs `details` and `threat_kind` vs `category` are safe
    /// renames once the server team confirms; `timestamp`/`session_id`
    /// on iOS may need to be dropped or added server-side.
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

    /// TODO(parity, PHASE1_REST_AUDIT §3.15): wire schema disagrees with
    /// Android `WipeConfirmRequest { wipe_id, confirmed }`. iOS sends
    /// `{device_id}`. Pending server-team clarification — the Android
    /// `wipe_id` suggests a nonce/challenge issued by a prior request;
    /// iOS may be missing that round-trip entirely.
    public func confirmWipe(deviceId: String) async throws {
        let dict = ["device_id": deviceId]
        let body = try JSONSerialization.data(withJSONObject: dict)
        _ = try await rest.post("/api/v1/security/wipe-confirm", body: body)
    }
}
