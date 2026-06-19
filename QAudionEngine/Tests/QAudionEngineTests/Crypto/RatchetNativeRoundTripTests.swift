import XCTest
@testable import QAudionEngine

/// Phase 1 (iOS) — v4 native ratchet round-trip test.
///
/// Mirrors the Android `RatchetNativeTest.kt` and Desktop `ratchetNative.v4.spec.ts`:
/// exercises version(), root0(), init(), 20 round-trips, crash-resume (serialize/free/
/// deserialize), dhRatchet epoch advance, tampered-frame fail-closed, and free(0) no-op.
///
/// All tests skip via `XCTSkip` when `RatchetNative.available == false` (i.e., only the
/// fail-closed stub is linked). They pass unconditionally when the real
/// `QaudionCryptoCore.xcframework` is linked (device or arm64 simulator run).
///
/// To run with the real core: replace the CQaudionCryptoCore stub target in
/// `QAudionEngine/Package.swift` with a binaryTarget pointing to the published
/// `QaudionCryptoCore.xcframework.zip` (see the TODO comment in Package.swift).
final class RatchetNativeRoundTripTests: XCTestCase {

    private let root     = Data(repeating: 0x10, count: 32)
    private let ss1      = Data(repeating: 0x20, count: 32)
    private let th       = Data(repeating: 0x30, count: 32)
    private let ss2      = Data(repeating: 0x40, count: 32)
    private let th2      = Data(repeating: 0x50, count: 32)

    // Handles freed in tearDown so they're released even on test failure.
    private var handleA:  UInt = 0
    private var handleB:  UInt = 0
    private var handleB2: UInt = 0

    override func tearDown() {
        RatchetNative.free(handleA);  handleA  = 0
        RatchetNative.free(handleB);  handleB  = 0
        RatchetNative.free(handleB2); handleB2 = 0
        super.tearDown()
    }

    // MARK: - Tests

    func testVersionNonZeroWhenAvailable() throws {
        try XCTSkipUnless(RatchetNative.available,
            "RatchetNative: stub linked — replace with real xcframework to run round-trip tests")
        XCTAssertEqual(RatchetNative.version(), 256)  // 0x000100 = 0.1.0
    }

    func testRoot0Returns32Bytes() throws {
        try XCTSkipUnless(RatchetNative.available)
        let r0 = RatchetNative.root0(ssHandshake: root)
        XCTAssertNotNil(r0)
        XCTAssertEqual(r0?.count, 32)
    }

    func testInitReturnsNonZeroHandles() throws {
        try XCTSkipUnless(RatchetNative.available)
        handleA = RatchetNative.initSession(root: root, firstSsXwing: ss1, transcriptHash: th, isA: true)
        handleB = RatchetNative.initSession(root: root, firstSsXwing: ss1, transcriptHash: th, isA: false)
        XCTAssertNotEqual(handleA, 0)
        XCTAssertNotEqual(handleB, 0)
    }

    func test20RoundTripsEncryptADecryptB() throws {
        try XCTSkipUnless(RatchetNative.available)
        handleA = RatchetNative.initSession(root: root, firstSsXwing: ss1, transcriptHash: th, isA: true)
        handleB = RatchetNative.initSession(root: root, firstSsXwing: ss1, transcriptHash: th, isA: false)

        for i in 0..<20 {
            let pt = Data("msg-\(i)".utf8)
            let frame = RatchetNative.encrypt(handleA, plaintext: pt)
            XCTAssertNotNil(frame, "encrypt(\(i)) returned nil")
            XCTAssertGreaterThan(frame?.count ?? 0, pt.count, "frame(\(i)) not longer than plaintext")
            let got = RatchetNative.decrypt(handleB, frame: frame!)
            XCTAssertNotNil(got, "decrypt(\(i)) returned nil")
            XCTAssertEqual(got, pt, "round-trip \(i) plaintext mismatch")
        }
    }

    func testCrashResume() throws {
        try XCTSkipUnless(RatchetNative.available)
        handleA = RatchetNative.initSession(root: root, firstSsXwing: ss1, transcriptHash: th, isA: true)
        handleB = RatchetNative.initSession(root: root, firstSsXwing: ss1, transcriptHash: th, isA: false)

        let f0 = RatchetNative.encrypt(handleA, plaintext: Data("m0".utf8))!
        let f1 = RatchetNative.encrypt(handleA, plaintext: Data("m1".utf8))!

        let d0 = RatchetNative.decrypt(handleB, frame: f0)
        XCTAssertEqual(d0, Data("m0".utf8))

        let blob = RatchetNative.serialize(handleB)
        XCTAssertNotNil(blob)
        XCTAssertGreaterThan(blob?.count ?? 0, 0)

        RatchetNative.free(handleB); handleB = 0

        handleB2 = RatchetNative.deserialize(blob!)
        XCTAssertNotEqual(handleB2, 0)

        let d1 = RatchetNative.decrypt(handleB2, frame: f1)
        XCTAssertEqual(d1, Data("m1".utf8))
    }

    func testDhRatchetAdvancesEpoch() throws {
        try XCTSkipUnless(RatchetNative.available)
        handleA  = RatchetNative.initSession(root: root, firstSsXwing: ss1, transcriptHash: th, isA: true)
        handleB2 = RatchetNative.initSession(root: root, firstSsXwing: ss1, transcriptHash: th, isA: false)

        XCTAssertTrue(RatchetNative.dhRatchet(handleA,  ssXwing: ss2, transcriptHash: th2))
        XCTAssertTrue(RatchetNative.dhRatchet(handleB2, ssXwing: ss2, transcriptHash: th2))

        for i in 0..<10 {
            let pt = Data("post-ratchet-\(i)".utf8)
            let frame = RatchetNative.encrypt(handleA, plaintext: pt)!
            let got   = RatchetNative.decrypt(handleB2, frame: frame)
            XCTAssertEqual(got, pt, "post-dhRatchet round-trip \(i)")
        }
    }

    func testTamperedFrameFailsClosed() throws {
        try XCTSkipUnless(RatchetNative.available)
        handleA  = RatchetNative.initSession(root: root, firstSsXwing: ss1, transcriptHash: th, isA: true)
        handleB2 = RatchetNative.initSession(root: root, firstSsXwing: ss1, transcriptHash: th, isA: false)

        var frame = RatchetNative.encrypt(handleA, plaintext: Data("secret".utf8))!
        frame[frame.count - 1] ^= 0xFF

        XCTAssertNil(RatchetNative.decrypt(handleB2, frame: frame),
                     "tampered frame must fail-closed (nil)")
    }

    func testFreeZeroIsNoop() throws {
        try XCTSkipUnless(RatchetNative.available)
        RatchetNative.free(0)  // must not crash
    }

    // MARK: - Phase 4/5 — file encryption + media key

    func testFileEncryptDecryptRoundTrip() throws {
        try XCTSkipUnless(RatchetNative.available)
        handleA = RatchetNative.initSession(root: root, firstSsXwing: ss1, transcriptHash: th, isA: true)
        let fileId  = Data("invoice-2026-06-19.pdf".utf8)
        let pt      = Data("sensitive content".utf8)
        let ctTag   = RatchetNative.fileEncrypt(handleA, fileId: fileId, plaintext: pt, counter: 0)
        XCTAssertNotNil(ctTag, "fileEncrypt returned nil")
        XCTAssertEqual(ctTag?.count, pt.count + 16, "ctTag must be plaintext.count + 16 bytes")
        let got = RatchetNative.fileDecrypt(handleA, fileId: fileId, ctTag: ctTag!, counter: 0)
        XCTAssertNotNil(got, "fileDecrypt returned nil")
        XCTAssertEqual(got, pt, "file round-trip plaintext mismatch")
    }

    func testFileEncryptTamperedTagFailsClosed() throws {
        try XCTSkipUnless(RatchetNative.available)
        handleA = RatchetNative.initSession(root: root, firstSsXwing: ss1, transcriptHash: th, isA: true)
        let fileId = Data("doc.txt".utf8)
        var ctTag  = RatchetNative.fileEncrypt(handleA, fileId: fileId, plaintext: Data("secret".utf8), counter: 0)!
        ctTag[ctTag.count - 1] ^= 0xFF
        XCTAssertNil(RatchetNative.fileDecrypt(handleA, fileId: fileId, ctTag: ctTag, counter: 0),
                     "tampered ctTag must fail-closed (nil)")
    }

    func testFileEncryptCounterIsolation() throws {
        try XCTSkipUnless(RatchetNative.available)
        handleA = RatchetNative.initSession(root: root, firstSsXwing: ss1, transcriptHash: th, isA: true)
        let fileId = Data("shared.bin".utf8)
        let pt     = Data("payload".utf8)
        let ct0    = RatchetNative.fileEncrypt(handleA, fileId: fileId, plaintext: pt, counter: 0)!
        let ct1    = RatchetNative.fileEncrypt(handleA, fileId: fileId, plaintext: pt, counter: 1)!
        XCTAssertNotEqual(ct0, ct1, "different counters must produce different ciphertexts")
        XCTAssertNil(RatchetNative.fileDecrypt(handleA, fileId: fileId, ctTag: ct1, counter: 0),
                     "counter mismatch must fail-closed")
    }

    func testMediaKeyIs32Bytes() throws {
        try XCTSkipUnless(RatchetNative.available)
        handleA = RatchetNative.initSession(root: root, firstSsXwing: ss1, transcriptHash: th, isA: true)
        let key = RatchetNative.mediaKey(handleA, callId: Data("call-uuid-abc123".utf8))
        XCTAssertNotNil(key, "mediaKey returned nil")
        XCTAssertEqual(key?.count, 32, "mediaKey must be 32 bytes")
    }

    func testMediaKeyDeterministicBothPeers() throws {
        try XCTSkipUnless(RatchetNative.available)
        handleA  = RatchetNative.initSession(root: root, firstSsXwing: ss1, transcriptHash: th, isA: true)
        handleB2 = RatchetNative.initSession(root: root, firstSsXwing: ss1, transcriptHash: th, isA: false)
        let callId = Data("call-determinism".utf8)
        let keyA = RatchetNative.mediaKey(handleA,  callId: callId)
        let keyB = RatchetNative.mediaKey(handleB2, callId: callId)
        XCTAssertNotNil(keyA); XCTAssertNotNil(keyB)
        XCTAssertEqual(keyA, keyB, "both peers must derive identical media key")
    }
}
