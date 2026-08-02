import XCTest
import CryptoKit
@testable import QAudionEngine

/// Round-trip + spec-conformance tests for the Swift port of `SFrameCodec`.
///
/// The cross-platform contract — byte-equal output for fixed inputs — is
/// enforced by `SFrameCodecKatTest`. This file mirrors the Kotlin
/// `SFrameCodecTest.kt` algebra: encrypt/decrypt round-trips, header-decode
/// invariants, padding strip, and the layer-mux CTR contract.
final class SFrameCodecRoundTripTest: XCTestCase {

    // Deterministic 0x00..0x1F PQC key, mirrors `pqcKey` in SFrameCodecTest.kt.
    private let pqcKey: Data = {
        var d = Data(count: 32)
        for i in 0..<32 { d[i] = UInt8(i) }
        return d
    }()

    // MARK: - 1:1 round-trip, no padding

    func test_1to1_roundTrip_noPadding() throws {
        let master = try SFrameCodec.deriveMaster1to1(pqcKey)
        let pt = Data("hello hevc nalu".utf8)
        let wire = try SFrameCodec.seal(master: master, ctr: 1, plaintext: pt)
        let opened = try SFrameCodec.open(master: master, wire: wire)
        XCTAssertEqual(opened, pt)
    }

    // MARK: - 1:1 round-trip with padding

    func test_1to1_roundTrip_withPadding_stripsCorrectly() throws {
        let master = try SFrameCodec.deriveMaster1to1(pqcKey)
        var pt = Data(count: 73)
        for i in 0..<73 { pt[i] = UInt8(i & 0xFF) }
        let wire = try SFrameCodec.seal(master: master, ctr: 42, plaintext: pt, padded: true)
        let (header, headerEnd) = try SFrameCodec.decodeHeader(wire)
        XCTAssertTrue(header.padded)
        // 73 mod 64 = 9, pad = 55 ⇒ padded plaintext = 128, plus tag 16 ⇒ trailer = 144.
        XCTAssertEqual(wire.count - headerEnd, 128 + 16)
        let opened = try SFrameCodec.open(master: master, wire: wire)
        XCTAssertEqual(opened, pt)
    }

    func test_padding_roundsBlockBoundaryToFullBlock() throws {
        let master = try SFrameCodec.deriveMaster1to1(pqcKey)
        // Plaintext of exactly 64 B should still get a full 64-B pad block (PKCS#7-style).
        var pt = Data(count: 64)
        for i in 0..<64 { pt[i] = 0xAB }
        let wire = try SFrameCodec.seal(master: master, ctr: 1, plaintext: pt, padded: true)
        let (_, headerEnd) = try SFrameCodec.decodeHeader(wire)
        // ct = 128 (64 + 64 pad block), tag = 16
        XCTAssertEqual(wire.count - headerEnd, 128 + 16)
        let opened = try SFrameCodec.open(master: master, wire: wire)
        XCTAssertEqual(opened, pt)
    }

    // MARK: - Header flags

    func test_keyframe_flagPreservedAndForcesExtension() throws {
        let master = try SFrameCodec.deriveMaster1to1(pqcKey)
        let wire = try SFrameCodec.seal(
            master: master, ctr: 0, plaintext: Data("x".utf8), keyFrame: true
        )
        let (header, _) = try SFrameCodec.decodeHeader(wire)
        XCTAssertTrue(header.keyFrame)
        XCTAssertTrue(header.hasExt) // extension byte forced when keyFrame=true
    }

    func test_layerEncoded_inExtensionByteAndCtrMux() throws {
        let master = try SFrameCodec.deriveMaster1to1(pqcKey)
        for layer in [SFrameCodec.Layer.low, .mid, .high] {
            let wire = try SFrameCodec.seal(
                master: master, ctr: 7, plaintext: Data("abc".utf8), layer: layer
            )
            let (header, _) = try SFrameCodec.decodeHeader(wire)
            XCTAssertEqual(header.layer, layer)
            XCTAssertEqual(header.ctr, 7)
        }
    }

    func test_samePlaintext_differentCtr_producesDifferentCiphertext() throws {
        let master = try SFrameCodec.deriveMaster1to1(pqcKey)
        let pt = Data("stable".utf8)
        let a = try SFrameCodec.seal(master: master, ctr: 1, plaintext: pt)
        let b = try SFrameCodec.seal(master: master, ctr: 2, plaintext: pt)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Tamper / wrong-key rejection

    func test_tamperedTag_rejected() throws {
        let master = try SFrameCodec.deriveMaster1to1(pqcKey)
        var wire = try SFrameCodec.seal(master: master, ctr: 1, plaintext: Data("abc".utf8))
        wire[wire.count - 1] ^= 0x01
        XCTAssertThrowsError(try SFrameCodec.open(master: master, wire: wire))
    }

    func test_tamperedAadBit_rejected() throws {
        let master = try SFrameCodec.deriveMaster1to1(pqcKey)
        var wire = try SFrameCodec.seal(
            master: master, ctr: 1, plaintext: Data("abc".utf8), keyFrame: true
        )
        // Flip a bit in the extension byte (KEY flag) — AAD changes, GCM rejects
        // (or the layer/CTR mux mismatch trips first; both are acceptable rejections).
        wire[wire.startIndex + 1] ^= 0x10   // startIndex-relative: see AeadCipherTests
        XCTAssertThrowsError(try SFrameCodec.open(master: master, wire: wire))
    }

    func test_wrongMaster_rejected() throws {
        let a = try SFrameCodec.deriveMaster1to1(pqcKey)
        var bKey = Data(count: 32)
        for i in 0..<32 { bKey[i] = 0xFF }
        let b = try SFrameCodec.deriveMaster1to1(bKey)
        let wire = try SFrameCodec.seal(master: a, ctr: 1, plaintext: Data("x".utf8))
        XCTAssertThrowsError(try SFrameCodec.open(master: b, wire: wire))
    }

    // MARK: - CTR top-4-bits guard

    func test_ctrTopFourBitsReserved_throwsOnSeal() throws {
        let master = try SFrameCodec.deriveMaster1to1(pqcKey)
        let ctrTooBig: UInt64 = UInt64(1) << 60
        XCTAssertThrowsError(
            try SFrameCodec.seal(master: master, ctr: ctrTooBig, plaintext: Data("x".utf8))
        ) { err in
            guard let e = err as? SFrameCodec.SFrameError else {
                XCTFail("expected SFrameError, got \(type(of: err))"); return
            }
            switch e {
            case .ctrTopFourBitsReserved: break
            default: XCTFail("expected ctrTopFourBitsReserved, got \(e)")
            }
        }
    }

    // MARK: - Group-mode

    func test_groupMaster_differsFrom_1to1Master() throws {
        var ck = Data(count: 32)
        for i in 0..<32 { ck[i] = 0x42 }
        let a = try SFrameCodec.deriveMaster1to1(pqcKey)
        let b = try SFrameCodec.deriveMasterGroup(chainKey: ck, groupIdHex: "abcd1234", senderId: "alice")
        XCTAssertNotEqual(a, b)
    }

    func test_groupWithKid_roundTrip() throws {
        var ck = Data(count: 32)
        for i in 0..<32 { ck[i] = 0x55 }
        let master = try SFrameCodec.deriveMasterGroup(chainKey: ck, groupIdHex: "deadbeef", senderId: "bob")
        let kid = Data([0x12, 0x34, 0x56])
        let pt = Data("group video frame".utf8)
        let wire = try SFrameCodec.seal(
            master: master, ctr: 5, plaintext: pt, kid: kid, layer: .mid
        )
        let (h, _) = try SFrameCodec.decodeHeader(wire)
        XCTAssertEqual(h.kid, kid)
        XCTAssertEqual(h.layer, .mid)
        let opened = try SFrameCodec.open(master: master, wire: wire)
        XCTAssertEqual(opened, pt)
    }

    // MARK: - Header geometry

    func test_headerByteSizeMatchesHeaderBytesLength() throws {
        let master = try SFrameCodec.deriveMaster1to1(pqcKey)
        let wire = try SFrameCodec.seal(
            master: master,
            ctr: 0xABCDEF,
            plaintext: Data("x".utf8),
            kid: Data([0x01, 0x02, 0x03]),
            layer: .high,
            padded: true,
            keyFrame: true
        )
        let (h, end) = try SFrameCodec.decodeHeader(wire)
        XCTAssertEqual(end, h.bytes.count)
        // 1 cfg + 1 ext + 3 KID + 8 CTR (muxed top byte 0x20 ⇒ ctrLen = 8) = 13.
        XCTAssertEqual(end, 1 + 1 + 3 + 8)
        XCTAssertEqual(h.len, 7) // 8 - 1
    }
}
