import XCTest
import CryptoKit
@testable import QAudionEngine

/// TRUST-2 (`docs/security/CRYPTO_PROTOCOL_AUDIT_2026-09-01.md`, security
/// audit backlog item 6) — coverage for the signed `remote_wipe` command
/// verifier. Signs its own fixtures inline with a fresh
/// `Curve25519.Signing.PrivateKey()` each run (same pattern
/// `BCryptoOtaModelClientTests` uses) rather than a committed KAT vector,
/// because bcrypto-server's real signer is being implemented by a separate
/// agent in the same batch and no cross-platform vector exists yet — see
/// `WipeSigningPublicKey`'s kdoc for that caveat. Every case here exercises
/// `WipeCommandVerifier` as a pure primitive (raw key in, no bundle/network
/// dependency), so it needs no KAT to be meaningful: the fail-closed
/// contract is what matters, not byte-for-byte interop with a signer that
/// does not exist to test against yet.
final class WipeCommandVerifierTests: XCTestCase {

    private var privateKey: Curve25519.Signing.PrivateKey!
    private var verifier: WipeCommandVerifier!
    private var replayCache: WipeReplayCache!

    private static let deviceId = "device-abc-123"
    private static let wipeId = "wipe-xyz-789"

    override func setUp() {
        super.setUp()
        privateKey = Curve25519.Signing.PrivateKey()
        verifier = WipeCommandVerifier(pinnedPublicKeyRaw: privateKey.publicKey.rawRepresentation)
        // In-memory only (persistenceURL: nil) — tests must not touch disk.
        replayCache = WipeReplayCache(persistenceURL: nil)
    }

    override func tearDown() {
        privateKey = nil
        verifier = nil
        replayCache = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeNonce(_ byte: UInt8 = 0x01) -> Data {
        Data(repeating: byte, count: 16)
    }

    private func sign(deviceId: String, wipeId: String, issuedAt: Int64, nonce: Data) -> Data {
        let canonical = WipeCommandVerifier.canonicalBytes(
            deviceId: deviceId, wipeId: wipeId, issuedAtUnixSeconds: issuedAt, nonce: nonce)
        // swiftlint:disable:next force_try
        return try! privateKey.signature(for: canonical)
    }

    private func makeCommand(
        deviceId: String = deviceId,
        wipeId: String = wipeId,
        issuedAt: Int64,
        nonce: Data,
        signWithWrongKey: Bool = false
    ) -> WipeCommandVerifier.WipeCommand {
        let sig: Data
        if signWithWrongKey {
            let evilKey = Curve25519.Signing.PrivateKey()
            let canonical = WipeCommandVerifier.canonicalBytes(
                deviceId: deviceId, wipeId: wipeId, issuedAtUnixSeconds: issuedAt, nonce: nonce)
            // swiftlint:disable:next force_try
            sig = try! evilKey.signature(for: canonical)
        } else {
            sig = sign(deviceId: deviceId, wipeId: wipeId, issuedAt: issuedAt, nonce: nonce)
        }
        return WipeCommandVerifier.WipeCommand(
            deviceId: deviceId, wipeId: wipeId, issuedAtUnixSeconds: issuedAt, nonce: nonce, signature: sig)
    }

    // MARK: - Happy path

    func testValidFreshUnseenCommandVerifies() {
        let now = Date()
        let nowSec = Int64(now.timeIntervalSince1970)
        let cmd = makeCommand(issuedAt: nowSec, nonce: makeNonce())
        XCTAssertTrue(verifier.verify(command: cmd, expectedDeviceId: Self.deviceId, replayCache: replayCache, now: now))
    }

    // MARK: - Signature integrity

    func testWrongSigningKeyIsRejected() {
        let now = Date()
        let nowSec = Int64(now.timeIntervalSince1970)
        let cmd = makeCommand(issuedAt: nowSec, nonce: makeNonce(), signWithWrongKey: true)
        XCTAssertFalse(verifier.verify(command: cmd, expectedDeviceId: Self.deviceId, replayCache: replayCache, now: now))
    }

    func testTamperedWipeIdInvalidatesSignature() {
        let now = Date()
        let nowSec = Int64(now.timeIntervalSince1970)
        let nonce = makeNonce()
        // Sign for one wipe_id, then present a command claiming a different one —
        // the signature was computed over the ORIGINAL wipe_id, so this must fail
        // even though every field individually "looks" well-formed.
        let sig = sign(deviceId: Self.deviceId, wipeId: "original-wipe", issuedAt: nowSec, nonce: nonce)
        let tampered = WipeCommandVerifier.WipeCommand(
            deviceId: Self.deviceId, wipeId: "tampered-wipe", issuedAtUnixSeconds: nowSec, nonce: nonce, signature: sig)
        XCTAssertFalse(verifier.verify(command: tampered, expectedDeviceId: Self.deviceId, replayCache: replayCache, now: now))
    }

    func testTamperedDeviceIdInSignedBytesInvalidatesSignature() {
        let now = Date()
        let nowSec = Int64(now.timeIntervalSince1970)
        let nonce = makeNonce()
        let sig = sign(deviceId: "device-A", wipeId: Self.wipeId, issuedAt: nowSec, nonce: nonce)
        let tampered = WipeCommandVerifier.WipeCommand(
            deviceId: "device-B", wipeId: Self.wipeId, issuedAtUnixSeconds: nowSec, nonce: nonce, signature: sig)
        XCTAssertFalse(verifier.verify(command: tampered, expectedDeviceId: "device-B", replayCache: replayCache, now: now))
    }

    func testFlippedSignatureByteFailsVerification() {
        let now = Date()
        let nowSec = Int64(now.timeIntervalSince1970)
        var cmd = makeCommand(issuedAt: nowSec, nonce: makeNonce())
        var sig = cmd.signature
        sig[0] ^= 0xFF
        cmd = WipeCommandVerifier.WipeCommand(
            deviceId: cmd.deviceId, wipeId: cmd.wipeId, issuedAtUnixSeconds: cmd.issuedAtUnixSeconds,
            nonce: cmd.nonce, signature: sig)
        XCTAssertFalse(verifier.verify(command: cmd, expectedDeviceId: Self.deviceId, replayCache: replayCache, now: now))
    }

    // MARK: - Device binding (a command genuinely signed for a DIFFERENT device
    // must not verify here, even though the signature itself is perfectly valid)

    func testCommandSignedForADifferentDeviceIsRejectedHere() {
        let now = Date()
        let nowSec = Int64(now.timeIntervalSince1970)
        let cmd = makeCommand(deviceId: "some-other-device", issuedAt: nowSec, nonce: makeNonce())
        XCTAssertFalse(verifier.verify(command: cmd, expectedDeviceId: Self.deviceId, replayCache: replayCache, now: now))
    }

    func testEmptyExpectedDeviceIdNeverVerifies() {
        let now = Date()
        let nowSec = Int64(now.timeIntervalSince1970)
        let cmd = makeCommand(deviceId: "", issuedAt: nowSec, nonce: makeNonce())
        XCTAssertFalse(verifier.verify(command: cmd, expectedDeviceId: "", replayCache: replayCache, now: now))
    }

    // MARK: - Freshness window

    func testExpiredIssuedAtIsRejected() {
        let now = Date()
        let stale = Int64(now.timeIntervalSince1970) - WipeCommandVerifier.defaultFreshnessWindowSeconds - 1
        let cmd = makeCommand(issuedAt: stale, nonce: makeNonce())
        XCTAssertFalse(verifier.verify(command: cmd, expectedDeviceId: Self.deviceId, replayCache: replayCache, now: now))
    }

    func testIssuedAtRightAtTheWindowEdgeStillVerifies() {
        let now = Date()
        let atEdge = Int64(now.timeIntervalSince1970) - WipeCommandVerifier.defaultFreshnessWindowSeconds
        let cmd = makeCommand(issuedAt: atEdge, nonce: makeNonce())
        XCTAssertTrue(verifier.verify(command: cmd, expectedDeviceId: Self.deviceId, replayCache: replayCache, now: now))
    }

    func testFarFutureIssuedAtIsRejected() {
        let now = Date()
        let farFuture = Int64(now.timeIntervalSince1970) + WipeCommandVerifier.defaultFreshnessWindowSeconds
        let cmd = makeCommand(issuedAt: farFuture, nonce: makeNonce())
        XCTAssertFalse(verifier.verify(command: cmd, expectedDeviceId: Self.deviceId, replayCache: replayCache, now: now))
    }

    func testSmallClockSkewIntoTheFutureIsTolerated() {
        let now = Date()
        let slightlyAhead = Int64(now.timeIntervalSince1970) + (WipeCommandVerifier.clockSkewToleranceSeconds - 1)
        let cmd = makeCommand(issuedAt: slightlyAhead, nonce: makeNonce())
        XCTAssertTrue(verifier.verify(command: cmd, expectedDeviceId: Self.deviceId, replayCache: replayCache, now: now))
    }

    // MARK: - Replay

    func testSameCommandVerifiedTwiceIsRejectedTheSecondTime() {
        let now = Date()
        let nowSec = Int64(now.timeIntervalSince1970)
        let cmd = makeCommand(issuedAt: nowSec, nonce: makeNonce())
        XCTAssertTrue(verifier.verify(command: cmd, expectedDeviceId: Self.deviceId, replayCache: replayCache, now: now))
        // Exact same (device_id, nonce) presented again — must be rejected as a
        // replay even though the signature is still perfectly valid on its own.
        XCTAssertFalse(verifier.verify(command: cmd, expectedDeviceId: Self.deviceId, replayCache: replayCache, now: now))
    }

    func testDifferentNonceSameDeviceIsNotTreatedAsReplay() {
        let now = Date()
        let nowSec = Int64(now.timeIntervalSince1970)
        let first = makeCommand(issuedAt: nowSec, nonce: makeNonce(0x01))
        let second = makeCommand(issuedAt: nowSec, nonce: makeNonce(0x02))
        XCTAssertTrue(verifier.verify(command: first, expectedDeviceId: Self.deviceId, replayCache: replayCache, now: now))
        XCTAssertTrue(verifier.verify(command: second, expectedDeviceId: Self.deviceId, replayCache: replayCache, now: now))
    }

    func testForgedGarbageDoesNotPoisonTheReplayCacheForALaterGenuineCommand() {
        // A garbage (unsigned) command with the SAME (device_id, nonce) as a
        // later genuine one must not have consumed the replay slot — since
        // signature verification runs BEFORE the replay check, the forged
        // attempt should never reach the cache at all.
        let now = Date()
        let nowSec = Int64(now.timeIntervalSince1970)
        let nonce = makeNonce()
        let forged = WipeCommandVerifier.WipeCommand(
            deviceId: Self.deviceId, wipeId: Self.wipeId, issuedAtUnixSeconds: nowSec,
            nonce: nonce, signature: Data(repeating: 0xAB, count: 64))
        XCTAssertFalse(verifier.verify(command: forged, expectedDeviceId: Self.deviceId, replayCache: replayCache, now: now))
        XCTAssertEqual(replayCache.size(), 0, "an unsigned/forged command must never touch the replay cache")

        let genuine = makeCommand(issuedAt: nowSec, nonce: nonce)
        XCTAssertTrue(verifier.verify(command: genuine, expectedDeviceId: Self.deviceId, replayCache: replayCache, now: now))
    }

    // MARK: - Malformed field shapes (via parseWipeCommand)

    func testParseRejectsMissingFields() {
        XCTAssertNil(WipeCommandVerifier.parseWipeCommand(from: [:]))
        XCTAssertNil(WipeCommandVerifier.parseWipeCommand(from: ["device_id": Self.deviceId]))
        XCTAssertNil(WipeCommandVerifier.parseWipeCommand(from: [
            "device_id": Self.deviceId, "wipe_id": Self.wipeId
        ]))
    }

    func testParseRejectsWrongLengthNonceOrSignature() {
        let shortNonce = Data(repeating: 0x01, count: 8).base64EncodedString()
        let goodSig = Data(repeating: 0x02, count: 64).base64EncodedString()
        XCTAssertNil(WipeCommandVerifier.parseWipeCommand(from: [
            "device_id": Self.deviceId, "wipe_id": Self.wipeId,
            "issued_at": 1_700_000_000, "nonce": shortNonce, "signature": goodSig
        ]))

        let goodNonce = Data(repeating: 0x01, count: 16).base64EncodedString()
        let shortSig = Data(repeating: 0x02, count: 10).base64EncodedString()
        XCTAssertNil(WipeCommandVerifier.parseWipeCommand(from: [
            "device_id": Self.deviceId, "wipe_id": Self.wipeId,
            "issued_at": 1_700_000_000, "nonce": goodNonce, "signature": shortSig
        ]))
    }

    func testParseAcceptsIssuedAtAsEitherNumberOrNumericString() {
        let nonce = Data(repeating: 0x01, count: 16).base64EncodedString()
        let sig = Data(repeating: 0x02, count: 64).base64EncodedString()
        let asNumber = WipeCommandVerifier.parseWipeCommand(from: [
            "device_id": Self.deviceId, "wipe_id": Self.wipeId,
            "issued_at": 1_700_000_000, "nonce": nonce, "signature": sig
        ])
        let asString = WipeCommandVerifier.parseWipeCommand(from: [
            "device_id": Self.deviceId, "wipe_id": Self.wipeId,
            "issued_at": "1700000000", "nonce": nonce, "signature": sig
        ])
        XCTAssertEqual(asNumber?.issuedAtUnixSeconds, 1_700_000_000)
        XCTAssertEqual(asString?.issuedAtUnixSeconds, 1_700_000_000)
    }

    // MARK: - Canonical bytes shape (documents the exact TRUST-2 layout)

    func testCanonicalBytesConcatenationOrderAndLengths() {
        let nonce = makeNonce(0x09)
        let bytes = WipeCommandVerifier.canonicalBytes(
            deviceId: "dev", wipeId: "wid", issuedAtUnixSeconds: 0x0102030405060708, nonce: nonce)
        var expected = Data()
        expected.append(WipeCommandVerifier.domainTag)
        expected.append(contentsOf: "dev".utf8)
        expected.append(contentsOf: "wid".utf8)
        expected.append(contentsOf: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]) // big-endian
        expected.append(nonce)
        XCTAssertEqual(bytes, expected)
    }

    // MARK: - Construction fail-closed contract

    func testVerifierInitRejectsWrongLengthKey() {
        XCTAssertNil(WipeCommandVerifier(pinnedPublicKeyRaw: Data(repeating: 0, count: 4)))
    }
}
