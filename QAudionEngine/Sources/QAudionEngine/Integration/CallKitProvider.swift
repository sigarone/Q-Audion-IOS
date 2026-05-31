import Foundation
#if canImport(CallKit) && os(iOS)
@preconcurrency import CallKit
import AVFoundation

public final class CallKitProvider: NSObject, CallKitManaging, CXProviderDelegate, @unchecked Sendable {

    private let provider: CXProvider
    private let controller: CXCallController

    /// W495 — UUIDs for which CallKit rejected reportNewIncomingCall
    /// (Focus/DnD/block-list). When the user taps Answer on the in-app
    /// banner for these calls we bypass CXCallController (which would
    /// also fail) and answer directly, manually activating the audio session.
    private var callKitRejectedUUIDs: Set<UUID> = []
    public var onAnswerCall: ((UUID) async -> Void)?
    public var onEndCall: ((UUID) async -> Void)?
    public var onMutedChanged: ((UUID, Bool) async -> Void)?
    /// W464 — fired when CallKit has activated the shared AVAudioSession.
    /// This is the ONLY safe moment to start `AVAudioEngine` (mic capture
    /// + speaker playback). Starting the engine before this point throws
    /// "Session activation failed" and the call has no audio. AppState
    /// wires this to `CallService.handleAudioSessionActivated()`.
    public var onAudioSessionActivated: (() -> Void)?
    /// W464 — fired when CallKit released the audio session (call ended
    /// or interrupted). AppState wires this to
    /// `CallService.handleAudioSessionDeactivated()`.
    public var onAudioSessionDeactivated: (() -> Void)?

    public override init() {
        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = true
        cfg.maximumCallsPerCallGroup = 1
        cfg.supportedHandleTypes = [.phoneNumber, .generic]
        cfg.iconTemplateImageData = nil
        cfg.ringtoneSound = nil
        self.provider = CXProvider(configuration: cfg)
        self.controller = CXCallController()
        super.init()
        self.provider.setDelegate(self, queue: nil)
    }

    // MARK: - CallKitManaging

    public func reportIncomingCall(uuid: UUID, callerName: String, hasVideo: Bool) async {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.hasVideo = hasVideo
        update.localizedCallerName = callerName
        do {
            try await provider.reportNewIncomingCall(with: uuid, update: update)
        } catch {
            // W478 — log instead of silently dropping. CallKit rejects with:
            //   Code=2 callUUIDAlreadyExists (PushKit+WS duplicate),
            //   Code=3 filteredByDoNotDisturb (Focus / DnD active on device),
            //   Code=4 filteredByBlockList.
            // In ALL these cases the system call UI won't appear, so we arm the
            // in-app ringing banner's manual answer path via callKitRejectedUUIDs.
            // The in-app `callState = .ringing` is set by the caller AFTER this
            // returns, regardless of success/failure, so the user can still
            // answer from the custom banner.
            let nsErr = error as NSError
            print("[CallKitProvider] reportNewIncomingCall rejected (domain=\(nsErr.domain) code=\(nsErr.code)) — arming in-app manual answer path for \(uuid)")
            callKitRejectedUUIDs.insert(uuid)
        }
    }

    public func reportCallEnded(uuid: UUID, reason: CallEndReason) async {
        // W495 — clean up rejected-UUID tracking on call end.
        callKitRejectedUUIDs.remove(uuid)
        let cxReason: CXCallEndedReason
        switch reason {
        case .userEnded: cxReason = .remoteEnded
        case .remoteEnded: cxReason = .remoteEnded
        case .unanswered: cxReason = .unanswered
        case .declined: cxReason = .declinedElsewhere
        case .failed: cxReason = .failed
        }
        provider.reportCall(with: uuid, endedAt: Date(), reason: cxReason)
    }

    public func startOutgoingCall(handle: String, hasVideo: Bool) async throws -> UUID {
        let uuid = UUID()
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: handle))
        action.isVideo = hasVideo
        let txn = CXTransaction(action: action)
        try await controller.request(txn)
        return uuid
    }

    public func reportCallConnected(uuid: UUID) async {
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    public func setMuted(uuid: UUID, isMuted: Bool) async throws {
        let action = CXSetMutedCallAction(call: uuid, muted: isMuted)
        try await controller.request(CXTransaction(action: action))
    }

    public func setOnHold(uuid: UUID, isOnHold: Bool) async throws {
        let action = CXSetHeldCallAction(call: uuid, onHold: isOnHold)
        try await controller.request(CXTransaction(action: action))
    }

    /// W520 — register a call UUID as "suppressed" so that answerCall() uses
    /// the manual audio-session activation path instead of going through
    /// CXCallController. Called for WS foreground incoming calls where we
    /// intentionally skip reportNewIncomingCall to avoid showing the native
    /// iOS phone UI (which looks identical to a plain voice call and would
    /// confuse users who need to distinguish encrypted calls from cleartext).
    public func registerSuppressedCall(_ uuid: UUID) {
        callKitRejectedUUIDs.insert(uuid)
    }

    /// W478 — answer an incoming call via the CallKit CXCallController.
    /// This path is triggered by the in-app answer button; it fires the same
    /// CXAnswerCallAction that the system UI button would fire, ensuring the
    /// `provider(_:perform:CXAnswerCallAction)` delegate callback runs and
    /// transitions the call to `.active` (same as tapping Answer on lock screen).
    ///
    /// W495 — if CallKit previously rejected reportNewIncomingCall for this
    /// UUID (Focus/DnD), CXCallController.request would also fail because
    /// CallKit never registered the call. In that case we fall back to a
    /// direct answer: manually activate AVAudioSession, fire
    /// onAudioSessionActivated, and call onAnswerCall directly — identical
    /// to what CXProviderDelegate would do on a successful CallKit path.
    public func answerCall(uuid: UUID) async throws {
        if callKitRejectedUUIDs.contains(uuid) {
            callKitRejectedUUIDs.remove(uuid)
            // W497 — mirror the EXACT order of CXProviderDelegate callbacks on
            // a normal CallKit answer:
            //   1. provider(_:perform:CXAnswerCallAction) → onAnswerCall (sets up
            //      callIntegration, WebRTC tracks, etc.)
            //   2. provider(_:didActivate:) → onAudioSessionActivated (starts
            //      AVAudioEngine capture/playback)
            //
            // The previous order (activate THEN answer) started the audio engine
            // before callIntegration existed → mic/speaker silent, level bars frozen.
            await onAnswerCall?(uuid)
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [
                    .allowBluetoothHFP,
                    .interruptSpokenAudioAndMixWithOthers
                ]
            )
            try? session.setActive(true)
            onAudioSessionActivated?()
            return
        }
        let action = CXAnswerCallAction(call: uuid)
        try await controller.request(CXTransaction(action: action))
    }

    // MARK: - CXProviderDelegate

    public func providerDidReset(_ provider: CXProvider) {
        // System reset — pending calls are gone.
    }

    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [
                .allowBluetoothHFP,
                .interruptSpokenAudioAndMixWithOthers
            ]
        )
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task {
            await onAnswerCall?(action.callUUID)
            action.fulfill()
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task {
            await onEndCall?(action.callUUID)
            action.fulfill()
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task {
            await onMutedChanged?(action.callUUID, action.isMuted)
            action.fulfill()
        }
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // W464 — keep these options in sync with
        // AudioProcessingPipeline.configureForVoIP(): if CallKit installs
        // a poorer category (e.g. no .defaultToSpeaker) it silently
        // downgrades the routing the app just configured.
        try? audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [
                .allowBluetoothHFP,
                .interruptSpokenAudioAndMixWithOthers
            ]
        )
        try? audioSession.setActive(true)
        // W464 — the session is now active: this is the moment
        // CallService may safely start its AVAudioEngine capture/playback.
        onAudioSessionActivated?()
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // System took the audio session — engine should pause mic capture.
        onAudioSessionDeactivated?()
    }
}
#endif
