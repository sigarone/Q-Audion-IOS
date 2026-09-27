import Foundation

/// W-CALLERUNMUTELOST (2026-09-27) — pure decision seam for the native
/// audio-srtp sender mute/unmute logic, split out so the race this task
/// fixes has somewhere to be tested WITHOUT the WebRTC binary (same
/// pattern as `AcceptGateDecisions` / `NativeAudioUnitGateDecisions`).
///
/// ## The bug this exists for
///
/// The "should the mic be muted" intent used to live ONLY on
/// `QAudionPeerConnection.pendingAudioSrtpMuted`, a property of an object
/// that can be recreated mid-call (a video-upgrade rebuild) or simply not
/// exist yet at the moment a genuine accept fires. Live evidence
/// (2026-09-27, three back-to-back iOS↔iOS calls): `onAnswerCall` ran
/// 150-370 ms BEFORE `QAudionPeerConnection.init` — building it is async
/// (`await fetchIceServers()`, `await sharedFactory(...)`) — finished on
/// another thread. `setNativeAudioSrtpMuted(false)` sent into that gap
/// reached a controller whose `peerConnection` was still `nil`, was
/// silently dropped, and the PeerConnection that showed up a moment later
/// started from its own hardcoded-muted default with nothing left to ever
/// retry the unmute. Both users perceived the call as connected; one mic
/// stayed muted for its entire length.
///
/// ## The fix's two halves
///
/// 1. `shouldMute` folds every reason the sender might need to stay muted
///    into ONE formula, recomputed at every "something changed" event
///    (answer, user mute toggle, SRTP-relay fallback engage/recover, a
///    fresh `PeerConnection`/controller becoming available) instead of
///    being derived from a one-shot command that only fires once and can
///    be lost.
/// 2. `trackEnabledAfterRequest` is the mirror-image safety rule for
///    actually flipping the track's `isEnabled` bit: a MUTE is always
///    safe to apply immediately, but an UNMUTE must wait for the sender
///    FrameCryptor to be confirmed attached (W-AUDIOSENDERGATE) — the
///    track can be pre-attached (W-PREATTACHMIC) well before the cryptor
///    exists, and enabling it in that window would send plaintext mic
///    audio.
///
/// `NativeSenderMuteLatch` glues the two together exactly the way
/// `QAudionWebRtcCallController.nativeSenderMuted` (survives a
/// PeerConnection replacement) and `QAudionPeerConnection
/// .pendingAudioSrtpMuted`/`.nativeSenderCryptorAttached` (survives the
/// track/cryptor not existing yet) do in the real code — that real code is
/// now a thin wrapper around this type's logic.
public enum NativeSenderMuteDecisions {

    /// Whether the native audio-srtp sender should be muted right now.
    ///
    /// - Parameters:
    ///   - peerAnswered: this device's own genuine-accept gate
    ///     (`CallService.peerAnswered`) — `false` while ringing, so a call
    ///     that has not been genuinely accepted yet always stays muted.
    ///   - userMuted: the user's own mute toggle (`CallService.isMuted`).
    ///   - fallbackActive: the SRTP-relay fallback owns the mic right now
    ///     (`CallService.audioSrtpFallbackActive`) — the native sender must
    ///     stay released so it does not contend with the fallback's own
    ///     `AVAudioEngine` capture (W-DEADTXRELEASE).
    public static func shouldMute(peerAnswered: Bool, userMuted: Bool, fallbackActive: Bool) -> Bool {
        !peerAnswered || userMuted || fallbackActive
    }

    /// What a mute/unmute request should do to the actual
    /// `RTCAudioTrack.isEnabled` bit, given whether the sender's
    /// FrameCryptor is confirmed attached yet.
    ///
    /// `nil` means "latch the requested value, do not touch the track" —
    /// the shape needed when an UNMUTE request lands on a track that is
    /// pre-attached but not yet cryptor-confirmed. A MUTE request is
    /// always safe to apply immediately: disabling a track can never leak
    /// plaintext.
    public static func trackEnabledAfterRequest(muted: Bool, senderCryptorAttached: Bool) -> Bool? {
        guard !muted else { return false }
        return senderCryptorAttached ? true : nil
    }

    /// Pairs "what mute state do we want" with "is it safe to apply to a
    /// track right now", mirroring the real split between
    /// `QAudionWebRtcCallController.nativeSenderMuted` and
    /// `QAudionPeerConnection.pendingAudioSrtpMuted`/
    /// `.nativeSenderCryptorAttached`.
    public struct NativeSenderMuteLatch {
        /// The latched intent — what the NEXT thing capable of touching a
        /// track (a cryptor attach, a brand new PeerConnection) should
        /// apply. Defaults to muted, matching every real default in this
        /// codebase (`pendingAudioSrtpMuted`, `nativeSenderMuted`): a call
        /// that never receives an explicit unmute must never be heard.
        public private(set) var wantMuted: Bool
        public private(set) var senderCryptorAttached: Bool

        public init(wantMuted: Bool = true, senderCryptorAttached: Bool = false) {
            self.wantMuted = wantMuted
            self.senderCryptorAttached = senderCryptorAttached
        }

        /// A mute/unmute request arrives (answer, user toggle, fallback
        /// engage/recover, or a controller re-pushing its latched intent
        /// onto a freshly (re)created PeerConnection). Returns the
        /// track-enabled value to apply now, or `nil` to only update the
        /// latch (the request is remembered and will be honoured the
        /// moment `senderCryptorDidAttach()` fires).
        @discardableResult
        public mutating func request(_ muted: Bool) -> Bool? {
            wantMuted = muted
            return NativeSenderMuteDecisions.trackEnabledAfterRequest(
                muted: muted, senderCryptorAttached: senderCryptorAttached)
        }

        /// The sender cryptor just attached (`activateNativeAudioSrtp`
        /// confirmed it). Returns the track-enabled value to apply now —
        /// always non-nil, since the cryptor attaching is exactly the
        /// condition an earlier `request(_:)` may have been waiting on.
        @discardableResult
        public mutating func senderCryptorDidAttach() -> Bool {
            senderCryptorAttached = true
            return !wantMuted
        }

        /// The value a BRAND NEW PeerConnection (a replacement mid-call, or
        /// the very first one) should be told to apply the moment it is
        /// assigned — always the latched intent. Reading this never
        /// resets `senderCryptorAttached`; the CALLER is responsible for
        /// starting a fresh `NativeSenderMuteLatch` (cryptor-attach state
        /// reset to `false`) for the new PeerConnection, since a new one
        /// has a new, not-yet-attached cryptor.
        public var valueForNewPeerConnection: Bool { wantMuted }
    }
}
