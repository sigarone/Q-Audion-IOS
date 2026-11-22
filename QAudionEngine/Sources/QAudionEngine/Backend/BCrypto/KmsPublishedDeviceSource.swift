import Foundation

/// The published device set of a contact, read from the server (`BCryptoKmsClient.fetchUserPublishedDevices`) with the safety-number
/// fingerprint of each published key computed exactly as the pins' fingerprints are (`PeerKeyPrint`), so the legacy account-level pin can
/// be matched by fingerprint. Nil on any failure, so the contact shield counts every row.
public final class KmsPublishedDeviceSource: PublishedDeviceSource, @unchecked Sendable {

    /// This account's user id and Ed25519 identity key (both are needed for a safety number), or nil while they are not available.
    public typealias SelfContext = @Sendable () -> (userId: String, identityKey: Data)?

    private let client: BCryptoKmsClient
    private let selfContext: SelfContext

    public init(client: BCryptoKmsClient, selfContext: @escaping SelfContext) {
        self.client = client
        self.selfContext = selfContext
    }

    public func published(peerUserId: String) async -> PublishedDevices? {
        guard let fetched = await client.fetchUserPublishedDevices(userId: peerUserId) else { return nil }
        var prints = Set<String>()
        if let me = selfContext() {
            for key in fetched.keys {
                if let fp = PeerKeyPrint.of(selfUserId: me.userId, selfIdentityKey: me.identityKey, peerUserId: peerUserId, peerKey: key) {
                    prints.insert(fp)
                }
            }
        }
        return PublishedDevices(deviceIds: fetched.deviceIds, fingerprints: prints)
    }
}
