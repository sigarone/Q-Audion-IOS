import XCTest
@testable import QAudionEngine

/// W-GRPFALLBACKAUDIO-IOS / W-GRPAUDIOKEY — unit coverage for the seal/open
/// round trip the group-call SFU-outage fallback-audio receive path unseals
/// real Opus frames with. Ungated from `canImport(WebRTC)` (unlike
/// `PqcRtpFrameSealerTests`): `GroupFallbackAudioSealer`'s own dependencies
/// (`GroupSenderKey`'s AES-256-GCM/HKDF helpers, `CryptoKit`) have nothing
/// to do with the WebRTC target — see that class's own kdoc.
///
/// The exact `audio_key`/`frame_key` derivation and wire pack/unpack bytes
/// are pinned separately, against the shared cross-platform KAT, by
/// `GroupAudioSessionKeyKatTests`; this file exercises the class-level API
/// (padding, frame counter, epoch/AAD binding, error posture) an actual
/// caller sees.
final class GroupFallbackAudioSealerTests: XCTestCase {

    private let audioKey32 = Data(repeating: 0x37, count: 32)
    private let noncePrefix4 = Data([0x00, 0x01, 0x02, 0x03])
    private let epoch: UInt32 = 1
    private let sender = "alice"

    /// Resolver stub that always hands back `key` regardless of the epoch
    /// the wire claims — isolates whatever a test is actually checking
    /// (padding, AAD binding, tamper detection) from the epoch-gating logic
    /// `GroupAudioEpochKeyResolverTests` covers on its own.
    private func alwaysResolve(_ key: Data) -> (UInt32) -> Data? {
        return { _ in key }
    }

    func testRoundTripTypicalOpusFrame() throws {
        let tx = GroupFallbackAudioSealer()
        // A realistic 20ms Opus frame at the standard 40kbps operating
        // point is well under the 118-byte (120 - 2 header) budget.
        let opus = Data((0..<80).map { UInt8($0 & 0xFF) })
        let wire = try tx.sealAudio(opus: opus, audioKey: audioKey32, noncePrefix: noncePrefix4, epochId: epoch, senderId: sender)
        let opened = try GroupFallbackAudioSealer.openAudio(wire: wire, senderId: sender, resolveAudioKey: alwaysResolve(audioKey32))
        XCTAssertEqual(opened.opus, opus)
    }

    func testMultipleFramesRoundTripInOrder() throws {
        let tx = GroupFallbackAudioSealer()
        let frames = (0..<5).map { i in Data(repeating: UInt8(i), count: 40 + i) }
        for f in frames {
            let wire = try tx.sealAudio(opus: f, audioKey: audioKey32, noncePrefix: noncePrefix4, epochId: epoch, senderId: sender)
            let opened = try GroupFallbackAudioSealer.openAudio(wire: wire, senderId: sender, resolveAudioKey: alwaysResolve(audioKey32))
            XCTAssertEqual(opened.opus, f)
        }
    }

    /// Wire layout is `tag(1) || epoch_id BE(4) || nonce(12) || ...` — the
    /// nonce is fully deterministic from `(noncePrefix, frame_counter)` and
    /// is NOT affected by the padded plaintext's random CSPRNG tail, so
    /// extracting it lets tests pin frame-counter behavior without a
    /// full-wire byte match (which would spuriously fail: two seals of the
    /// identical plaintext never produce the identical wire, since the
    /// padding tail is freshly randomized every call regardless of the
    /// frame counter).
    private func wireNonce(_ wire: Data) -> Data {
        wire.subdata(in: (wire.startIndex + 5)..<(wire.startIndex + 17))
    }

    /// The per-frame nonce (`random(4) || BE64(frame_counter)`) must
    /// actually advance every frame — otherwise two frames sealed under the
    /// SAME (frame_key, nonce) pair would be an AES-GCM catastrophic reuse.
    func testSequentialFramesNeverReuseANonce() throws {
        let tx = GroupFallbackAudioSealer()
        let opus = Data(repeating: 0x5A, count: 40)
        let wire0 = try tx.sealAudio(opus: opus, audioKey: audioKey32, noncePrefix: noncePrefix4, epochId: epoch, senderId: sender)
        let wire1 = try tx.sealAudio(opus: opus, audioKey: audioKey32, noncePrefix: noncePrefix4, epochId: epoch, senderId: sender)
        XCTAssertNotEqual(wireNonce(wire0), wireNonce(wire1), "frame counter must advance between successive seals")
    }

    /// `resetFrameCounter()` — called when a fresh `audio_key` is derived
    /// for a new epoch — must actually restart at 0, so the FIRST frame
    /// sealed after a reset reproduces frame 0's nonce.
    func testResetFrameCounterRestartsAtZero() throws {
        let tx = GroupFallbackAudioSealer()
        let opus = Data(repeating: 0x5A, count: 40)
        let wire0 = try tx.sealAudio(opus: opus, audioKey: audioKey32, noncePrefix: noncePrefix4, epochId: epoch, senderId: sender)
        let wire1 = try tx.sealAudio(opus: opus, audioKey: audioKey32, noncePrefix: noncePrefix4, epochId: epoch, senderId: sender)
        XCTAssertNotEqual(wireNonce(wire0), wireNonce(wire1))

        tx.resetFrameCounter()
        let afterReset = try tx.sealAudio(opus: opus, audioKey: audioKey32, noncePrefix: noncePrefix4, epochId: epoch, senderId: sender)
        XCTAssertEqual(wireNonce(wire0), wireNonce(afterReset), "resetFrameCounter() must restart the counter at 0, reproducing frame 0's nonce")
    }

    /// W-PADOVERFLOW parity — an Opus frame too large for the standard
    /// 120-byte block (budget = 118 bytes after the 2-byte length header)
    /// must NOT throw and must NOT change the wire size: it degrades to a
    /// declared-length-zero packet, which `openAudio` surfaces as
    /// `OpenResult(opus: nil)` — the caller's PLC-concealment sentinel —
    /// rather than corrupting or truncating the oversized frame.
    func testOversizedFrameDegradesToSilenceSentinelNotError() throws {
        let tx = GroupFallbackAudioSealer()
        let tooLarge = Data(repeating: 0xAB, count: 200) // > 118-byte budget
        let wire = try tx.sealAudio(opus: tooLarge, audioKey: audioKey32, noncePrefix: noncePrefix4, epochId: epoch, senderId: sender)
        let opened = try GroupFallbackAudioSealer.openAudio(wire: wire, senderId: sender, resolveAudioKey: alwaysResolve(audioKey32))
        XCTAssertNil(opened.opus, "oversized frame must degrade to the silence sentinel, not leak/truncate the real audio")
    }

    func testWireSizeIsConstantRegardlessOfOpusLength() throws {
        let tx = GroupFallbackAudioSealer()
        let short = try tx.sealAudio(opus: Data([0x01, 0x02]), audioKey: audioKey32, noncePrefix: noncePrefix4, epochId: epoch, senderId: sender)
        let long = try tx.sealAudio(opus: Data(repeating: 0x03, count: 100), audioKey: audioKey32, noncePrefix: noncePrefix4, epochId: epoch, senderId: sender)
        // Anti-traffic-analysis property: every sealed frame is the same
        // size on the wire regardless of the real Opus payload length.
        XCTAssertEqual(short.count, long.count)
    }

    func testWrongKeyFailsToOpen() throws {
        let tx = GroupFallbackAudioSealer()
        let wire = try tx.sealAudio(opus: Data([0x01, 0x02, 0x03]), audioKey: audioKey32, noncePrefix: noncePrefix4, epochId: epoch, senderId: sender)
        let wrongKey = Data(repeating: 0x99, count: 32)
        XCTAssertThrowsError(try GroupFallbackAudioSealer.openAudio(wire: wire, senderId: sender, resolveAudioKey: alwaysResolve(wrongKey)))
    }

    func testTamperedCiphertextFailsToOpen() throws {
        let tx = GroupFallbackAudioSealer()
        var wire = try tx.sealAudio(opus: Data([0x0A, 0x0B]), audioKey: audioKey32, noncePrefix: noncePrefix4, epochId: epoch, senderId: sender)
        let last = wire.endIndex - 1
        wire[last] ^= 0xFF
        XCTAssertThrowsError(try GroupFallbackAudioSealer.openAudio(wire: wire, senderId: sender, resolveAudioKey: alwaysResolve(audioKey32)))
    }

    func testRejectsWrongKeyLengthOnSeal() {
        let tx = GroupFallbackAudioSealer()
        XCTAssertThrowsError(try tx.sealAudio(opus: Data([0x01]), audioKey: Data(repeating: 0x01, count: 16), noncePrefix: noncePrefix4, epochId: epoch, senderId: sender))
    }

    func testRejectsWrongKeyLengthOnOpen() throws {
        let tx = GroupFallbackAudioSealer()
        let wire = try tx.sealAudio(opus: Data([0x01]), audioKey: audioKey32, noncePrefix: noncePrefix4, epochId: epoch, senderId: sender)
        XCTAssertThrowsError(try GroupFallbackAudioSealer.openAudio(
            wire: wire, senderId: sender, resolveAudioKey: alwaysResolve(Data(repeating: 0x01, count: 16))))
    }

    func testTwoDifferentAudioKeysDontInterop() throws {
        let tx = GroupFallbackAudioSealer()
        let wire = try tx.sealAudio(opus: Data([0x01, 0x02]), audioKey: audioKey32, noncePrefix: noncePrefix4, epochId: epoch, senderId: sender)
        let otherKey = Data(repeating: 0x77, count: 32)
        XCTAssertThrowsError(try GroupFallbackAudioSealer.openAudio(wire: wire, senderId: sender, resolveAudioKey: alwaysResolve(otherKey)))
    }

    /// AAD binds `sender_id` — the receiver supplies `senderId` from the
    /// relay's OWN out-of-band tag (never from inside the wire bytes), so
    /// an attacker who could make the relay misattribute a frame's sender
    /// (or a caller bug that mixes up two senders' frames) must fail to
    /// decrypt rather than silently opening under the WRONG peer's audio.
    func testMismatchedSenderIdFailsAad() throws {
        let tx = GroupFallbackAudioSealer()
        let wire = try tx.sealAudio(opus: Data([0x01, 0x02, 0x03]), audioKey: audioKey32, noncePrefix: noncePrefix4, epochId: epoch, senderId: "alice")
        XCTAssertThrowsError(try GroupFallbackAudioSealer.openAudio(wire: wire, senderId: "bob", resolveAudioKey: alwaysResolve(audioKey32)))
    }

    /// AAD also binds `epoch_id`, sourced from the WIRE's own field (never
    /// a caller-supplied value) — tampering that field on the wire changes
    /// the AAD the receiver reconstructs without changing the GCM tag that
    /// authenticated the ORIGINAL epoch_id, so it must fail even though the
    /// resolver stub here would happily hand back a key for any epoch.
    func testTamperedEpochIdFailsAad() throws {
        let tx = GroupFallbackAudioSealer()
        var wire = try tx.sealAudio(opus: Data([0x0A, 0x0B]), audioKey: audioKey32, noncePrefix: noncePrefix4, epochId: 1, senderId: sender)
        // epoch_id occupies wire bytes 1 through 4 (tag is byte 0) — flip the
        // low byte so it decodes as a well-formed but DIFFERENT epoch.
        wire[wire.startIndex + 4] ^= 0x01
        XCTAssertThrowsError(try GroupFallbackAudioSealer.openAudio(wire: wire, senderId: sender, resolveAudioKey: alwaysResolve(audioKey32)))
    }

    /// The resolver rejecting an epoch outright (e.g.
    /// `GroupAudioEpochKeyResolver` returning `nil` for a wire epoch that is
    /// neither current nor within the grace window) must surface as
    /// `.keyUnavailable`, not silently fall through to some default key.
    func testResolverRejectingEpochThrowsKeyUnavailable() throws {
        let tx = GroupFallbackAudioSealer()
        let wire = try tx.sealAudio(opus: Data([0x01]), audioKey: audioKey32, noncePrefix: noncePrefix4, epochId: epoch, senderId: sender)
        XCTAssertThrowsError(try GroupFallbackAudioSealer.openAudio(wire: wire, senderId: sender) { _ in nil }) { error in
            XCTAssertEqual(error as? GroupFallbackAudioSealer.SealError, .keyUnavailable)
        }
    }

    /// Interop sanity: the AUDIO_DATA envelope batches N sealed wire frames
    /// (`QAudionCapabilityExchange.createAudioData`/`parseAudioDataBatch`).
    /// This exercises exactly that combination — seal locally, batch, wrap,
    /// unwrap, unseal — the same path `GroupCallController.
    /// handleFallbackAudioData` runs against a real inbound envelope.
    func testRoundTripThroughAudioDataEnvelope() throws {
        let tx = GroupFallbackAudioSealer()
        let opusFrames = [Data([0x01, 0x02, 0x03]), Data([0x04, 0x05])]
        let wireFrames = try opusFrames.map {
            try tx.sealAudio(opus: $0, audioKey: audioKey32, noncePrefix: noncePrefix4, epochId: epoch, senderId: sender)
        }
        let envelope = QAudionCapabilityExchange.createAudioData(frames: wireFrames)
        guard let message = QAudionCapabilityExchange.parse(envelope),
              case .audioData(let parsedFrames) = message else {
            XCTFail("failed to parse AUDIO_DATA envelope")
            return
        }
        XCTAssertEqual(parsedFrames.count, opusFrames.count)
        for (wire, expectedOpus) in zip(parsedFrames, opusFrames) {
            let opened = try GroupFallbackAudioSealer.openAudio(wire: wire, senderId: sender, resolveAudioKey: alwaysResolve(audioKey32))
            XCTAssertEqual(opened.opus, expectedOpus)
        }
    }
}
