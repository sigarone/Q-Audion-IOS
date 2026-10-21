import XCTest
import CryptoKit
@testable import QAudionEngine

/// docs/security/CALL_KEY_PRIORITY.md section 4a at the vault: a confirmed pairing with the same phone by the same
/// method stores a second key beside the first (the name carries the key fingerprint), puts it where the earlier
/// key was with that key mark, and keeps the earlier key, live, until the new one is finalized; a pairing with
/// another phone, or by the other method, is a new key; a pairing that does not complete leaves the earlier key as
/// it was.
///
/// These cases store real keys through `ProximityPairingStore.persist` (the NFC path writes with the same
/// `SovereignKeyVault.storePsk` call), so they need the Keychain: they skip on a host that has none, such as the CI
/// simulator, and must pass wherever it works (`KeychainAvailability`). The order of the list, the store and the
/// finalize are covered without the Keychain in `CallKeyPriorityTests`, and the NFC ceremony that is not confirmed
/// (nothing is stored, nothing is sent) in `NfcReaderCeremonyTests`.
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

    /// The name `persist` gives the key of this result, remembered for the clean-up.
    private func entryName(of result: ProximityPairingResult) -> String {
        let name = ProximityPairingStore.vaultEntryName(peerSigningPublicKey: result.peer.signingPublicKey,
                                                        keyFingerprint: result.pskFingerprint)
        storedNames.append(name)
        return name
    }

    private func random32() -> Data {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
    }

    // MARK: - Tests

    func testPairingTheSamePhoneAgainStoresASecondKeyAndKeepsTheFirst() throws {
        try KeychainAvailability.requireKeychain()
        let vault = SovereignKeyVault()
        let peer = try makePeer()
        let first = makeResult(peer: peer, psk: random32())
        let second = makeResult(peer: peer, psk: random32())
        XCTAssertNotEqual(first.psk, second.psk)
        let firstName = entryName(of: first)
        let secondName = entryName(of: second)
        XCTAssertNotEqual(firstName, secondName, "a fresh pairing has a name of its own")
        XCTAssertEqual(CallKeyPriority.inPersonDevice(ofAccount: firstName),
                       CallKeyPriority.inPersonDevice(ofAccount: secondName), "and the same device")

        try ProximityPairingStore.persist(first, vault: vault)
        try ProximityPairingStore.persist(second, vault: vault)

        XCTAssertEqual(try vault.loadPsk(name: firstName), first.psk, "the earlier key is still there")
        XCTAssertEqual(try vault.loadPsk(name: secondName), second.psk)
        XCTAssertEqual(vault.origin(name: secondName), .proximity)
        XCTAssertEqual(vault.nfcPeerIdentityKey(name: secondName), peer.signingPublicKey)
        let list = CallKeyPriorityStore.live(vault: vault).current()
        XCTAssertLessThan(try XCTUnwrap(list.position(of: secondName)), try XCTUnwrap(list.position(of: firstName)))
        XCTAssertEqual(list.pending(secondName), .waiting)
        XCTAssertEqual(list.pending(firstName), .retiring)
    }

    func testTheNewKeyTakesThePlaceAndTheMarkOfTheEarlierOneAndFinalizeDeletesTheEarlierOne() throws {
        try KeychainAvailability.requireKeychain()
        let vault = SovereignKeyVault()
        let phoneA = try makePeer()
        let phoneB = try makePeer()
        let resultA = makeResult(peer: phoneA, psk: random32())
        let firstB = makeResult(peer: phoneB, psk: random32())
        let secondB = makeResult(peer: phoneB, psk: random32())
        let entryA = entryName(of: resultA)
        let entryFirstB = entryName(of: firstB)
        let entrySecondB = entryName(of: secondB)

        try ProximityPairingStore.persist(resultA, vault: vault)
        try ProximityPairingStore.persist(firstB, vault: vault)
        let order = CallKeyPriorityStore.live(vault: vault)
        // The user puts the key of phone B above the key of phone A by hand.
        XCTAssertTrue(order.moveUp(entryFirstB).saved)
        let before = order.current()
        let placeOfB = try XCTUnwrap(before.position(of: entryFirstB))
        XCTAssertLessThan(placeOfB, try XCTUnwrap(before.position(of: entryA)))
        XCTAssertTrue(before.isPlacedByHand(entryFirstB))

        try ProximityPairingStore.persist(secondB, vault: vault)
        let after = order.current()
        XCTAssertEqual(after.position(of: entrySecondB), placeOfB, "the new key takes the place of the earlier one")
        XCTAssertEqual(after.position(of: entryFirstB), placeOfB + 1, "the earlier one directly below")
        XCTAssertTrue(after.isPlacedByHand(entrySecondB), "the new key has the mark")
        XCTAssertFalse(after.isPlacedByHand(entryFirstB))
        XCTAssertEqual(after.pending(entryA), .none)

        // Finalize deletes the earlier key of phone B from the vault, never the key of phone A.
        XCTAssertEqual(order.finalize(entrySecondB).deleted, [entryFirstB])
        XCTAssertNil(try vault.loadPsk(name: entryFirstB))
        XCTAssertEqual(try vault.loadPsk(name: entrySecondB), secondB.psk)
        XCTAssertEqual(try vault.loadPsk(name: entryA), resultA.psk)
        XCTAssertNil(order.current().position(of: entryFirstB))
    }

    func testAnotherPhoneOfTheSamePersonIsANewKeyAndTheEarlierKeyStays() throws {
        try KeychainAvailability.requireKeychain()
        let vault = SovereignKeyVault()
        let resultA = makeResult(peer: try makePeer(), psk: random32())
        let resultB = makeResult(peer: try makePeer(), psk: random32())
        let entryA = entryName(of: resultA)
        let entryB = entryName(of: resultB)
        XCTAssertNotEqual(CallKeyPriority.inPersonDevice(ofAccount: entryA),
                          CallKeyPriority.inPersonDevice(ofAccount: entryB))

        try ProximityPairingStore.persist(resultA, vault: vault)
        try ProximityPairingStore.persist(resultB, vault: vault)

        XCTAssertEqual(try vault.loadPsk(name: entryA), resultA.psk)
        let list = CallKeyPriorityStore.live(vault: vault).current()
        XCTAssertEqual(list.position(of: entryB), list.entries.count - 1, "a new in-person key goes to the end")
        XCTAssertLessThan(try XCTUnwrap(list.position(of: entryA)), try XCTUnwrap(list.position(of: entryB)))
        XCTAssertEqual(list.pending(entryB), .none)
    }

    /// A key stored before the identity was kept (no bound identity) is never replaced: the new key is a new key.
    func testAnInPersonKeyWithNoBoundIdentityIsNeverReplaced() throws {
        try KeychainAvailability.requireKeychain()
        let vault = SovereignKeyVault()
        let peer = try makePeer()
        let legacyName = ProximityPairingStore.vaultEntryName(peerSigningPublicKey: peer.signingPublicKey)
        storedNames.append(legacyName)
        try vault.storePsk(name: legacyName, key: random32(), fingerprint: "legacy", keyClass: nil,
                           origin: .proximity, nfcPeerIdentityKey: nil)
        let fresh = makeResult(peer: peer, psk: random32())
        let freshName = entryName(of: fresh)
        try ProximityPairingStore.persist(fresh, vault: vault)

        let list = CallKeyPriorityStore.live(vault: vault).current()
        XCTAssertEqual(list.pending(legacyName), .none)
        XCTAssertEqual(list.pending(freshName), .none)
        XCTAssertLessThan(try XCTUnwrap(list.position(of: legacyName)), try XCTUnwrap(list.position(of: freshName)),
                          "the new key goes to the end, as a new key")
        XCTAssertNotNil(try vault.loadPsk(name: legacyName))
    }

    func testAPairingThatFailsBeforeTheKeyIsStoredLeavesTheEarlierKeyAsItWas() throws {
        try KeychainAvailability.requireKeychain()
        let vault = SovereignKeyVault()
        let peer = try makePeer()
        let earlier = makeResult(peer: peer, psk: random32())
        let entry = entryName(of: earlier)
        try ProximityPairingStore.persist(earlier, vault: vault)

        // A result whose fingerprint is not the key, and one with an all-zero key: neither may touch the entry,
        // nor add one.
        let wrongFingerprint = ProximityPairingResult(
            role: .scanner, peer: peer, psk: random32(),
            pskFingerprint: PskAdvertising.canonicalFingerprint(forPsk: random32()),
            sas: "123456", identityWarning: nil)
        let zeroKey = makeResult(peer: peer, psk: Data(count: 32))
        storedNames.append(ProximityPairingStore.vaultEntryName(peerSigningPublicKey: peer.signingPublicKey,
                                                                keyFingerprint: zeroKey.pskFingerprint))
        XCTAssertThrowsError(try ProximityPairingStore.persist(wrongFingerprint, vault: vault))
        XCTAssertThrowsError(try ProximityPairingStore.persist(zeroKey, vault: vault))

        XCTAssertEqual(try vault.loadPsk(name: entry), earlier.psk)
        XCTAssertEqual(vault.nfcPeerIdentityKey(name: entry), peer.signingPublicKey)
        let device = try XCTUnwrap(CallKeyPriority.inPersonDevice(ofAccount: entry))
        XCTAssertEqual(vault.listPskNames().filter { $0.hasPrefix(device) }, [entry], "no second entry")
    }
}
