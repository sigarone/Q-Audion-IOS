import Foundation

public protocol AccountApi {
    func register(userId: String, credential: Data) async throws
    func login(userId: String, credential: Data) async throws -> String  // returns JWT
    func refreshToken(currentToken: String) async throws -> String
    func getProfile() async throws -> UserProfile
    func updateProfile(_ profile: UserProfile) async throws
}

public struct UserProfile: Codable {
    public var userId: String
    public var displayName: String?
    public var avatarUrl: String?
    public init(userId: String, displayName: String? = nil, avatarUrl: String? = nil) {
        self.userId = userId; self.displayName = displayName; self.avatarUrl = avatarUrl
    }
}
