import XCTest
import CryptoKit
@testable import QAudionEngine

/// The dual-dialect selection rule (WIRE_SPEC §3.3 + §3.3.1), pinned.
///
/// Mirrors Android's `PskAdvertResolverTest.kt` and Desktop's
/// `pskAdvertResolver.spec.ts` case for case. Every one is a way the rollout could
/// silently lose a PSK or silently mislabel one. None of them crash — they degrade
/// quietly and both users still see a connected call — which is why they get a test
/// rather than a comment.
final class PskAdvertResolverTests: XCTestCase {

    private let callId = "3f2b7c10-9a4d-4e11-8b62-0c5d7e91a204"
    private let initiatorPub = Data((0..<32).map { UInt8(($0 + 1) & 0xFF) })
    private let responderPub = Data((0..<32).map { UInt8(($0 + 200) & 0xFF) })

    private func psk(_ seed: Int) -> Data {
        Data((0..<32).map { UInt8((($0 * 31) + seed) & 0xFF) })
    }

    private func staticFp(_ p: Data) -> String {
        SHA256.hash(data: p).map { String(format: "%02x", $0) }.joined()
    }

    private func cand(_ seed: Int, _ role: Int = PskAdvertV3.roleOrdinary) -> PskAdvertResolver.Candidate {
        PskAdvertResolver.Candidate(staticFp: staticFp(psk(seed)), psk: psk(seed), localRole: role)
    }

    // MARK: - v3

    func testResolvesABlindedAdvertAndReportsTheV3Dialect() {
        let c = cand(1, PskAdvertV3.roleNfc)
        let advert = PskAdvertV3.buildAdvertisement(
            callId: callId, ownEphemeralX25519Pub: initiatorPub,
            orderedEntries: [PskAdvertV3.Entry(psk: c.psk, role: PskAdvertV3.roleNfc)]
        )!
        let r = PskAdvertResolver.resolve(
            receivedAdvert: advert, receivedRoles: nil, callId: callId,
            senderEphemeralX25519Pub: initiatorPub, candidates: [c]
        )
        XCTAssertEqual(.v3Blinded, r.dialect)
        // The echo goes back as the RECEIVED value, never as our static fingerprint —
        // echoing the static form would put the selected key's permanent correlator
        // back on the wire on every call and defeat the whole point.
        XCTAssertEqual(advert[0], r.wireValue)
        // Everything downstream gets the STATIC fingerprint instead.
        XCTAssertEqual(c.staticFp, r.staticFp)
        XCTAssertEqual(PskAdvertV3.roleNfc, r.peerRole)
        XCTAssertEqual(Set([c.staticFp]), r.mutualStaticFps)
        XCTAssertEqual(Set([PskAdvertV3.roleNfc]), r.mutualPeerRoles)
    }

    /// The role the peer recorded, not the one WE recorded. Under v3 this is the only
    /// way that fact survives, since `pskRoles` is omitted from the wire.
    func testRecoversThePeersRoleEvenWhenOursDisagrees() {
        // We hold it as KMS-origin (0); the peer tapped it over NFC (1).
        let local = cand(2, PskAdvertV3.roleOrdinary)
        let advert = PskAdvertV3.buildAdvertisement(
            callId: callId, ownEphemeralX25519Pub: initiatorPub,
            orderedEntries: [PskAdvertV3.Entry(psk: local.psk, role: PskAdvertV3.roleNfc)]
        )!
        let r = PskAdvertResolver.resolve(
            receivedAdvert: advert, receivedRoles: nil, callId: callId,
            senderEphemeralX25519Pub: initiatorPub, candidates: [local]
        )
        XCTAssertEqual(.v3Blinded, r.dialect)
        XCTAssertEqual(
            PskAdvertV3.roleNfc, r.peerRole,
            "a role disagreement must not cost the PSK — this is why the receiver walks all 256"
        )
    }

    func testKeepsTheAdvertisersPriorityUnderV3() {
        let a = cand(3)
        let b = cand(4)
        // The peer advertises b FIRST. We hold both, and our own order puts a first.
        let advert = PskAdvertV3.buildAdvertisement(
            callId: callId, ownEphemeralX25519Pub: initiatorPub,
            orderedEntries: [
                PskAdvertV3.Entry(psk: b.psk, role: 0),
                PskAdvertV3.Entry(psk: a.psk, role: 0),
            ]
        )!
        let r = PskAdvertResolver.resolve(
            receivedAdvert: advert, receivedRoles: nil, callId: callId,
            senderEphemeralX25519Pub: initiatorPub, candidates: [a, b]
        )
        XCTAssertEqual(b.staticFp, r.staticFp, "scanning our own list first would move the priority to us")
        XCTAssertEqual([b.staticFp, a.staticFp], r.mutual.map { $0.0 })
    }

    /// The full mutual set, not just the selection. The §D4 hw_only intersect and the
    /// NFC-in-common signal both read it; a set truncated at the first hit would stop
    /// enforcing a requirement and blank a trust chip.
    func testReportsEverySharedSecretNotOnlyTheSelectedOne() {
        let a = cand(5)
        let b = cand(6)
        let advert = PskAdvertV3.buildAdvertisement(
            callId: callId, ownEphemeralX25519Pub: initiatorPub,
            orderedEntries: [
                PskAdvertV3.Entry(psk: a.psk, role: PskAdvertV3.roleOrdinary),
                PskAdvertV3.Entry(psk: b.psk, role: PskAdvertV3.roleNfc),
            ]
        )!
        let r = PskAdvertResolver.resolve(
            receivedAdvert: advert, receivedRoles: nil, callId: callId,
            senderEphemeralX25519Pub: initiatorPub, candidates: [a, b]
        )
        XCTAssertEqual(a.staticFp, r.staticFp)
        XCTAssertEqual(Set([a.staticFp, b.staticFp]), r.mutualStaticFps)
        XCTAssertTrue(r.mutualPeerRoles.contains(PskAdvertV3.roleNfc))
    }

    /// The nonce is the sender's. Matching a blinded advert with our OWN ephemeral key
    /// finds nothing, which is exactly the silent no-match the explicit argument exists
    /// to prevent.
    func testTheWrongEphemeralKeyFindsNothing() {
        let c = cand(7)
        let advert = PskAdvertV3.buildAdvertisement(
            callId: callId, ownEphemeralX25519Pub: initiatorPub,
            orderedEntries: [PskAdvertV3.Entry(psk: c.psk, role: 0)]
        )!
        let r = PskAdvertResolver.resolve(
            receivedAdvert: advert, receivedRoles: nil, callId: callId,
            senderEphemeralX25519Pub: responderPub, candidates: [c]
        )
        XCTAssertEqual(.unknown, r.dialect)
        XCTAssertNil(r.staticFp)
    }

    // MARK: - §3.3 static fallback

    func testResolvesALegacyStaticAdvertAndReportsTheV2Dialect() {
        let c = cand(8)
        let r = PskAdvertResolver.resolve(
            receivedAdvert: [c.staticFp], receivedRoles: [PskAdvertV3.roleNfc], callId: callId,
            senderEphemeralX25519Pub: initiatorPub, candidates: [c]
        )
        XCTAssertEqual(.v2Static, r.dialect)
        XCTAssertEqual(c.staticFp, r.wireValue)
        XCTAssertEqual(c.staticFp, r.staticFp)
        // Under the static dialect the role DOES come off the wire.
        XCTAssertEqual(PskAdvertV3.roleNfc, r.peerRole)
    }

    /// The whole reason there is no capability bit: a pre-v3 peer keeps working with no
    /// negotiation, because the dialect is inferred from what arrived.
    func testALegacyPeerIsNotBrokenByTheV3Attempt() {
        let a = cand(9)
        let b = cand(10)
        let r = PskAdvertResolver.resolve(
            receivedAdvert: [b.staticFp, a.staticFp], receivedRoles: nil, callId: callId,
            senderEphemeralX25519Pub: initiatorPub, candidates: [a, b]
        )
        XCTAssertEqual(.v2Static, r.dialect)
        XCTAssertEqual(b.staticFp, r.staticFp, "the advertiser's priority holds in the static dialect too")
        XCTAssertEqual(Set([a.staticFp, b.staticFp]), r.mutualStaticFps)
    }

    /// `pskRoles` is a PARALLEL array. If a malformed advertised entry were dropped
    /// instead of skipped in place, every later role would shift by one and an NFC
    /// secret would be reported as ordinary — a wrong trust chip, not a crash.
    func testAMalformedEntryDoesNotShiftTheParallelRolesArray() {
        let c = cand(11)
        let r = PskAdvertResolver.resolve(
            receivedAdvert: ["", "not-hex", c.staticFp],
            receivedRoles: [0, 0, PskAdvertV3.roleNfc],
            callId: callId, senderEphemeralX25519Pub: initiatorPub, candidates: [c]
        )
        XCTAssertEqual(.v2Static, r.dialect)
        XCTAssertEqual(c.staticFp, r.staticFp)
        XCTAssertEqual(
            PskAdvertV3.roleNfc, r.peerRole,
            "the role must come from index 2, not from a re-indexed filtered list"
        )
    }

    func testAnAbsentRolesArrayReadsAsOrdinary() {
        let c = cand(12)
        let r = PskAdvertResolver.resolve(
            receivedAdvert: [c.staticFp], receivedRoles: nil, callId: callId,
            senderEphemeralX25519Pub: initiatorPub, candidates: [c]
        )
        XCTAssertEqual(PskAdvertV3.roleOrdinary, r.peerRole)
    }

    // MARK: - nothing shared

    func testNoSharedSecretIsUnknownNotAWrongMatch() {
        let theirs = cand(13)
        let ours = cand(14)
        let blinded = PskAdvertV3.buildAdvertisement(
            callId: callId, ownEphemeralX25519Pub: initiatorPub,
            orderedEntries: [PskAdvertV3.Entry(psk: theirs.psk, role: 0)]
        )!
        for advert in [blinded, [theirs.staticFp]] {
            let r = PskAdvertResolver.resolve(
                receivedAdvert: advert, receivedRoles: nil, callId: callId,
                senderEphemeralX25519Pub: initiatorPub, candidates: [ours]
            )
            XCTAssertEqual(.unknown, r.dialect)
            XCTAssertNil(r.wireValue)
            XCTAssertNil(r.psk)
            XCTAssertTrue(r.mutual.isEmpty)
        }
    }

    func testEmptyAndNilInputsAreHandledWithoutCrashing() {
        let c = cand(15)
        XCTAssertEqual(.unknown, PskAdvertResolver.resolve(
            receivedAdvert: nil, receivedRoles: nil, callId: callId,
            senderEphemeralX25519Pub: initiatorPub, candidates: [c]).dialect)
        XCTAssertEqual(.unknown, PskAdvertResolver.resolve(
            receivedAdvert: [], receivedRoles: nil, callId: callId,
            senderEphemeralX25519Pub: initiatorPub, candidates: [c]).dialect)
        XCTAssertEqual(.unknown, PskAdvertResolver.resolve(
            receivedAdvert: [c.staticFp], receivedRoles: nil, callId: callId,
            senderEphemeralX25519Pub: initiatorPub, candidates: []).dialect)
    }

    /// A legacy/unsigned leg has no ephemeral key to hand us. That must skip the v3
    /// attempt and still resolve a static advert, not fail outright.
    func testAMissingEphemeralKeySkipsV3AndStillResolvesStatic() {
        let c = cand(16)
        let r = PskAdvertResolver.resolve(
            receivedAdvert: [c.staticFp], receivedRoles: nil, callId: callId,
            senderEphemeralX25519Pub: nil, candidates: [c]
        )
        XCTAssertEqual(.v2Static, r.dialect)
        XCTAssertEqual(c.staticFp, r.staticFp)
    }

    func testAWrongWidthEphemeralKeyIsTreatedAsMissingRatherThanCrashing() {
        let c = cand(17)
        let r = PskAdvertResolver.resolve(
            receivedAdvert: [c.staticFp], receivedRoles: nil, callId: callId,
            senderEphemeralX25519Pub: Data(repeating: 1, count: 31), candidates: [c]
        )
        XCTAssertEqual(.v2Static, r.dialect)
    }

    // MARK: - mirroring

    func testMirroringV3EmitsTagsAndOmitsTheRolesArray() {
        let c = cand(18, PskAdvertV3.roleNfc)
        let out = PskAdvertResolver.buildAdvertisement(
            dialect: .v3Blinded, callId: callId,
            ownEphemeralX25519Pub: responderPub, candidates: [c]
        )
        XCTAssertNil(out.roles, "roles must be omitted under v3 — they are inside the tags")
        XCTAssertEqual(1, out.fingerprints.count)
        XCTAssertEqual(64, out.fingerprints[0].count)
        XCTAssertNotEqual(c.staticFp, out.fingerprints[0])
        XCTAssertEqual(
            PskAdvertV3.Match(receivedIndex: 0, localIndex: 0, role: PskAdvertV3.roleNfc),
            PskAdvertV3.matchAgainstPeer(
                receivedTagsHex: out.fingerprints, callId: callId,
                peerEphemeralX25519Pub: responderPub, localPsks: [c.psk])
        )
    }

    func testMirroringStaticEmitsFingerprintsAndTheRolesArray() {
        let c = cand(19, PskAdvertV3.roleNfc)
        let out = PskAdvertResolver.buildAdvertisement(
            dialect: .v2Static, callId: callId,
            ownEphemeralX25519Pub: responderPub, candidates: [c]
        )
        XCTAssertEqual([c.staticFp], out.fingerprints)
        XCTAssertEqual([PskAdvertV3.roleNfc], out.roles)
    }

    /// W-UNKNOWNMIRROR (2026-07-25) — THE regression this file exists to prevent, and it
    /// shipped once. This test asserted the OPPOSITE, with the reasoning "`.unknown` means we
    /// found no shared secret, so falling back to static costs nothing".
    ///
    /// The wrong version is the plausible-looking one, which is why the history stays
    /// attached: `.unknown` means nothing matched THE PEER'S ADVERTISEMENT, not that we hold
    /// nothing. Mirroring statically shipped `lc_hex(SHA-256(psk))` for every key we hold
    /// plus the role byte marking which came from a physical NFC tap — both of the things
    /// §3.3.1 exists to remove, emitted by the responder, on the routine "no shared secret"
    /// path the spec itself calls the common case. A relay could force it against a pair that
    /// DOES share a secret by simply DELETING the OFFER's advert field: no key material, no
    /// forgery required.
    func testUnknownMirrorsAsBlindedNotStatic() {
        let c = cand(20, PskAdvertV3.roleNfc)
        let out = PskAdvertResolver.buildAdvertisement(
            dialect: .unknown, callId: callId,
            ownEphemeralX25519Pub: responderPub, candidates: [c]
        )
        XCTAssertNil(out.roles, "the role array names the NFC-tapped keys and must not go out")
        XCTAssertEqual(1, out.fingerprints.count)
        XCTAssertNotEqual(c.staticFp, out.fingerprints[0],
                          "the static fingerprint IS the correlator")
        // Still a usable advertisement for a peer holding the same secret.
        XCTAssertEqual(
            PskAdvertV3.Match(receivedIndex: 0, localIndex: 0, role: PskAdvertV3.roleNfc),
            PskAdvertV3.matchAgainstPeer(
                receivedTagsHex: out.fingerprints, callId: callId,
                peerEphemeralX25519Pub: responderPub, localPsks: [c.psk])
        )
    }

    /// The one dialect that must still mirror static: a genuine legacy peer. Reached only by
    /// a real `.v2Static` resolution — a legacy peer sends static fingerprints, we match
    /// them, and the dialect is `.v2Static`, never `.unknown`.
    func testOnlyARealLegacyPeerStillGetsTheStaticMirror() {
        let c = cand(23, PskAdvertV3.roleNfc)
        let out = PskAdvertResolver.buildAdvertisement(
            dialect: .v2Static, callId: callId,
            ownEphemeralX25519Pub: responderPub, candidates: [c]
        )
        XCTAssertEqual([c.staticFp], out.fingerprints)
        XCTAssertEqual([PskAdvertV3.roleNfc], out.roles)
    }

    /// Asking for v3 with no usable ephemeral key must degrade to static rather than
    /// emit an advertisement nobody can match — that would look like "we hold no keys"
    /// and silently drop the PSK.
    func testV3WithoutAnEphemeralKeyDegradesToStaticRatherThanEmittingGarbage() {
        let c = cand(21)
        let out = PskAdvertResolver.buildAdvertisement(
            dialect: .v3Blinded, callId: callId, ownEphemeralX25519Pub: nil, candidates: [c]
        )
        XCTAssertEqual([c.staticFp], out.fingerprints)
        XCTAssertEqual([0], out.roles)
    }

    // MARK: - §3.3.1.1 the forceable-downgrade refusal

    /// THE attack, reproduced. A relay logged this pair's static fingerprints from a
    /// pre-v3 call, substitutes them into a v3 OFFER and strips the signature (policy
    /// is warn-and-proceed, never drop). Without the latch the static branch matches and
    /// both sides spend the call on the correlatable dialect. With it, the match is
    /// discarded.
    func testASubstitutedStaticAdvertIsRefusedOnceTheContactHasSpokenV3() {
        let c = cand(30, PskAdvertV3.roleNfc)
        let substituted = [c.staticFp] // exactly what a long-lived relay logged

        let permissive = PskAdvertResolver.resolve(
            receivedAdvert: substituted, receivedRoles: [PskAdvertV3.roleNfc], callId: callId,
            senderEphemeralX25519Pub: initiatorPub, candidates: [c]
        )
        XCTAssertEqual(
            .v2Static, permissive.dialect,
            "sanity: without the latch this is precisely the downgrade"
        )
        XCTAssertEqual(c.staticFp, permissive.staticFp)

        let latched = PskAdvertResolver.resolve(
            receivedAdvert: substituted, receivedRoles: [PskAdvertV3.roleNfc], callId: callId,
            senderEphemeralX25519Pub: initiatorPub, candidates: [c], refuseStaticFallback: true
        )
        XCTAssertEqual(.v2StaticRefused, latched.dialect)
        XCTAssertNil(latched.psk, "the refused secret must not reach the session key")
        XCTAssertNil(latched.staticFp)
        XCTAssertNil(latched.wireValue)
    }

    /// The refusal is DISTINGUISHABLE from "we share nothing". Folding it into
    /// `.unknown` would make the downgrade invisible again, which is the whole failure
    /// mode being closed here.
    func testRefusalIsNotConfusedWithNothingShared() {
        let ours = cand(31)
        let theirs = cand(32)
        XCTAssertEqual(
            .unknown,
            PskAdvertResolver.resolve(
                receivedAdvert: [theirs.staticFp], receivedRoles: nil, callId: callId,
                senderEphemeralX25519Pub: initiatorPub, candidates: [ours],
                refuseStaticFallback: true
            ).dialect,
            "no shared secret is routine and must stay .unknown even under the latch"
        )
        XCTAssertEqual(
            .v2StaticRefused,
            PskAdvertResolver.resolve(
                receivedAdvert: [ours.staticFp], receivedRoles: nil, callId: callId,
                senderEphemeralX25519Pub: initiatorPub, candidates: [ours],
                refuseStaticFallback: true
            ).dialect
        )
    }

    /// The latch must not touch v3. It is a refusal of the FALLBACK, nothing else.
    func testTheLatchDoesNotAffectAGenuineV3Advert() {
        let c = cand(33, PskAdvertV3.roleQr)
        let advert = PskAdvertV3.buildAdvertisement(
            callId: callId, ownEphemeralX25519Pub: initiatorPub,
            orderedEntries: [PskAdvertV3.Entry(psk: c.psk, role: PskAdvertV3.roleQr)]
        )!
        let r = PskAdvertResolver.resolve(
            receivedAdvert: advert, receivedRoles: nil, callId: callId,
            senderEphemeralX25519Pub: initiatorPub, candidates: [c], refuseStaticFallback: true
        )
        XCTAssertEqual(.v3Blinded, r.dialect)
        XCTAssertEqual(c.staticFp, r.staticFp)
        XCTAssertEqual(PskAdvertV3.roleQr, r.peerRole)
    }

    /// A refusal must not silently answer in the dialect we just rejected. We refuse
    /// only because the contact is KNOWN v3-capable, so v3 is what our own
    /// advertisement should be — a legitimate peer whose OFFER was tampered with still
    /// gets an ACCEPT it can read.
    func testARefusalMirrorsAsV3NotAsStatic() {
        let c = cand(34, PskAdvertV3.roleNfc)
        let out = PskAdvertResolver.buildAdvertisement(
            dialect: .v2StaticRefused, callId: callId,
            ownEphemeralX25519Pub: responderPub, candidates: [c]
        )
        XCTAssertNil(out.roles, "mirroring a refusal must not emit the roles array")
        XCTAssertNotEqual(c.staticFp, out.fingerprints[0], "nor the fingerprint we just refused")
        XCTAssertEqual(
            PskAdvertV3.Match(receivedIndex: 0, localIndex: 0, role: PskAdvertV3.roleNfc),
            PskAdvertV3.matchAgainstPeer(
                receivedTagsHex: out.fingerprints, callId: callId,
                peerEphemeralX25519Pub: responderPub, localPsks: [c.psk])
        )
    }

    /// A refused advertisement must not feed the §D4 hw_only intersect or the
    /// NFC-in-common chip. Acting on a mutual set derived from bytes we just decided
    /// not to trust would hand the attacker back some of what the refusal took away.
    func testARefusalReportsNoMutualSet() {
        let a = cand(35, PskAdvertV3.roleNfc)
        let b = cand(36)
        let r = PskAdvertResolver.resolve(
            receivedAdvert: [a.staticFp, b.staticFp],
            receivedRoles: [PskAdvertV3.roleNfc, 0],
            callId: callId, senderEphemeralX25519Pub: initiatorPub, candidates: [a, b],
            refuseStaticFallback: true
        )
        XCTAssertEqual(.v2StaticRefused, r.dialect)
        XCTAssertTrue(r.mutual.isEmpty)
        XCTAssertTrue(r.mutualStaticFps.isEmpty)
        XCTAssertTrue(
            r.mutualPeerRoles.isEmpty,
            "an NFC role from a refused advert must not light the chip"
        )
    }

    /// End to end: an initiator blinds, the responder resolves and mirrors, and the
    /// initiator resolves the mirror back to the SAME static fingerprint. Both legs
    /// agreeing on that value is what keeps kc_mac and the session KDF byte-equal.
    func testBothLegsConvergeOnTheSameStaticFingerprint() {
        let shared = cand(22, PskAdvertV3.roleNfc)
        let offerAdvert = PskAdvertV3.buildAdvertisement(
            callId: callId, ownEphemeralX25519Pub: initiatorPub,
            orderedEntries: [PskAdvertV3.Entry(psk: shared.psk, role: shared.localRole)]
        )!

        let resp = PskAdvertResolver.resolve(
            receivedAdvert: offerAdvert, receivedRoles: nil, callId: callId,
            senderEphemeralX25519Pub: initiatorPub, candidates: [shared]
        )
        XCTAssertEqual(.v3Blinded, resp.dialect)
        let mirror = PskAdvertResolver.buildAdvertisement(
            dialect: resp.dialect, callId: callId,
            ownEphemeralX25519Pub: responderPub, candidates: [shared]
        )
        XCTAssertNil(mirror.roles)

        let initLeg = PskAdvertResolver.resolve(
            receivedAdvert: mirror.fingerprints, receivedRoles: mirror.roles, callId: callId,
            senderEphemeralX25519Pub: responderPub, candidates: [shared]
        )
        XCTAssertEqual(.v3Blinded, initLeg.dialect)
        XCTAssertEqual(resp.staticFp, initLeg.staticFp)
        XCTAssertEqual(shared.staticFp, initLeg.staticFp)
        // And the two legs' wire values genuinely differ, which is the per-leg freshness
        // the derived nonce buys.
        XCTAssertNotEqual(resp.wireValue, initLeg.wireValue)
    }
}
