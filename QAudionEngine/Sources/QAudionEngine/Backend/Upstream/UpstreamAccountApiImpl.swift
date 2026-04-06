import Foundation

public final class UpstreamAccountApiImpl: AccountApi {
    public init() {}
    public func register(userId: String, credential: Data) async throws {}
    public func login(userId: String, credential: Data) async throws -> String { "" }
    public func refreshToken(currentToken: String) async throws -> String { currentToken }
    public func getProfile() async throws -> UserProfile { UserProfile(userId: "") }
    public func updateProfile(_ profile: UserProfile) async throws {}
}
