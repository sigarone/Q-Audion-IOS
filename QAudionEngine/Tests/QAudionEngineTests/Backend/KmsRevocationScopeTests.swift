import XCTest
@testable import QAudionEngine

/// A `kms_key_revoked` event deletes a KMS key and nothing else: whatever key_id it carries, an in-person key
/// (nfc-, prox-) or any other entry stays.
final class KmsRevocationScopeTests: XCTestCase {

    func testOnlyAKmsOriginMayBeDeletedByARevocation() {
        XCTAssertTrue(KmsPollerService.revocationMayDelete(origin: .kms))
        for origin in [PskOrigin.nfc, .proximity, .qr, .manual, .callDerived, .deviceInternal, .identityKey] {
            XCTAssertFalse(KmsPollerService.revocationMayDelete(origin: origin), origin.rawValue)
        }
    }

    func testTheNamesOfInPersonKeysAreNotKmsOrigins() {
        XCTAssertEqual(PskOrigin.inferred(fromAccountName: "nfc-0123456789abcdef-0a1b2c3d"), .nfc)
        XCTAssertEqual(PskOrigin.inferred(fromAccountName: "prox-0123456789abcdef"), .proximity)
        XCTAssertEqual(PskOrigin.inferred(fromAccountName: "3F2504E0-4F89-11D3-9A0C-0305E82C3301"), .kms)
    }

    func testARevocationNamingAnInPersonKeyLeavesItInTheVault() async throws {
        try KeychainAvailability.requireKeychain()
        let vault = SovereignKeyVault()
        let rest = BCryptoRestClient(config: BackendConfig(serverUrl: "https://test.local"))
        let poller = KmsPollerService(kmsClient: BCryptoKmsClient(rest: rest), vault: vault)
        let inPerson = "nfc-" + String(repeating: "ab", count: 8) + "-0a1b2c3d"
        let kms = UUID().uuidString
        try vault.storePsk(name: inPerson, key: Data(repeating: 7, count: 32), fingerprint: "fp", keyClass: nil,
                           origin: .nfc, nfcPeerIdentityKey: Data(repeating: 1, count: 32))
        try vault.storePsk(name: kms, key: Data(repeating: 8, count: 32), fingerprint: "fp")
        defer {
            try? vault.deletePsk(name: inPerson)
            try? vault.deletePsk(name: kms)
        }
        await poller.notifyRevoked(keyId: inPerson)
        XCTAssertNotNil(try vault.loadPsk(name: inPerson), "an in-person key is not deleted by a revocation")
        await poller.notifyRevoked(keyId: kms)
        XCTAssertNil(try vault.loadPsk(name: kms), "a KMS key is")
    }
}
