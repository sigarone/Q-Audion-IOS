import XCTest
import CryptoKit
@testable import QAudionEngine

/// Tests for ``SFrameVideoSealer`` — the drop-in adapter that the iOS
/// `SecureVideoPipeline` will switch to once the iOS port is wired into
/// the WebRTC frame-encryptor slot.
///
/// The codec itself is exercised by `SFrameCodecRoundTripTest` and the
/// cross-platform KAT verifier. This file only validates the adapter
/// wiring (counter monotonicity, kid/master propagation, 1:1 vs group
/// factory, and — most importantly — the rotating-key behaviour that
/// keeps the video pipeline transparent to the audio-driven
/// `ReKeyScheduler`).
///
/// Mirrors the Kotlin `SFrameVideoSealerTest.kt` shape one-for-one. The
/// only deviation is the two `precondition` cases (Kotlin uses
/// `IllegalArgumentException` which is catchable; Swift's `precondition`
/// traps the process and cannot be caught from XCTest). Those slots are
/// retained as documentation tests using the negative input through
/// the public surface in a way that does NOT fire the precondition,
/// asserting the success path while leaving the failure path validated
/// by inspection.
final class SFrameVideoSealerTest: XCTestCase {

    private let pqcKey: Data = {
        var d = Data(count: 32)
        for i in 0..<32 { d[i] = UInt8(i) }
        return d
    }()

    // MARK: 1) 1:1 round-trip via sealer

    func test_1to1_roundTripViaSealer() throws {
        let sealer = SFrameVideoSealer.forOneToOne(pqcSessionKey: pqcKey)
        let nal = Data([0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0x0C, 0x01])
        let wire = try sealer.seal(plaintext: nal, layer: .mid)
        let opened = try sealer.open(wire)
        XCTAssertEqual(opened, nal)
    }

    // MARK: 2) Counter is monotonic across calls

    func test_counterIsMonotonicAcrossCalls() throws {
        let sealer = SFrameVideoSealer.forOneToOne(pqcSessionKey: pqcKey)
        XCTAssertEqual(sealer.counterSnapshot(), 0)
        _ = try sealer.seal(plaintext: Data([0x01]))
        XCTAssertEqual(sealer.counterSnapshot(), 1)
        _ = try sealer.seal(plaintext: Data([0x02]))
        XCTAssertEqual(sealer.counterSnapshot(), 2)
    }

    // MARK: 3) Same plaintext + different CTR yields different wire bytes

    func test_samePlaintextDifferentCtrYieldsDifferentWireBytes() throws {
        let sealer = SFrameVideoSealer.forOneToOne(pqcSessionKey: pqcKey)
        let nal = Data([0x42])
        let a = try sealer.seal(plaintext: nal)
        let b = try sealer.seal(plaintext: nal)
        XCTAssertNotEqual(a, b)
        // Both still decrypt with the same sealer (counter monotonic, master shared).
        XCTAssertEqual(try sealer.open(a), nal)
        XCTAssertEqual(try sealer.open(b), nal)
    }

    // MARK: 4) Group sealer uses chain key not pqc key

    func test_groupSealerUsesChainKeyNotPqcKey() throws {
        var chainKey = Data(count: 32)
        for i in 0..<32 { chainKey[i] = 0x55 }
        let kid = Data([0x12, 0x34, 0x56])
        let groupSealer = SFrameVideoSealer.forGroup(
            chainKey: chainKey,
            groupIdHex: "deadbeef",
            senderId: "alice",
            kid: kid
        )
        let pairSealer = SFrameVideoSealer.forOneToOne(pqcSessionKey: chainKey)
        let nal = Data([0x42])
        // Same input bytes, different master derivation ⇒ different ciphertext.
        let groupWire = try groupSealer.seal(plaintext: nal)
        let pairWire = try pairSealer.seal(plaintext: nal)
        XCTAssertNotEqual(groupWire, pairWire)
        // Pair sealer can't open group wire (AEAD tag mismatch).
        XCTAssertThrowsError(try pairSealer.open(groupWire))
    }

    // MARK: 5) Keyframe + layer flags reach the wire

    func test_keyframeAndLayerFlagsReachTheWire() throws {
        let sealer = SFrameVideoSealer.forOneToOne(pqcSessionKey: pqcKey)
        let wire = try sealer.seal(
            plaintext: Data([0x01]),
            layer: .high,
            keyFrame: true,
            padded: false
        )
        let (h, _) = try SFrameCodec.decodeHeader(wire)
        XCTAssertEqual(h.layer, .high)
        XCTAssertTrue(h.keyFrame)
        XCTAssertFalse(h.padded)
    }

    // MARK: 6) Padding flag round-trip strips padding correctly

    func test_paddingRoundTripStripsCorrectly() throws {
        let sealer = SFrameVideoSealer.forOneToOne(pqcSessionKey: pqcKey)
        var nal = Data(count: 73)
        for i in 0..<73 { nal[i] = UInt8(i & 0xFF) }
        let wire = try sealer.seal(plaintext: nal, padded: true)
        let (h, _) = try SFrameCodec.decodeHeader(wire)
        XCTAssertTrue(h.padded)
        XCTAssertEqual(try sealer.open(wire), nal)
    }

    // MARK: 7) Group sealer requires 3-byte KID
    //
    // Kotlin throws `IllegalArgumentException` (catchable). Swift uses
    // `precondition` which traps the process and cannot be caught from
    // XCTest. We assert the positive 3-byte path here; the rejection
    // path is enforced by `precondition(kid.count == 3, ...)` in
    // `SFrameVideoSealer.forGroup` and validated by code review.

    func test_groupSealerRequires3ByteKid_positivePath() throws {
        let chainKey = Data(repeating: 0x55, count: 32)
        let kid = Data([0x12, 0x34, 0x56])
        let sealer = SFrameVideoSealer.forGroup(
            chainKey: chainKey,
            groupIdHex: "deadbeef",
            senderId: "alice",
            kid: kid
        )
        let wire = try sealer.seal(plaintext: Data([0x01]))
        let (h, _) = try SFrameCodec.decodeHeader(wire)
        XCTAssertEqual(h.kid, kid)
    }

    // MARK: 8) forRotatingKey re-derives master per frame so rekey is transparent
    //
    // **The key test for this commit.** Set up a mutable key reference,
    // build a sealer that captures it via a closure, seal under key1,
    // mutate to key2, seal again, and confirm:
    //   - the two wire blobs differ (different master ⇒ different
    //     ciphertext for the same plaintext + counter+1),
    //   - opening frame1 under the new key (key2) fails with an AEAD
    //     authentication error,
    //   - reverting to key1 restores the ability to open frame1.

    func test_forRotatingKey_reDerivesMasterPerFrameRekeyTransparent() throws {
        let key1 = Data(repeating: 0x11, count: 32)
        let key2 = Data(repeating: 0x22, count: 32)

        // Use a class-backed reference holder so the closure can observe mutations.
        final class KeyHolder { var k: Data; init(_ k: Data) { self.k = k } }
        let holder = KeyHolder(key1)
        let lock = NSLock()

        let sealer = SFrameVideoSealer.forRotatingKey {
            lock.lock(); defer { lock.unlock() }
            return holder.k
        }

        let pt = Data("rekey test".utf8)
        let wire1 = try sealer.seal(plaintext: pt)

        // Concurrently with the audio-driven scheduler, the next frame must use key2.
        lock.lock(); holder.k = key2; lock.unlock()
        let wire2 = try sealer.seal(plaintext: pt)

        // Same plaintext + different master ⇒ different ciphertext.
        XCTAssertNotEqual(wire1, wire2)

        // wire1 must NOT decrypt with the now-current (key2) master.
        XCTAssertThrowsError(try sealer.open(wire1))

        // Reverting to key1 lets us decrypt wire1 again (same key path).
        lock.lock(); holder.k = key1; lock.unlock()
        let opened = try sealer.open(wire1)
        XCTAssertEqual(opened, pt)
    }

    // MARK: 9) forRotatingKey rejects malformed key from provider
    //
    // Kotlin throws `IllegalArgumentException` (catchable). Swift
    // `precondition` traps the process. We exercise the success path
    // with a fresh 32-byte key and rely on code review for the
    // rejection branch (`precondition(k.count == 32, ...)`). The
    // intent of the slot is preserved.

    func test_forRotatingKey_rejectsMalformedKeyFromProvider_positivePath() throws {
        let goodKey = Data(repeating: 0x33, count: 32)
        let sealer = SFrameVideoSealer.forRotatingKey { goodKey }
        let wire = try sealer.seal(plaintext: Data([0x42]))
        XCTAssertEqual(try sealer.open(wire), Data([0x42]))
    }

    // MARK: 10) forGroupRotating tracks chain advance

    func test_forGroupRotating_tracksChainAdvance() throws {
        let ck1 = Data(repeating: 0x11, count: 32)
        let ck2 = Data(repeating: 0x22, count: 32)
        final class KeyHolder { var k: Data; init(_ k: Data) { self.k = k } }
        let holder = KeyHolder(ck1)
        let lock = NSLock()

        let sealer = SFrameVideoSealer.forGroupRotating(
            chainKeyProvider: {
                lock.lock(); defer { lock.unlock() }
                return holder.k
            },
            groupIdHex: "deadbeef",
            senderId: "alice",
            kid: Data([0x12, 0x34, 0x56])
        )

        let pt = Data("group rekey".utf8)
        let wire1 = try sealer.seal(plaintext: pt)

        lock.lock(); holder.k = ck2; lock.unlock()
        let wire2 = try sealer.seal(plaintext: pt)
        XCTAssertNotEqual(wire1, wire2)

        // Reverting lets us decode the old frame.
        lock.lock(); holder.k = ck1; lock.unlock()
        XCTAssertEqual(try sealer.open(wire1), pt)
    }
}
