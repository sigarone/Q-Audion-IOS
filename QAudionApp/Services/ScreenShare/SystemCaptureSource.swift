#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(ScreenCaptureKit)
import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import os
import QAudionEngine

/// The share on iOS 27: the whole display, captured by the system (ScreenCaptureKit) and delivered to the app, so no
/// extension is involved and frames keep arriving while the app is in the background (the `screen-capture` background
/// mode).
///
/// The person picks "the whole display" in the system picker, which is the only mode it offers here, and the system
/// shows its own indicator for the capture. The app builds one stream from the filter the picker hands over: the long
/// side is at most `ScreenShareLifecycle.maxLongSide`, and the frames that reach the sinks are spaced for 15 frames
/// per second by a trailing throttle (`TrailingFrameThrottle`), so the last frame before the screen goes still is
/// always delivered. A stop from the system (the indicator, its own controls, an error) reaches
/// the delegate and ends the share; a stop from the app asks the stream to stop and checks that the stream is over.
@available(iOS 27.0, *)
@MainActor
final class SystemCaptureSource: NSObject, ScreenFrameSource {

    var kind: ScreenFrameSourceKind { .systemCapture }
    var isRunning: Bool { liveness.phase == .running }
    var isConfirmed: Bool { liveness.phase == .running && liveness.confirmed }

    nonisolated var onFrame: ((CVPixelBuffer, Int64) -> Void)? {
        get { sink.onFrame }
        set { sink.onFrame = newValue }
    }
    var onConfirmed: (() -> Void)?
    var onEnded: (() -> Void)?

    private let sink = ScreenFrameSink()
    private let sampleQueue = DispatchQueue(label: "qaudion.screenshare.system", qos: .userInitiated)
    private var liveness = ScreenShareLiveness()
    private var stream: SCStream?
    private var pickerWaiter: CheckedContinuation<SCContentFilter, Error>?
    private var pickerObserver: PickerObserver?
    /// True once the stream is known to be over: it was stopped from here, or the system reported its end.
    private var streamOver = true
    /// The code of the error the system ended the stream with, 0 when it did not.
    private var systemEndCode = 0
    private(set) var lastStopReport: ScreenCaptureStopReport?
    private var isStopping = false
    /// The spacing of the frames and the timer that delivers a pending one. Used on the sample queue only; the lock
    /// makes the reset from `start()` and `tearDown()` safe.
    private struct Spacing {
        var throttle = TrailingFrameThrottle<CVPixelBuffer>(
            spacingNs: Int64(1_000_000_000 / ScreenShareLifecycle.framesPerSecond))
        var flushScheduled = false
    }
    private let spacing = OSAllocatedUnfairLock<Spacing>(initialState: Spacing())
    // MARK: - ScreenFrameSource

    func start(into capturer: WebRTCPixelBufferCapturer?) async throws {
        if liveness.isActive || isStopping { throw ScreenShareController.ScreenShareError.alreadyRunning }
        sink.open(capturer: capturer)
        systemEndCode = 0
        lastStopReport = nil
        liveness.begin()
        spacing.withLock { $0 = Spacing() }
        let filter: SCContentFilter
        do {
            filter = try await pickFilter()
        } catch {
            liveness.startFailed()
            sink.close()
            throw error
        }
        let configuration = SCStreamConfiguration()
        let size = ScreenShareLifecycle.outputSize(width: Int(filter.contentRect.width * CGFloat(filter.pointPixelScale)),
                                                   height: Int(filter.contentRect.height * CGFloat(filter.pointPixelScale)))
        configuration.width = size.width
        configuration.height = size.height

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            streamOver = false
            stream = newStream
            try await newStream.startCapture()
        } catch {
            streamOver = true
            stream = nil
            liveness.startFailed()
            sink.close()
            throw ScreenShareController.ScreenShareError.captureFailed(error)
        }
        // An end that arrived while the stream was starting stops it here: the caller never sees a running capture.
        if liveness.startCompleted(now: ProcessInfo.processInfo.systemUptime, isRecording: !streamOver) != nil {
            _ = await tearDown()
            throw ScreenShareController.ScreenShareError.notRunning
        }
    }

    @discardableResult
    func stop() async -> ScreenCaptureStopReport? {
        // A stop while the picker is up ends the wait, so the start does not stay suspended.
        pickerAnswered(.failure(ScreenShareController.ScreenShareError.notRunning))
        guard liveness.phase == .running || liveness.phase == .ended, !isStopping else { return nil }
        isStopping = true
        defer { isStopping = false }
        onEnded = nil
        onConfirmed = nil
        return await tearDown()
    }

    // MARK: - Private

    /// Presents the system picker, which offers the whole display on iOS, and waits for the filter of the person's choice.
    private func pickFilter() async throws -> SCContentFilter {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = false
        picker.defaultConfiguration = configuration
        let observer = PickerObserver(owner: self)
        pickerObserver = observer
        picker.add(observer)
        picker.isActive = true
        defer {
            picker.remove(observer)
            picker.isActive = false
            pickerObserver = nil
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SCContentFilter, Error>) in
            pickerWaiter = continuation
            picker.present()
        }
    }

    fileprivate func pickerAnswered(_ result: Result<SCContentFilter, Error>) {
        guard let waiter = pickerWaiter else { return }
        pickerWaiter = nil
        waiter.resume(with: result)
    }

    /// Stops the stream, closes the sink first so nothing is delivered from here on, and reports what the system
    /// answered. A stream that is not known to be over afterwards is reported as still capturing.
    private func tearDown() async -> ScreenCaptureStopReport {
        liveness.reset()
        sink.close()
        // The pending frame is dropped with the stop.
        spacing.withLock { $0 = Spacing() }
        var code = 0
        if let stream, !streamOver {
            do {
                try await stream.stopCapture()
                streamOver = true
            } catch {
                code = ScreenShareLifecycle.errorCode(error)
            }
        }
        let still = !streamOver
        if !still { stream = nil }
        if code == 0 { code = systemEndCode }
        let report = ScreenCaptureStopReport(errorCode: code, stillCapturing: still)
        lastStopReport = report
        return report
    }

    /// The system ended the stream (its indicator, its own controls, an error): the share ends once.
    fileprivate func systemEnded(code: Int) {
        streamOver = true
        systemEndCode = code
        guard liveness.end(.error) else { return }
        onEnded?()
    }

    fileprivate func noteFrame() {
        guard liveness.frame(now: ProcessInfo.processInfo.systemUptime) else { return }
        onConfirmed?()
    }

    /// One sample of the stream, on the sample queue: only complete frames of the screen carry an image.
    fileprivate nonisolated func handle(sample: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sample), let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           SCFrameStatus(rawValue: raw) != .complete {
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let nanos = Int64(CMTimeGetSeconds(pts) * 1_000_000_000)
        let now = Self.nowNs()
        nonisolated(unsafe) let frame = pixelBuffer
        let decision = spacing.withLock { $0.throttle.offer(frame, timestampNs: nanos, nowNs: now) }
        act(on: decision, now: now)
    }

    private nonisolated static func nowNs() -> Int64 {
        Int64(clamping: DispatchTime.now().uptimeNanoseconds)
    }

    /// Delivers a frame that is due, or arms the one timer that delivers the pending frame when its time has come.
    private nonisolated func act(on decision: TrailingFrameThrottle<CVPixelBuffer>.Decision, now: Int64) {
        switch decision {
        case .deliver(let pixelBuffer, let nanos):
            guard sink.deliver(pixelBuffer, timestampNs: nanos) else { return }
            Task { @MainActor [weak self] in self?.noteFrame() }
        case .wait(let until):
            let arm = spacing.withLock { state -> Bool in
                guard !state.flushScheduled else { return false }
                state.flushScheduled = true
                return true
            }
            guard arm else { return }
            let delay = max(0, until - now)
            sampleQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) { [weak self] in self?.flushPending() }
        }
    }

    /// The timer of the pending frame, on the sample queue.
    private nonisolated func flushPending() {
        let now = Self.nowNs()
        let decision = spacing.withLock { state -> TrailingFrameThrottle<CVPixelBuffer>.Decision? in
            state.flushScheduled = false
            return state.throttle.flush(nowNs: now)
        }
        if let decision { act(on: decision, now: now) }
    }
}

@available(iOS 27.0, *)
extension SystemCaptureSource: SCStreamOutput, SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        handle(sample: sampleBuffer)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let code = ScreenShareLifecycle.errorCode(error)
        Task { @MainActor [weak self] in self?.systemEnded(code: code) }
    }
}

/// Receives the answer of the system picker and passes it to the source.
@available(iOS 27.0, *)
private final class PickerObserver: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    private weak var owner: SystemCaptureSource?

    init(owner: SystemCaptureSource) {
        self.owner = owner
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [owner] in owner?.pickerAnswered(.success(filter)) }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [owner] in owner?.pickerAnswered(.failure(ScreenShareController.ScreenShareError.notRunning)) }
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [owner] in owner?.pickerAnswered(.failure(ScreenShareController.ScreenShareError.captureFailed(error))) }
    }
}
#endif
