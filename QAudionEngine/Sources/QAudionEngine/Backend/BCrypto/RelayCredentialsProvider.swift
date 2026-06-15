import Foundation

/// TTL-aware cache for `/api/v1/calling/relays` responses.
///
/// Mirror of Android's
/// `core/core-data/.../turn/RelayCredentialsProvider.kt`. Keep iOS and
/// Android refresh semantics aligned so Codemagic-generated TURN
/// credentials don't expire mid-call on one platform but not the other.
///
/// Refresh conditions:
///   1. No cached bundle yet.
///   2. Cached bundle within `refreshBeforeTtlMs` of expiry.
///   3. Caller passes `forceRefresh = true` (e.g. after TURN auth failure).
///
/// Thread-safety: a single internal lock guards the cache; concurrent
/// refresh calls are coalesced — only one network round-trip is in flight
/// at any time.
public actor RelayCredentialsProvider {

    public struct RelayBundle: Equatable {
        public let servers: [RelayServer]
        public let wssTurnUrl: String?
        public let onionAddress: String?
        /// MASQUE proxy endpoint (`masque_url`) for the HTTP/3 CONNECT-UDP
        /// TURN fallback. nil when the server doesn't advertise MASQUE.
        public let masqueUrl: String?
        /// Epoch milliseconds at which the freshest server expires.
        public let expiresAtEpochMs: Int64

        public init(
            servers: [RelayServer],
            wssTurnUrl: String?,
            onionAddress: String?,
            masqueUrl: String? = nil,
            expiresAtEpochMs: Int64
        ) {
            self.servers = servers
            self.wssTurnUrl = wssTurnUrl
            self.onionAddress = onionAddress
            self.masqueUrl = masqueUrl
            self.expiresAtEpochMs = expiresAtEpochMs
        }

        public func isValid(nowMs: Int64 = Self.nowMs()) -> Bool {
            expiresAtEpochMs > nowMs
        }

        public static func nowMs() -> Int64 {
            Int64(Date().timeIntervalSince1970 * 1000)
        }
    }

    public static let defaultTtlSec: Int64 = 3600
    /// Refresh when within 5 minutes of expiry — matches Android.
    public static let refreshBeforeTtlMs: Int64 = 5 * 60 * 1000

    private let api: CallingApi
    private var cached: RelayBundle?
    private var inflightRefresh: Task<RelayBundle, Error>?

    public init(api: CallingApi) { self.api = api }

    /// Return a valid bundle, refreshing if needed.
    public func credentials(forceRefresh: Bool = false) async throws -> RelayBundle {
        let now = RelayBundle.nowMs()
        if !forceRefresh,
           let existing = cached,
           existing.expiresAtEpochMs - Self.refreshBeforeTtlMs > now {
            return existing
        }
        // Coalesce concurrent refreshes.
        if let inflight = inflightRefresh {
            return try await inflight.value
        }
        let task = Task<RelayBundle, Error> { [self] in
            try await self.fetch()
        }
        inflightRefresh = task
        defer { inflightRefresh = nil }
        let bundle = try await task.value
        cached = bundle
        return bundle
    }

    /// Convenience wrapper for the WebRTC call path. Returns a [RelayBundle]
    /// or `nil` if the network call failed — caller falls back to a static
    /// STUN-only list rather than aborting the call.
    public func currentOrRefresh() async -> RelayBundle? {
        do {
            return try await credentials()
        } catch {
            print("[RelayCredentialsProvider] currentOrRefresh failed: \(error)")
            return nil
        }
    }

    /// Non-suspend peek at the last-known-good bundle.
    /// Returns `nil` if we never succeeded or the cached bundle expired.
    public func cachedOrNil() -> RelayBundle? {
        guard let existing = cached, existing.isValid() else { return nil }
        return existing
    }

    /// Drop the cache; the next [credentials] call goes to the network.
    public func invalidate() {
        cached = nil
    }

    // MARK: - Internal

    private func fetch() async throws -> RelayBundle {
        let response = try await api.getRelaysResponse()
        let now = RelayBundle.nowMs()
        let shortestTtl = response.relays
            .map { Int64($0.ttl) }
            .min() ?? Self.defaultTtlSec
        return RelayBundle(
            servers: response.relays,
            wssTurnUrl: response.wssTurnUrl,
            onionAddress: response.onionAddress,
            masqueUrl: response.masqueUrl,
            expiresAtEpochMs: now + shortestTtl * 1000
        )
    }
}
