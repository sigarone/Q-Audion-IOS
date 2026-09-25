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
///
/// Lookups are sent in chunks of at most `maxHashesPerRequest` hashes;
/// `discoverChunked(alg:hashes:chunkSize:)` reports how far a pass got.
public final class BCryptoContactsDiscoverV2Client {

    public struct PepperBundle: Equatable {
        public let pepperBytes: Data
        public let alg: String
        public init(pepperBytes: Data, alg: String) {
            self.pepperBytes = pepperBytes
            self.alg = alg
        }
    }

    /// 2026-07-30 fix (real device evidence: dialing a registered E.164 from
    /// the iPhone keypad failed with "decoding failed: typeMismatch expected
    /// value type array") — this struct/the `discover()` decode below never
    /// matched what the server actually sends. `cmd/bcrypto-lite/main.go`'s
    /// `handleDiscoverContactsV2` returns `{"contacts": [safeUser, ...]}`
    /// where each entry has `id`/`user_id`/`phone_hash`/`display_name`/
    /// `avatar_url`/`status_message` — there has never been a `"results"`
    /// wrapper, a bare top-level array, or a per-entry `"hash"` echo field.
    /// Mirrors Android's `DiscoveredContactDto` (`ContactsDto.kt`) exactly,
    /// which already matches the server correctly.
    public struct DiscoveredEntry: Equatable, Decodable {
        public let userId: String
        public let phoneHash: String?
        public let displayName: String?
        public let avatarUrl: String?
        public let statusMessage: String?
        public let phoneNumber: String?

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case phoneHash = "phone_hash"
            case displayName = "display_name"
            case avatarUrl = "avatar_url"
            case statusMessage = "status_message"
            case phoneNumber = "phone_number"
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

    /// Requests are chunked to stay within the server's per-request limit.
    public static let maxHashesPerRequest: Int = 500

    /// Why a chunked pass ended before every hash was looked up.
    public enum DiscoverStopReason: Equatable {
        /// HTTP 429. `retryAfterSeconds` is the parsed `Retry-After` header, nil when
        /// the header was absent or unusable.
        case rateLimited(retryAfterSeconds: TimeInterval?)
        /// Any other failure that happened after at least one chunk had been answered
        /// (a failure of the very first chunk is thrown instead, like a single request).
        case failed(message: String)
    }

    /// What a chunked pass achieved. The entries of the chunks that were answered are
    /// always kept, whatever happened to the later ones.
    public struct DiscoverOutcome: Equatable {
        /// Contacts returned by the answered chunks, in request order.
        public let entries: [DiscoveredEntry]
        /// Number of hashes the caller asked about.
        public let totalHashes: Int
        /// Hashes the server reports as looked up. A chunk's `processed` field is used
        /// when the server sends it (clamped to the chunk size); an older server does
        /// not send it, and then the whole chunk counts as looked up, unless the answer
        /// says `truncated` without saying by how much (then none of it counts).
        public let processedHashes: Int
        /// The hashes that were not looked up, in request order: never sent (the pass
        /// stopped early), part of a chunk that failed or was rate limited, or beyond
        /// the `processed` count the server reported for an answered chunk (the server
        /// is taken to process a chunk from its start). Its count is `pendingHashes`.
        /// Lets a caller that keeps a hash-to-numbers mapping tell how many numbers,
        /// not only how many unique hashes, are still unchecked.
        public let unprocessedHashes: [String]
        /// HTTP responses received (a 429 counts, a transport failure does not).
        public let requestCount: Int
        /// True when at least one answer carried `"truncated": true`.
        public let serverTruncated: Bool
        /// Set when the pass stopped early; nil when every chunk was sent.
        public let stopReason: DiscoverStopReason?

        /// Hashes that were not looked up (never sent, or reported as not processed).
        public var pendingHashes: Int {
            return max(totalHashes - processedHashes, 0)
        }

        /// True only when every hash was sent and none was reported as not processed.
        public var isComplete: Bool {
            if stopReason != nil { return false }
            if serverTruncated { return false }
            return processedHashes >= totalHashes
        }

        /// True when the pass ended on an HTTP 429.
        public var wasRateLimited: Bool {
            guard let reason = stopReason else { return false }
            if case .rateLimited = reason { return true }
            return false
        }

        /// The `Retry-After` of the 429 that ended the pass, when it carried one.
        public var retryAfterSeconds: TimeInterval? {
            guard let reason = stopReason else { return nil }
            if case .rateLimited(retryAfterSeconds: let wait) = reason { return wait }
            return nil
        }
    }

    /// Discover contacts via `POST /api/v1/contacts/discover-v2`.
    /// Hashes are pre-computed by caller via `PepperedPhoneHash.hash(...)`.
    /// Body shape: `{"alg":"sha256","hashes":[...]}` (matches Android
    /// `DiscoverContactsV2Request`).
    ///
    /// Up to `maxHashesPerRequest` hashes go out as one request, exactly as before.
    /// A longer list is sent as sequential chunks of that size and the results are
    /// concatenated in order. An empty list sends nothing. This overload keeps the
    /// all-or-nothing contract: any failure, including HTTP 429, is thrown. Callers
    /// that want to keep the progress made before a failure use
    /// `discoverChunked(alg:hashes:chunkSize:)`.
    public func discover(alg: String, hashes: [String]) async throws -> [DiscoveredEntry] {
        let outcome: DiscoverOutcome = try await runChunks(
            alg: alg,
            hashes: hashes,
            chunkSize: BCryptoContactsDiscoverV2Client.maxHashesPerRequest,
            salvagePartial: false
        )
        return outcome.entries
    }

    /// Like `discover(alg:hashes:)`, but reports how far the pass got instead of
    /// discarding it.
    ///
    ///  - HTTP 429 stops the loop (no further request is sent) and is reported in
    ///    `stopReason` with the parsed `Retry-After`; the entries already received
    ///    are returned. Resuming later is up to the caller.
    ///  - A failure of the first chunk is thrown, like a single request would.
    ///    A failure after that stops the loop and is reported in `stopReason`.
    ///  - The answer's optional `truncated` (Bool) and `processed` (Int) fields are
    ///    read when present and ignored when absent, mistyped or accompanied by
    ///    unknown fields, so old and new servers both decode.
    ///  - An empty list sends nothing.
    ///  - `chunkSize` is clamped to `1...maxHashesPerRequest`: a smaller value sends
    ///    smaller requests, a larger one never sends an oversized request.
    public func discoverChunked(
        alg: String,
        hashes: [String],
        chunkSize: Int = BCryptoContactsDiscoverV2Client.maxHashesPerRequest
    ) async throws -> DiscoverOutcome {
        return try await runChunks(
            alg: alg,
            hashes: hashes,
            chunkSize: chunkSize,
            salvagePartial: true
        )
    }

    /// Answer of one request, before it is folded into the pass.
    private struct ChunkResult {
        let entries: [DiscoveredEntry]
        let truncated: Bool?
        let processed: Int?
    }

    private enum ChunkResponse {
        case answered(ChunkResult)
        case rateLimited(retryAfterSeconds: TimeInterval?)
    }

    /// Real server shape (handleDiscoverContactsV2): `{"contacts": [...]}`, plus the
    /// optional `truncated` / `processed` fields of newer servers. Those two are read
    /// leniently on purpose: a missing, null or wrongly typed value must never fail
    /// the whole answer (the contacts are what matters).
    private struct DiscoverResponseBody: Decodable {
        let contacts: [DiscoveredEntry]
        let truncated: Bool?
        let processed: Int?

        private enum CodingKeys: String, CodingKey {
            case contacts
            case truncated
            case processed
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.contacts = try container.decode([DiscoveredEntry].self, forKey: .contacts)
            let truncatedValue: Bool? = try? container.decodeIfPresent(Bool.self, forKey: .truncated)
            let processedValue: Int? = try? container.decodeIfPresent(Int.self, forKey: .processed)
            self.truncated = truncatedValue
            self.processed = processedValue
        }
    }

    /// Sends the chunks one after the other. `salvagePartial == false` reproduces the
    /// single-request contract (every failure is thrown); `true` keeps what was
    /// received and reports the stop instead.
    private func runChunks(
        alg: String,
        hashes: [String],
        chunkSize: Int,
        salvagePartial: Bool
    ) async throws -> DiscoverOutcome {
        // At least 1 (a zero or negative size would never advance) and at most
        // the server's per-request limit (a larger caller value would send an
        // oversized request).
        let atLeastOne: Int = max(chunkSize, 1)
        let size: Int = min(atLeastOne, BCryptoContactsDiscoverV2Client.maxHashesPerRequest)
        var entries: [DiscoveredEntry] = []
        var processedTotal: Int = 0
        var requestCount: Int = 0
        var answeredChunks: Int = 0
        var sawTruncation: Bool = false
        var stop: DiscoverStopReason?
        var start: Int = 0
        var unprocessed: [String] = []

        while start < hashes.count {
            let end: Int = min(start + size, hashes.count)
            let chunk: [String] = Array(hashes[start..<end])
            start = end

            let answer: ChunkResponse
            do {
                answer = try await postDiscoverChunk(alg: alg, hashes: chunk)
            } catch {
                if !salvagePartial || answeredChunks == 0 || Task.isCancelled {
                    throw error
                }
                stop = .failed(message: error.localizedDescription)
                unprocessed.append(contentsOf: chunk)
                break
            }
            requestCount += 1

            switch answer {
            case .rateLimited(retryAfterSeconds: let wait):
                if !salvagePartial {
                    throw Error.httpError(429)
                }
                stop = .rateLimited(retryAfterSeconds: wait)
                unprocessed.append(contentsOf: chunk)
            case .answered(let result):
                answeredChunks += 1
                entries.append(contentsOf: result.entries)
                let done: Int = BCryptoContactsDiscoverV2Client.processedCount(
                    reported: result.processed,
                    truncated: result.truncated,
                    sent: chunk.count
                )
                processedTotal += done
                if done < chunk.count {
                    unprocessed.append(contentsOf: chunk[done...])
                }
                if result.truncated == true {
                    sawTruncation = true
                }
            }
            if stop != nil {
                break
            }
        }
        // Hashes never sent because the pass stopped early.
        if start < hashes.count {
            unprocessed.append(contentsOf: hashes[start...])
        }

        return DiscoverOutcome(
            entries: entries,
            totalHashes: hashes.count,
            processedHashes: processedTotal,
            unprocessedHashes: unprocessed,
            requestCount: requestCount,
            serverTruncated: sawTruncation,
            stopReason: stop
        )
    }

    /// Hashes of one chunk to count as looked up: what the server reported, clamped
    /// to what was sent. An older server reports nothing and the whole chunk counts.
    /// An answer that says the batch was cut without saying by how much confirms
    /// nothing, so none of that chunk counts.
    private static func processedCount(reported: Int?, truncated: Bool?, sent: Int) -> Int {
        guard let value = reported else {
            if truncated == true { return 0 }
            return sent
        }
        return min(max(value, 0), sent)
    }

    /// One `discover-v2` request. The wire format is the one this client has always
    /// used; only a 429 is told apart (it is returned, with its `Retry-After`).
    private func postDiscoverChunk(alg: String, hashes: [String]) async throws -> ChunkResponse {
        var req = URLRequest(url: baseUrl.appendingPathComponent("api/v1/contacts/discover-v2"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = bearerTokenProvider() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = ["alg": alg, "hashes": hashes]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 429 {
                let rawWait: String? = http.value(forHTTPHeaderField: "Retry-After")
                let wait: TimeInterval? = LiveLogBackoff.parseRetryAfter(rawWait, now: Date())
                return .rateLimited(retryAfterSeconds: wait)
            }
            if !(200..<300).contains(http.statusCode) {
                throw Error.httpError(http.statusCode)
            }
        }
        let decoded: DiscoverResponseBody
        do {
            decoded = try JSONDecoder().decode(DiscoverResponseBody.self, from: data)
        } catch {
            throw Error.decodingFailed(String(describing: error))
        }
        let result = ChunkResult(
            entries: decoded.contacts,
            truncated: decoded.truncated,
            processed: decoded.processed
        )
        return .answered(result)
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
