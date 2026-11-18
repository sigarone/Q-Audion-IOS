import XCTest
import CoreVideo
@testable import QAudionApp

/// The pure decisions of the screen share: which source an OS version uses, the numbers of the capture, the end line
/// and the sink that hands frames to the two transports.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-ci.yml`.
final class ScreenShareLifecycleTests: XCTestCase {

    func test_theSourceFollowsTheOsVersion() {
        for major in [16, 17, 18, 26] {
            for compiledIn in [false, true] {
                XCTAssertEqual(ScreenShareLifecycle.sourceKind(osMajor: major, systemCaptureCompiledIn: compiledIn), .inApp)
            }
        }
        for major in [27, 28] {
            XCTAssertEqual(ScreenShareLifecycle.sourceKind(osMajor: major, systemCaptureCompiledIn: true), .systemCapture)
            XCTAssertNil(ScreenShareLifecycle.sourceKind(osMajor: major, systemCaptureCompiledIn: false),
                         "the in-app recorder is never the source from iOS 27")
        }
    }

    func test_theTextsUseTheWordsOfTheCaptureThatIsUsed() {
        XCTAssertTrue(ScreenShareLifecycle.usesRecordingWords(kind: .inApp))
        XCTAssertFalse(ScreenShareLifecycle.usesRecordingWords(kind: .systemCapture))
        XCTAssertFalse(ScreenShareLifecycle.usesRecordingWords(kind: nil))
    }

    func test_theEndLineCarriesWhySourceAnswerAndTheCheck() {
        XCTAssertEqual(
            ScreenShareLifecycle.endLine(why: .app, kind: .inApp, report: ScreenCaptureStopReport(errorCode: 0, stillCapturing: false)),
            "vcap capture end=1 why=5 src=1 code=0 rec=0")
        XCTAssertEqual(
            ScreenShareLifecycle.endLine(why: .system, kind: .systemCapture, report: ScreenCaptureStopReport(errorCode: -3821, stillCapturing: true)),
            "vcap capture end=1 why=4 src=3 code=-3821 rec=1")
        XCTAssertEqual(
            ScreenShareLifecycle.endLine(why: .hold, kind: .inApp, report: nil),
            "vcap capture end=1 why=10 src=1 code=0 rec=0")
        XCTAssertEqual(ScreenShareLifecycle.endLineWithoutCapture(why: .endedBeforeCapture), "vcap capture end=1 why=3")
        XCTAssertEqual(ScreenShareLifecycle.endLineWithoutCapture(why: .callEnded), "vcap capture end=1 why=1")
    }

    func test_theWhyCodesAreStable() {
        XCTAssertEqual([ScreenShareEndWhy.callEnded, .endedWhileStarting, .endedBeforeCapture, .system, .app, .hold,
                        .displayAppeared].map(\.rawValue),
                       [1, 2, 3, 4, 5, 10, 11])
    }

    func test_aShareDoesNotStartOverACaptureOrAnotherDisplay() {
        XCTAssertTrue(ScreenShareLifecycle.mayStart(screenCaptured: false, externalDisplay: false))
        XCTAssertFalse(ScreenShareLifecycle.mayStart(screenCaptured: true, externalDisplay: false))
        XCTAssertFalse(ScreenShareLifecycle.mayStart(screenCaptured: false, externalDisplay: true))
        XCTAssertFalse(ScreenShareLifecycle.mayStart(screenCaptured: true, externalDisplay: true))
    }

    func test_aDisplayEndsOnlyAShareThatIsRunning() {
        XCTAssertTrue(ScreenShareLifecycle.displayEndsShare(shareRunning: true, externalDisplay: true))
        XCTAssertFalse(ScreenShareLifecycle.displayEndsShare(shareRunning: true, externalDisplay: false))
        XCTAssertFalse(ScreenShareLifecycle.displayEndsShare(shareRunning: false, externalDisplay: true))
        XCTAssertEqual(ScreenShareLifecycle.endLineWithoutCapture(why: .displayAppeared), "vcap capture end=1 why=11")
    }

    /// A burst ends with its last frame delivered, a newer frame replaces a pending one, and no two deliveries are
    /// closer than the spacing.
    func test_theTrailingThrottleDeliversTheLastFrameOfABurst() {
        var throttle = TrailingFrameThrottle<Int>(spacingNs: 100)
        var delivered: [(frame: Int, at: Int64)] = []
        func apply(_ decision: TrailingFrameThrottle<Int>.Decision?, at now: Int64) -> Int64? {
            switch decision {
            case .deliver(let frame, _)?:
                delivered.append((frame, now))
                return nil
            case .wait(let until)?:
                return until
            case nil:
                return nil
            }
        }
        XCTAssertNil(apply(throttle.offer(1, timestampNs: 0, nowNs: 0), at: 0))
        XCTAssertEqual(apply(throttle.offer(2, timestampNs: 30, nowNs: 30), at: 30), 100)
        XCTAssertEqual(apply(throttle.offer(3, timestampNs: 60, nowNs: 60), at: 60), 100, "a newer frame replaces the pending one")
        XCTAssertTrue(throttle.hasPending)
        XCTAssertEqual(apply(throttle.flush(nowNs: 99), at: 99), 100, "a timer that fires early waits")
        XCTAssertNil(apply(throttle.flush(nowNs: 100), at: 100))
        XCTAssertEqual(delivered.map(\.frame), [1, 3])
        XCTAssertNil(apply(throttle.flush(nowNs: 100), at: 100), "nothing is delivered twice")

        // A frame that is due when it comes in goes out at once and clears a pending one.
        XCTAssertEqual(apply(throttle.offer(4, timestampNs: 120, nowNs: 120), at: 120), 200)
        XCTAssertNil(apply(throttle.offer(5, timestampNs: 210, nowNs: 210), at: 210))
        XCTAssertFalse(throttle.hasPending)
        XCTAssertNil(apply(throttle.flush(nowNs: 220), at: 220))
        XCTAssertEqual(delivered.map(\.frame), [1, 3, 5])

        // The stop drops the pending frame.
        XCTAssertEqual(apply(throttle.offer(6, timestampNs: 230, nowNs: 230), at: 230), 310)
        throttle.reset()
        XCTAssertFalse(throttle.hasPending)
        XCTAssertNil(apply(throttle.flush(nowNs: 400), at: 400))
        XCTAssertEqual(delivered.map(\.frame), [1, 3, 5])
    }

    func test_theTrailingThrottleKeepsTheSpacingAndEndsOnTheLastFrame() {
        let spacing: Int64 = 100
        var throttle = TrailingFrameThrottle<Int>(spacingNs: spacing)
        var delivered: [(frame: Int, at: Int64)] = []
        var timer: Int64?
        func take(_ decision: TrailingFrameThrottle<Int>.Decision?, at now: Int64) {
            switch decision {
            case .deliver(let frame, _)?: delivered.append((frame, now))
            case .wait(let until)?: if timer == nil { timer = until }
            case nil: break
            }
        }
        // Frames every 13 ticks from 0 to 650, with the timer of the pending frame run in between.
        var now: Int64 = 0
        var frame = 0
        let lastFrameAt: Int64 = 650
        while now <= lastFrameAt || timer != nil {
            let nextFrame: Int64? = now <= lastFrameAt ? now : nil
            if let due = timer, nextFrame == nil || due <= nextFrame! {
                now = due
                timer = nil
                take(throttle.flush(nowNs: now), at: now)
                continue
            }
            if let at = nextFrame {
                take(throttle.offer(frame, timestampNs: at, nowNs: at), at: at)
                frame += 1
                now = at + 13
            }
        }
        XCTAssertEqual(delivered.last?.frame, frame - 1, "the last frame of the burst is delivered")
        for pair in zip(delivered, delivered.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.at - pair.0.at, spacing)
        }
        XCTAssertFalse(throttle.hasPending)
    }

    func test_anErrorCodeForTheLog() {
        XCTAssertEqual(ScreenShareLifecycle.errorCode(nil), 0)
        XCTAssertEqual(ScreenShareLifecycle.errorCode(NSError(domain: "x", code: -5807)), -5807)
        XCTAssertEqual(ScreenShareLifecycle.errorCode(NSError(domain: "x", code: 0)), -1, "an error is never logged as no error")
    }

    func test_theFrameSizeKeepsTheLongSideAtMost1280AndBothSidesEven() {
        XCTAssertEqual(ScreenShareLifecycle.maxLongSide, 1280)
        XCTAssertEqual(ScreenShareLifecycle.framesPerSecond, 15)
        // A portrait phone display and a large tablet display, shrunk.
        var size = ScreenShareLifecycle.outputSize(width: 1290, height: 2796)
        XCTAssertEqual(size.height, 1280)
        XCTAssertEqual(size.width, 590)
        size = ScreenShareLifecycle.outputSize(width: 2752, height: 2064)
        XCTAssertEqual(size.width, 1280)
        XCTAssertEqual(size.height, 960)
        // A display that is already small is not scaled up, and odd sizes are made even.
        size = ScreenShareLifecycle.outputSize(width: 641, height: 1001)
        XCTAssertEqual(size.width, 640)
        XCTAssertEqual(size.height, 1000)
        // No size known: the portrait default.
        size = ScreenShareLifecycle.outputSize(width: 0, height: 0)
        XCTAssertEqual(size.height, 1280)
        XCTAssertEqual(size.width % 2, 0)
    }

    #if os(iOS)

    private func makePixelBuffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA, nil, &buffer)
        return buffer!
    }

    func test_theSinkDeliversOnlyWhileOpen() {
        let sink = ScreenFrameSink()
        var received = 0
        sink.onFrame = { _, _ in received += 1 }
        XCTAssertFalse(sink.deliver(makePixelBuffer(), timestampNs: 1), "closed until a capture opens it")

        sink.open(capturer: nil)
        XCTAssertTrue(sink.deliver(makePixelBuffer(), timestampNs: 2))
        XCTAssertEqual(received, 1)

        sink.close()
        XCTAssertFalse(sink.deliver(makePixelBuffer(), timestampNs: 3))
        XCTAssertEqual(received, 1)
        XCTAssertNil(sink.onFrame, "closing lets go of the transport")
    }

    func test_aSinkThatIsOpenedAgainStartsClean() {
        let sink = ScreenFrameSink()
        var received = 0
        sink.open(capturer: nil)
        sink.onFrame = { _, _ in received += 1 }
        sink.close()

        sink.open(capturer: nil)
        sink.deliver(makePixelBuffer(), timestampNs: 1)

        XCTAssertEqual(received, 0, "the sink of the earlier capture is gone")
    }

    func test_theSinkIsSafeFromTheCaptureQueueWhileTheMainActorChangesIt() {
        let sink = ScreenFrameSink()
        sink.open(capturer: nil)
        let buffer = makePixelBuffer()
        let queue = DispatchQueue(label: "test.capture")
        let group = DispatchGroup()
        for index in 0..<200 {
            group.enter()
            queue.async {
                sink.deliver(buffer, timestampNs: Int64(index))
                group.leave()
            }
            if index % 10 == 0 { sink.onFrame = { _, _ in } }
            if index == 100 { sink.close() }
        }
        group.wait()
        XCTAssertFalse(sink.deliver(buffer, timestampNs: 0))
    }

    #endif
}
