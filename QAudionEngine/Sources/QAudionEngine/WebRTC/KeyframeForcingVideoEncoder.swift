import Foundation
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
/// Protocol surface mirrored from `sdk/objc/base/RTCVideoEncoder.h`
/// (webrtc-sdk M144) exactly as the shipping
/// `SFrameVideoEncoderDecorator` (same binary) already conforms to it.
public final class KeyframeForcingVideoEncoder: NSObject, RTCVideoEncoder {

    private let inner: RTCVideoEncoder
    private let lock = NSLock()
    /// Monotonic ms timestamp of the last key frame we forced (or saw
    /// already requested by libwebrtc). 0 = none yet since init.
    private var lastKeyframeAtMs: Int64 = 0

    public init(inner: RTCVideoEncoder) {
        self.inner = inner
        super.init()
    }

    /// Monotonic clock (mirror of Android's SystemClock.elapsedRealtime
    /// use — wall-clock jumps must not fake/starve the periodic cadence).
    private static func nowMs() -> Int64 {
        return Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    // MARK: - RTCVideoEncoder (delegate everything; augment encode only)

    public func setCallback(_ callback: RTCVideoEncoderCallback?) {
        inner.setCallback(callback)
    }

    public func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        lock.lock()
        lastKeyframeAtMs = 0
        lock.unlock()
        return inner.startEncode(with: settings, numberOfCores: numberOfCores)
    }

    public func release() -> Int {
        return inner.release()
    }

    public func encode(_ frame: RTCVideoFrame,
                       codecSpecificInfo: RTCCodecSpecificInfo?,
                       frameTypes: [NSNumber]) -> Int {
        // Android parity: an empty frameTypes array is passed through
        // untouched (nothing to rewrite).
        guard !frameTypes.isEmpty else {
            return inner.encode(frame, codecSpecificInfo: codecSpecificInfo, frameTypes: frameTypes)
        }
        let keyRaw = RTCFrameType.videoFrameKey.rawValue
        let alreadyKey = frameTypes.contains { $0.uintValue == keyRaw }
        // consumeForce() is evaluated UNCONDITIONALLY (before the `||`)
        // so a queued on-demand request is consumed even when the
        // periodic cadence is due anyway — Android parity
        // (`consumeForce() || due`, Kotlin `||` evaluates the left side).
        let forcedRequest = VideoKeyframeController.shared.consumeForce()
        let now = Self.nowMs()
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
        return inner.encode(frame, codecSpecificInfo: codecSpecificInfo, frameTypes: effectiveTypes)
    }

    public func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        return inner.setBitrate(bitrateKbit, framerate: framerate)
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
