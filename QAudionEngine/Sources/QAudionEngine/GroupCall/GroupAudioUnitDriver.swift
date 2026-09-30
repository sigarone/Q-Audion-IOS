import Foundation
#if canImport(WebRTC)
import WebRTC
#endif

/// Group calls v2 — WHEN WebRTC's audio unit may run for a group call. The same
/// rule as the 1:1 native-SRTP path (`NativeAudioUnitGateDecisions`): only on a
/// session CallKit itself activated, or on one CallKit will never activate, or
/// once CallKit's own `didActivate` has been waited for long enough.
public enum GroupAudioUnitDecisions {

    public enum Action: Equatable, Sendable {
        /// Enable the unit now.
        case enableNow
        /// The app activated the session but CallKit's `didActivate` is still
        /// expected: enable after `NativeAudioUnitGateDecisions.callKitActivationWaitMs`
        /// unless it arrives first.
        case enableAfterCallKitWait
        /// Nothing to do (the group audio has not begun, or no session).
        case ignore
    }

    public static func action(begun: Bool, source: AudioSessionActivationSource, callKitAlreadySeen: Bool) -> Action {
        guard begun, source != .notActivated else { return .ignore }
        switch source {
        case .callKit, .selfManaged:
            return .enableNow
        case .selfExpectingCallKit:
            return callKitAlreadySeen ? .enableNow : .enableAfterCallKitWait
        case .notActivated:
            return .ignore
        }
    }
}

#if canImport(WebRTC)

/// Group calls v2 — the audio unit of a group call, on the ONE audio-session
/// policy of the app: WebRTC's manual audio mode (`NativeAudioSessionGate`), a
/// single `RTCPeerConnectionFactory`/ADM shared with 1:1 calls, CallKit's
/// activation as the trigger.
///
///  * `begin()` arms manual mode, unless a live 1:1 call already holds the arm
///    (a 1:1 -> group promotion, make-before-break): then the running unit is
///    simply shared and this driver does not own it;
///  * `sessionActivated(source:)` enables the unit on the rule above;
///  * `oneToOneEnded()` re-arms and re-enables after the 1:1 call that shared
///    the unit tore it down;
///  * `end()` switches the unit off and releases the arm it owns.
public final class GroupAudioUnitDriver: @unchecked Sendable {

    /// Numeric `admgate` lines go through `NativeAudioSessionGate.log`; this is
    /// the group-specific side channel (ids and numbers only).
    public var log: ((String) -> Void)?
    /// The unit cannot run because no session is active (after a 1:1 call
    /// released it): the app layer activates one and calls `sessionActivated`.
    public var onNeedsSessionActivation: (() -> Void)?

    private let lock = NSLock()
    private var token = 0
    private var ownsArm = false
    private var begun = false
    private var sessionActive = false
    private var callKitSeen = false
    private var pendingEnable: DispatchWorkItem?

    public init() {}

    public func begin() {
        lock.lock()
        begun = true
        sessionActive = false
        callKitSeen = false
        lock.unlock()
        if NativeAudioSessionGate.isArmed {
            log?("grpaudio begin=1 shared=1")
            return
        }
        arm()
        log?("grpaudio begin=1 shared=0")
    }

    private func arm() {
        let newToken = NativeAudioSessionGate.armManualMode()
        lock.lock()
        token = newToken
        ownsArm = true
        lock.unlock()
    }

    public func sessionActivated(source: AudioSessionActivationSource) {
        lock.lock()
        let alreadySeen = callKitSeen
        let started = begun
        if source == .callKit { callKitSeen = true }
        sessionActive = started
        lock.unlock()
        switch GroupAudioUnitDecisions.action(begun: started, source: source, callKitAlreadySeen: alreadySeen) {
        case .enableNow:
            cancelPendingEnable()
            enable()
        case .enableAfterCallKitWait:
            let item = DispatchWorkItem { [weak self] in self?.enable() }
            lock.lock()
            pendingEnable?.cancel()
            pendingEnable = item
            lock.unlock()
            let waitMs = Int(NativeAudioUnitGateDecisions.callKitActivationWaitMs)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(waitMs), execute: item)
        case .ignore:
            break
        }
    }

    public func sessionDeactivated() {
        lock.lock()
        sessionActive = false
        callKitSeen = false
        let owns = ownsArm
        let current = token
        lock.unlock()
        cancelPendingEnable()
        if owns {
            NativeAudioSessionGate.setNativeAudioInactive(
                ifCurrent: current, reason: NativeAudioUnitGateDecisions.ChangeReason.sessionDeactivated.rawValue)
        }
    }

    /// The 1:1 call this group call was promoted from has ended and torn the
    /// shared unit down (its PeerConnection released the arm): take it over.
    public func oneToOneEnded() {
        lock.lock()
        let started = begun
        let owns = ownsArm
        let current = token
        let active = sessionActive
        lock.unlock()
        guard started else { return }
        if !NativeAudioSessionGate.isArmed || (owns && !NativeAudioSessionGate.isCurrent(token: current)) {
            arm()
            log?("grpaudio rearm=1")
        }
        if active {
            enable()
        } else {
            onNeedsSessionActivation?()
        }
    }

    public func end() {
        cancelPendingEnable()
        lock.lock()
        let owns = ownsArm
        let current = token
        begun = false
        sessionActive = false
        ownsArm = false
        token = 0
        lock.unlock()
        guard owns else { return }
        NativeAudioSessionGate.setNativeAudioInactive(
            ifCurrent: current, reason: NativeAudioUnitGateDecisions.ChangeReason.groupEnd.rawValue)
        NativeAudioSessionGate.disarm(token: current)
    }

    private func enable() {
        lock.lock()
        let started = begun
        lock.unlock()
        guard started, NativeAudioSessionGate.isArmed else { return }
        _ = NativeAudioSessionGate.enableNativeAudio(
            reason: NativeAudioUnitGateDecisions.ChangeReason.groupEnable.rawValue)
    }

    private func cancelPendingEnable() {
        lock.lock()
        let item = pendingEnable
        pendingEnable = nil
        lock.unlock()
        item?.cancel()
    }
}

#endif
