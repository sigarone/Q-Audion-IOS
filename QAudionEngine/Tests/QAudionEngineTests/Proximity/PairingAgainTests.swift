import XCTest
import CryptoKit
@testable import QAudionEngine

/// docs/security/CALL_KEY_PRIORITY.md section 4a at the vault: a confirmed pairing with the same phone by the same
/// method replaces the earlier key under the same name and keeps its place in the call-key list and its mark; a
/// pairing with another phone, or by the other method, is a new key; a pairing that does not complete leaves the
/// earlier key as it was.
///
/// These cases store real keys through `ProximityPairingStore.persist` (the NFC path writes with the same
/// `SovereignKeyVault.storePsk` call), so they need the Keychain: they skip on a host that has none, such as the CI
/// simulator, and must pass wherever it works (`KeychainAvailability`). The order of the list, and the tap that is
/// not confirmed, are covered without the Keychain in `CallKeyPriorityTests` and `NfcApduExchangeSasGateTests`.
final class PairingAgainTests: XCTestCase {

    private var storedNames: [String] = []

    override func tearDownWithError() throws {
        if !storedNames.isEmpty {
            let vault = SovereignKeyVault()
            for name in storedNames {
                try? vault.deletePsk(name: name)
            }
            // The list drops the keys the test stored and their marks.
            CallKeyPriorityStore.live(vault: vault).syncWithVault()
            storedNames = []
        }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func makePeer() throws -> ProximityPeerIdentity {
        let signing = Curve25519.Signing.PrivateKey()
        let agreement = Curve25519.KeyAgreement.PrivateKey()
        return try ProximityPeerIdentity(userId: "bob",
                                         signingPublicKey: signing.publicKey.rawRepresentation,
                                         encryptionPublicKey: agreement.publicKey.rawRepresentation)
    }

    private func makeResult(peer: ProximityPeerIdentity, psk: Data) -> ProximityPairingResult {
        ProximityPairingResult(role: .displayer, peer: peer, psk: psk,
                               pskFingerprint: PskAdvertising.canonicalFingerprint(forPsk: psk),
                               sas: "123456", identityWarning: nil)
    }

    private func entryName(of peer: ProximityPeerIdentity) -> String {
        let name = ProximityPairingStore.vaultEntryName(peerSigningPublicKey: peer.signingPublicKey)
        storedNames.append(name)
        return name
    }

    private func random32() -> Data {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
    }

    // MARK: - Tests

    func testPairingTheSamePhoneAgainReplacesTheKeyUnderTheSameName() throws {
        try KeychainAvailability.requireKeychain()
        let vault = SovereignKeyVault()
        let peer = try makePeer()
        let entry = entryName(of: peer)
        let first = makeResult(peer: peer, psk: random32())
        let second = makeResult(peer: peer, psk: random32())
        XCTAssertNotEqual(first.psk, second.psk)

        try ProximityPairingStore.persist(first, vault: vault)
        XCTAssertEqual(try vault.loadPsk(name: entry), first.psk)

        try ProximityPairingStore.persist(second, vault: vault)
        XCTAssertEqual(try vault.loadPsk(name: entry), second.psk, "the earlier key is replaced")
        XCTAssertEqual(vault.listPskNames().filter { $0 == entry }.count, 1, "there is one entry, not two")
        XCTAssertEqual(vault.origin(name: entry), .proximity)
        XCTAssertEqual(vault.nfcPeerIdentityKey(name: entry), peer.signingPublicKey)
    }

    func testTheReplacingKeyKeepsThePlaceAndTheMarkOfTheEarlierOne() throws {
        try KeychainAvailability.requireKeychain()
        let vault = SovereignKeyVault()
        let phoneA = try makePeer()
        let phoneB = try makePeer()
        let entryA = entryName(of: phoneA)
        let entryB = entryName(of: phoneB)

        try ProximityPairingStore.persist(makeResult(peer: phoneA, psk: random32()), vault: vault)
        try ProximityPairingStore.persist(makeResult(peer: phoneB, psk: random32()), vault: vault)
        let order = CallKeyPriorityStore.live(vault: vault)
        // The user puts B's key above A's by hand.
        XCTAssertTrue(order.moveUp(entryB).saved)
        let before = order.current()
        let placeOfB = try XCTUnwrap(before.position(of: entryB))
        let placeOfA = try XCTUnwrap(before.position(of: entryA))
        XCTAssertLessThan(placeOfB, placeOfA)
        XCTAssertTrue(before.isPlacedByHand(entryB))

        try ProximityPairingStore.persist(makeResult(peer: phoneB, psk: random32()), vault: vault)
        let after = order.current()
        XCTAssertEqual(after.position(of: entryB), placeOfB, "the new key takes the place of the earlier one")
        XCTAssertEqual(after.position(of: entryA), placeOfA)
        XCTAssertTrue(after.isPlacedByHand(entryB), "and its mark")
        XCTAssertFalse(after.isPlacedByHand(entryA))
    }

    func testAnotherPhoneOfTheSamePersonIsANewKeyAndTheEarlierKeyStays() throws {
        try KeychainAvailability.requireKeychain()
        let vault = SovereignKeyVault()
        let phoneA = try makePeer()
        let phoneB = try makePeer()
        let entryA = entryName(of: phoneA)
        let entryB = entryName(of: phoneB)
        XCTAssertNotEqual(entryA, entryB)
        let keyA = random32()

        try ProximityPairingStore.persist(makeResult(peer: phoneA, psk: keyA), vault: vault)
        try ProximityPairingStore.persist(makeResult(peer: phoneB, psk: random32()), vault: vault)

        XCTAssertEqual(try vault.loadPsk(name: entryA), keyA)
        let list = CallKeyPriorityStore.live(vault: vault).current()
        XCTAssertEqual(list.position(of: entryB), list.entries.count - 1, "a new in-person key goes to the end")
        XCTAssertLessThan(try XCTUnwrap(list.position(of: entryA)), try XCTUnwrap(list.position(of: entryB)))
    }

    func testAPairingThatFailsBeforeTheKeyIsStoredLeavesTheEarlierKeyAsItWas() throws {
        try KeychainAvailability.requireKeychain()
        let vault = SovereignKeyVault()
        let peer = try makePeer()
        let entry = entryName(of: peer)
        let earlier = makeResult(peer: peer, psk: random32())
        try ProximityPairingStore.persist(earlier, vault: vault)

        // A result whose fingerprint is not the key's, and one with an all-zero key: neither may touch the entry.
        let wrongFingerprint = ProximityPairingResult(
            role: .scanner, peer: peer, psk: random32(),
            pskFingerprint: PskAdvertising.canonicalFingerprint(forPsk: random32()),
            sas: "123456", identityWarning: nil)
        XCTAssertThrowsError(try ProximityPairingStore.persist(wrongFingerprint, vault: vault))
        XCTAssertThrowsError(try ProximityPairingStore.persist(makeResult(peer: peer, psk: Data(count: 32)), vault: vault))

        XCTAssertEqual(try vault.loadPsk(name: entry), earlier.psk)
        XCTAssertEqual(vault.nfcPeerIdentityKey(name: entry), peer.signingPublicKey)
    }
}
