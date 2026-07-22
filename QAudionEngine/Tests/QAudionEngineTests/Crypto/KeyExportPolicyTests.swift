import XCTest
@testable import QAudionEngine

/// W-NFCBIND (2026-07-22) — fences `PskOrigin`, the iOS half of the Android
/// `isKeyExportable` policy.
///
/// The property being defended is not confidentiality of the key — the Keychain
/// and `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` already handle that. It is
/// that an NFC secret cannot exist on a device that was not present at the tap,
/// because that is the only reason a contact may ever be shown as authenticated
/// by physical presence. On Android one QR export silently converted that claim
/// into a lie on the receiving phone; iOS has no export surface yet, so here the
/// tests pin the rule before something is built on top of it.
///
/// Pure-function tests only: everything below runs without a Keychain, so it
/// executes identically on a CI Linux runner and on a device.
final class KeyExportPolicyTests: XCTestCase {

    func testNfcKeyNeverLeavesTheDevice() {
        XCTAssertFalse(PskOrigin.nfc.isExportable)
    }

    /// HKDF output of a past call's session key, scoped to one peer's chat and
    /// files. Nothing legitimate reads it off the device.
    func testCallDerivedKeyNeverLeavesTheDevice() {
        XCTAssertFalse(PskOrigin.callDerived.isExportable)
    }

    /// `DeviceKeyManager` keeps this device's X25519, ML-KEM and Ed25519 PRIVATE
    /// keys in the same Keychain service as the shared secrets, under `__device.*`.
    /// Whatever else is arguable, handing those out is not.
    func testDeviceInternalMaterialNeverLeavesTheDevice() {
        XCTAssertFalse(PskOrigin.deviceInternal.isExportable)
    }

    /// Blocking these would break real workflows rather than protect anything:
    /// QR and manual keys were carried in from elsewhere to begin with, and a
    /// KMS key is already held by the server that issued it.
    func testTransferableOriginsStayExportable() {
        XCTAssertTrue(PskOrigin.qr.isExportable)
        XCTAssertTrue(PskOrigin.manual.isExportable)
        XCTAssertTrue(PskOrigin.kms.isExportable)
    }

    // MARK: - Legacy inference
    //
    // Every entry currently on a real device predates the stored origin tag, so
    // the name-based fallback is what actually protects them today.

    func testNfcNamesAreRecognisedFromTheAccountNameAlone() {
        // The exact shape `NfcExchangeView.persistPsk` writes: "nfc-" + the
        // first 16 hex chars of the peer's identity pubkey.
        XCTAssertEqual(PskOrigin.inferred(fromAccountName: "nfc-a3f7c29184be0d12"), .nfc)
    }

    func testInternalPrefixesAreRecognised() {
        XCTAssertEqual(PskOrigin.inferred(fromAccountName: "__device.x25519.priv"), .deviceInternal)
        XCTAssertEqual(PskOrigin.inferred(fromAccountName: "__device.ed25519.priv"), .deviceInternal)
        XCTAssertEqual(PskOrigin.inferred(fromAccountName: "__kmsname.aabbcc"), .deviceInternal)
        XCTAssertEqual(PskOrigin.inferred(fromAccountName: "__kms.active_epoch.3"), .deviceInternal)
    }

    func testUuidAccountNamesAreKmsKeyIds() {
        // Same test `AppState.resolvePskDisplayMeta` already applies.
        XCTAssertEqual(
            PskOrigin.inferred(fromAccountName: "3F2504E0-4F89-11D3-9A0C-0305E82C3301"),
            .kms
        )
    }

    /// The fallback may only ever REMOVE privilege. An unrecognised name keeps
    /// behaving exactly as it does today rather than being quietly locked down,
    /// which would break a future export feature for legitimate keys and be
    /// blamed on the wrong commit.
    func testUnrecognisedNamesFallBackToManual() {
        XCTAssertEqual(PskOrigin.inferred(fromAccountName: "peer.u-12345"), .manual)
        XCTAssertEqual(PskOrigin.inferred(fromAccountName: "chiave ufficio"), .manual)
        XCTAssertTrue(PskOrigin.inferred(fromAccountName: "chiave ufficio").isExportable)
    }

    /// A near-miss must NOT be treated as NFC: the prefix is "nfc-" with the
    /// hyphen, so a user-named key beginning with those three letters stays
    /// exportable and a genuine NFC entry is never mistaken for one.
    func testTheNfcPrefixRequiresTheHyphen() {
        XCTAssertEqual(PskOrigin.inferred(fromAccountName: "nfcbackup"), .manual)
    }

    /// The raw values are persisted inside the Keychain generic blob, so they
    /// are storage format, not display strings. Renaming one silently reclassifies
    /// every key already written with the old spelling — most dangerously turning
    /// a stored `nfc` into an unparseable value that falls back to the name
    /// heuristic, or worse to `.manual`.
    func testRawValuesAreFrozenStorageFormat() {
        XCTAssertEqual(PskOrigin.nfc.rawValue, "nfc")
        XCTAssertEqual(PskOrigin.qr.rawValue, "qr")
        XCTAssertEqual(PskOrigin.manual.rawValue, "manual")
        XCTAssertEqual(PskOrigin.kms.rawValue, "kms")
        XCTAssertEqual(PskOrigin.callDerived.rawValue, "call_derived")
        XCTAssertEqual(PskOrigin.deviceInternal.rawValue, "device_internal")
    }

    // MARK: - Blob compatibility
    //
    // The generic blob gained a second field. Both directions must survive,
    // because a hw_only contact that reads back as `.shared` disables the D4
    // policy that consults it — a security regression dressed as a parse bug.

    func testLegacyClassOnlyBlobStillParses() {
        XCTAssertEqual(SovereignKeyVault.KeyClass.parse("hw_only"), .hwOnly)
        XCTAssertEqual(SovereignKeyVault.KeyClass.parse("sw_only"), .swOnly)
        XCTAssertEqual(SovereignKeyVault.KeyClass.parse("shared"), .shared)
        XCTAssertEqual(SovereignKeyVault.KeyClass.parse(nil), .shared)
    }

    func testClassSurvivesAnAppendedOriginField() {
        XCTAssertEqual(SovereignKeyVault.KeyClass.parse("hw_only;origin=nfc"), .hwOnly)
        XCTAssertEqual(SovereignKeyVault.KeyClass.parse("sw_only;origin=kms"), .swOnly)
        XCTAssertEqual(SovereignKeyVault.KeyClass.parse("shared;origin=manual"), .shared)
    }

    func testAnUnknownClassStillDegradesToShared() {
        // Never to hwOnly: the D4 abort must not be reachable by feeding the
        // vault a blob it does not understand.
        XCTAssertEqual(SovereignKeyVault.KeyClass.parse("wat;origin=nfc"), .shared)
    }
}
