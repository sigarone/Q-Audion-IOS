import CryptoKit
import XCTest
@testable import QAudionEngine

/// CL-5.10 — KAT guard tests for EarbudPairTranscript + EarbudPairGatt (FE-5).
///
/// Frozen cross-platform contract (firmware / Android / iOS must agree):
///   pair_id  = SHA-256("qa-earbud-excl-pair-v2" || eid_min || eid_max)
///   confirm  = SHA-256("qa-earbud-excl-sas-confirm-v2" ||
///                       pair_id(32) || eid_I(32) || eid_R(32) || sha256_ct_ee(32))
///   INITIATOR = unsigned-lex-lesser eid
///
/// Any change to labels, orderings, or sizes MUST be accompanied by a cross-platform
/// KAT update (firmware ee_pair.c, Android EarbudPairKatTest.kt, iOS EarbudPairKatTests.swift).
final class EarbudPairKatTests: XCTestCase {

    // ─── Helpers ──────────────────────────────────────────────────────────────

    private func sha256(_ parts: Data...) -> Data {
        var h = SHA256()
        for p in parts { h.update(data: p) }
        return Data(h.finalize())
    }

    /// eid that is unsigned-lex LESS than eidHigh. Byte 0 = 0x01.
    private let eidLow  = Data((0x01...0x20).map { UInt8($0) })   // 0x01..0x20
    /// eid that is unsigned-lex GREATER than eidLow. Byte 0 = 0x80.
    private let eidHigh = Data((0x80..<0xa0).map { UInt8($0) })   // 0x80..0x9f

    private let fakePkSe     = Data((0..<32).map { UInt8($0) })
    private let fakeMaterial = Data((0..<1568).map { UInt8($0 % 256) })
    private let fakeCtEe     = Data((0..<1568).map { UInt8(($0 + 17) % 256) })

    // ─── EarbudPairTranscript.pairId ──────────────────────────────────────────

    func testPairIdReturns32Bytes() {
        XCTAssertEqual(32, EarbudPairTranscript.pairId(eidA: eidLow, eidB: eidHigh).count)
    }

    func testPairIdIsSymmetric() {
        let ab = EarbudPairTranscript.pairId(eidA: eidLow, eidB: eidHigh)
        let ba = EarbudPairTranscript.pairId(eidA: eidHigh, eidB: eidLow)
        XCTAssertEqual(ab, ba, "pairId must be symmetric")
    }

    func testPairIdChangesWhenEidChanges() {
        let other = Data((0x42..<0x62).map { UInt8($0) })
        let p1 = EarbudPairTranscript.pairId(eidA: eidLow, eidB: eidHigh)
        let p2 = EarbudPairTranscript.pairId(eidA: eidLow, eidB: other)
        XCTAssertNotEqual(p1, p2, "different eid must yield different pairId")
    }

    func testPairIdIsDeterministic() {
        XCTAssertEqual(
            EarbudPairTranscript.pairId(eidA: eidLow, eidB: eidHigh),
            EarbudPairTranscript.pairId(eidA: eidLow, eidB: eidHigh)
        )
    }

    func testPairIdUsesCorrectLabelAndEidMinFirstOrdering() {
        let label = Data("qa-earbud-excl-pair-v2".utf8)
        // eidLow < eidHigh unsigned-lex → min=eidLow, max=eidHigh
        let expected = sha256(label, eidLow, eidHigh)
        let actual   = EarbudPairTranscript.pairId(eidA: eidLow, eidB: eidHigh)
        XCTAssertEqual(expected, actual, "pairId must match independent SHA-256 recompute")
        // Symmetry: eidHigh-first also picks min=eidLow, max=eidHigh
        XCTAssertEqual(expected, EarbudPairTranscript.pairId(eidA: eidHigh, eidB: eidLow))
    }

    // ─── EarbudPairTranscript.confirmHash ─────────────────────────────────────

    func testConfirmHashReturns32Bytes() {
        let pid = EarbudPairTranscript.pairId(eidA: eidLow, eidB: eidHigh)
        XCTAssertEqual(32, EarbudPairTranscript.confirmHash(pairId: pid, eidI: eidLow, eidR: eidHigh, ctEe: fakeCtEe).count)
    }

    func testConfirmHashUsesCorrectLabelAndInputOrder() {
        let pid = EarbudPairTranscript.pairId(eidA: eidLow, eidB: eidHigh)
        let label = Data("qa-earbud-excl-sas-confirm-v2".utf8)
        let sha256CtEe = Data(SHA256.hash(data: fakeCtEe))
        let expected = sha256(label, pid, eidLow, eidHigh, sha256CtEe)
        let actual   = EarbudPairTranscript.confirmHash(pairId: pid, eidI: eidLow, eidR: eidHigh, ctEe: fakeCtEe)
        XCTAssertEqual(expected, actual, "confirmHash must match independent SHA-256 recompute")
    }

    func testConfirmHashIsDeterministic() {
        let pid = EarbudPairTranscript.pairId(eidA: eidLow, eidB: eidHigh)
        let c1 = EarbudPairTranscript.confirmHash(pairId: pid, eidI: eidLow, eidR: eidHigh, ctEe: fakeCtEe)
        let c2 = EarbudPairTranscript.confirmHash(pairId: pid, eidI: eidLow, eidR: eidHigh, ctEe: fakeCtEe)
        XCTAssertEqual(c1, c2)
    }

    func testConfirmHashChangesWhenCtEeChanges() {
        let pid = EarbudPairTranscript.pairId(eidA: eidLow, eidB: eidHigh)
        let c1 = EarbudPairTranscript.confirmHash(pairId: pid, eidI: eidLow, eidR: eidHigh, ctEe: fakeCtEe)
        let c2 = EarbudPairTranscript.confirmHash(pairId: pid, eidI: eidLow, eidR: eidHigh, ctEe: Data(count: 1568))
        XCTAssertNotEqual(c1, c2, "different ct_ee must yield different confirmHash")
    }

    // ─── EarbudPairTranscript.isInitiator ─────────────────────────────────────

    func testIsInitiatorTrueWhenSelfEidIsLesser() {
        XCTAssertTrue(EarbudPairTranscript.isInitiator(selfEid: eidLow, peerEid: eidHigh),
                      "eidLow must be INITIATOR vs eidHigh")
    }

    func testIsInitiatorFalseWhenSelfEidIsGreater() {
        XCTAssertFalse(EarbudPairTranscript.isInitiator(selfEid: eidHigh, peerEid: eidLow),
                       "eidHigh must be RESPONDER vs eidLow")
    }

    func testIsInitiatorRolesAreMutuallyExclusive() {
        let aInit = EarbudPairTranscript.isInitiator(selfEid: eidLow, peerEid: eidHigh)
        let bInit = EarbudPairTranscript.isInitiator(selfEid: eidHigh, peerEid: eidLow)
        XCTAssertTrue(aInit != bInit, "exactly one side must be INITIATOR")
    }

    func testIsInitiatorUsesUnsignedByteComparison0x80VsFF() {
        // 0x80 = 128 unsigned; 0xFF = 255 unsigned → 0x80 is INITIATOR.
        // A signed comparison would give -128 (0x80) < -1 (0xFF) = true — same result here.
        // The CRITICAL test: 0xFF vs 0x80. Signed: -1 < -128 = FALSE. Unsigned: 255 < 128 = FALSE.
        // So BOTH agree 0xFF is NOT the initiator vs 0x80. The unsigned test is exercised by
        // picking bytes where signed and unsigned order diverge in the isInitiator direction.
        // Test: is 0xFF initiator vs 0x80? Signed: -1 < -128 = false (not initiator, wrong).
        // Unsigned: 255 < 128 = false (not initiator, correct). Both give false — no divergence here.
        // The real divergence: 0x81 (signed -127) vs 0x80 (signed -128): signed -127 > -128 so 0x80 init.
        //                       unsigned 129 > 128 so 0x80 init. Still same.
        // True divergence: 0x01 vs 0xFF. Signed: 1 < -1 = false (0x01 NOT init). Unsigned: 1 < 255 = true (0x01 IS init).
        var eid01 = Data(repeating: 0, count: 32); eid01[0] = 0x01
        var eidFF = Data(repeating: 0, count: 32); eidFF[0] = 0xFF
        // Unsigned: 0x01 (1) < 0xFF (255) → 0x01 is INITIATOR
        XCTAssertTrue(EarbudPairTranscript.isInitiator(selfEid: eid01, peerEid: eidFF),
                      "0x01 must be INITIATOR vs 0xFF (unsigned comparison)")
        XCTAssertFalse(EarbudPairTranscript.isInitiator(selfEid: eidFF, peerEid: eid01))

        // Also test Android's specific case: 0x80 < 0xFF (128 < 255 unsigned = true)
        var eid80 = Data(repeating: 0, count: 32); eid80[0] = 0x80
        XCTAssertTrue(EarbudPairTranscript.isInitiator(selfEid: eid80, peerEid: eidFF),
                      "0x80 must be INITIATOR vs 0xFF")
    }

    func testIsInitiatorReturnsFalseWhenEidsAreEqual() {
        XCTAssertFalse(EarbudPairTranscript.isInitiator(selfEid: Data(count: 32), peerEid: Data(count: 32)))
    }

    // ─── EarbudPairGatt.buildPairBegin ────────────────────────────────────────

    func testBuildPairBeginReturns1632Bytes() {
        let buf = EarbudPairGatt.buildPairBegin(ownPkSe: fakePkSe, ownMaterial: fakeMaterial, ownEid: eidLow)
        XCTAssertEqual(EarbudGattConstants.EE_PAIR_MSG_LEN, buf.count)
        XCTAssertEqual(1632, EarbudGattConstants.EE_PAIR_MSG_LEN)
    }

    func testBuildPairBeginLayoutPkSeAtZeroMaterialAt32EidAt1600() {
        let buf = EarbudPairGatt.buildPairBegin(ownPkSe: fakePkSe, ownMaterial: fakeMaterial, ownEid: eidLow)
        XCTAssertEqual(fakePkSe, Data(buf[0..<32]))
        XCTAssertEqual(fakeMaterial, Data(buf[32..<1600]))
        XCTAssertEqual(eidLow, Data(buf[1600..<1632]))
    }

    // ─── EarbudPairGatt.buildPairFin vs EarbudPairTranscript.confirmHash ──────

    func testBuildPairFinAgreesWithConfirmHashWhenGivenSha256CtEe() {
        let pid = EarbudPairTranscript.pairId(eidA: eidLow, eidB: eidHigh)
        let sha256CtEe = Data(SHA256.hash(data: fakeCtEe))
        // EarbudPairGatt.buildPairFin takes sha256(ct_ee) already hashed
        let fromGatt = EarbudPairGatt.buildPairFin(pairId: pid, eidI: eidLow, eidR: eidHigh, sha256CtEe: sha256CtEe)
        // EarbudPairTranscript.confirmHash hashes ct_ee internally
        let fromTranscript = EarbudPairTranscript.confirmHash(pairId: pid, eidI: eidLow, eidR: eidHigh, ctEe: fakeCtEe)
        XCTAssertEqual(fromGatt, fromTranscript, "buildPairFin and confirmHash must agree")
    }

    // ─── EarbudPairGatt.parsePairResp ─────────────────────────────────────────

    func testParsePairRespExtractsCorrectComponents() {
        let payload = EarbudPairGatt.buildPairBegin(ownPkSe: fakePkSe, ownMaterial: fakeMaterial, ownEid: eidHigh)
        guard let parsed = EarbudPairGatt.parsePairResp(payload) else {
            XCTFail("parsePairResp returned nil for valid 1632B payload"); return
        }
        XCTAssertEqual(fakePkSe, parsed.pkSe)
        XCTAssertEqual(fakeMaterial, parsed.material)
        XCTAssertEqual(eidHigh, parsed.eid)
    }

    func testParsePairRespReturnsNilForWrongSize() {
        XCTAssertNil(EarbudPairGatt.parsePairResp(Data(count: 1631)))
        XCTAssertNil(EarbudPairGatt.parsePairResp(Data(count: 1633)))
        XCTAssertNil(EarbudPairGatt.parsePairResp(Data()))
    }
}
