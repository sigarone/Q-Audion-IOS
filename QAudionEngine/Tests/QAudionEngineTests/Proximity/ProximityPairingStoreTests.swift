import XCTest
import CryptoKit
@testable import QAudionEngine

/// Pure tests of ProximityPairingStore (spec §12): vault naming, the identity
/// policy, and persist's input validation (every case here throws BEFORE the
/// Keychain is touched). A successful `persist` and `loadLocalIdentity` need
/// the Keychain and are not unit-tested.
final class ProximityPairingStoreTests: XCTestCase {

    private static let selfMessage: String = "Non puoi associare il telefono con se stesso."

    // MARK: - Fixtures

    private func makeLocal(userId: String) throws -> ProximityLocalIdentity {
        let signing = Curve25519.Signing.PrivateKey()
        let agreement = Curve25519.KeyAgreement.PrivateKey()
        return try ProximityLocalIdentity(userId: userId,
                                          signingPrivateKey: signing.rawRepresentation,
                                          encryptionPublicKey: agreement.publicKey.rawRepresentation)
    }

    private func makePeer(userId: String, signingPublicKey: Data? = nil) throws -> ProximityPeerIdentity {
        let key: Data = signingPublicKey ?? Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let agreement = Curve25519.KeyAgreement.PrivateKey()
        return try ProximityPeerIdentity(userId: userId,
                                         signingPublicKey: key,
                                         encryptionPublicKey: agreement.publicKey.rawRepresentation)
    }

    private func makeResult(peer: ProximityPeerIdentity, psk: Data, fingerprint: String) -> ProximityPairingResult {
        return ProximityPairingResult(role: .displayer, peer: peer, psk: psk,
                                      pskFingerprint: fingerprint, sas: "123456",
                                      identityWarning: nil)
    }

    private func assertCryptoFailure(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let pairingError = error as? ProximityPairingError else {
            XCTFail("expected ProximityPairingError", file: file, line: line)
            return
        }
        guard case .cryptoFailure = pairingError else {
            XCTFail("expected .cryptoFailure", file: file, line: line)
            return
        }
    }

    // MARK: - vaultEntryName

    func testVaultEntryNameIsPrefixPlusFirst16LowercaseHex() {
        var bytes: [UInt8] = []
        var value: UInt8 = 0
        while bytes.count < 32 {
            bytes.append(value)
            value &+= 0x11
        }
        let name: String = ProximityPairingStore.vaultEntryName(peerSigningPublicKey: Data(bytes))
        XCTAssertEqual(name, "prox-0011223344556677")
        XCTAssertEqual(name.count, 21)
    }

    func testVaultEntryNameUsesOnlyLowercaseHexDigits() {
        let key = Data(repeating: 0xAB, count: 32)
        let name: String = ProximityPairingStore.vaultEntryName(peerSigningPublicKey: key)
        XCTAssertEqual(name, "prox-abababababababab")
        XCTAssertTrue(name.hasPrefix("prox-"))
        let suffix: Substring = name.dropFirst(5)
        XCTAssertEqual(suffix.count, 16)
        for character in suffix {
            XCTAssertTrue("0123456789abcdef".contains(character))
        }
    }

    func testVaultEntryNameAcceptsSliceWithNonZeroStartIndex() {
        var backing = Data([0xFF, 0xFF, 0xFF])
        backing.append(Data(repeating: 0x0C, count: 32))
        let slice: Data = backing[3..<35]
        XCTAssertEqual(slice.startIndex, 3)
        XCTAssertEqual(ProximityPairingStore.vaultEntryName(peerSigningPublicKey: slice),
                       "prox-0c0c0c0c0c0c0c0c")
    }

    func testVaultEntryNameMatchesKatSigningKey() throws {
        guard let url = Bundle.module.url(forResource: "proximity-pairing-kat", withExtension: "json") else {
            XCTFail("proximity-pairing-kat.json not found in test bundle")
            return
        }
        let raw: Data = try Data(contentsOf: url)
        let object: Any = try JSONSerialization.jsonObject(with: raw, options: [])
        guard let root = object as? [String: Any],
              let inputs = root["inputs"] as? [String: Any],
              let hex = inputs["displayerSigningPublicKey"] as? String,
              let key = proxStoreHexDecode(hex) else {
            XCTFail("malformed KAT JSON")
            return
        }
        XCTAssertEqual(key.count, 32)
        let expectedSuffix: String = String(hex.lowercased().prefix(16))
        let expected: String = "prox-" + expectedSuffix
        XCTAssertEqual(ProximityPairingStore.vaultEntryName(peerSigningPublicKey: key), expected)
    }

    func testVaultEntryNameIsClassifiedAsProximityAndNonExportable() {
        let key = Data(repeating: 0x42, count: 32)
        let name: String = ProximityPairingStore.vaultEntryName(peerSigningPublicKey: key)
        XCTAssertEqual(PskOrigin.inferred(fromAccountName: name), .proximity)
        XCTAssertFalse(PskOrigin.proximity.isExportable)
    }

    func testVaultEntryNameDoesNotTrapOnShortKey() {
        XCTAssertEqual(ProximityPairingStore.vaultEntryName(peerSigningPublicKey: Data([0x01, 0xEF])), "prox-01ef")
        XCTAssertEqual(ProximityPairingStore.vaultEntryName(peerSigningPublicKey: Data()), "prox-")
    }

    // MARK: - identityDecision (spec §12)

    func testSelfBySigningKeyIsRejected() throws {
        let local = try makeLocal(userId: "alice")
        let peer = try makePeer(userId: "bob", signingPublicKey: local.signingPublicKey)
        let decision = ProximityPairingStore.identityDecision(peer: peer, local: local, pinnedSigningKey: nil)
        XCTAssertEqual(decision, .reject(ProximityPairingStoreTests.selfMessage))
    }

    func testSelfByUserIdIsRejected() throws {
        let local = try makeLocal(userId: "alice")
        let peer = try makePeer(userId: "alice")
        XCTAssertNotEqual(peer.signingPublicKey, local.signingPublicKey)
        let decision = ProximityPairingStore.identityDecision(peer: peer, local: local, pinnedSigningKey: nil)
        XCTAssertEqual(decision, .reject(ProximityPairingStoreTests.selfMessage))
    }

    func testSelfWinsOverAMatchingPin() throws {
        let local = try makeLocal(userId: "alice")
        let peer = try makePeer(userId: "bob", signingPublicKey: local.signingPublicKey)
        let decision = ProximityPairingStore.identityDecision(peer: peer, local: local,
                                                              pinnedSigningKey: local.signingPublicKey)
        XCTAssertEqual(decision, .reject(ProximityPairingStoreTests.selfMessage))
    }

    func testNoPinIsAccepted() throws {
        let local = try makeLocal(userId: "alice")
        let peer = try makePeer(userId: "bob")
        let decision = ProximityPairingStore.identityDecision(peer: peer, local: local, pinnedSigningKey: nil)
        XCTAssertEqual(decision, .accept)
    }

    func testPinnedEqualKeyIsAccepted() throws {
        let local = try makeLocal(userId: "alice")
        let peer = try makePeer(userId: "bob")
        let decision = ProximityPairingStore.identityDecision(peer: peer, local: local,
                                                              pinnedSigningKey: peer.signingPublicKey)
        XCTAssertEqual(decision, .accept)
    }

    func testPinnedEqualKeyAsSliceIsAccepted() throws {
        let local = try makeLocal(userId: "alice")
        let peer = try makePeer(userId: "bob")
        var backing = Data([0x00, 0x00])
        backing.append(peer.signingPublicKey)
        let slice: Data = backing[2..<34]
        let decision = ProximityPairingStore.identityDecision(peer: peer, local: local, pinnedSigningKey: slice)
        XCTAssertEqual(decision, .accept)
    }

    func testPinnedDifferentKeyWarns() throws {
        let local = try makeLocal(userId: "alice")
        let peer = try makePeer(userId: "bob")
        let otherKey: Data = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let decision = ProximityPairingStore.identityDecision(peer: peer, local: local, pinnedSigningKey: otherKey)
        guard case .acceptWithWarning(let message) = decision else {
            XCTFail("expected .acceptWithWarning")
            return
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNotEqual(message, ProximityPairingStoreTests.selfMessage)
    }

    func testMalformedPinWarnsInsteadOfAccepting() throws {
        let local = try makeLocal(userId: "alice")
        let peer = try makePeer(userId: "bob")
        let truncated: Data = Data(peer.signingPublicKey.prefix(16))
        let decision = ProximityPairingStore.identityDecision(peer: peer, local: local, pinnedSigningKey: truncated)
        guard case .acceptWithWarning = decision else {
            XCTFail("a malformed pin must never read as a match")
            return
        }
    }

    /// The self check runs before the pin lookup, so this path never reaches
    /// the Keychain.
    func testDefaultPolicyRejectsSelfWithoutKeychain() throws {
        let local = try makeLocal(userId: "alice")
        let policy = ProximityPairingStore.defaultIdentityPolicy(local: local)
        let sameKey = try makePeer(userId: "bob", signingPublicKey: local.signingPublicKey)
        let sameUser = try makePeer(userId: "alice")
        XCTAssertEqual(policy(sameKey), .reject(ProximityPairingStoreTests.selfMessage))
        XCTAssertEqual(policy(sameUser), .reject(ProximityPairingStoreTests.selfMessage))
    }

    // MARK: - loadLocalIdentity

    func testLoadLocalIdentityRejectsEmptyUserIdBeforeKeychain() {
        XCTAssertNil(ProximityPairingStore.loadLocalIdentity(userId: ""))
    }

    // MARK: - persist input validation (fails closed before the Keychain)

    func testPersistRejectsWrongLengthPsk() throws {
        let peer = try makePeer(userId: "bob")
        let psk = Data(repeating: 0x5A, count: 31)
        let fingerprint: String = PskAdvertising.canonicalFingerprint(forPsk: psk)
        let result = makeResult(peer: peer, psk: psk, fingerprint: fingerprint)
        XCTAssertThrowsError(try ProximityPairingStore.persist(result, vault: SovereignKeyVault())) { error in
            self.assertCryptoFailure(error)
        }
    }

    func testPersistRejectsAllZeroPsk() throws {
        let peer = try makePeer(userId: "bob")
        let psk = Data(count: 32)
        let fingerprint: String = PskAdvertising.canonicalFingerprint(forPsk: psk)
        let result = makeResult(peer: peer, psk: psk, fingerprint: fingerprint)
        XCTAssertThrowsError(try ProximityPairingStore.persist(result, vault: SovereignKeyVault())) { error in
            self.assertCryptoFailure(error)
        }
    }

    func testPersistRejectsFingerprintMismatch() throws {
        let peer = try makePeer(userId: "bob")
        let psk = Data(repeating: 0x5A, count: 32)
        let otherPsk = Data(repeating: 0x5B, count: 32)
        let wrongFingerprint: String = PskAdvertising.canonicalFingerprint(forPsk: otherPsk)
        let result = makeResult(peer: peer, psk: psk, fingerprint: wrongFingerprint)
        XCTAssertThrowsError(try ProximityPairingStore.persist(result, vault: SovereignKeyVault())) { error in
            self.assertCryptoFailure(error)
        }
    }

    func testPersistRejectsEmptyFingerprint() throws {
        let peer = try makePeer(userId: "bob")
        let psk = Data(repeating: 0x5A, count: 32)
        let result = makeResult(peer: peer, psk: psk, fingerprint: "")
        XCTAssertThrowsError(try ProximityPairingStore.persist(result, vault: SovereignKeyVault())) { error in
            self.assertCryptoFailure(error)
        }
    }
}

// MARK: - File-private helpers

private func proxStoreHexDecode(_ text: String) -> Data? {
    let scalars: [UInt8] = Array(text.utf8)
    guard scalars.count % 2 == 0 else { return nil }
    var out = Data(capacity: scalars.count / 2)
    var index: Int = 0
    while index < scalars.count {
        guard let high = proxStoreNibble(scalars[index]),
              let low = proxStoreNibble(scalars[index + 1]) else { return nil }
        let byte: UInt8 = (high << 4) | low
        out.append(byte)
        index += 2
    }
    return out
}

private func proxStoreNibble(_ c: UInt8) -> UInt8? {
    switch c {
    case 0x30...0x39: return c - 0x30
    case 0x61...0x66: return c - 0x61 + 10
    case 0x41...0x46: return c - 0x41 + 10
    default: return nil
    }
}
