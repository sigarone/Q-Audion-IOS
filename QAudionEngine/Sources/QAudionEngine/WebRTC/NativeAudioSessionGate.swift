import AVFoundation
import Foundation
import WebRTC

/// W-ADMNOMANUAL (2026-08-31) — manual audio mode is GONE. This type is kept
/// as an inert seam plus the record of why, because the idea ("CallKit apps
/// should use `RTCAudioSession.useManualAudio`") is superficially right and
/// will otherwise be reintroduced.
///
/// What was tried, and what each attempt measured on a live call:
///
///   1.0.1053  `useManualAudio = true` + `isAudioEnabled` at the gate=4
///             chokepoint. The app's own session configuration stopped being
///             the one in force: `buf=0.02` (the SDK's default) where the app
///             asks for 0.005.
///   1.0.1056  plus the documented `audioSessionDidActivate` relay. Capture
///             died outright — `audioIO capfail=1` appears here for the first
///             time and in every build after, and the in-call session reported
///             `in=` EMPTY, `out=Speaker`.
///   1.0.1066  relay removed, manual mode kept. The route probe caught the
///             moment of death, two `gate=4` lines one second apart:
///                 inp=1 outp=1 rec=1 buf=5     <- correct session
///                 inp=0 outp=1 rec=1 buf=20    <- after isAudioEnabled=true
///             `rec=1` throughout: the microphone is available, it is simply
///             no longer in the route. Enabling the unit is what makes the SDK
///             reconfigure the session out from under the app.
///
/// Both directions of the same mistake: this app configures and activates
/// `AVAudioSession` directly (AudioProcessingPipeline.configureForVoIP,
/// CallKitProvider), which is outside `RTCAudioSession`'s bookkeeping. With
/// the relay the SDK reconfigures; without it the SDK believes the session is
/// inactive and tears it down. Manual mode only has a coherent meaning if the
/// app ALSO routes every session mutation and activation through
/// `RTCAudioSession` under its lock — a much larger change than the one this
/// file attempted, and not one to make blind.
///
/// So: automatic mode, the arrangement that shipped for months and that the
/// telemetry shows with a healthy session (`buf=0.005 vpio=true`, no
/// `capfail`) up to and including 1.0.1052. WebRTC starts its own audio unit
/// when a track is ready, as it always did. The genuine defect 1053 was built
/// to fix — the callee announcing no outbound audio — was a JSEP transceiver
/// problem and is fixed independently by W-PREATTACHMIC.
///
/// Both entry points are deliberately kept and deliberately do nothing, so
/// the call sites keep documenting where the audio unit's lifecycle would be
/// controlled if this is ever revisited WITH the full contract in hand.
public enum NativeAudioSessionGate {

    /// No-op. See the type's note: manual audio mode is not used.
    public static func armManualMode() {}

    /// No-op. WebRTC owns its audio unit's lifecycle in automatic mode.
    public static func setNativeAudioActive(_ active: Bool) {
        _ = active
    }
}
