import CryptoKit
import Foundation

/// Failures of the legal endpoints that the screens tell apart.
public enum LegalApiError: Error, Equatable, Sendable {
    /// `409 terms_version_stale`: the server moved to a newer edition (or another text) since the app fetched it.
    case versionStale
    /// The server answered with something that is not the contract.
    case malformedResponse
}

/// The legal endpoints (`/api/v1/legal/...`).
public protocol LegalApi: Sendable {
    /// `GET /legal/terms?lang=`: no authentication needed.
    func fetchTerms(lang: String) async throws -> LegalTermsFetch
    /// `GET /legal/status`.
    func status() async throws -> LegalStatus
    /// `POST /legal/accept`: throws ``LegalApiError/versionStale`` on a 409.
    func accept(_ acceptance: TermsAcceptance) async throws
    /// `GET /legal/acceptance`: the copy of what the person accepted, as the server returns it.
    func acceptanceCopy() async throws -> Data
    /// `POST /legal/withdraw` with `{"confirm": true}`: records the withdrawal and runs the account deletion.
    func withdraw() async throws -> WithdrawalReceipt
}

public final class BCryptoLegalApi: LegalApi, @unchecked Sendable {
    private let rest: BCryptoRestClient

    public init(rest: BCryptoRestClient) { self.rest = rest }

    /// Lower-case hex SHA-256 of `data`.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func fetchTerms(lang: String) async throws -> LegalTermsFetch {
        let code = LegalLanguage.code(forAppLanguage: lang)
        let data = try await rest.get("/api/v1/legal/terms?lang=\(code)")
        guard let document = try? JSONDecoder().decode(LegalTermsDocument.self, from: data) else {
            throw LegalApiError.malformedResponse
        }
        return LegalTermsFetch(document: document, sha256: Self.sha256Hex(data))
    }

    public func status() async throws -> LegalStatus {
        let data = try await rest.get("/api/v1/legal/status")
        guard let status = try? JSONDecoder().decode(LegalStatus.self, from: data) else {
            throw LegalApiError.malformedResponse
        }
        return status
    }

    public func accept(_ acceptance: TermsAcceptance) async throws {
        do {
            _ = try await rest.post("/api/v1/legal/accept", body: try acceptance.jsonData())
        } catch BCryptoError.httpError(409) {
            throw LegalApiError.versionStale
        }
    }

    public func acceptanceCopy() async throws -> Data {
        try await rest.get("/api/v1/legal/acceptance")
    }

    public func withdraw() async throws -> WithdrawalReceipt {
        let body = try JSONSerialization.data(withJSONObject: ["confirm": true])
        let data = try await rest.post("/api/v1/legal/withdraw", body: body)
        guard let receipt = try? JSONDecoder().decode(WithdrawalReceipt.self, from: data),
              !receipt.receiptText.isEmpty else { throw LegalApiError.malformedResponse }
        return receipt
    }
}
