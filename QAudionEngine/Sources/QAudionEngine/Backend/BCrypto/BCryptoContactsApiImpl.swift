import Foundation

public final class BCryptoContactsApiImpl: ContactsApi {
    private let rest: BCryptoRestClient
    init(rest: BCryptoRestClient) { self.rest = rest }

    public func discoverContacts(phoneHashes: [String]) async throws -> [DiscoveredContact] {
        let body = try JSONSerialization.data(withJSONObject: ["hashes": phoneHashes])
        let data = try await rest.post("/api/v1/contacts/discover", body: body)
        return try JSONDecoder().decode([DiscoveredContact].self, from: data)
    }
    public func addContact(userId: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["userId": userId])
        _ = try await rest.post("/api/v1/contacts", body: body)
    }
    public func removeContact(userId: String) async throws {
        _ = try await rest.delete("/api/v1/contacts/\(userId)")
    }
    public func listContacts() async throws -> [DiscoveredContact] {
        let data = try await rest.get("/api/v1/contacts")
        return try JSONDecoder().decode([DiscoveredContact].self, from: data)
    }
}
