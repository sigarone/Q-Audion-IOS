import Foundation

/// Contact discovery and management via Signal-compatible REST endpoints.
///
/// Signal's contact discovery uses hashed phone numbers to find registered users
/// without exposing plaintext contacts to the server (private contact intersection).
/// This provider sends pre-hashed identifiers and receives back matching Signal
/// user records.
public final class UpstreamContactsApiImpl: ContactsApi {
    private let rest: BCryptoRestClient

    init(rest: BCryptoRestClient) {
        self.rest = rest
    }

    // MARK: - ContactsApi

    /// Discover which phone numbers in the user's address book are registered
    /// on Signal. Phone numbers are pre-hashed by the caller for privacy.
    ///
    /// Signal's contact discovery service returns intersection results
    /// without the server learning which contacts were queried.
    public func discoverContacts(phoneHashes: [String]) async throws -> [DiscoveredContact] {
        let body = try JSONSerialization.data(withJSONObject: [
            "hashes": phoneHashes
        ])
        let data = try await rest.post("/v1/contacts/discover", body: body)
        return try JSONDecoder().decode([DiscoveredContact].self, from: data)
    }

    /// Add a user to the local contact list on the server.
    public func addContact(userId: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "userId": userId
        ])
        _ = try await rest.post("/v1/contacts", body: body)
    }

    /// Remove a user from the contact list (block/unfriend).
    public func removeContact(userId: String) async throws {
        _ = try await rest.delete("/v1/contacts/\(userId)")
    }

    /// Retrieve the full list of contacts synced with the server.
    public func listContacts() async throws -> [DiscoveredContact] {
        let data = try await rest.get("/v1/contacts")
        return try JSONDecoder().decode([DiscoveredContact].self, from: data)
    }
}
