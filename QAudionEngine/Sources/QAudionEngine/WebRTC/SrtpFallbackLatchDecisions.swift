import Foundation

/// W-FALLBACKLATCH (2026-10-03) — pure decisions that keep the native-audio-srtp
/// fallback latch (`CallService.audioSrtpFallbackActive`) from outliving, or being
/// set after, the call it belongs to. Same seam as `CallerAcceptLatch` /
/// `NativeSenderMuteDecisions`: the real code in `CallService` / `AppState` /
/// `QAudionWebRtcCallController` is a thin wrapper around these functions, so the
/// race has somewhere to be tested without WebRTC, AVAudioSession or CallKit.
///
/// ## The field failure this closes (two iOS devices, 1.0.1206, 2026-10-03)
///
/// 1. The peer hung up. `AppState.endCall` ran `CallService.endCall` first (generation
///    bump, `teardownAudioStack` -> latch reset to `false`) and closed the
///    PeerConnection only afterwards (`sendHangupAndClose`; the audio unit must go off
///    BEFORE the PC closes, W-ADMGATE, so that order is deliberate and stays).
/// 2. In that window the controller's `srtpFallbackTask` (armed by the ICE
///    `.disconnected` the hangup itself caused) fired, and called
///    `CallService.engageAudioSrtpFallback()`, whose only guard was
///    `!audioSrtpFallbackActive`: the latch went `true` again, for a call that no
///    longer existed.
/// 3. The next INCOMING call runs `teardownAudioStack(resetSrtpFallback: false)` at
///    answer time (a ringing-time engage must survive the answer), so the stale
///    latch survived, `NativeSenderMuteDecisions.shouldMute(... fallbackActive: true)`
///    muted the native sender, the legacy engine started on a native call, WebRTC's
///    audio unit never switched on and the callee heard nothing for the whole call.
///
/// Three independent fences, each decided here:
///  * `engageVerdict` — an engage is honoured only for a LIVE call and only for the
///    call generation the callback was wired in;
///  * `latchHonouredAtAnswer` — the latch kept across the answer-time teardown must
///    belong to the call being answered;
///  * the controller-side `callClosed` inputs on `SrtpFallbackDecisions`.
public enum SrtpFallbackLatchDecisions {

    /// Outcome of an engage request. Raw values are the `why=` codes of the
    /// `audiosrtpfb engage=0 why=<n>` log line (numeric only: ships through the
    /// phone-log vocabulary gate with no new word beyond `engage`/`why`).
    public enum EngageVerdict: Int, Equatable {
        /// Honour it: latch the fallback and re-run the audio-I/O chokepoint.
        case engage = 0
        /// The latch is already set (a repeat request) — silent no-op, as before.
        case alreadyActive = 1
        /// No call is live (nothing owns an id any more): a late callback of a call
        /// that already ended.
        case noCallLive = 2
        /// The call generation moved since the callback was wired: the call it was
        /// wired for is over (and possibly another one has started).
        case staleGeneration = 3
    }

    /// Decide whether an engage request may latch the fallback.
    ///
    /// - Parameters:
    ///   - callLive: `CallService` still knows an active call id.
    ///   - capturedGeneration: the call generation read when the engage callback was
    ///     wired (AppState, caller and callee sites). A negative value means "could not
    ///     be proven" (same convention as `RelaySealerInstallGuard`): the generation
    ///     fence is skipped, the liveness fence still applies. Muting a live call is
    ///     worse than the rare stale case this fence closes.
    ///   - currentGeneration: `CallService.currentCallGeneration()` right now.
    ///   - alreadyActive: the latch is already set.
    public static func engageVerdict(
        callLive: Bool,
        capturedGeneration: Int,
        currentGeneration: Int,
        alreadyActive: Bool
    ) -> EngageVerdict {
        guard callLive else { return .noCallLive }
        if capturedGeneration >= 0, capturedGeneration != currentGeneration {
            return .staleGeneration
        }
        return alreadyActive ? .alreadyActive : .engage
    }

    /// What a latch was set FOR. Stored beside the Bool so the answer-time teardown
    /// can tell a ringing-time engage of THIS call from a leftover of another one.
    /// Only the 8-char lowercase prefix of the call id is kept (public-repo and log
    /// hygiene: never a full id).
    public struct LatchTag: Equatable {
        public let generation: Int
        public let callIdPrefix: String?

        public init(generation: Int, callId: String?) {
            self.generation = generation
            if let callId, !callId.isEmpty {
                self.callIdPrefix = String(callId.lowercased().prefix(8))
            } else {
                self.callIdPrefix = nil
            }
        }
    }

    /// Whether a latch found set at answer time may stay set for the call being
    /// answered.
    ///
    /// The call id is the primary key: two different ids are two different calls,
    /// whatever the generation says (an unrelated `endCall` — a busy/offline bounce of
    /// another call — also bumps the generation and must not discard a genuine
    /// ringing-time engage of the call being answered). The generation is the fallback
    /// when either id is unknown. No tag at all (should not happen: every engage sets
    /// one) is not honoured.
    public static func latchHonouredAtAnswer(
        tag: LatchTag?,
        answeringCallId: String?,
        currentGeneration: Int
    ) -> Bool {
        guard let tag else { return false }
        if let latched = tag.callIdPrefix,
           let answering = answeringCallId, !answering.isEmpty {
            return latched == String(answering.lowercased().prefix(8))
        }
        return tag.generation == currentGeneration
    }
}

/// W-FALLBACKLATCH (2026-10-03) — what this side can say LOCALLY about the two ends of
/// a call being on different audio transports (native SRTP vs the sealed
/// DataChannel/WS legacy path). The field case had exactly this shape and nothing in
/// the telemetry said so (`fallback_fired=false`, `suspect_silent=false`).
///
/// Only what one device can see by itself is used: it cannot know the peer's mode
/// directly (the server relays opaque audio and there is no signalling field for it),
/// so the peer's side is inferred from receive evidence.
public enum AudioTransportSplit {

    /// Code shipped as `transport_split` in `call.audio.counts`.
    public enum Code: Int, Equatable {
        /// Nothing observed: the native path carried the call, or the call was legacy
        /// by negotiation on both sides.
        case none = 0
        /// This side ran its legacy engine on a call that negotiated native SRTP
        /// WITHOUT a recorded fallback engage: the sender was muted or the unit never
        /// started, and audio went over the DataChannel only (the field case).
        case localLegacyUnexplained = 1
        /// This side is on native SRTP and received legacy-path audio from the peer
        /// (decoded frames injected into the native playout): the peer is on the other
        /// transport.
        case peerLegacy = 2
        /// Both of the above.
        case both = 3
    }

    /// - Parameters:
    ///   - nativeNegotiated: the call negotiated native SRTP on this side.
    ///   - localLegacyEngineStarted: the manual AVAudioEngine capture/playback path
    ///     ran at some point in the call.
    ///   - fallbackEverEngaged: a legitimate fallback engage was honoured during the
    ///     call (explains a legacy engine on a native call).
    ///   - peerLegacyRxFrames: decoded legacy-path frames this side routed into the
    ///     native playout injector.
    public static func classify(
        nativeNegotiated: Bool,
        localLegacyEngineStarted: Bool,
        fallbackEverEngaged: Bool,
        peerLegacyRxFrames: Int64
    ) -> Code {
        guard nativeNegotiated else { return .none }
        let local = localLegacyEngineStarted && !fallbackEverEngaged
        let peer = peerLegacyRxFrames > 0
        switch (local, peer) {
        case (false, false): return .none
        case (true, false): return .localLegacyUnexplained
        case (false, true): return .peerLegacy
        case (true, true): return .both
        }
    }
}
