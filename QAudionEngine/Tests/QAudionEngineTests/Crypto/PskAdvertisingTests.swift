import XCTest
import CryptoKit
@testable import QAudionEngine

/// W-PSKMIX step 3 (iOS hygiene) — advert filtering, stable advertise order,
/// and fingerprint normalisation. Exercises `PskAdvertising` as plain data
/// (no Keychain/`SovereignKeyVault` dependency — see that type's doc comment
/// for why), mirroring the pure-function test style `PskFingerprintGateTests`
/// already uses for the matching-gate half of this same negotiation.
final class PskAdvertisingTests: XCTestCase {

    private func canonicalFp(_ psk: Data) -> String {
        SHA256.hash(data: psk).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 1. Advert filtering

    func testDeviceInternalEntriesAreExcludedFromAdvertisement() {
        let realPsk = Data(repeating: 0x11, count: 32)
        let devicePriv = Data(repeating: 0x22, count: 32)
        let kmsNameSidecar = Data("some-kms-key-name".utf8)

        let entries: [PskAdvertising.Entry] = [
            PskAdvertising.Entry(name: "peer.alice", origin: .manual, material: realPsk, createdAt: nil),
            PskAdvertising.Entry(name: "__device.x25519.priv", origin: .deviceInternal, material: devicePriv, createdAt: nil),
            PskAdvertising.Entry(name: "__kmsname.\(canonicalFp(realPsk))", origin: .deviceInternal, material: kmsNameSidecar, createdAt: nil)
        ]

        let advertised = PskAdvertising.fingerprintsForAdvertisement(entries)

        XCTAssertEqual(advertised, [canonicalFp(realPsk)])
        XCTAssertFalse(advertised.contains(canonicalFp(devicePriv)))
        XCTAssertFalse(advertised.contains(canonicalFp(kmsNameSidecar)))
    }

    func testAllDeviceInternalVaultAdvertisesNothing() {
        let entries: [PskAdvertising.Entry] = [
            PskAdvertising.Entry(name: "__device.mlkem.priv", origin: .deviceInternal, material: Data(repeating: 0x01, count: 32), createdAt: nil),
            PskAdvertising.Entry(name: "__kmsname.abcd", origin: .deviceInternal, material: Data("x".utf8), createdAt: nil)
        ]
        XCTAssertEqual(PskAdvertising.fingerprintsForAdvertisement(entries), [])
    }

    // MARK: - 2. Stable advertise order

    func testAdvertiseOrderIsStableAcrossRepeatedCalls() {
        let now = Date()
        let entries: [PskAdvertising.Entry] = [
            PskAdvertising.Entry(name: "peer.charlie", origin: .manual, material: Data(repeating: 0x03, count: 32), createdAt: now.addingTimeInterval(30)),
            PskAdvertising.Entry(name: "peer.alice", origin: .manual, material: Data(repeating: 0x01, count: 32), createdAt: now),
            PskAdvertising.Entry(name: "peer.bob", origin: .manual, material: Data(repeating: 0x02, count: 32), createdAt: now.addingTimeInterval(10))
        ]

        let first = PskAdvertising.fingerprintsForAdvertisement(entries)
        let second = PskAdvertising.fingerprintsForAdvertisement(entries)
        XCTAssertEqual(first, second, "identical vault state must advertise the identical order every time")

        // Oldest-created-first: alice (t+0) < bob (t+10) < charlie (t+30).
        XCTAssertEqual(first, [
            canonicalFp(Data(repeating: 0x01, count: 32)),
            canonicalFp(Data(repeating: 0x02, count: 32)),
            canonicalFp(Data(repeating: 0x03, count: 32))
        ])
    }

    func testAdvertiseOrderIsIndependentOfInputArrayOrder() {
        let now = Date()
        let a = PskAdvertising.Entry(name: "peer.a", origin: .manual, material: Data(repeating: 0xAA, count: 32), createdAt: now)
        let b = PskAdvertising.Entry(name: "peer.b", origin: .manual, material: Data(repeating: 0xBB, count: 32), createdAt: now.addingTimeInterval(5))

        let orderOne = PskAdvertising.fingerprintsForAdvertisement([a, b])
        let orderTwo = PskAdvertising.fingerprintsForAdvertisement([b, a])
        XCTAssertEqual(orderOne, orderTwo, "the vault's own enumeration order must not leak into the advertised order")
    }

    func testMissingCreationDateTieBreaksByName() {
        // Two entries with no recorded creation date (legacy Keychain items
        // predating this feature) must still sort deterministically — by
        // name — rather than in whatever order they were passed.
        let x = PskAdvertising.Entry(name: "peer.zzz", origin: .manual, material: Data(repeating: 0x01, count: 32), createdAt: nil)
        let y = PskAdvertising.Entry(name: "peer.aaa", origin: .manual, material: Data(repeating: 0x02, count: 32), createdAt: nil)

        XCTAssertEqual(
            PskAdvertising.fingerprintsForAdvertisement([x, y]),
            PskAdvertising.fingerprintsForAdvertisement([y, x])
        )
        XCTAssertEqual(PskAdvertising.fingerprintsForAdvertisement([x, y]), [
            canonicalFp(Data(repeating: 0x02, count: 32)),
            canonicalFp(Data(repeating: 0x01, count: 32))
        ])
    }

    func testEntryWithCreationDateSortsBeforeEntryWithout() {
        let dated = PskAdvertising.Entry(name: "peer.newer-named-but-dated", origin: .manual, material: Data(repeating: 0x01, count: 32), createdAt: Date())
        let undated = PskAdvertising.Entry(name: "peer.aaa-undated", origin: .manual, material: Data(repeating: 0x02, count: 32), createdAt: nil)

        // "peer.aaa-undated" would sort FIRST by name alone — proving the
        // dated entry wins on the creation-date criterion, not name.
        XCTAssertEqual(
            PskAdvertising.fingerprintsForAdvertisement([undated, dated]),
            [canonicalFp(Data(repeating: 0x01, count: 32)), canonicalFp(Data(repeating: 0x02, count: 32))]
        )
    }

    // MARK: - 3. Fingerprint normalisation

    func testCanonicalFingerprintIsFullLowercase64HexSha256() {
        let psk = Data(repeating: 0x42, count: 32)
        let expected = SHA256.hash(data: psk).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(PskAdvertising.canonicalFingerprint(forPsk: psk), expected)
        XCTAssertEqual(expected.count, 64)
    }

    func test16HexTruncatedLabelledEntryIsAdvertisedInCanonical64HexForm() {
        // Mirrors AppState.installKmsPreBootstrapPsk's bug: the Keychain
        // LABEL on this entry is the WRONG (16-hex-truncated) format, but
        // `Entry.material` is always the real raw key bytes — the vault
        // label is never consulted by `fingerprintsForAdvertisement`.
        let rk0 = Data(repeating: 0x55, count: 32)
        let wrongTruncatedLabel = String(SHA256.hash(data: rk0).map { String(format: "%02x", $0) }.joined().prefix(16))
        XCTAssertEqual(wrongTruncatedLabel.count, 16)

        let entry = PskAdvertising.Entry(name: "auto:deadbeef:peer-1", origin: .manual, material: rk0, createdAt: nil)
        let advertised = PskAdvertising.fingerprintsForAdvertisement([entry])

        XCTAssertEqual(advertised, [canonicalFp(rk0)])
        XCTAssertFalse(advertised.contains(wrongTruncatedLabel), "must never advertise the truncated label form")
        XCTAssertEqual(advertised.first?.count, 64)
    }

    func testDottedGroupLabelledEntryIsAdvertisedInCanonical64HexForm() {
        // Mirrors KeyRotationCoordinator's bug: entries there are labelled
        // via `Fingerprint.format(pubkey:)` (`xxxx.xxxx.xxxx.xxxx`, the
        // display form), never the wire's 64-hex form.
        let pubkey = Data(repeating: 0x66, count: 32)
        let digest = SHA256.hash(data: pubkey)
        let sixteenHex = Data(digest.prefix(8)).map { String(format: "%02x", $0) }.joined()
        var groups = [String]()
        for i in stride(from: 0, to: 16, by: 4) {
            let s = sixteenHex.index(sixteenHex.startIndex, offsetBy: i)
            let e = sixteenHex.index(s, offsetBy: 4)
            groups.append(String(sixteenHex[s..<e]))
        }
        let dottedDisplayLabel = groups.joined(separator: ".")
        XCTAssertTrue(dottedDisplayLabel.contains("."))

        let entry = PskAdvertising.Entry(name: "peer.some-user-id", origin: .manual, material: pubkey, createdAt: nil)
        let advertised = PskAdvertising.fingerprintsForAdvertisement([entry])

        XCTAssertEqual(advertised, [canonicalFp(pubkey)])
        XCTAssertFalse(advertised.contains(dottedDisplayLabel), "must never advertise the dotted display form")
    }

    func testNormalizedAdvertisedFingerprintIsSelectableByThePeerMatchingGate() {
        // End-to-end proof that item 3's fix closes the real gap: an entry
        // whose Keychain label is a non-canonical display form still
        // produces a fingerprint the OTHER side's negotiation gate
        // (`QAudionCallIntegration.pskIfFingerprintMatches`) recognises as a
        // match — i.e. it is no longer silently unselectable dead weight.
        let psk = Data(repeating: 0x77, count: 32)
        let entry = PskAdvertising.Entry(name: "rotated_ephemeral.123", origin: .manual, material: psk, createdAt: nil)
        let advertisedFp = PskAdvertising.fingerprintsForAdvertisement([entry]).first!

        XCTAssertEqual(QAudionCallIntegration.pskIfFingerprintMatches(psk, advertisedFp), psk)
    }
}
