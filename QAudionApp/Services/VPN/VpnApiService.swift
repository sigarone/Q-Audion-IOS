// VpnApiService.swift — Q-Audion iOS
//
// REST client for the BCrypto VPN control-plane endpoints.
// Mirrors Android `VpnApi.kt` and Desktop `vpn-api.ts`.
//
// Endpoints:
//   GET  /api/v1/vpn/nodes          → [VpnNode]
//   POST /api/v1/vpn/token          → VpnTokenResponse
//   POST /api/v1/vpn/wg-register    → WgConfigResponse

import Foundation
import QAudionEngine

enum VpnApiError: LocalizedError {
    case httpError(Int, String)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let body):
            return "VPN API errore \(code): \(body)"
        case .decodingError(let err):
            return "VPN risposta non valida: \(err.localizedDescription)"
        }
    }
}

struct VpnApiService {
    private static let base = URL(string: "https://voip.bcrypto.com/api/v1")!
    // URLSession retains CertPinningDelegate internally, so this is safe
    // after the temporary BCryptoRestClient is released.
    private let decoder: JSONDecoder = JSONDecoder()
    /// SECURITY C-6 — cert-pinned session for all VPN control-plane calls.
    /// Pins Let's Encrypt E8 + ISRG Root X1 (see PinnedServerHost.certChainPins).
    private let session: URLSession = PinnedURLSession.make(for: PinnedServerHost.url)

    // MARK: - Fetch helpers

    private func get<T: Decodable>(
        _ path: String,
        bearerToken: String
    ) async throws -> T {
        try await request(path: path, method: "GET", bearerToken: bearerToken, body: nil)
    }

    private func post<T: Decodable>(
        _ path: String,
        bearerToken: String,
        body: some Encodable
    ) async throws -> T {
        let data = try JSONEncoder().encode(body)
        return try await request(path: path, method: "POST", bearerToken: bearerToken, body: data)
    }

    private func request<T: Decodable>(
        path: String,
        method: String,
        bearerToken: String,
        body: Data?
    ) async throws -> T {
        let url = Self.base.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw VpnApiError.httpError(http.statusCode, body)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw VpnApiError.decodingError(error)
        }
    }

    // MARK: - Public API

    /// Returns available VPN nodes with live load/ping telemetry.
    func getNodes(accessToken: String) async throws -> [VpnNode] {
        try await get("vpn/nodes", bearerToken: accessToken)
    }

    /// Exchanges the session JWT for a short-lived VPN sub-token.
    func getToken(accessToken: String) async throws -> VpnTokenResponse {
        try await post("vpn/token", bearerToken: accessToken, body: EmptyBody())
    }

    /// Registers a WireGuard public key with the selected node.
    /// Returns server WG config (pubkey, endpoint, assigned IP, PSK).
    ///
    /// - Parameter accessToken: Main session JWT (HS256), NOT the VPN sub-token.
    func registerWgPeer(
        accessToken: String,
        clientPubkey: String,
        nodeId: String
    ) async throws -> WgConfigResponse {
        struct Body: Encodable {
            let clientPubkey: String
            let nodeId: String
            enum CodingKeys: String, CodingKey {
                case clientPubkey = "client_pubkey"
                case nodeId       = "node_id"
            }
        }
        return try await post(
            "vpn/wg-register",
            bearerToken: accessToken,
            body: Body(clientPubkey: clientPubkey, nodeId: nodeId)
        )
    }

    private struct EmptyBody: Encodable {}
}
