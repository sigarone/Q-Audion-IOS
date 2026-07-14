import XCTest
import CommonCrypto
@testable import QAudionEngine

/// KAT — LiveKit SFU group-call E2EE key derivation (CROSS-PLATFORM CONTRACT).
///
/// Freezes the deterministic pipeline that turns a `GroupSession` `SK_0` (the
/// pinned send/recv chain key `currentSendKey`/`currentRecvKey` expose) into
/// the AES-128-GCM frame key the LiveKit native `RTCFrameCryptorKeyProvider`
/// derives from the STRING we hand it via `BaseKeyProvider.setKey(key:
/// participantId:index:)`. Any Android / Desktop / iOS client that joins the
/// same SFU room MUST derive the byte-identical key from the byte-identical
/// input string + options below, or media frames fail to decrypt
/// cross-platform. Byte-identical to Desktop's
/// `test/kat/livekitGroupE2ee.kat.spec.ts` (WebCrypto `deriveBits`/
/// `deriveKey`) — same frozen vector, verified independently here via
/// `CommonCrypto.CCKeyDerivationPBKDF` (a real system PBKDF2-HMAC-SHA256
/// implementation, not a hand-rolled one) since this package cannot link
/// LiveKit's native `LKRTCFrameCryptorKeyProvider` from a unit test.
///
/// Reference derivation (matches livekit-client's `createKeyMaterialFromString`
/// + `deriveKeys`, which the native FrameCryptor mirrors):
///   S        = base64(SK_0)                          // RFC4648, '=' pad, no NL
///   material = PBKDF2 key material from utf8(S)       // UTF-8 of the STRING!
///   key      = PBKDF2(material, salt=utf8("LKFrameEncryptionKey"),
///                     hash=SHA-256, iterations=100000) -> AES-GCM 128-bit
///
/// Bytes are FROZEN: if this test fails, the Swift/derivation code is wrong,
/// never the vector — regenerate ONLY with a deliberate contract bump
/// (and update Desktop/Android in lockstep).
///
/// ⚠️ CommonCrypto is Apple-platform only — authored on win32 which cannot
/// run it. The byte construction was hand-verified offline against the
/// Desktop KAT's frozen hex (same PBKDF2-HMAC-SHA256 primitive, standardized
/// and platform-independent). CI (`swift test` on macOS) is the gate.
final class LiveKitGroupE2eeKatTests: XCTestCase {

    // ── The exact options `LiveKitGroupCallRoom.connect` passes to the SDK ──
    private static let ratchetSalt = "LKFrameEncryptionKey"
    private static let pbkdf2Iterations: UInt32 = 100_000
    private static let keyLenBytes = 16 // AES-128-GCM = 128 bits

    // ── Frozen reference vector (byte-identical to Desktop's KAT) ───────────
    private static let sk0Hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    private static let expectedS = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
    private static let expectedKeyHex = "d12890ca8bf45b0009bac82b78bfd57a"

    private func hexToData(_ hex: String) -> Data {
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
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
    private func pbkdf2(passwordUtf8 s: String, saltUtf8 salt: String, iterations: UInt32, keyLen: Int) -> Data? {
        let pwd = Data(s.utf8)
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

    func testBase64OfSk0IsTheRfc4648PaddedString() {
        let sk0 = hexToData(Self.sk0Hex)
        XCTAssertEqual(sk0.count, 32)
        XCTAssertEqual(sk0.base64EncodedString(), Self.expectedS)
    }

    func testDerivesTheFrozenAes128GcmFrameKeyFromBase64Sk0() throws {
        let sk0 = hexToData(Self.sk0Hex)
        let s = sk0.base64EncodedString()
        let key = try XCTUnwrap(pbkdf2(
            passwordUtf8: s,
            saltUtf8: Self.ratchetSalt,
            iterations: Self.pbkdf2Iterations,
            keyLen: Self.keyLenBytes
        ))
        XCTAssertEqual(hexString(key), Self.expectedKeyHex)
        XCTAssertEqual(key.count, 16) // 128 bits
    }

    func testIsDeterministicAcrossRepeatedDerivations() throws {
        let s = hexToData(Self.sk0Hex).base64EncodedString()
        let run = { try self.pbkdf2(passwordUtf8: s, saltUtf8: Self.ratchetSalt,
                                     iterations: Self.pbkdf2Iterations, keyLen: Self.keyLenBytes) }
        let a = try XCTUnwrap(run())
        let b = try XCTUnwrap(run())
        XCTAssertEqual(a, b)
    }

    func testADifferentSk0YieldsADifferentFrameKey() throws {
        let other = Data(repeating: 0xAB, count: 32)
        let key = try XCTUnwrap(pbkdf2(
            passwordUtf8: other.base64EncodedString(),
            saltUtf8: Self.ratchetSalt,
            iterations: Self.pbkdf2Iterations,
            keyLen: Self.keyLenBytes
        ))
        XCTAssertNotEqual(hexString(key), Self.expectedKeyHex)
    }

    /// Cross-checks the SK_0 DISTRIBUTION contract this feeds from:
    /// `GroupSession.currentSendKey`/`currentRecvKey` return the exact same
    /// bytes the sender transmitted verbatim as base64 in `sender_key_init`
    /// (see `GroupCallController.buildOwnInitEnvelope`-equivalent path) — so
    /// the LiveKit key-input STRING is byte-identical sender vs. receiver,
    /// which (combined with the frozen vector above) means an identical
    /// AES-128-GCM frame key. Mirrors Desktop's
    /// `test/kat/livekitGroupDistribution.kat.spec.ts`.
    func testSenderSk0AndInstalledReceiverSk0ProduceTheSameLiveKitKeyInputString() throws {
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

        XCTAssertEqual(bobViewOfAlice.base64EncodedString(), sAlice)
    }
}
