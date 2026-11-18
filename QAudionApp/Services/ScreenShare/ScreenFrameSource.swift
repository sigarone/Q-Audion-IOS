import Foundation
import CoreVideo
import os
#if os(iOS)
import QAudionEngine
#endif

/// Where the frames of this device's own screen share come from. The call code starts, watches and stops the share
/// through this one interface; each source says how its capture is started and when it is over.
enum ScreenFrameSourceKind: Int, Equatable {
    /// The recorder of the app (`RPScreenRecorder`): the windows of the app only. Used below iOS 27.
    case inApp = 1
    /// A broadcast extension, reserved for iOS 16 to 26.
    case broadcast = 2
    /// The system capture of iOS 27 (ScreenCaptureKit): the whole display.
    case systemCapture = 3
}

/// Why a share ended, as the number in the `why=` word of the end line.
enum ScreenShareEndWhy: Int, Equatable {
    /// The call ended.
    case callEnded = 1
    /// The call ended while the capture was starting, and the capture was stopped with it.
    case endedWhileStarting = 2
    /// The call ended before a capture was opened.
    case endedBeforeCapture = 3
    /// The system ended the capture: its own indicator, its own controls, an error it reported.
    case system = 4
    /// The person stopped the share in the app.
    case app = 5
    /// The call was put on hold.
    case hold = 10
    /// The screen is shown on another display: a scene on an external screen appeared during the share.
    case displayAppeared = 11
}

/// What a capture answered when it was asked to stop, and what the check right after found.
struct ScreenCaptureStopReport: Equatable {
    /// The code of the error the system answered with, 0 when it answered without one.
    var errorCode: Int
    /// True when the system still reports a capture after the stop.
    var stillCapturing: Bool
}

/// The pure decisions of the share: which source an OS version uses, the numbers of the capture, the end line.
enum ScreenShareLifecycle {

    /// The first iOS version whose share uses the system capture.
    static let systemCaptureMajor = 27

    /// The long side of a shared frame, in pixels.
    static let maxLongSide = 1280
    /// The frame rate of a shared screen.
    static let framesPerSecond = 15

    /// Whether this build carries the system capture (it needs the iOS 27 SDK).
    static var systemCaptureCompiledIn: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(ScreenCaptureKit)
        return true
        #else
        return false
        #endif
    }

    /// The source for an OS version: the in-app recorder below iOS 27, the system capture from iOS 27. Nil when the OS
    /// needs the system capture and this build has none: the in-app recorder is never used there.
    static func sourceKind(osMajor: Int, systemCaptureCompiledIn: Bool) -> ScreenFrameSourceKind? {
        if osMajor < systemCaptureMajor { return .inApp }
        return systemCaptureCompiledIn ? .systemCapture : nil
    }

    /// The source for this device.
    static func currentKind() -> ScreenFrameSourceKind? {
        sourceKind(osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                   systemCaptureCompiledIn: systemCaptureCompiledIn)
    }

    /// Whether the texts of the share use the words of the system recording (the in-app recorder shows a screen
    /// recording prompt and indicator); the system capture of iOS 27 is a share.
    static func usesRecordingWords(kind: ScreenFrameSourceKind?) -> Bool {
        kind == .inApp
    }

    /// Whether a share may start: not while the screen is already captured (a recording, a mirror) or shown on another
    /// display.
    static func mayStart(screenCaptured: Bool, externalDisplay: Bool) -> Bool {
        !screenCaptured && !externalDisplay
    }

    /// Whether a display that shows the screen ends the share that is running.
    static func displayEndsShare(shareRunning: Bool, externalDisplay: Bool) -> Bool {
        shareRunning && externalDisplay
    }

    /// The code of an error for the log: its own code, and -1 for an error whose code is 0.
    static func errorCode(_ error: Error?) -> Int {
        guard let error else { return 0 }
        let code = (error as NSError).code
        return code == 0 ? -1 : code
    }

    /// The one line of a stop: why it ended, which source, what the system answered, and whether a capture is still
    /// reported after it. Words and numbers only.
    static func endLine(why: ScreenShareEndWhy, kind: ScreenFrameSourceKind, report: ScreenCaptureStopReport?) -> String {
        "vcap capture end=1 why=\(why.rawValue) src=\(kind.rawValue) code=\(report?.errorCode ?? 0) rec=\(report?.stillCapturing == true ? 1 : 0)"
    }

    /// The line of a share that never opened a capture (the call ended first): there was nothing to ask the system.
    static func endLineWithoutCapture(why: ScreenShareEndWhy) -> String {
        "vcap capture end=1 why=\(why.rawValue)"
    }

    /// The size of a shared frame: the long side at most `maxLongSide`, never larger than the display, both sides
    /// even.
    static func outputSize(width: Int, height: Int, maxLongSide: Int = ScreenShareLifecycle.maxLongSide) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (even(maxLongSide * 590 / 1280), even(maxLongSide)) }
        let longSide = max(width, height)
        let scale = longSide > maxLongSide ? Double(maxLongSide) / Double(longSide) : 1
        return (even(Int((Double(width) * scale).rounded())), even(Int((Double(height) * scale).rounded())))
    }

    private static func even(_ value: Int) -> Int { max(2, value - value % 2) }
}

/// The spacing of the frames of a share as a trailing throttle: a frame that comes in before the spacing since the last
/// delivery has elapsed is kept as the pending one (it replaces an older pending frame) and is delivered when the
/// spacing has elapsed, unless a newer frame comes in first. The last frame of a burst is therefore always delivered,
/// and no two deliveries are closer than the spacing. Pure: the caller gives the clock and runs the timer; all calls come
/// from one queue.
struct TrailingFrameThrottle<Frame> {

    enum Decision {
        /// Hand this frame, with its timestamp, to the sinks now.
        case deliver(Frame, Int64)
        /// Nothing to deliver yet: call `flush` at this clock value.
        case wait(until: Int64)
    }

    let spacingNs: Int64
    private var lastDeliveredAt: Int64?
    private var pending: (frame: Frame, timestampNs: Int64)?

    init(spacingNs: Int64) {
        self.spacingNs = spacingNs
    }

    var hasPending: Bool { pending != nil }

    /// A frame comes in at clock value `nowNs`.
    mutating func offer(_ frame: Frame, timestampNs: Int64, nowNs: Int64) -> Decision {
        if let last = lastDeliveredAt, nowNs >= last, nowNs - last < spacingNs {
            pending = (frame, timestampNs)
            return .wait(until: last + spacingNs)
        }
        lastDeliveredAt = nowNs
        pending = nil
        return .deliver(frame, timestampNs)
    }

    /// The timer fired at clock value `nowNs`: the pending frame, when there is one and its time has come.
    mutating func flush(nowNs: Int64) -> Decision? {
        guard let held = pending else { return nil }
        if let last = lastDeliveredAt, nowNs >= last, nowNs - last < spacingNs {
            return .wait(until: last + spacingNs)
        }
        pending = nil
        lastDeliveredAt = nowNs
        return .deliver(held.frame, held.timestampNs)
    }

    /// Forgets the pending frame and the last delivery.
    mutating func reset() {
        pending = nil
        lastDeliveredAt = nil
    }
}

#if os(iOS)
/// A source of screen frames for the share. The members that start and stop run on the main actor; `onFrame` is read
/// on the capture queue of the source, so it is guarded by a lock where it is stored.
@MainActor
protocol ScreenFrameSource: AnyObject {
    var kind: ScreenFrameSourceKind { get }
    /// True while a capture is sending frames.
    var isRunning: Bool { get }
    /// True once the running capture has delivered its first frame.
    var isConfirmed: Bool { get }
    /// The second sink, for the iOS to iOS transport. Frames reach the WebRTC capturer given to `start` as well.
    nonisolated var onFrame: ((CVPixelBuffer, Int64) -> Void)? { get set }
    /// Called once, on the main actor, when the first frame has arrived.
    var onConfirmed: (() -> Void)? { get set }
    /// Called once, on the main actor, when the running capture ends without a call to `stop()`.
    var onEnded: (() -> Void)? { get set }
    /// What the last stop of this source answered, set also when the source stopped by itself because its capture
    /// ended while it was starting. Cleared when a capture starts.
    var lastStopReport: ScreenCaptureStopReport? { get }
    /// Starts the capture and returns once it runs. Throws when it cannot start or ended while starting.
    func start(into capturer: WebRTCPixelBufferCapturer?) async throws
    /// Stops the capture, asks the system what it answered, and checks that the capture is over. Nil when nothing was
    /// capturing.
    func stop() async -> ScreenCaptureStopReport?
}

/// The two places a frame goes: the WebRTC capturer and the WS-HEVC sink. Frames arrive on the capture queue of the
/// source; both places and the closed flag live under one lock, so a frame that arrives after `close()` goes nowhere.
/// A frame that was already handed to a place when `close()` runs may still complete.
final class ScreenFrameSink: @unchecked Sendable {

    private final class WeakCapturer {
        weak var value: WebRTCPixelBufferCapturer?
        init(_ value: WebRTCPixelBufferCapturer?) { self.value = value }
    }

    private struct State {
        var onFrame: ((CVPixelBuffer, Int64) -> Void)?
        var capturer: WeakCapturer?
        var closed = true
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    /// The WS-HEVC sink, readable and writable from any thread.
    var onFrame: ((CVPixelBuffer, Int64) -> Void)? {
        get { state.withLock { $0.onFrame } }
        set { state.withLock { $0.onFrame = newValue } }
    }

    /// Opens the sink for a capture. The capturer is held weakly: the call owns it.
    func open(capturer: WebRTCPixelBufferCapturer?) {
        state.withLock {
            $0.capturer = WeakCapturer(capturer)
            $0.closed = false
        }
    }

    /// Closes the sink: nothing is delivered from here on, and both places are let go.
    func close() {
        state.withLock {
            $0.closed = true
            $0.capturer = nil
            $0.onFrame = nil
        }
    }

    /// Hands a frame to the two places. Returns false when the sink is closed.
    @discardableResult
    func deliver(_ pixelBuffer: CVPixelBuffer, timestampNs: Int64) -> Bool {
        let places = state.withLock { state -> (((CVPixelBuffer, Int64) -> Void)?, WebRTCPixelBufferCapturer?)? in
            guard !state.closed else { return nil }
            return (state.onFrame, state.capturer?.value)
        }
        guard let places else { return false }
        places.0?(pixelBuffer, timestampNs)
        places.1?.push(pixelBuffer, rotation: ._0, timestampNs: timestampNs)
        return true
    }
}
#endif
