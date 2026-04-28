import Foundation

public struct SecurityDashboardViewModel: ViewModelProtocol {
    public enum KeyHealth: Sendable, Equatable { case healthy, rotationDue, compromised }

    public let identityFingerprint: String  // §5.1 4-group hex
    public let keyHealth: KeyHealth
    public let lastKeyRotation: Date?
    public let pqcAlgorithm: String  // "ML-KEM-1024"
    public let unverifiedContacts: Int
    public let activeThreatReports: Int
    public let wipeRequestPending: Bool

    public init(identityFingerprint: String, keyHealth: KeyHealth, lastKeyRotation: Date?,
                pqcAlgorithm: String, unverifiedContacts: Int, activeThreatReports: Int,
                wipeRequestPending: Bool) {
        self.identityFingerprint = identityFingerprint
        self.keyHealth = keyHealth
        self.lastKeyRotation = lastKeyRotation
        self.pqcAlgorithm = pqcAlgorithm
        self.unverifiedContacts = unverifiedContacts
        self.activeThreatReports = activeThreatReports
        self.wipeRequestPending = wipeRequestPending
    }

    public static let mock = SecurityDashboardViewModel(
        identityFingerprint: Fingerprint.format(pubkey: Data(repeating: 0x46, count: 32)),
        keyHealth: .healthy,
        lastKeyRotation: Date(timeIntervalSince1970: 1_744_000_000),
        pqcAlgorithm: "ML-KEM-1024",
        unverifiedContacts: 2,
        activeThreatReports: 0,
        wipeRequestPending: false
    )
}
