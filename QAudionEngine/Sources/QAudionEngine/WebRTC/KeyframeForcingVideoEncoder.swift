import Foundation

/// The log line of the WebRTC video encoder's session recovery, handed to the app's log (`RTLog` in the app). Words and
/// digits only: no id, key or name. Until the app sets a sink the line is printed, which the app's stdout capture
/// records.
public enum EncoderRecoveryLog {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var sink: (@Sendable (String) -> Void)?

    public static func setSink(_ handler: (@Sendable (String) -> Void)?) {
        lock.lock()
        sink = handler
        lock.unlock()
    }

    static func line(_ text: String) {
        lock.lock()
        let handler = sink
        lock.unlock()
        if let handler {
            handler(text)
        } else {
            print(text)
        }
    }
}

#if canImport(WebRTC)
import WebRTC

/// Process-wide coordinator for proactive video key-frame (IDR) emission
/// on the WebRTC RTP rail. Swift mirror of Android's
/// `VideoKeyframeController.kt` (same force-next flag + 5s periodic
/// cadence semantics).
///
/// WIRE_SPEC §8.7 (INT-4a, sender side): the E2EE frame-transform
/// (native RTCFrameCryptor) suppresses libwebrtc's own PLI-driven IDR
/// request on every platform, so a reinitialised / migrated remote
/// decoder starves waiting for a key frame. The receiver nudges us over
/// `video_keyframe_request` / `call_media_ready`; this controller is
/// the sender-side forcing handle those signals flip.
///
/// Why a process-wide singleton and not a per-encoder registry: the
/// encoder instances are created deep inside libwebrtc (via
/// `HevcPreferredVideoEncoderFactory.createEncoder`) and the app layer
/// never holds a reference to them. Android solved the same reachability
/// problem with the process-wide `VideoKeyframeController` object; we
/// mirror it exactly. Calls are strictly 1:1 (one live video encoder at
/// a time), so a process-wide flag is unambiguous.
public final class VideoKeyframeController: @unchecked Sendable {

    public static let shared = VideoKeyframeController()

    /// Periodic key-frame cadence (safety net), ms. Android parity: 5s.
    public let intervalMs: Int64 = 5_000

    private let lock = NSLock()
    private var forceNext = false

    private init() {}

    /// Queue an immediate key frame on the next `encode()` of the live
    /// `KeyframeForcingVideoEncoder`. Thread-safe; callable from any
    /// thread (WS handler, main actor, WebRTC threads).
    public func requestKeyFrame() {
        lock.lock()
        forceNext = true
        lock.unlock()
    }

    /// Consume a pending on-demand request (true at most once per request).
    func consumeForce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let pending = forceNext
        forceNext = false
        return pending
    }
}

/// Transparent `RTCVideoEncoder` decorator that proactively forces key
/// frames (IDRs) so a reinitialised / migrated remote decoder recovers
/// quickly. Swift mirror of Android's `KeyframeForcingVideoEncoder.kt`.
///
/// Every method delegates to `inner`; only `encode(_:codecSpecificInfo:frameTypes:)`
/// is augmented — when a key frame is due it rewrites the per-layer
/// `frameTypes` array to `RTCFrameType.videoFrameKey`, which is exactly
/// how libwebrtc itself requests an IDR from the VideoToolbox encoder on
/// a PLI (`RTCVideoEncoderH265`/`H264` scan `frameTypes` for
/// `RTCFrameTypeVideoFrameKey` and set
/// `kVTEncodeFrameOptionKey_ForceKeyFrame`).
///
/// Unlike Android (where a HW encoder can bypass the Java shim via
/// `createNativeVideoEncoder`), every ObjC `RTCVideoEncoder` on iOS is
/// driven through the `ObjCVideoEncoder` C++ shim, so this wrapper is
/// ALWAYS on the encode hot path — no bypass to guard against.
///
/// Session recovery: the wrapper keeps the settings and core count of the last start, the callback and the last
/// bitrate. When a frame is refused (a negative result code) it releases the inner encoder, starts it again with the
/// saved settings, restores the callback and the bitrate, and makes the next frame a key frame. A rebuild is asked for
/// at most once per `EncodeFailureGate.minRecreateIntervalMs`, only between a successful `startEncode` and `release`,
/// and one log line (`vcap encfail ...`) is written per episode of refused frames.
///
/// Protocol surface mirrored from `sdk/objc/base/RTCVideoEncoder.h`
/// (webrtc-sdk M144).
public final class KeyframeForcingVideoEncoder: NSObject, RTCVideoEncoder {

    /// `WEBRTC_VIDEO_CODEC_OK`; a negative result code is a refusal.
    private static let codecOk = 0
    /// The refusals that mean the session is gone: `WEBRTC_VIDEO_CODEC_ERROR` and `WEBRTC_VIDEO_CODEC_UNINITIALIZED`.
    /// The others (a bad parameter, a request for the software fallback) are for libwebrtc to act on, so the encoder
    /// is left alone for them.
    static let rebuildableStatuses: Set<Int> = [-1, -7]

    private let inner: RTCVideoEncoder
    private let clock: @Sendable () -> Int64
    private let emitLine: @Sendable (String) -> Void
    private let lock = NSLock()
    /// Monotonic ms timestamp of the last key frame we forced (or saw
    /// already requested by libwebrtc). 0 = none yet since init.
    private var lastKeyframeAtMs: Int64 = 0

    /// Held by `startEncode`, `release`, `setCallback`, `setBitrate` and the rebuild, so a rebuild never interleaves
    /// with one of them. Taken before `lock`, never the other way round. `encode` takes it only to rebuild.
    private let sessionLock = NSLock()
    private let recoveryGate = EncodeFailureGate()
    // What a rebuild needs, all guarded by `lock`.
    private var savedSettings: RTCVideoEncoderSettings?
    private var savedCores: Int32 = 0
    private var savedCallback: RTCVideoEncoderCallback?
    private var savedRate: (kbit: UInt32, framerate: UInt32)?

    public convenience init(inner: RTCVideoEncoder) {
        self.init(inner: inner,
                  clock: { KeyframeForcingVideoEncoder.monotonicNowMs() },
                  emitLine: { line in EncoderRecoveryLog.line(line) })
    }

    init(inner: RTCVideoEncoder,
         clock: @escaping @Sendable () -> Int64,
         emitLine: @escaping @Sendable (String) -> Void) {
        self.inner = inner
        self.clock = clock
        self.emitLine = emitLine
        super.init()
    }

    /// Monotonic clock (mirror of Android's SystemClock.elapsedRealtime
    /// use — wall-clock jumps must not fake/starve the periodic cadence).
    private static func monotonicNowMs() -> Int64 {
        return Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    // MARK: - RTCVideoEncoder (delegate everything; augment encode only)

    public func setCallback(_ callback: RTCVideoEncoderCallback?) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        lock.lock()
        savedCallback = callback
        lock.unlock()
        inner.setCallback(callback)
    }

    public func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        lock.lock()
        lastKeyframeAtMs = 0
        savedSettings = settings
        savedCores = numberOfCores
        savedRate = nil
        lock.unlock()
        let status = inner.startEncode(with: settings, numberOfCores: numberOfCores)
        if status == Self.codecOk {
            recoveryGate.arm()
        } else {
            recoveryGate.disarm()
        }
        return status
    }

    public func release() -> Int {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        recoveryGate.disarm()
        return inner.release()
    }

    public func encode(_ frame: RTCVideoFrame,
                       codecSpecificInfo: RTCCodecSpecificInfo?,
                       frameTypes: [NSNumber]) -> Int {
        // Android parity: an empty frameTypes array is passed through
        // untouched (nothing to rewrite).
        guard !frameTypes.isEmpty else {
            return noteEncodeResult(
                inner.encode(frame, codecSpecificInfo: codecSpecificInfo, frameTypes: frameTypes))
        }
        let keyRaw = RTCFrameType.videoFrameKey.rawValue
        let alreadyKey = frameTypes.contains { $0.uintValue == keyRaw }
        // consumeForce() is evaluated UNCONDITIONALLY (before the `||`)
        // so a queued on-demand request is consumed even when the
        // periodic cadence is due anyway — Android parity
        // (`consumeForce() || due`, Kotlin `||` evaluates the left side).
        let forcedRequest = VideoKeyframeController.shared.consumeForce()
        let now = clock()
        lock.lock()
        let due = lastKeyframeAtMs == 0 ||
            now - lastKeyframeAtMs >= VideoKeyframeController.shared.intervalMs
        let force = forcedRequest || due
        if alreadyKey || force {
            lastKeyframeAtMs = now
        }
        lock.unlock()

        let effectiveTypes: [NSNumber]
        if force && !alreadyKey {
            effectiveTypes = Array(repeating: NSNumber(value: keyRaw), count: frameTypes.count)
        } else {
            effectiveTypes = frameTypes
        }
        return noteEncodeResult(
            inner.encode(frame, codecSpecificInfo: codecSpecificInfo, frameTypes: effectiveTypes))
    }

    public func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        lock.lock()
        savedRate = (bitrateKbit, framerate)
        lock.unlock()
        return inner.setBitrate(bitrateKbit, framerate: framerate)
    }

    // MARK: - Session recovery

    /// The result of the inner `encode`: an accepted frame ends the episode, a refused one may rebuild the session.
    /// The result code goes back to libwebrtc unchanged.
    private func noteEncodeResult(_ status: Int) -> Int {
        if status >= Self.codecOk {
            recoveryGate.noteSuccess()
            return status
        }
        let decision = recoveryGate.noteRefusal(rebuildable: Self.rebuildableStatuses.contains(status), nowMs: clock())
        var rebuilt = false
        var rebuildStatus = 0
        if decision.recreate {
            (rebuilt, rebuildStatus) = rebuildSession()
            recoveryGate.noteRecreateResult(succeeded: rebuilt)
        }
        if decision.log {
            emitLine("vcap encfail st=\(status) ask=\(decision.recreate ? 1 : 0) rec=\(rebuilt ? 1 : 0) code=\(rebuildStatus)")
        }
        return status
    }

    /// Releases the inner encoder, starts it again with the saved settings, restores the callback and the last bitrate,
    /// and makes the next frame a key frame. Returns whether the encoder is running again and the status of its start
    /// (0 when nothing was attempted, which is the case once `release` has run or while no callback is set).
    private func rebuildSession() -> (rebuilt: Bool, status: Int) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        lock.lock()
        let settings = savedSettings
        let cores = savedCores
        let callback = savedCallback
        let rate = savedRate
        lock.unlock()
        guard recoveryGate.isArmed, let settings, let callback else { return (false, 0) }
        _ = inner.release()
        let status = inner.startEncode(with: settings, numberOfCores: cores)
        inner.setCallback(callback)
        guard status == Self.codecOk else { return (false, status) }
        if let rate {
            _ = inner.setBitrate(rate.kbit, framerate: rate.framerate)
        }
        lock.lock()
        lastKeyframeAtMs = 0
        lock.unlock()
        return (true, 0)
    }

    public func implementationName() -> String {
        // Android parity: the wrapper is transparent in stats/telemetry —
        // return the inner encoder's name UNCHANGED (Android's
        // KeyframeForcingVideoEncoder does the same; a prefix here would
        // show up in `encoderImplementation` stats and could break any
        // string-matching diagnostics).
        return inner.implementationName()
    }

    public func scalingSettings() -> RTCVideoEncoderQpThresholds? {
        return inner.scalingSettings()
    }

    public var resolutionAlignment: Int { return inner.resolutionAlignment }
    public var applyAlignmentToAllSimulcastLayers: Bool { return inner.applyAlignmentToAllSimulcastLayers }
    public var supportsNativeHandle: Bool { return inner.supportsNativeHandle }
}
#endif
