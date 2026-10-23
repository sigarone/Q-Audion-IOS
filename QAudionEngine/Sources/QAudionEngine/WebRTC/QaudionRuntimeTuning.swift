import Foundation
#if canImport(WebRTC)
import WebRTC

/// I4 (webrtc-plan.md v2 §3.3, M150 migration, 2026-09-29) — M150-DEPENDENT.
/// Every selector below is the P8 (`rtc_base/qaudion_tuning.{h,cc}`)
/// runtime-tuning API, which exists only in the M150 build this app links
/// (`Package.swift`'s WebRTC binaryTarget, I1); the earlier M144 build
/// (df1011beabae) does not have it and this file does not compile against it.
///
/// This is the ONE file that calls a P8 selector (task instruction: "keep
/// ALL native P8 calls in ONE adapter file per platform so a later rename is
/// a one-file change") — every other file reaches the native API only
/// through the wrappers here, never `RTCPeerConnectionFactory.setQaudion...`
/// directly.
///
/// Selectors verified by READING the actual declarations, not guessed:
/// `sdk/objc/api/peerconnection/RTCPeerConnectionFactory.h` in
/// `E:/DEVKIT/workspace/webrtc-aes256-build` (branch `m150-hardening`,
/// `m150/patches/P8-qaudion-runtime-api.patch`) — the exact names and
/// argument types this task's own instructions require using. Every one is
/// a CLASS method (`+`), so every wrapper below is a `static func`; the ObjC
/// clang importer turns a no-arg `+ (void)foo;`/`+ (NSString *)foo;` into a
/// Swift `class func foo()` / `class func foo() -> String`, NOT a computed
/// property (there is no `@property` in the ObjC declaration) — verified
/// against the actual declaration shape, not the usual Swift-import
/// convention for a property-like getter.
///
/// P8 itself (per the patch's own "Safety" note) is a process-wide,
/// lock-free API: every setter here is safe to call before, at, or during
/// any call, from any thread, and every native setter range-checks/clamps
/// its own input, so nothing this adapter passes it can reach an
/// `RTC_CHECK` or a bad libopus CTL.
public enum QaudionRuntimeTuning {

    /// `+[RTCPeerConnectionFactory setQaudionOpusEncoderComplexity:]`. `-1`
    /// (this app never passes it) means "use the build default" natively;
    /// every call site here passes a real 0...10 value from
    /// `AdaptiveOpusComplexityPolicy`.
    public static func setEncoderComplexity(_ complexity: Int) {
        RTCPeerConnectionFactory.setQaudionOpusEncoderComplexity(complexity)
    }

    /// `+[RTCPeerConnectionFactory setQaudionOpusDecoderComplexity:]`. Only
    /// 5 (deep PLC), 6 (OSCE LACE) and 7 (OSCE NoLACE, also
    /// `kQaudionDefaultDecoderComplexity`) change libopus behavior at this
    /// pinned build — see `AdaptiveOpusDecoderComplexityPolicy` for this
    /// app's own thermal/device-adaptive 7/6/5 policy (owner decision,
    /// 2026-09-29 — supersedes the plan's original "decoder always 5", which
    /// only ever applied to the CUSTOM path; see that policy's own doc for
    /// why the two paths now differ).
    public static func setDecoderComplexity(_ complexity: Int) {
        RTCPeerConnectionFactory.setQaudionOpusDecoderComplexity(complexity)
    }

    /// `+[RTCPeerConnectionFactory setQaudionOpusMinPacketLossPercent:]` —
    /// native P8 FEC floor, clamped 0...20 natively. This app always passes
    /// the plan's aligned constant (10, §3.1); a future remote override
    /// (`calls.opus_min_loss_pct`) changes only the value handed to this
    /// call, never this file.
    public static func setMinPacketLossPercent(_ percent: Int) {
        RTCPeerConnectionFactory.setQaudionOpusMinPacketLossPercent(percent)
    }

    /// `+[RTCPeerConnectionFactory setQaudionOpusEncoderMaxPlaybackRate:]` - an upper bound, in Hz, on the audio
    /// band the native Opus encoder codes (`EncoderBandHint`): 8000 narrowband, 16000 wideband, `-1` for no limit.
    /// It only lowers what the SDP negotiated and leaves bitrate, packet size and CBR alone.
    ///
    /// Reached through the Objective-C runtime instead of a direct call, because the WebRTC binary this app pins
    /// may predate the selector: a build without it answers `false` and nothing happens. Once the pinned binary
    /// carries it, this can become `RTCPeerConnectionFactory.setQaudionOpusEncoderMaxPlaybackRate(hz)`.
    /// The selector takes an `NSInteger`, which is `Int` on every 64-bit target this app builds for.
    @discardableResult
    public static func setEncoderMaxPlaybackRate(_ hz: Int) -> Bool {
        let selector: Selector = NSSelectorFromString("setQaudionOpusEncoderMaxPlaybackRate:")
        let factoryClass: AnyClass = RTCPeerConnectionFactory.self
        guard let method = class_getClassMethod(factoryClass, selector) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, Int) -> Void
        let implementation: IMP = method_getImplementation(method)
        let setter: Setter = unsafeBitCast(implementation, to: Setter.self)
        setter(factoryClass as AnyObject, selector, hz)
        return true
    }

    /// `+[RTCPeerConnectionFactory setQaudionRequireDtlsPqc]` — tighten-only
    /// for the life of the process; there is deliberately no corresponding
    /// "un-require" native call. Owner instruction (2026-09-29): "deve
    /// essere sempre utilizzato AES256 senza compromessi" — this app calls
    /// it unconditionally at the start of every native-audio-srtp call
    /// (`QAudionPeerConnection.init`), not behind any remote flag. A peer
    /// that cannot meet it fails DTLS while its ICE stays healthy, which is
    /// exactly the shape `QAudionWebRtcCallController
    /// .didChangeConnectionState`'s I6 branch routes to the sealed WS relay
    /// instead of ending the call.
    public static func requireDtlsPqc() {
        RTCPeerConnectionFactory.setQaudionRequireDtlsPqc()
    }
}
#endif
