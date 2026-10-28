import Foundation
import DeviceCheck
import QAudionEngine

/// DeviceCheck App Attest, reduced to the engine protocol.
struct SystemAppAttestService: AppAttestPlatformService {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        do { return try await DCAppAttestService.shared.generateKey() } catch { throw Self.map(error) }
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        do {
            return try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash)
        } catch { throw Self.map(error) }
    }

    private static func map(_ error: Error) -> AppAttestServiceError {
        let ns = error as NSError
        guard ns.domain == DCError.errorDomain, let code = DCError.Code(rawValue: ns.code) else { return .failed(-1) }
        switch code {
        case .invalidKey: return .invalidKey
        case .serverUnavailable: return .transient
        default: return .failed(ns.code)
        }
    }
}

/// The two attestation endpoints; the bearer token is read at call time.
struct AppAttestHTTPTransport: AppAttestTransport {
    let serverUrl: String
    let bearer: @Sendable () -> String?
    let session: URLSession

    func challenge() async throws -> String {
        guard let token = bearer(), !token.isEmpty,
              let request = AppAttestRequests.challengeRequest(serverUrl: serverUrl, bearer: token) else {
            throw AppAttestTransportError(status: 401, code: nil)
        }
        let data = try await send(request)
        guard let challenge = AppAttestRequests.parseChallenge(data) else {
            throw AppAttestTransportError(status: 0, code: "bad_body")
        }
        return challenge
    }

    func submit(_ body: AppAttestSubmission) async throws {
        guard let token = bearer(), !token.isEmpty,
              let request = AppAttestRequests.attestRequest(serverUrl: serverUrl, bearer: token, submission: body) else {
            throw AppAttestTransportError(status: 401, code: nil)
        }
        _ = try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            throw AppAttestTransportError(status: 0, code: nil)
        }
        guard let http = response as? HTTPURLResponse else { throw AppAttestTransportError(status: 0, code: nil) }
        guard (200..<300).contains(http.statusCode) else {
            throw AppAttestTransportError(status: http.statusCode, code: AppAttestRequests.parseErrorCode(data))
        }
        return data
    }
}
