import XCTest
import CommonCrypto
@testable import QAudionEngine

/// KAT — LiveKit SFU group-call E2EE key derivation (CROSS-PLATFORM CONTRACT).
///
/// W-GRPKEY256 (2026-07-20 lockstep flag day): the production key INPUT is
/// the RAW 32-byte `SK_0` (`GroupSession.currentSendKey`/`currentRecvKey`),
/// base64-DECODED from its wire form at the key-provider boundary
/// (`LiveKitGroupCallRoom.rawKeyMaterial`) and handed VERBATIM to the native
/// `LKRTCFrameCryptorKeyProvider` via the fork's raw-Data
/// `BaseKeyProvider.setKey(keyData:participantId:index:)` overload
/// (sigarone/client-sdk-swift tag `2.13.1-aes256-raw`). The patched native
/// DeriveKeys (aes256-framecryptor.patch: `password.size() == 32 ? 256 :
/// 128`) then PBKDF2-derives an AES-256-GCM frame key. Any Android /
/// Desktop / iOS client joining the same SFU room MUST derive the
/// byte-identical key from the byte-identical raw input + options below.
///
/// Reference derivation (native `DerivePBKDF2KeyFromRawKey`):
///   key = PBKDF2(password = raw SK_0 (32 bytes),
///                salt     = utf8("LKFrameEncryptionKey"),
///                hash     = SHA-256, iterations = 100000) -> AES-GCM 256-bit
///
/// The PRE-flip contract (kept below as a labeled regression guard, never a
/// production path) fed utf8(base64(SK_0)) — a 44-byte password that can
/// never fire the ==32 native gate, so the whole fleet silently derived
/// AES-128-GCM. Bytes are FROZEN: if a test fails, the Swift/derivation
/// code is wrong, never the vector — regenerate ONLY with a deliberate
/// contract bump (and update Desktop/Android in lockstep). The lockstep
/// vectors are byte-identical to Desktop's `test/kat/livekitGroupE2ee.kat.
/// spec.ts` / `scripts/livekit-derivation-kat.mjs` frozen pair.
///
/// ⚠️ CommonCrypto is Apple-platform only — authored on win32 which cannot
/// run it. Both frozen pairs were independently re-derived offline with a
/// second PBKDF2-HMAC-SHA256 implementation before freezing. CI
/// (`swift test` on macOS) is the gate.
final class LiveKitGroupE2eeKatTests: XCTestCase {

    // ── The exact options `LiveKitGroupCallRoom.connect` passes to the SDK ──
    private static let ratchetSalt = "LKFrameEncryptionKey"
    private static let pbkdf2Iterations: UInt32 = 100_000
    private static let aes256KeyLenBytes = 32 // production: AES-256-GCM
    private static let legacyAes128KeyLenBytes = 16 // pre-flip regression guard

    // ── Frozen LOCKSTEP vector (SK_0 = 0x01..0x20, shared with Desktop) ────
    private static let lockstepSk0Hex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
    private static let lockstepB64 = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="
    /// TARGET-256: raw 32-byte SK_0 password, 256-bit output (the contract).
    private static let lockstepExpected256Hex =
        "7345bb511d0a9e6782a09ad6b3d4b4961787a986031091f5a2c4e4bd41394732"
    /// CURRENT-128 (historical): utf8(base64(SK_0)) password, 128-bit output.
    private static let lockstepLegacy128Hex = "4ade5f5758640f101702bbe11d3e4d46"

    // ── This file's original iOS vector (SK_0 = 0x00..0x1f), kept frozen ───
    private static let sk0Hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    private static let expectedS = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
    private static let expected256Hex =
        "74884f8739e616fffc831a2172ff98b7589b553813c3610b64f2ccc54a0331ab"
    private static let legacy128Hex = "d12890ca8bf45b0009bac82b78bfd57a"

    private func hexToData(_ hex: String) -> Data {
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            // Only fed hardcoded even-length hex literals (frozen KAT vectors above).
            // swiftlint:disable:next force_unwrapping
            data.append(UInt8(hex[idx..<next], radix: 16)!)
            idx = next
        }
        return data
    }

    private func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// PBKDF2-HMAC-SHA256 via CommonCrypto — the SAME primitive already used
    /// elsewhere in this package (see `PhoneHash.swift`/`Scrypt.swift`).
    /// Takes the password as RAW BYTES — the production path's shape; the
    /// legacy string path wraps this with `Data(s.utf8)`.
    private func pbkdf2(password pwd: Data, saltUtf8 salt: String, iterations: UInt32, keyLen: Int) -> Data? {
        let saltData = Data(salt.utf8)
        var derived = Data(count: keyLen)
        let status = derived.withUnsafeMutableBytes { dPtr -> Int32 in
            pwd.withUnsafeBytes { pPtr -> Int32 in
                saltData.withUnsafeBytes { sPtr -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pPtr.bindMemory(to: Int8.self).baseAddress, pwd.count,
                        sPtr.bindMemory(to: UInt8.self).baseAddress, saltData.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        dPtr.bindMemory(to: UInt8.self).baseAddress, keyLen
                    )
                }
            }
        }
        return status == kCCSuccess ? derived : nil
    }

    // ── The production AES-256/raw contract ─────────────────────────────────

    /// The lockstep cross-platform vector — MUST match Desktop's
    /// `livekitGroupE2ee.kat.spec.ts` "raw/AES-256 contract" test and the
    /// Android equivalent byte-for-byte.
    func testLockstepRawSk0DerivesTheFrozenAes256GcmFrameKey() throws {
        let sk0 = hexToData(Self.lockstepSk0Hex)
        XCTAssertEqual(sk0.count, 32) // exactly what fires the native ==32 gate
        XCTAssertEqual(sk0.base64EncodedString(), Self.lockstepB64)
        let key = try XCTUnwrap(pbkdf2(
            password: sk0,
            saltUtf8: Self.ratchetSalt,
            iterations: Self.pbkdf2Iterations,
            keyLen: Self.aes256KeyLenBytes
        ))
        XCTAssertEqual(hexString(key), Self.lockstepExpected256Hex)
        XCTAssertEqual(key.count, 32) // 256 bits
    }

    func testRawSk0DerivesTheFrozenAes256GcmFrameKey() throws {
        let sk0 = hexToData(Self.sk0Hex)
        XCTAssertEqual(sk0.base64EncodedString(), Self.expectedS)
        let key = try XCTUnwrap(pbkdf2(
            password: sk0,
            saltUtf8: Self.ratchetSalt,
            iterations: Self.pbkdf2Iterations,
            keyLen: Self.aes256KeyLenBytes
        ))
        XCTAssertEqual(hexString(key), Self.expected256Hex)
    }

    func testIsDeterministicAcrossRepeatedDerivations() throws {
        let sk0 = hexToData(Self.sk0Hex)
        let run = { try self.pbkdf2(password: sk0, saltUtf8: Self.ratchetSalt,
                                    iterations: Self.pbkdf2Iterations, keyLen: Self.aes256KeyLenBytes) }
        let a = try XCTUnwrap(run())
        let b = try XCTUnwrap(run())
        XCTAssertEqual(a, b)
    }

    func testADifferentSk0YieldsADifferentFrameKey() throws {
        let key = try XCTUnwrap(pbkdf2(
            password: Data(repeating: 0xAB, count: 32),
            saltUtf8: Self.ratchetSalt,
            iterations: Self.pbkdf2Iterations,
            keyLen: Self.aes256KeyLenBytes
        ))
        XCTAssertNotEqual(hexString(key), Self.expected256Hex)
    }

    // ── Pre-flip regression guards (NEVER a production path) ────────────────

    /// HISTORICAL b64/AES-128 behavior, frozen so a drift in the primitive
    /// itself is distinguishable from a contract change. Mirrors Desktop's
    /// labeled legacy guard.
    func testLegacyBase64StringInputDerivedTheFrozenAes128Key() throws {
        for (sk0Hex, legacyHex) in [(Self.lockstepSk0Hex, Self.lockstepLegacy128Hex),
                                    (Self.sk0Hex, Self.legacy128Hex)] {
            let s = hexToData(sk0Hex).base64EncodedString()
            let key = try XCTUnwrap(pbkdf2(
                password: Data(s.utf8),
                saltUtf8: Self.ratchetSalt,
                iterations: Self.pbkdf2Iterations,
                keyLen: Self.legacyAes128KeyLenBytes
            ))
            XCTAssertEqual(hexString(key), legacyHex)
        }
    }

    /// W-GRPKEYSIZE negative interop guard: a stale peer still feeding the
    /// utf8(base64) STRING derives a DIFFERENT key even at equal output
    /// length — mixed pre/post-flip builds MUST fail to decrypt (fail
    /// closed), never silently interoperate on a weaker/wrong key.
    func testStringInputAndRawInputNeverConverge() throws {
        let sk0 = hexToData(Self.lockstepSk0Hex)
        let rawKey = try XCTUnwrap(pbkdf2(
            password: sk0, saltUtf8: Self.ratchetSalt,
            iterations: Self.pbkdf2Iterations, keyLen: Self.aes256KeyLenBytes))
        let stringKey = try XCTUnwrap(pbkdf2(
            password: Data(sk0.base64EncodedString().utf8), saltUtf8: Self.ratchetSalt,
            iterations: Self.pbkdf2Iterations, keyLen: Self.aes256KeyLenBytes))
        XCTAssertNotEqual(rawKey, stringKey)
        // And the raw key's 128-bit prefix is NOT the legacy key either.
        XCTAssertNotEqual(hexString(rawKey.prefix(16)), Self.lockstepLegacy128Hex)
    }

    // ── Distribution contract (unchanged by the flip) ───────────────────────

    /// Cross-checks the SK_0 DISTRIBUTION contract this feeds from:
    /// `GroupSession.currentSendKey`/`currentRecvKey` return the exact same
    /// bytes the sender transmitted verbatim as base64 in `sender_key_init`.
    /// base64 REMAINS the wire format after W-GRPKEY256 — only the
    /// key-provider boundary decodes it — so sender and receiver still
    /// install byte-identical RAW SK_0, hence identical AES-256-GCM frame
    /// keys. Mirrors Desktop's `livekitGroupDistribution.kat.spec.ts`.
    func testSenderSk0AndInstalledReceiverSk0AreByteIdentical() throws {
        let callId = "11111111-2222-3333-4444-555555555555"
        let groupIdBytes = Data(callId.utf8)
        let alice = "alice-11111111"
        let bob = "bob-22222222"
        let aliceSeed = hexToData(Self.sk0Hex)

        let aliceSession = GroupSession()
        let aliceState = try aliceSession.create(
            groupIdBytes: groupIdBytes, groupEpoch: 1,
            members: [alice, bob], selfId: alice, selfSeed: aliceSeed
        )
        let aliceSk0 = try XCTUnwrap(aliceSession.currentSendKey(state: aliceState))
        let sAlice = aliceSk0.base64EncodedString()

        let initEnv = SenderKeyInitEnvelope(
            g: GroupSenderKey.toHex(aliceState.groupIdBytes),
            e: aliceState.groupEpoch,
            seed: sAlice, // base64(SK_0) — transmitted verbatim, never re-derived
            idx: 0
        )

        let bobSession = GroupSession()
        let bobState = try bobSession.create(
            groupIdBytes: groupIdBytes, groupEpoch: 1, members: [alice, bob], selfId: bob
        )
        try bobSession.handleSenderKeyInit(state: bobState, env: initEnv, fromUserId: alice)
        let bobViewOfAlice = try XCTUnwrap(bobSession.currentRecvKey(state: bobState, senderId: alice))

        XCTAssertEqual(bobViewOfAlice, aliceSk0)
        XCTAssertEqual(bobViewOfAlice.count, 32) // decodes to the raw 32B the provider needs
    }

    /// Fail-closed gate parity: the EXACT validation `LiveKitGroupCallRoom.
    /// rawKeyMaterial` applies (base64-decodable AND exactly 32 bytes) —
    /// anything else must install NO key.
    func testRawKeyMaterialGateRejectsNon32ByteOrNonBase64Input() {
        func gate(_ b64: String) -> Data? {
            guard let raw = Data(base64Encoded: b64), raw.count == 32 else { return nil }
            return raw
        }
        XCTAssertNotNil(gate(Self.lockstepB64))
        XCTAssertEqual(gate(Self.lockstepB64)?.count, 32)
        XCTAssertNil(gate("not-base64!!!"))
        XCTAssertNil(gate(Data(repeating: 1, count: 16).base64EncodedString())) // 16B
        XCTAssertNil(gate(Data(repeating: 1, count: 33).base64EncodedString())) // 33B
        XCTAssertNil(gate(""))
    }
}
