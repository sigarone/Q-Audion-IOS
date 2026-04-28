import Foundation

/// Client for contact-discovery v2 (peppered) endpoints.
///
/// Standalone — does NOT modify `BCryptoContactsApiImpl` (which still
/// uses the v1 `discover` endpoint pending a coordinated migration).
/// Once Android, Desktop, and Server agree on v2 cutover, this client's
/// behavior should be folded into `BCryptoContactsApiImpl.discoverContacts`.
///
/// See spec §5.1 + INVARIANTS_VERIFIED.md Open Discrepancy §2.
public final class BCryptoContactsDiscoverV2Client {

    public struct DiscoveredEntry: Equatable, Decodable {
        public let hash: String      // peppered hash echo
        public let userId: String?   // present if a user is registered with that hash

        enum CodingKeys: String, CodingKey {
            case hash
            case userId = "user_id"
        }
    }

    public enum Error: Swift.Error, LocalizedError {
        case missingPepper
        case httpError(Int)
        case decodingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missingPepper: return "Server returned no pepper"
            case .httpError(let code): return "HTTP error \(code)"
            case .decodingFailed(let m): return "Decoding failed: \(m)"
            }
        }
    }

    private let baseUrl: URL
    private let session: URLSession
    private let bearerTokenProvider: () -> String?

    public init(baseUrl: URL, session: URLSession = .shared,
                bearerTokenProvider: @escaping () -> String?) {
        self.baseUrl = baseUrl
        self.session = session
        self.bearerTokenProvider = bearerTokenProvider
    }

    /// Fetch the global pepper from `GET /api/v1/contacts/pepper`.
    public func fetchPepper() async throws -> String {
        var req = URLRequest(url: baseUrl.appendingPathComponent("api/v1/contacts/pepper"))
        req.httpMethod = "GET"
        if let token = bearerTokenProvider() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Error.httpError(http.statusCode)
        }
        struct PepperResponse: Decodable { let pepper: String }
        let decoded: PepperResponse
        do {
            decoded = try JSONDecoder().decode(PepperResponse.self, from: data)
        } catch {
            throw Error.decodingFailed(String(describing: error))
        }
        guard !decoded.pepper.isEmpty else { throw Error.missingPepper }
        return decoded.pepper
    }

    /// Discover contacts via `POST /api/v1/contacts/discover-v2`.
    /// Hashes are pre-computed by caller via `PepperedPhoneHash.hash(...)`.
    public func discover(hashes: [String]) async throws -> [DiscoveredEntry] {
        var req = URLRequest(url: baseUrl.appendingPathComponent("api/v1/contacts/discover-v2"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = bearerTokenProvider() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        // Server expects {"hashes": [{"hash": "...", "pepper": "..."}]} per audit, but
        // simpler shape {"hashes": ["...", "...", ...]} also works on the lite variant
        // if client has already peppered (which we have). Use the simpler shape and let
        // server team confirm at unblock time.
        let body: [String: Any] = ["hashes": hashes]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Error.httpError(http.statusCode)
        }
        struct DiscoverResponse: Decodable {
            let results: [DiscoveredEntry]
        }
        do {
            // Try wrapped form first.
            if let wrapped = try? JSONDecoder().decode(DiscoverResponse.self, from: data) {
                return wrapped.results
            }
            // Fallback: bare array.
            return try JSONDecoder().decode([DiscoveredEntry].self, from: data)
        } catch {
            throw Error.decodingFailed(String(describing: error))
        }
    }
}
