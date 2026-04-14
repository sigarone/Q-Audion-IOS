import Foundation

public final class BCryptoContactsApiImpl: ContactsApi {
    private let rest: BCryptoRestClient
    init(rest: BCryptoRestClient) { self.rest = rest }

    public func discoverContacts(phoneHashes: [String]) async throws -> [DiscoveredContact] {
        let body = try JSONSerialization.data(withJSONObject: ["phone_hashes": phoneHashes])
        let data = try await rest.post("/api/v1/contacts/discover", body: body)
        let response = try JSONDecoder().decode(DiscoverResponse.self, from: data)
        return response.contacts
    }

    public func addContact(userId: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["user_id": userId])
        _ = try await rest.post("/api/v1/contacts", body: body)
    }

    public func removeContact(userId: String) async throws {
        _ = try await rest.delete("/api/v1/contacts/\(userId)")
    }

    public func listContacts() async throws -> [DiscoveredContact] {
        let data = try await rest.get("/api/v1/contacts")
        let response = try JSONDecoder().decode(DiscoverResponse.self, from: data)
        return response.contacts
    }

    public func syncContacts(phoneHashes: [String]) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["phone_hashes": phoneHashes])
        _ = try await rest.post("/api/v1/contacts/sync", body: body)
    }

    public func blockContact(userId: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["user_id": userId])
        _ = try await rest.post("/api/v1/contacts/block", body: body)
    }

    public func unblockContact(userId: String) async throws {
        _ = try await rest.delete("/api/v1/contacts/block/\(userId)")
    }

    public func getBlockedContacts() async throws -> [DiscoveredContact] {
        let data = try await rest.get("/api/v1/contacts/blocked")
        let response = try JSONDecoder().decode(DiscoverResponse.self, from: data)
        return response.contacts
    }
}

private struct DiscoverResponse: Codable {
    let contacts: [DiscoveredContact]
}
