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

    /// W-PSKMIX step 4 — the group-control-channel ratchet seed (RK_0)
    /// `AppState.installKmsPreBootstrapPsk` installs under
    /// `"auto:<prefix8>:<peerId>"` must never be advertisable as a 1:1-call
    /// PSK candidate, even though (post PR #32's `canonicalFingerprint` fix)
    /// its fingerprint is now correctly computable and would otherwise be
    /// advertised. `origin` here is `.callDerived` — what `PskOrigin.inferred`
    /// actually classifies this name as (see `KeyExportPolicyTests`), since
    /// the entry is written with no persisted origin blob.
    func testAutoPrefixedGroupCtrlRatchetSeedIsExcludedFromAdvertisement() {
        let rk0 = Data(repeating: 0x99, count: 32)
        let manualPsk = Data(repeating: 0x11, count: 32)
        let entries: [PskAdvertising.Entry] = [
            PskAdvertising.Entry(
                name: "auto:a3f7c291:11111111-2222-3333-4444-555555555555",
                origin: PskOrigin.inferred(fromAccountName: "auto:a3f7c291:11111111-2222-3333-4444-555555555555"),
                material: rk0,
                createdAt: nil
            ),
            PskAdvertising.Entry(name: "peer.alice", origin: .manual, material: manualPsk, createdAt: nil)
        ]

        let advertised = PskAdvertising.fingerprintsForAdvertisement(entries)

        XCTAssertEqual(advertised, [canonicalFp(manualPsk)])
        XCTAssertFalse(advertised.contains(canonicalFp(rk0)), "the auto: group-ctrl ratchet seed must never be advertised as a call PSK")
    }

    /// Direct exclusion check independent of the name-inference path — pins
    /// the filter itself, not just today's one caller of it.
    func testCallDerivedOriginEntriesAreExcludedFromAdvertisement() {
        let rk0 = Data(repeating: 0x88, count: 32)
        let entries: [PskAdvertising.Entry] = [
            PskAdvertising.Entry(name: "call-pb-tag1", origin: .callDerived, material: rk0, createdAt: nil)
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
        // Safe: a single .manual-origin entry is never filtered out by
        // fingerprintsForAdvertisement (see the exclusion tests above), so
        // the result always has exactly one element here.
        // swiftlint:disable:next force_unwrapping
        let advertisedFp = PskAdvertising.fingerprintsForAdvertisement([entry]).first!

        XCTAssertEqual(QAudionCallIntegration.pskIfFingerprintMatches(psk, advertisedFp), psk)
    }

    // MARK: - 4. Receive-side matching gate (W-PSKMIX step 5)

    /// `fingerprintsForAdvertisement` (step 4, 771f4c1) keeps a `.callDerived`
    /// entry off the wire on the ADVERTISE side. That investigation also
    /// found — and explicitly deferred — three RECEIVE-side call sites that
    /// scan/match the local vault by fingerprint with no origin check at
    /// all. `isEligibleMatchCandidate` is the fix: the same exclusion,
    /// applied before a vault-name candidate is ever compared against a
    /// peer-supplied fingerprint.
    func testCallDerivedOriginIsNeverAnEligibleMatchCandidate() {
        XCTAssertFalse(PskAdvertising.isEligibleMatchCandidate(origin: .callDerived))
    }

    func testNonExcludedOriginsRemainEligibleMatchCandidates() {
        XCTAssertTrue(PskAdvertising.isEligibleMatchCandidate(origin: .manual))
        XCTAssertTrue(PskAdvertising.isEligibleMatchCandidate(origin: .nfc))
        XCTAssertTrue(PskAdvertising.isEligibleMatchCandidate(origin: .qr))
        XCTAssertTrue(PskAdvertising.isEligibleMatchCandidate(origin: .kms))
    }

    /// W-IDKEYEXCL — `.deviceInternal` (this device's own long-term keys) and
    /// `.identityKey` (this device's rotated identity, or an imported peer's)
    /// are neither of them shared secrets and must never be a call-PSK match
    /// candidate, same reasoning as `.callDerived`.
    func testDeviceInternalAndIdentityKeyAreNeverEligibleMatchCandidates() {
        XCTAssertFalse(PskAdvertising.isEligibleMatchCandidate(origin: .deviceInternal))
        XCTAssertFalse(PskAdvertising.isEligibleMatchCandidate(origin: .identityKey))
    }

    /// Mirrors `AppState.routeInboundAndroidOffer`/`routeInboundAndroidAccept`
    /// building the `eligiblePsks` catalogue: every vault entry is reduced to
    /// (fingerprint, rawKey) pairs, EXCLUDING any entry that fails
    /// `isEligibleMatchCandidate`, before that catalogue is ever consulted
    /// against the peer's OFFER/ACCEPT-advertised fingerprint list. Proves a
    /// `.callDerived` entry's fingerprint never survives into the catalogue
    /// even though a bare byte/hash comparison against it would otherwise
    /// succeed.
    func testCallDerivedEntryExcludedFromResponderEligiblePsksCatalogue() {
        let rk0 = Data(repeating: 0xAB, count: 32) // the "auto:" group-ctrl ratchet seed material
        let manualPsk = Data(repeating: 0xCD, count: 32)
        let entries: [PskAdvertising.Entry] = [
            PskAdvertising.Entry(
                name: "auto:a3f7c291:11111111-2222-3333-4444-555555555555",
                origin: PskOrigin.inferred(fromAccountName: "auto:a3f7c291:11111111-2222-3333-4444-555555555555"),
                material: rk0,
                createdAt: nil
            ),
            PskAdvertising.Entry(name: "peer.alice", origin: .manual, material: manualPsk, createdAt: nil)
        ]

        // Same reduce-to-(fingerprint, rawKey) shape as AppState's
        // eligiblePsks Dictionary(...) builder, minus the Keychain calls.
        let eligiblePsks: [String: Data] = Dictionary(
            entries.compactMap { entry -> (String, Data)? in
                guard PskAdvertising.isEligibleMatchCandidate(origin: entry.origin) else { return nil }
                return (canonicalFp(entry.material), entry.material)
            },
            uniquingKeysWith: { first, _ in first }
        )

        let rk0Fp = canonicalFp(rk0)
        XCTAssertNil(eligiblePsks[rk0Fp], "the auto: group-ctrl ratchet seed must never be an eligible call-PSK match candidate")
        XCTAssertEqual(eligiblePsks[canonicalFp(manualPsk)], manualPsk)
        XCTAssertEqual(eligiblePsks.count, 1)
    }

    /// Mirrors `QAudionCallIntegration`'s post-ACCEPT lookup (both the V4
    /// branch's `vaultPsk` and the schema:2 fallback's `fallbackPsk`): find
    /// the FIRST vault name whose fingerprint is a member of the peer-echoed
    /// `selectedPskFingerprint` selection. Proves a `.callDerived` entry
    /// whose fingerprint exactly equals the peer-echoed value is skipped —
    /// even though the raw fingerprint comparison alone would match — and
    /// that an ordinary entry is still found normally.
    func testCallDerivedEntryNeverSelectedInInitiatorPostAcceptLookup() {
        let rk0 = Data(repeating: 0xEF, count: 32)
        let callDerivedName = "call-pb-tag1"
        let entries: [PskAdvertising.Entry] = [
            PskAdvertising.Entry(name: callDerivedName, origin: PskOrigin.inferred(fromAccountName: callDerivedName), material: rk0, createdAt: nil)
        ]
        let selectedFp = canonicalFp(rk0) // the peer echoed exactly this fingerprint back

        // Same filter-then-match shape as the two QAudionCallIntegration
        // closures: `vault.listPskNames().first(where: { origin-check &&
        // fingerprint ∈ selection })`.
        let matched = entries.first(where: { entry in
            guard PskAdvertising.isEligibleMatchCandidate(origin: entry.origin) else { return false }
            return canonicalFp(entry.material) == selectedFp
        })
        XCTAssertNil(matched, "a .callDerived entry must never be selected even when its fingerprint byte-matches the peer-echoed value")

        // Sanity: an ordinary manual entry with the same fingerprint IS found.
        let manualEntries: [PskAdvertising.Entry] = [
            PskAdvertising.Entry(name: "peer.alice", origin: .manual, material: rk0, createdAt: nil)
        ]
        let matchedManual = manualEntries.first(where: { entry in
            guard PskAdvertising.isEligibleMatchCandidate(origin: entry.origin) else { return false }
            return canonicalFp(entry.material) == selectedFp
        })
        XCTAssertEqual(matchedManual?.material, rk0)
    }

    // MARK: - 5. resolvePskBytes video-HKDF-salt gate (W-PSKMIX step 6)

    /// `AppState.resolvePskBytes` (`QAudionApp/AppState.swift`) does the same
    /// `listPskNames().first(where:)` scan-by-fingerprint as the step-5 gates
    /// above, but its return value is more severe if unfiltered: it feeds
    /// directly into `QAudionCallIntegration.deriveVideoKey`'s HKDF *salt*
    /// (`videoContactPsk`), not merely "which PSK gets selected/displayed".
    /// This cannot `@testable import` `AppState` (QAudionApp depends on
    /// QAudionEngine, not the reverse), so — same workaround the step-5 tests
    /// above use for the AppState.swift closures — this mirrors the exact
    /// filter-then-match shape added to `resolvePskBytes` (and its
    /// display-only twin `resolvePskDisplayMeta`) as plain `Entry` values.
    /// Proves a `.callDerived` entry's raw material is never returned even
    /// when the peer echoes its exact fingerprint back.
    func testCallDerivedEntryNeverReturnedAsVideoHkdfSaltMaterial() {
        let ratchetSeed = Data(repeating: 0x5A, count: 32) // group-ctrl "auto:" ratchet seed
        let autoName = "auto:a3f7c291:11111111-2222-3333-4444-555555555555"
        let entries: [PskAdvertising.Entry] = [
            PskAdvertising.Entry(name: autoName, origin: PskOrigin.inferred(fromAccountName: autoName), material: ratchetSeed, createdAt: nil)
        ]
        let peerEchoedFp = canonicalFp(ratchetSeed)

        // Same shape as resolvePskBytes: find the first non-"__" name whose
        // origin is an eligible match candidate AND whose fingerprint equals
        // the peer-supplied value, then return its raw material (nil if none).
        let resolvedBytes: Data? = entries.first(where: { entry in
            guard !entry.name.hasPrefix("__") else { return false }
            guard PskAdvertising.isEligibleMatchCandidate(origin: entry.origin) else { return false }
            return canonicalFp(entry.material) == peerEchoedFp
        })?.material
        XCTAssertNil(resolvedBytes, "a .callDerived entry's raw bytes must never be returned as video HKDF salt material, even on an exact fingerprint echo")

        // Sanity: an ordinary manual PSK with the same fingerprint IS resolved
        // (nil is the safe "fall back to default video salt" case, not a
        // side-effect of the guard rejecting everything).
        let manualEntries: [PskAdvertising.Entry] = [
            PskAdvertising.Entry(name: "peer.alice", origin: .manual, material: ratchetSeed, createdAt: nil)
        ]
        let resolvedManualBytes: Data? = manualEntries.first(where: { entry in
            guard !entry.name.hasPrefix("__") else { return false }
            guard PskAdvertising.isEligibleMatchCandidate(origin: entry.origin) else { return false }
            return canonicalFp(entry.material) == peerEchoedFp
        })?.material
        XCTAssertEqual(resolvedManualBytes, ratchetSeed)
    }
}
