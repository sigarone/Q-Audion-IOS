import XCTest
#if canImport(WebRTC)
import WebRTC
@testable import QAudionEngine

/// The audio sender pin on the REAL WebRTC build (iOS Simulator slice): a peer connection built with the native audio
/// path on carries a pre-attached (muted) microphone track, and the sender of that track reads back as pinned (32 kbps
/// min = max, fixed packet time, high priority) as soon as it exists and again after the local description. Nothing
/// is ever connected: no network, no remote peer.
final class NativeAudioSenderPinTests: XCTestCase {

    private let callId = "audio-wire-shape-pin"
    private var savedOverride: Bool?

    override func setUp() {
        super.setUp()
        savedOverride = CallCapabilities.audioSrtpDebugOverride
        CallCapabilities.audioSrtpDebugOverride = true
        // A snapshot left by another test must not decide this call; the call gets its own, with the override on.
        CallCapabilities.endNativeSrtpCallSnapshotAtCallEnd(callId: nil)
        CallCapabilities.beginNativeSrtpCallSnapshot(callId: callId)
    }

    override func tearDown() {
        CallCapabilities.endNativeSrtpCallSnapshot(callId: callId)
        CallCapabilities.audioSrtpDebugOverride = savedOverride
        super.tearDown()
    }

    /// Lines handed over from WebRTC callback threads.
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ line: String) { lock.lock(); items.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private let highPriority: Int = RTCPriority.high.rawValue

    private func makePeer() async throws -> (peer: QAudionPeerConnection, lines: Lines) {
        let factory = await QAudionPeerConnectionFactory.shared.factory()
        guard let context = CallDtlsContextStore().context(forCallId: callId) else {
            throw XCTSkip("no per-call certificate could be generated on this host")
        }
        let peer = QAudionPeerConnection(factory: factory, iceServers: [], delegate: nil, dtlsContext: context)
        XCTAssertNotNil(peer.peerConnection, "the peer connection exists")
        let lines = Lines()
        // The pin at creation was produced inside `init`, before any closure existed: it is held and delivered now.
        peer.onNativeAudioDiagLine = { lines.add($0) }
        return (peer, lines)
    }

    private func assertPinned(_ sender: RTCRtpSender, file: StaticString = #filePath, line: UInt = #line) throws {
        let encodings = sender.parameters.encodings
        XCTAssertEqual(encodings.count, 1, file: file, line: line)
        let encoding = try XCTUnwrap(encodings.first, file: file, line: line)
        XCTAssertEqual(encoding.minBitrateBps?.intValue, 32_000, file: file, line: line)
        XCTAssertEqual(encoding.maxBitrateBps?.intValue, 32_000, file: file, line: line)
        XCTAssertFalse(encoding.adaptiveAudioPacketTime, "the packet time stays fixed", file: file, line: line)
        XCTAssertEqual(encoding.networkPriority, .high, file: file, line: line)
    }

    func testThePreAttachedMicSenderIsPinnedWhenItIsCreated() async throws {
        let (peer, lines) = try await makePeer()
        defer { peer.close() }
        let sender = try XCTUnwrap(peer.nativeAudioSender, "the mic track is pre-attached")
        XCTAssertEqual(sender.track?.kind, "audio")
        try assertPinned(sender)
        XCTAssertEqual(lines.all, ["audiosrtp cap n=1 min=32000 max=32000 apt=0 prio=\(highPriority) ok=1 src=1"])
    }

    func testTheOfferHasNoSpeechLevelNorBandwidthExtensionOnAudioAndTheSenderIsPinnedAgain() async throws {
        let (peer, lines) = try await makePeer()
        defer { peer.close() }
        let offer: String = try await withCheckedThrowingContinuation { continuation in
            peer.createOffer(audioOnly: true) { continuation.resume(with: $0) }
        }
        let all = offer.components(separatedBy: "\r\n")
        let audioStart = try XCTUnwrap(all.firstIndex { $0.hasPrefix("m=audio") }, offer)
        let audioEnd = all[(audioStart + 1)...].firstIndex { $0.hasPrefix("m=") } ?? all.endIndex
        let audio = Array(all[audioStart..<audioEnd])
        let video = Array(all[audioEnd...])

        for gone in ["ssrc-audio-level", "csrc-audio-level", "transport-wide-cc", "abs-send-time", "abs-capture-time",
                     "toffset"] {
            XCTAssertFalse(audio.contains { $0.hasPrefix("a=extmap:") && $0.contains(gone) },
                           "\(gone) must not be negotiated on audio: \(audio)")
        }
        XCTAssertFalse(audio.contains { $0.hasPrefix("a=rtcp-fb:") && $0.contains("transport-cc") }, "\(audio)")
        XCTAssertTrue(audio.contains("a=ptime:60"), "\(audio)")
        XCTAssertTrue(audio.contains("a=maxptime:60"), "\(audio)")
        XCTAssertTrue(video.contains { $0.hasPrefix("a=extmap:") && $0.contains("transport-wide-cc") },
                      "the video section keeps its own bandwidth extension: \(video)")

        // Pinned at creation (src=1) and again once the local description is applied (src=2), both accepted.
        let expected = "audiosrtp cap n=1 min=32000 max=32000 apt=0 prio=\(highPriority) ok=1 src="
        XCTAssertTrue(lines.all.contains(expected + "1"), "\(lines.all)")
        XCTAssertTrue(lines.all.contains(expected + "2"), "\(lines.all)")
        XCTAssertFalse(lines.all.contains { $0.contains("ok=0") }, "every read-back is accepted: \(lines.all)")
        try assertPinned(try XCTUnwrap(peer.nativeAudioSender))
    }

    /// The group publisher's audio sender: pinned when it is created and again after the offer, every read-back accepted.
    func testTheGroupPublisherAudioSenderReadsBackAsPinnedAfterTheOffer() async throws {
        let factory = await QAudionPeerConnectionFactory.shared.factory()
        let hub = GroupFrameCryptorHub()
        hub.bind(factory: factory)
        hub.installKey(GroupCallFixtures.keyBytes(7), index: 1, participantId: GroupCallFixtures.pseudoA)
        hub.setSendKeyIndex(1)
        let peer = GroupPublisherPeer(factory: factory, iceServers: [], cryptors: hub, selfPseudonym: GroupCallFixtures.pseudoA)
        let lines = Lines()
        peer.onAudioSenderLine = { lines.add($0) }
        try await peer.start()
        _ = try await peer.createOffer(iceRestart: false)
        peer.close()
        let all = lines.all
        XCTAssertGreaterThanOrEqual(all.count, 2, "created, then after the offer: \(all)")
        XCTAssertEqual(Set(all), ["grp audio cap n=1 min=32000 max=32000 apt=0 ok=1"], "\(all)")
    }
}
#endif
