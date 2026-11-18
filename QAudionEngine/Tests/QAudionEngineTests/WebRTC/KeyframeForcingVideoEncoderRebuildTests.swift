import XCTest
import CoreVideo
#if canImport(WebRTC)
import WebRTC
#endif
@testable import QAudionEngine

/// The WebRTC video encoder wrapper rebuilds the inner encoder when frames are refused: at most once per interval, only
/// while the encoder is started, with the callback, the settings and the bitrate back, and a key frame next.
final class KeyframeForcingVideoEncoderRebuildTests: XCTestCase {
    #if canImport(WebRTC)

    private final class FakeEncoder: NSObject, RTCVideoEncoder {
        var events: [String] = []
        var callback: RTCVideoEncoderCallback?
        var startStatus = 0
        var encodeStatus = 0
        var coresSeen: [Int32] = []
        var rates: [UInt32] = []
        var keyFlags: [Bool] = []

        func setCallback(_ callback: RTCVideoEncoderCallback?) {
            events.append("callback")
            self.callback = callback
        }
        func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
            events.append("start")
            coresSeen.append(numberOfCores)
            return startStatus
        }
        func release() -> Int {
            events.append("release")
            return 0
        }
        func encode(_ frame: RTCVideoFrame, codecSpecificInfo: RTCCodecSpecificInfo?, frameTypes: [NSNumber]) -> Int {
            events.append("encode")
            keyFlags.append(frameTypes.contains { $0.uintValue == RTCFrameType.videoFrameKey.rawValue })
            return encodeStatus
        }
        func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
            events.append("rate")
            rates.append(bitrateKbit)
            return 0
        }
        func implementationName() -> String { "fake" }
        func scalingSettings() -> RTCVideoEncoderQpThresholds? { nil }
        var resolutionAlignment: Int { 1 }
        var supportsNativeHandle: Bool { false }
        var applyAlignmentToAllSimulcastLayers: Bool { false }
    }

    private final class Clock: @unchecked Sendable {
        var nowMs: Int64 = 100_000
    }

    private final class LineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private struct Rig {
        let inner: FakeEncoder
        let clock: Clock
        let lines: LineBox
        let wrapper: KeyframeForcingVideoEncoder
    }

    private func makeRig() -> Rig {
        let inner = FakeEncoder()
        let clock = Clock()
        let lines = LineBox()
        let wrapper = KeyframeForcingVideoEncoder(
            inner: inner, clock: { clock.nowMs }, emitLine: { lines.add($0) })
        return Rig(inner: inner, clock: clock, lines: lines, wrapper: wrapper)
    }

    private func makeFrame() -> RTCVideoFrame {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer)
        return RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer!), rotation: ._0, timeStampNs: 0)
    }

    private func encode(_ rig: Rig) -> Int {
        rig.wrapper.encode(makeFrame(), codecSpecificInfo: nil,
                           frameTypes: [NSNumber(value: RTCFrameType.videoFrameDelta.rawValue)])
    }

    private func start(_ rig: Rig, cores: Int32 = 2) {
        _ = rig.wrapper.startEncode(with: RTCVideoEncoderSettings(), numberOfCores: cores)
        rig.wrapper.setCallback { _, _ in true }
        _ = rig.wrapper.setBitrate(900, framerate: 15)
        rig.inner.events.removeAll()
    }

    func testARefusedFrameRebuildsTheSessionWithTheSavedState() {
        let rig = makeRig()
        start(rig, cores: 3)
        rig.inner.encodeStatus = -1
        XCTAssertEqual(encode(rig), -1, "the result code goes back to libwebrtc unchanged")
        XCTAssertEqual(rig.inner.events, ["encode", "release", "start", "callback", "rate"])
        XCTAssertEqual(rig.inner.coresSeen.last, 3)
        XCTAssertEqual(rig.inner.rates.last, 900)
        XCTAssertNotNil(rig.inner.callback)
        XCTAssertEqual(rig.lines.all, ["vcap encfail st=-1 ask=1 rec=1 code=0"])
    }

    func testTheFrameAfterTheRebuildIsAKeyFrame() {
        let rig = makeRig()
        start(rig)
        // The first frame is a key frame by cadence; the next one is not, until the rebuild.
        _ = encode(rig)
        _ = encode(rig)
        XCTAssertEqual(rig.inner.keyFlags, [true, false])
        rig.inner.encodeStatus = -1
        _ = encode(rig)
        rig.inner.encodeStatus = 0
        _ = encode(rig)
        XCTAssertEqual(rig.inner.keyFlags.last, true)
    }

    func testAtMostOneRebuildPerIntervalAndOneLinePerEpisode() {
        let rig = makeRig()
        start(rig)
        rig.inner.encodeStatus = -1
        for _ in 0..<10 {
            _ = encode(rig)
            rig.clock.nowMs += 60
        }
        XCTAssertEqual(rig.inner.events.filter { $0 == "release" }.count, 1)
        XCTAssertEqual(rig.lines.all.count, 1)
        rig.clock.nowMs += 1_000
        _ = encode(rig)
        XCTAssertEqual(rig.inner.events.filter { $0 == "release" }.count, 2)
        XCTAssertEqual(rig.lines.all.count, 1, "the episode goes on: no new line")
        // An accepted frame ends the episode; the next failure logs again.
        rig.inner.encodeStatus = 0
        _ = encode(rig)
        rig.inner.encodeStatus = -1
        rig.clock.nowMs += 5_000
        _ = encode(rig)
        XCTAssertEqual(rig.lines.all.count, 2)
    }

    func testNoRebuildAfterReleaseOrBeforeStart() {
        let rig = makeRig()
        rig.inner.encodeStatus = -1
        _ = encode(rig)
        XCTAssertEqual(rig.inner.events, ["encode"], "never started: nothing to rebuild")
        start(rig)
        _ = rig.wrapper.release()
        rig.inner.events.removeAll()
        rig.clock.nowMs += 5_000
        _ = encode(rig)
        XCTAssertEqual(rig.inner.events, ["encode"], "released on purpose: no rebuild")
    }

    func testAFailedRestartDoesNotLoopAndTheNextIntervalTriesAgain() {
        let rig = makeRig()
        start(rig)
        rig.inner.encodeStatus = -1
        rig.inner.startStatus = -1
        _ = encode(rig)
        XCTAssertEqual(rig.lines.all, ["vcap encfail st=-1 ask=1 rec=0 code=-1"])
        rig.inner.events.removeAll()
        _ = encode(rig)
        XCTAssertEqual(rig.inner.events, ["encode"], "inside the interval: no second attempt")
        rig.clock.nowMs += 1_000
        rig.inner.startStatus = 0
        _ = encode(rig)
        XCTAssertEqual(rig.inner.events.filter { $0 == "start" }.count, 1)
    }

    func testRefusalsThatAreNotASessionLossLeaveTheEncoderAlone() {
        let rig = makeRig()
        start(rig)
        for status in [-4, -13, -14] {
            rig.inner.encodeStatus = status
            XCTAssertEqual(encode(rig), status)
        }
        XCTAssertFalse(rig.inner.events.contains("release"))
    }

    func testTheSuccessPathIsUntouched() {
        let rig = makeRig()
        start(rig)
        XCTAssertEqual(encode(rig), 0)
        rig.inner.encodeStatus = 1
        XCTAssertEqual(encode(rig), 1)
        XCTAssertEqual(rig.inner.events, ["encode", "encode"])
        XCTAssertTrue(rig.lines.all.isEmpty)
    }

    #endif
}
