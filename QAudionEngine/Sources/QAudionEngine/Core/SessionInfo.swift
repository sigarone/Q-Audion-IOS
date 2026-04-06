import Foundation

public struct SessionInfo {
    public let sessionId: Data
    public let remotePublicKey: Data?
    public let pqcAlgorithm: String
    public let aeadAlgorithm: String
    public let createdAt: Date
    public var isActive: Bool

    public init(sessionId: Data = Data(), remotePublicKey: Data? = nil,
                pqcAlgorithm: String = "ML-KEM-1024", aeadAlgorithm: String = "AES-256-GCM",
                createdAt: Date = Date(), isActive: Bool = false) {
        self.sessionId = sessionId; self.remotePublicKey = remotePublicKey
        self.pqcAlgorithm = pqcAlgorithm; self.aeadAlgorithm = aeadAlgorithm
        self.createdAt = createdAt; self.isActive = isActive
    }

    public func getAgeMs() -> Int64 { Int64(Date().timeIntervalSince(createdAt) * 1000) }
    public func isExpired(timeoutMs: Int64 = 3_600_000) -> Bool { getAgeMs() > timeoutMs }

    public func toSafeString() -> String {
        "SessionInfo(id=\(sessionId.prefix(8).map { String(format: "%02x", $0) }.joined())..., pqc=\(pqcAlgorithm), aead=\(aeadAlgorithm), active=\(isActive))"
    }

    public static func createEmpty() -> SessionInfo { SessionInfo() }
}
