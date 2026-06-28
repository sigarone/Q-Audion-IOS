import XCTest
@testable import QAudionEngine

/// Phase 3/18 (iOS) — wiring tests for the v4 PQ "continuum" ratchet native binding (``RatchetNative``)
/// and the feature gate on ``MessageRatchet``.
///
/// These do NOT exercise the v4 ratchet crypto (that requires the real `QaudionCryptoCore.xcframework`
/// linked + a device test). They verify the **wiring contract**: the flag is at its go-live state,
/// the v4 surface compiles + links against the real C ABI, and — because the engine-tests CI links
/// only the FAIL-CLOSED stub (``RatchetNative/available`` == false) — every v4 method still fail-
/// closes there, so the CI live messaging path stays the v3.1 engine, bit-for-bit. This is what
/// makes `engine-tests.yml` a real verifier of Stage B.
final class RatchetNativeV4Tests: XCTestCase {

    private let root = Data(repeating: 0x10, count: 32)
    private let ssXwing = Data(repeating: 0x20, count: 32)
    private let th = Data(repeating: 0x30, count: 32)

    // MARK: - The go-live tripwire

    /// GO-LIVE (Pavel, 2026-06-28): the shipped iOS build now has the v4 native ratchet ON, matching
    /// Android (`V4_NATIVE_RATCHET_ENABLED = true`) + Desktop. iOS bootstraps its v4 message session
    /// from the call handshake; cross-platform iOS↔Android messaging needs both ends on v4. If this
    /// fails, someone reverted the go-live — restore it (the live path is still runtime-gated by
    /// ``RatchetNative/available``, so a build without the linked core stays inert regardless).
    func testV4FlagIsLive() {
        XCTAssertTrue(MessageRatchet.v4NativeRatchetEnabled,
                      "v4 native ratchet is GO-LIVE ON (Pavel 2026-06-28) — runtime-gated by RatchetNative.available")
    }

    /// Under the fail-closed stub (engine-tests CI: no XCFramework linked, ``RatchetNative/available``
    /// == false), `isV4Enabled()` is false even with the flag ON — so the CI messaging path is the
    /// v3.1 engine. With the real core linked this returns true (covered by the device round-trip).
    func testIsV4EnabledFalseUnderStub() {
        let ratchet = MessageRatchet(vault: InMemoryRatchetVault())
        // The assertion is only meaningful when the stub is linked (CI reality); when the real core
        // IS linked the live path is covered elsewhere, so don't assert false in that case.
        if !RatchetNative.available {
            XCTAssertFalse(ratchet.isV4Enabled())
        }
    }

    // MARK: - v4 methods fail-closed while the path is INERT (stub core: not available)

    func testV4SessionOpsFailClosedWhenDisabled() throws {
        // Go-live note: the flag is now ON, so "disabled" here means the runtime path is INERT
        // because the native core is the fail-closed stub (engine-tests CI). When the real core is
        // linked these ops succeed (covered by the device round-trip), so skip the inert assertions
        // in that case.
        try XCTSkipIf(RatchetNative.available, "real core linked — inert assertions N/A (round-trip covers live)")
        let ratchet = MessageRatchet(vault: InMemoryRatchetVault())

        let handle = ratchet.ensureSessionV4(root: root, sessionEpochId: Data(repeating: 0x20, count: 16), transcriptHash: th, isLexMin: true)
        XCTAssertEqual(handle, 0, "ensureSessionV4 must return 0 (no session) while the v4 path is inert")

        XCTAssertNil(ratchet.encryptV4(handle, plaintext: Data("hi".utf8)))
        XCTAssertNil(ratchet.decryptV4(handle, frame: Data([0xE5, 0x04, 0x00])))
        XCTAssertFalse(ratchet.dhRatchetV4(handle, ssXwing: ssXwing, transcriptHash: th))
        XCTAssertNil(ratchet.serializeV4Session(handle))
        XCTAssertEqual(ratchet.deserializeV4Session(Data([0x00, 0x01, 0x02])), 0)

        // free is always safe (no-op on 0 / when unavailable) and must not crash.
        ratchet.freeV4Session(handle)
        ratchet.freeV4Session(0)
    }

    // MARK: - Wire magic probes (v3.1 unaffected; v4 distinct)

    func testWireMagicProbes() {
        XCTAssertEqual(MessageRatchet.magicV3, 0xE3)
        XCTAssertEqual(MessageRatchet.magicV4, 0xE5)

        let v3 = Data([0xE3, 0x00])
        let v4 = Data([0xE5, 0x04])
        XCTAssertTrue(MessageRatchet.isV3Wire(v3))
        XCTAssertFalse(MessageRatchet.isV4Wire(v3))
        XCTAssertTrue(MessageRatchet.isV4Wire(v4))
        XCTAssertFalse(MessageRatchet.isV3Wire(v4))
        XCTAssertFalse(MessageRatchet.isV4Wire(Data()))
    }

    // MARK: - RatchetNative links + fail-closes against the C ABI (stub or real core)

    /// Verifies the Swift wrapper actually compiles + LINKS against the C ABI symbols. With only the
    /// placeholder stub linked, `available` is false and `version()` is 0; with the real published
    /// XCFramework linked, `version()` is the packed semver (0.1.0 -> 0x0001_0000). Either way these
    /// calls must not crash, and the wrapper must fail-close when unavailable.
    func testRatchetNativeLinksAndFailsClosed() {
        // Touching these forces the linker to resolve qa_version / qa_* — the link-time proof.
        let v = RatchetNative.version()
        if RatchetNative.available {
            XCTAssertNotEqual(v, 0, "available implies a real (non-stub) core linked")
        } else {
            XCTAssertEqual(v, 0, "stub core reports version 0 and available == false")
            // Every wrapper call must fail-close when the core is unavailable.
            XCTAssertNil(RatchetNative.root0(ssHandshake: root))
            XCTAssertEqual(RatchetNative.initSession(root: root, sessionEpochId: Data(repeating: 0x20, count: 16), transcriptHash: th, isLexMin: true), 0)
            XCTAssertNil(RatchetNative.encrypt(0, plaintext: Data("x".utf8)))
            XCTAssertNil(RatchetNative.decrypt(0, frame: Data([0xE5])))
            XCTAssertFalse(RatchetNative.dhRatchet(0, ssXwing: ssXwing, transcriptHash: th))
            XCTAssertNil(RatchetNative.serialize(0))
            XCTAssertEqual(RatchetNative.deserialize(Data([0x00])), 0)
            RatchetNative.free(0)  // must not crash
        }
    }

    /// Wrong-length 32-byte inputs are rejected fail-closed even before reaching native code.
    func testRatchetNativeRejectsWrongLengthInputs() {
        let short = Data(repeating: 0x01, count: 16)
        XCTAssertNil(RatchetNative.root0(ssHandshake: short))
        XCTAssertEqual(RatchetNative.initSession(root: short, sessionEpochId: Data(repeating: 0x20, count: 16), transcriptHash: th, isLexMin: true), 0)
        XCTAssertFalse(RatchetNative.dhRatchet(1, ssXwing: short, transcriptHash: th))
    }

    // MARK: - Phase 4/5 fail-closed wiring (stub OR unavailable core)

    func testPhase45FailClosedWhenUnavailable() {
        guard !RatchetNative.available else { return }
        let fakeHandle: UInt = 42
        let fileId = Data("f".utf8)
        let pt     = Data("p".utf8)
        XCTAssertNil(RatchetNative.fileEncrypt(fakeHandle, fileId: fileId, plaintext: pt, counter: 0))
        XCTAssertNil(RatchetNative.fileDecrypt(fakeHandle, fileId: fileId, ctTag: Data([0x00]), counter: 0))
        XCTAssertNil(RatchetNative.mediaKey(fakeHandle, callId: Data("c".utf8)))
        // handle 0 must also fail-close
        XCTAssertNil(RatchetNative.fileEncrypt(0, fileId: fileId, plaintext: pt, counter: 0))
        XCTAssertNil(RatchetNative.fileDecrypt(0, fileId: fileId, ctTag: pt, counter: 0))
        XCTAssertNil(RatchetNative.mediaKey(0, callId: Data("c".utf8)))
    }
}
