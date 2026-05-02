import Foundation

/// Client for contact-discovery v2 (peppered) endpoints.
///
/// **W343 cross-platform parity update:**
///  - `fetchPepper()` now decodes `{pepper_b64, alg}` (matches Android's
///    `ContactPepperResponse`) and returns both the pepper bytes and the
///    algorithm tag the server expects on the discover request.
///  - `discover(alg:hashes:)` now sends `{alg, hashes}` matching Android's
///    `DiscoverContactsV2Request`.
///  - New `registerPepperedPhones(alg:hashes:)` uploads our own peppered
///    phones to `POST /api/v1/contacts/phones`. Without this PEERS who
///    have OUR phone in their contact book never get matched on
///    discovery; iOS users were one-way-invisible to Android peers.
public final class BCryptoContactsDiscoverV2Client {

    public struct PepperBundle: Equatable {
        public let pepperBytes: Data
        public let alg: String
        public init(pepperBytes: Data, alg: String) {
            self.pepperBytes = pepperBytes
            self.alg = alg
        }
    }

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
        case invalidPepperBase64
        case httpError(Int)
        case decodingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missingPepper: return "Server returned no pepper"
            case .invalidPepperBase64: return "Pepper response is not valid base64"
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

    // MARK: - Pepper

    /// Fetch the global pepper bundle from `GET /api/v1/contacts/pepper`.
    /// Server response shape (Android `ContactPepperResponse`):
    /// ```json
    /// { "pepper_b64": "<base64>", "alg": "sha256" }
    /// ```
    /// Some older / lite server variants may instead return `{"pepper": "..."}`
    /// — we tolerate both shapes and prefer the canonical one.
    public func fetchPepper() async throws -> PepperBundle {
        var req = URLRequest(url: baseUrl.appendingPathComponent("api/v1/contacts/pepper"))
        req.httpMethod = "GET"
        if let token = bearerTokenProvider() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Error.httpError(http.statusCode)
        }
        struct PepperResponse: Decodable {
            let pepperB64: String?
            let pepper: String?
            let alg: String?
            enum CodingKeys: String, CodingKey {
                case pepperB64 = "pepper_b64"
                case pepper, alg
            }
        }
        let decoded: PepperResponse
        do {
            decoded = try JSONDecoder().decode(PepperResponse.self, from: data)
        } catch {
            throw Error.decodingFailed(String(describing: error))
        }
        let payload = decoded.pepperB64 ?? decoded.pepper
        guard let payload = payload, !payload.isEmpty else {
            throw Error.missingPepper
        }
        guard let bytes = Data(base64Encoded: payload) else {
            throw Error.invalidPepperBase64
        }
        let alg = decoded.alg ?? "sha256"
        return PepperBundle(pepperBytes: bytes, alg: alg)
    }

    // MARK: - Discover

    /// Discover contacts via `POST /api/v1/contacts/discover-v2`.
    /// Hashes are pre-computed by caller via `PepperedPhoneHash.hash(...)`.
    /// Body shape: `{"alg":"sha256","hashes":[...]}` (matches Android
    /// `DiscoverContactsV2Request`).
    public func discover(alg: String, hashes: [String]) async throws -> [DiscoveredEntry] {
        var req = URLRequest(url: baseUrl.appendingPathComponent("api/v1/contacts/discover-v2"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = bearerTokenProvider() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = ["alg": alg, "hashes": hashes]
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

    /// Legacy overload for callers that haven't been updated to thread
    /// the `alg` from `fetchPepper()`. Defaults to `"sha256"`.
    @available(*, deprecated, renamed: "discover(alg:hashes:)")
    public func discover(hashes: [String]) async throws -> [DiscoveredEntry] {
        return try await discover(alg: "sha256", hashes: hashes)
    }

    // MARK: - Register own peppered phones (W343)

    /// Upload our own peppered phone hashes via
    /// `POST /api/v1/contacts/phones`. Without this peers who have our
    /// number stored in their device contacts never match against us on
    /// discovery — the server only has UUID/peppered-hash mappings for
    /// numbers that have been registered via this endpoint. Mirrors
    /// Android `DiscoverContactsUseCase.syncOwnPhones`.
    @discardableResult
    public func registerPepperedPhones(alg: String, hashes: [String]) async throws -> Int {
        var req = URLRequest(url: baseUrl.appendingPathComponent("api/v1/contacts/phones"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = bearerTokenProvider() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = ["alg": alg, "hashes": hashes]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Error.httpError(http.statusCode)
        }
        return hashes.count
    }
}
