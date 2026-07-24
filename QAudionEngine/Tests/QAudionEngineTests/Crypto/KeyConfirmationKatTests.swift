import XCTest
@testable import QAudionEngine

/// W-KCMAC (multi-PSK-mixing SYNTHESIS.md ship step 5) — cross-platform KAT vectors
/// for `KeyConfirmation`, shared byte-for-byte with the Android/Desktop ports (all
/// three MUST reproduce these exact hex values). `N<=1` scope only — see the type doc.
///
/// Vectors verified independently against a from-scratch Python HKDF/HMAC/SHA-256
/// reconstruction before being written into this file (not hand-typed/invented) —
/// all five (`kc_transcript_basic`, `kc_shrink`, `kc_permute`, `kc_reflect`,
/// `kc_identity`) reproduce byte-for-byte.
final class KeyConfirmationKatTests: XCTestCase {

    // MARK: - Shared fixture (kc_transcript_basic)

    private let sessionKeyHex = "96420bb860e8274eb31d33c4dde67b90498eefd8d7039853afadf2889b95e027"
    private let ikInitHex = "f6fdb67ebddfe29764093430d1d0c7fa1a2fb6b4c5bba7c7cf062adbb9796f8a"
    private let ikRespHex = "140832a6d0e3f7d3700b3c4675adf17731345b86a19059fe4c1a5cc195d676bf"
    private let offerBindingHex = "bd34106bc34fd2ab539ef464ce1a6f941461e76f4669151ced2dd24a2e14cf77"
    private let acceptBindingHex = "121c74a70018f18a143560196c54587ea4c11eca7a6c77d243dc40e04924289c"
    private let fp1Hex = "f425f16640411d0ddaed20071678553e90c6567ffd96b709841a7d85b84c499d"

    private let expectedKKcHex = "e4f60f40c85533a29bc4a5030f763e47b7c47b5946a134e0cd19f82e49f84ce5"
    private let expectedTranscriptBasicHex = "c535c97e8eb03218f83a5837ffc9eacae7932266d37b9546fedebee3969e0419"
    private let expectedMacInitBasicHex = "267dd2e97ceeda09b2d8b66f555d5577ec57ae36bbe53e945d8c855a7c3692e5"
    private let expectedMacRespBasicHex = "5eee1fdcedae6146411855e827defc81e2325c838a14cd0313361ee41de211ba"

    private func data(_ hex: String) -> Data {
        var out = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            out.append(UInt8(hex[idx..<next], radix: 16)!)
            idx = next
        }
        return out
    }

    private func initAdvert() -> [KeyConfirmation.PskAdvertEntry] {
        [
            .init(role: 1, fingerprintHex: "a7d0154968e8d2bdf5b86ef307ad7fc232a2f15a271a8396ec1af0d79a4dca78"),
            .init(role: 0, fingerprintHex: "affb1ca9212ebd548130f2334a1be58f2dfe3c72031a0b99e71c6256f373e907"),
        ]
    }

    private func respAdvert() -> [KeyConfirmation.PskAdvertEntry] {
        [
            .init(role: 2, fingerprintHex: "235c568d6e03358235e846add4477a4b587e6d137c011d110348d9b9a7680978"),
            .init(role: 0, fingerprintHex: "e75c2a84d437d40c3eb9ff4bd11d65badd833ee4582fa6e5a4c4263f9eb1378e"),
        ]
    }

    // MARK: - K_kc

    func testDeriveKcKeyMatchesSharedVector() {
        let kKc = KeyConfirmation.deriveKcKey(sessionKey: data(sessionKeyHex))
        XCTAssertEqual(kKc.map { String(format: "%02x", $0) }.joined(), expectedKKcHex)
    }

    // MARK: - kc_transcript_basic

    func testTranscriptBasicMatchesSharedVector() {
        guard let transcript = KeyConfirmation.transcript(
            offerBinding: data(offerBindingHex),
            acceptBinding: data(acceptBindingHex),
            initAdvert: initAdvert(),
            respAdvert: respAdvert(),
            mixFingerprints: [data(fp1Hex)],
            mixId: Data(),
            ikInit: data(ikInitHex),
            ikResp: data(ikRespHex)
        ) else {
            XCTFail("transcript returned nil"); return
        }
        XCTAssertEqual(transcript.map { String(format: "%02x", $0) }.joined(), expectedTranscriptBasicHex)

        let kKc = data(expectedKKcHex)
        let macInit = KeyConfirmation.macInit(kcKey: kKc, transcript: transcript)
        let macResp = KeyConfirmation.macResp(kcKey: kKc, transcript: transcript)
        XCTAssertEqual(macInit.map { String(format: "%02x", $0) }.joined(), expectedMacInitBasicHex)
        XCTAssertEqual(macResp.map { String(format: "%02x", $0) }.joined(), expectedMacRespBasicHex)

        XCTAssertTrue(KeyConfirmation.verify(received: macInit, kcKey: kKc, asInitiator: true, transcript: transcript))
        XCTAssertTrue(KeyConfirmation.verify(received: macResp, kcKey: kKc, asInitiator: false, transcript: transcript))
    }

    // MARK: - kc_shrink: dropping one resp_advert entry must invalidate kc_mac_resp

    func testShrinkInvalidatesRespMac() {
        let kKc = data(expectedKKcHex)
        let genuineMacResp = data(expectedMacRespBasicHex) // computed by the real responder over the FULL list

        let shrunkRespAdvert = [respAdvert()[0]] // entry dropped in transit

        guard let shrunkTranscript = KeyConfirmation.transcript(
            offerBinding: data(offerBindingHex),
            acceptBinding: data(acceptBindingHex),
            initAdvert: initAdvert(),
            respAdvert: shrunkRespAdvert,
            mixFingerprints: [data(fp1Hex)],
            mixId: Data(),
            ikInit: data(ikInitHex),
            ikResp: data(ikRespHex)
        ) else {
            XCTFail("transcript returned nil"); return
        }

        XCTAssertEqual(
            shrunkTranscript.map { String(format: "%02x", $0) }.joined(),
            "417044414877eafef85b22b3a44cae88c83cd57aa14a404bb476069666296584"
        )

        let expectedMacOverShrunk = KeyConfirmation.macResp(kcKey: kKc, transcript: shrunkTranscript)
        XCTAssertEqual(
            expectedMacOverShrunk.map { String(format: "%02x", $0) }.joined(),
            "90ff5415d3220a245fe0ef6f8d31952e7aa3b8dead4405132050aeee3ceb05a4"
        )

        XCTAssertFalse(
            KeyConfirmation.verify(received: genuineMacResp, kcKey: kKc, asInitiator: false, transcript: shrunkTranscript),
            "the genuine kc_mac_resp (over the FULL advert) MUST NOT verify against the shrunk transcript a relay tampered with"
        )
    }

    // MARK: - kc_permute: same membership, different wire order => different transcript

    func testPermuteChangesTranscriptAndInvalidatesMac() {
        let kKc = data(expectedKKcHex)
        let genuineMacInit = data(expectedMacInitBasicHex)

        let permutedInitAdvert = Array(initAdvert().reversed())

        guard let permutedTranscript = KeyConfirmation.transcript(
            offerBinding: data(offerBindingHex),
            acceptBinding: data(acceptBindingHex),
            initAdvert: permutedInitAdvert,
            respAdvert: respAdvert(),
            mixFingerprints: [data(fp1Hex)],
            mixId: Data(),
            ikInit: data(ikInitHex),
            ikResp: data(ikRespHex)
        ) else {
            XCTFail("transcript returned nil"); return
        }

        XCTAssertEqual(
            permutedTranscript.map { String(format: "%02x", $0) }.joined(),
            "defc8b16197d9cb5bfbfb2f9f9fbc5a7dd4ae7043cc9ccfa5599dac8885f83d9"
        )
        XCTAssertNotEqual(
            permutedTranscript.map { String(format: "%02x", $0) }.joined(),
            expectedTranscriptBasicHex,
            "advEnc must bind wire ORDER, not a sorted set — permuting must change kc_transcript"
        )

        let macInitPermuted = KeyConfirmation.macInit(kcKey: kKc, transcript: permutedTranscript)
        let macRespPermuted = KeyConfirmation.macResp(kcKey: kKc, transcript: permutedTranscript)
        XCTAssertEqual(macInitPermuted.map { String(format: "%02x", $0) }.joined(), "2c3da5f19422c8b38974bdf04099f5a0a6852142537c47cb38e0e8b48ca5a14f")
        XCTAssertEqual(macRespPermuted.map { String(format: "%02x", $0) }.joined(), "9d40da543c5c04fa75edd276ac3b52deb5f1439154fb1bbc0195a285226c8a26")

        XCTAssertFalse(
            KeyConfirmation.verify(received: genuineMacInit, kcKey: kKc, asInitiator: true, transcript: permutedTranscript),
            "a kc_mac_init computed over the ORIGINAL order must not verify against a permuted-order transcript"
        )
    }

    // MARK: - kc_reflect: replaying kc_mac_init as kc_mac_resp must never verify

    func testReflectedMacNeverVerifies() {
        let kKc = data(expectedKKcHex)
        let transcript = data(expectedTranscriptBasicHex)
        let genuineMacInit = data(expectedMacInitBasicHex)

        XCTAssertNotEqual(
            genuineMacInit.map { String(format: "%02x", $0) }.joined(),
            expectedMacRespBasicHex,
            "role-byte domain separation must make kc_mac_init != kc_mac_resp over the identical transcript"
        )
        XCTAssertFalse(
            KeyConfirmation.verify(received: genuineMacInit, kcKey: kKc, asInitiator: false, transcript: transcript),
            "kc_mac_init replayed verbatim as kc_mac_resp MUST NOT verify (0x01 vs 0x02 role-byte domain separation)"
        )
    }

    // MARK: - kc_identity: swapped ik_init/ik_resp must change the transcript

    func testIdentityKeySwapChangesTranscriptAndInvalidatesMac() {
        let kKc = data(expectedKKcHex)
        let genuineMacInit = data(expectedMacInitBasicHex)

        guard let swappedTranscript = KeyConfirmation.transcript(
            offerBinding: data(offerBindingHex),
            acceptBinding: data(acceptBindingHex),
            initAdvert: initAdvert(),
            respAdvert: respAdvert(),
            mixFingerprints: [data(fp1Hex)],
            mixId: Data(),
            ikInit: data(ikRespHex), // swapped
            ikResp: data(ikInitHex) // swapped
        ) else {
            XCTFail("transcript returned nil"); return
        }

        XCTAssertEqual(
            swappedTranscript.map { String(format: "%02x", $0) }.joined(),
            "fb8245bf92634a537e980c105153e722ea0dabc3afdf13fb3a70fea1685a66bd"
        )
        XCTAssertNotEqual(swappedTranscript.map { String(format: "%02x", $0) }.joined(), expectedTranscriptBasicHex)

        let macInitSwapped = KeyConfirmation.macInit(kcKey: kKc, transcript: swappedTranscript)
        let macRespSwapped = KeyConfirmation.macResp(kcKey: kKc, transcript: swappedTranscript)
        XCTAssertEqual(macInitSwapped.map { String(format: "%02x", $0) }.joined(), "ef2bd529d9dffa5e371caa3eb08786597dca0412981da3a8282cd300828fec4f")
        XCTAssertEqual(macRespSwapped.map { String(format: "%02x", $0) }.joined(), "ec87dc5ca180d0ac3c54dd612bb756c74b353e3a520f53dcc06775836bf40c38")

        XCTAssertFalse(
            KeyConfirmation.verify(received: genuineMacInit, kcKey: kKc, asInitiator: true, transcript: swappedTranscript),
            "an identity-key mix-up (MITM rebinding) must invalidate the genuine MAC"
        )
    }

    // MARK: - advEnc oversized-list never-throw discipline (mirrors HandshakeTranscript.advEnc)

    func testAdvEncReturnsNilForOversizedList() {
        let many = (0..<256).map { _ in KeyConfirmation.PskAdvertEntry(role: 0, fingerprintHex: String(repeating: "0", count: 64)) }
        XCTAssertNil(KeyConfirmation.advEnc(many))
    }

    func testTranscriptReturnsNilWhenEitherAdvertOversized() {
        let many = (0..<256).map { _ in KeyConfirmation.PskAdvertEntry(role: 0, fingerprintHex: String(repeating: "0", count: 64)) }
        let result = KeyConfirmation.transcript(
            offerBinding: data(offerBindingHex), acceptBinding: data(acceptBindingHex),
            initAdvert: many, respAdvert: respAdvert(),
            mixFingerprints: [data(fp1Hex)], mixId: Data(),
            ikInit: data(ikInitHex), ikResp: data(ikRespHex)
        )
        XCTAssertNil(result, "an oversized advert list on either side must fail gracefully (nil), never trap")
    }

    // MARK: - pskAdvertEntries (ship step 5 wiring helper: wire fields → PskAdvertEntry[])

    func testPskAdvertEntriesNilFingerprintsIsEmpty() {
        XCTAssertEqual(KeyConfirmation.pskAdvertEntries(fingerprintsHex: nil, roles: nil), [])
        XCTAssertEqual(KeyConfirmation.pskAdvertEntries(fingerprintsHex: nil, roles: [1, 2]), [])
    }

    func testPskAdvertEntriesNilRolesDefaultToZero() {
        let fps = ["a", "b", "c"]
        let entries = KeyConfirmation.pskAdvertEntries(fingerprintsHex: fps, roles: nil)
        XCTAssertEqual(entries.map(\.role), [0, 0, 0])
        XCTAssertEqual(entries.map(\.fingerprintHex), fps)
    }

    func testPskAdvertEntriesShorterRolesArrayDefaultsTrailingToZero() {
        // Mirrors `HandshakeTranscript.advEnc`'s "roles shorter than fingerprints
        // ⇒ 0 for the missing tail" convention.
        let fps = ["a", "b", "c"]
        let entries = KeyConfirmation.pskAdvertEntries(fingerprintsHex: fps, roles: [7])
        XCTAssertEqual(entries.map(\.role), [7, 0, 0])
    }

    func testPskAdvertEntriesPreservesOrderExactly() {
        let fps = ["z", "a", "m"]
        let roles = [3, 1, 2]
        let entries = KeyConfirmation.pskAdvertEntries(fingerprintsHex: fps, roles: roles)
        XCTAssertEqual(entries.map(\.fingerprintHex), fps, "must preserve wire order verbatim, never re-sort")
        XCTAssertEqual(entries.map(\.role), roles)
    }

    func testPskAdvertEntriesEmptyFingerprintsIsEmptyEntries() {
        XCTAssertEqual(KeyConfirmation.pskAdvertEntries(fingerprintsHex: [], roles: nil), [])
    }

    // MARK: - W-KCMACROLES (2026-07-24) — regression guards for the class of bug that
    // produced a FALSE `S1_KC_FAILED` "active attack" verdict on live call db4e5b20.
    //
    // Root cause shape: iOS is the ONLY platform that rebuilds a transcript advert from
    // a SEPARATE source of truth (a stash, or a hardcoded `nil`) instead of from the
    // bundle object that actually went on the wire — Android
    // (`PqcHandshake.toKcAdverts(signedOffer.pskFingerprints, signedOffer.pskRoles)`)
    // and Desktop (`advertEntriesFromWire(offerBundle…, acceptBundle…)`) are immune by
    // construction. So iOS needs these explicit guards instead.

    /// The exact live failure: our OFFER carried real roles (an NFC key ⇒ role 1) but our
    /// own transcript was rebuilt with `roles: nil` (⇒ all-zero). The peer rebuilds from
    /// the OFFER it RECEIVED, i.e. with the real roles — so the two transcripts diverge
    /// and every MAC comparison fails, which `AssuranceState` then reports as an active
    /// attack (S1) on a completely healthy call.
    func testDroppingRealRolesDivergesTranscript_theFalseS1Bug() {
        let sessionKey = data(sessionKeyHex)
        let ikInit = data(ikInitHex)
        let ikResp = data(ikRespHex)
        let offerBinding = data(offerBindingHex)
        let acceptBinding = data(acceptBindingHex)
        let sentFps = [fp1Hex]
        let sentRoles = [1] // NFC-origin — exactly what triggered the live failure

        // What the PEER computes: rebuilt from the wire it received (real roles).
        let peerSide = KeyConfirmation.transcript(
            offerBinding: offerBinding, acceptBinding: acceptBinding,
            initAdvert: KeyConfirmation.pskAdvertEntries(fingerprintsHex: sentFps, roles: sentRoles),
            respAdvert: [], mixFingerprints: [], mixId: Data(),
            ikInit: ikInit, ikResp: ikResp)

        // What the BUGGY local side computed: same fingerprints, roles dropped to nil.
        let buggyLocal = KeyConfirmation.transcript(
            offerBinding: offerBinding, acceptBinding: acceptBinding,
            initAdvert: KeyConfirmation.pskAdvertEntries(fingerprintsHex: sentFps, roles: nil),
            respAdvert: [], mixFingerprints: [], mixId: Data(),
            ikInit: ikInit, ikResp: ikResp)

        XCTAssertNotNil(peerSide)
        XCTAssertNotNil(buggyLocal)
        XCTAssertNotEqual(peerSide, buggyLocal,
                          "dropping real role bytes MUST change the transcript — this is why the bug was silent-but-fatal")

        // And therefore the MACs never verify: the false-S1 mechanism, end to end.
        let kKc = KeyConfirmation.deriveKcKey(sessionKey: sessionKey)
        let peerMac = KeyConfirmation.macInit(kcKey: kKc, transcript: peerSide!)
        XCTAssertFalse(
            KeyConfirmation.verify(received: peerMac, kcKey: kKc, asInitiator: true, transcript: buggyLocal!),
            "the peer's MAC must NOT verify against the role-stripped transcript")

        // The fix: rebuild with the roles we actually sent ⇒ byte-identical ⇒ verifies.
        let fixedLocal = KeyConfirmation.transcript(
            offerBinding: offerBinding, acceptBinding: acceptBinding,
            initAdvert: KeyConfirmation.pskAdvertEntries(fingerprintsHex: sentFps, roles: sentRoles),
            respAdvert: [], mixFingerprints: [], mixId: Data(),
            ikInit: ikInit, ikResp: ikResp)
        XCTAssertEqual(fixedLocal, peerSide)
        XCTAssertTrue(
            KeyConfirmation.verify(received: peerMac, kcKey: kKc, asInitiator: true, transcript: fixedLocal!))
    }

    /// The mirror case on the responder leg: our ACCEPT advertises fingerprints/roles,
    /// but the local transcript rebuilt `respAdvert` as empty. Same divergence, same
    /// false S1 — just in the other direction. (Both sites existed simultaneously.)
    func testDroppingOwnAcceptAdvertDivergesTranscript_theMirrorBug() {
        let ikInit = data(ikInitHex)
        let ikResp = data(ikRespHex)
        let offerBinding = data(offerBindingHex)
        let acceptBinding = data(acceptBindingHex)
        let ourAcceptFps = [fp1Hex]
        let ourAcceptRoles = [1]

        let peerSide = KeyConfirmation.transcript(
            offerBinding: offerBinding, acceptBinding: acceptBinding,
            initAdvert: [],
            respAdvert: KeyConfirmation.pskAdvertEntries(fingerprintsHex: ourAcceptFps, roles: ourAcceptRoles),
            mixFingerprints: [], mixId: Data(), ikInit: ikInit, ikResp: ikResp)

        let buggyLocal = KeyConfirmation.transcript(
            offerBinding: offerBinding, acceptBinding: acceptBinding,
            initAdvert: [],
            respAdvert: [], // the old hardcoded "the ACCEPT no longer advertises" assumption
            mixFingerprints: [], mixId: Data(), ikInit: ikInit, ikResp: ikResp)

        XCTAssertNotEqual(peerSide, buggyLocal,
                          "an ACCEPT that advertises on the wire but rebuilds its own advert as empty MUST diverge")
    }

    /// Guards the invariant directly, independent of any one call site: a transcript is
    /// only reproducible when BOTH adverts are rebuilt from what was ACTUALLY sent. Any
    /// future refactor that re-introduces a separate/derived source for either side
    /// fails here rather than in production as a phantom "active attack".
    func testTranscriptIsReproducibleOnlyFromWhatWasActuallySent() {
        let ikInit = data(ikInitHex)
        let ikResp = data(ikRespHex)
        let offerBinding = data(offerBindingHex)
        let acceptBinding = data(acceptBindingHex)
        let initFps = [fp1Hex], initRoles = [1]
        let respFps = [fp1Hex], respRoles = [0]

        let onTheWire = KeyConfirmation.transcript(
            offerBinding: offerBinding, acceptBinding: acceptBinding,
            initAdvert: KeyConfirmation.pskAdvertEntries(fingerprintsHex: initFps, roles: initRoles),
            respAdvert: KeyConfirmation.pskAdvertEntries(fingerprintsHex: respFps, roles: respRoles),
            mixFingerprints: [], mixId: Data(), ikInit: ikInit, ikResp: ikResp)
        XCTAssertNotNil(onTheWire)

        // Every "lossy" rebuild of either side must be detectably different.
        let lossyVariants: [(String, [Int]?, [Int]?)] = [
            ("init roles dropped", nil, respRoles),
            ("resp roles dropped", initRoles, nil),
            ("both roles dropped", nil, nil),
        ]
        for (label, iR, rR) in lossyVariants {
            let variant = KeyConfirmation.transcript(
                offerBinding: offerBinding, acceptBinding: acceptBinding,
                initAdvert: KeyConfirmation.pskAdvertEntries(fingerprintsHex: initFps, roles: iR),
                respAdvert: KeyConfirmation.pskAdvertEntries(fingerprintsHex: respFps, roles: rR),
                mixFingerprints: [], mixId: Data(), ikInit: ikInit, ikResp: ikResp)
            XCTAssertNotEqual(onTheWire, variant, "\(label) must not silently reproduce the wire transcript")
        }
    }
}
