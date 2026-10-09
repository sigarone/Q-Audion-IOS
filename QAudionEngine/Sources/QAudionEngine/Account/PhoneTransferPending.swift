import Foundation

/// A request, made by someone else, to move the phone number that is a login identity of this
/// account. The server lists it for the holder until it is no longer pending; `expiresAt` is when it
/// is due. The listing carries neither the number nor the requester.
public struct PhoneTransferPending: Equatable, Sendable, Identifiable {
    public let id: String
    public let expiresAt: Date

    public init(id: String, expiresAt: Date) {
        self.id = id
        self.expiresAt = expiresAt
    }

    /// Whole hours left, rounded DOWN, so the screen never promises more time than there is. 0 means
    /// "less than an hour" (also when the device clock is ahead of the expiry: the entry itself is never
    /// dropped because of the local clock, only the server decides when it is gone).
    public func hoursRemaining(at now: Date) -> Int {
        let seconds = expiresAt.timeIntervalSince(now)
        guard seconds >= 3600 else { return 0 }
        return Int(seconds / 3600)
    }
}

/// Reading of the WebSocket `account_notice` message.
public enum PhoneTransferNotice {
    /// True only for `{"code":"phone_transfer_pending"}`. Any other code and any payload without a
    /// string `code` is ignored.
    public static func isPending(_ data: [String: Any]) -> Bool {
        (data["code"] as? String) == "phone_transfer_pending"
    }
}

/// The two calls the holder's screen needs.
public protocol PhoneTransferApi: Sendable {
    /// `GET /api/v1/account/phone-transfers`. An empty list means there is nothing to show.
    func fetchPending() async throws -> [PhoneTransferPending]

    /// `POST /api/v1/account/phone-transfers/{id}/cancel`.
    func cancel(id: String) async throws
}

/// Production `PhoneTransferApi` on top of `BCryptoRestClient`, which already carries the bearer token
/// and the 401 refresh-and-retry cascade. `getRestClient` is set after construction and read at call
/// time, like `BCryptoEntitlementsApiClient`, because the client can be absent (signed out, not yet
/// connected) or replaced over the lifetime of this object.
public final class BCryptoPhoneTransferApi: PhoneTransferApi, @unchecked Sendable {
    public var getRestClient: (() -> BCryptoRestClient?)?

    static let listPath = "/api/v1/account/phone-transfers"

    public init() {}

    public func fetchPending() async throws -> [PhoneTransferPending] {
        guard let rest = getRestClient?() else { throw BCryptoError.unauthorized }
        do {
            let data = try await rest.get(Self.listPath)
            return try Self.parseList(data)
        } catch let error as BCryptoError {
            if case .httpError(404) = error { return [] }
            throw error
        }
    }

    public func cancel(id: String) async throws {
        guard let rest = getRestClient?() else { throw BCryptoError.unauthorized }
        _ = try await rest.post(Self.cancelPath(id: id), body: nil)
    }

    static func cancelPath(id: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let escaped = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
        return "\(listPath)/\(escaped)/cancel"
    }

    private struct ListResponse: Decodable {
        struct Item: Decodable {
            let id: String
            let expiresAt: String

            private enum CodingKeys: String, CodingKey {
                case id
                case expiresAt = "expires_at"
            }
        }

        let transfers: [Item]?
    }

    /// Reads `{"transfers":[{"id","expires_at"}]}`; other fields are ignored. Only `id` and
    /// `expires_at` are used. An entry whose `expires_at` is not an RFC 3339 date is left out, since
    /// no time left can be computed for it.
    static func parseList(_ data: Data) throws -> [PhoneTransferPending] {
        guard let response = try? JSONDecoder().decode(ListResponse.self, from: data) else {
            throw BCryptoError.decodingError
        }
        return (response.transfers ?? []).compactMap { item in
            guard let expiresAt = parseDate(item.expiresAt) else { return nil }
            return PhoneTransferPending(id: item.id, expiresAt: expiresAt)
        }
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
