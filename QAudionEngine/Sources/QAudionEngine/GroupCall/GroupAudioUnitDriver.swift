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

extension GroupAudioUnitDecisions {

    /// How long an owned unit waits for ANY session activation before asking the
    /// app to make one (the group twin of the 1:1 W574b fallback). Covers a group
    /// call CallKit never activates: a foreground accept that fell back to the
    /// direct path, or a cold start whose activation was reported before the
    /// controller existed.
    public static let activationWatchdogSeconds: Double = 2.0

    /// How long after the 1:1 leg ended the driver looks again at who holds the
    /// arm: the 1:1 PeerConnection releases it on its own teardown, which has no
    /// completion signal.
    public static let takeOverRecheckSeconds: Double = 0.6

    /// Whether the activation watchdog must ask the app for a session: the driver
    /// OWNS the unit (a shared unit belongs to the 1:1 leg, whose session is up),
    /// no activation ever arrived and none was requested yet.
    public static func watchdogNeedsActivation(begun: Bool, ownsArm: Bool, sessionActive: Bool, alreadyRequested: Bool) -> Bool {
        begun && ownsArm && !sessionActive && !alreadyRequested
    }

    /// What a session activation does to the unit. Only a unit this driver OWNS is
    /// switched on: while the 1:1 leg still holds the arm (promotion overlap) it is
    /// the 1:1 call's unit (it may have switched it off on purpose, e.g. relay
    /// fallback), and flipping it from here would run two units on one hardware.
    public static func unitMayBeEnabled(ownsArm: Bool) -> Bool { ownsArm }
}

/// What `GroupCallController` needs from the audio unit driver; tests use a fake.
public protocol GroupAudioUnitControlling: AnyObject {
    /// The unit cannot run because no session is active (after a 1:1 call
    /// released it): the app layer activates one and calls `sessionActivated`.
    var onNeedsSessionActivation: (() -> Void)? { get set }
    func begin()
    func sessionActivated(source: AudioSessionActivationSource)
    func sessionDeactivated()
    func oneToOneEnded()
    func end()
}

/// Builds without the WebRTC module (macOS package build): no audio unit.
public final class NoopGroupAudioUnit: GroupAudioUnitControlling {
    public var onNeedsSessionActivation: (() -> Void)?
    public init() {}
    public func begin() {}
    public func sessionActivated(source: AudioSessionActivationSource) {}
    public func sessionDeactivated() {}
    public func oneToOneEnded() {}
    public func end() {}
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
public final class GroupAudioUnitDriver: GroupAudioUnitControlling, @unchecked Sendable {

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
    private var watchdog: DispatchWorkItem?
    /// An activation was already asked of the app for this call (never twice).
    private var activationRequested = false

    public init() {}

    public func begin() {
        lock.lock()
        begun = true
        sessionActive = false
        callKitSeen = false
        activationRequested = false
        lock.unlock()
        if NativeAudioSessionGate.isArmed {
            log?("grpaudio begin=1 shared=1")
            return
        }
        arm()
        log?("grpaudio begin=1 shared=0")
        armActivationWatchdog()
    }

    private func armActivationWatchdog() {
        let item = DispatchWorkItem { [weak self] in self?.activationWatchdogFired() }
        lock.lock()
        watchdog?.cancel()
        watchdog = item
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + GroupAudioUnitDecisions.activationWatchdogSeconds, execute: item)
    }

    private func cancelActivationWatchdog() {
        lock.lock()
        let item = watchdog
        watchdog = nil
        lock.unlock()
        item?.cancel()
    }

    private func activationWatchdogFired() {
        lock.lock()
        let due = GroupAudioUnitDecisions.watchdogNeedsActivation(
            begun: begun, ownsArm: ownsArm, sessionActive: sessionActive, alreadyRequested: activationRequested)
        if due { activationRequested = true }
        watchdog = nil
        lock.unlock()
        guard due else { return }
        log?("grpaudio watchdog=1 noactivation=1")
        onNeedsSessionActivation?()
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
        let owns = ownsArm
        if source == .callKit { callKitSeen = true }
        sessionActive = started
        activationRequested = false
        lock.unlock()
        if started { cancelActivationWatchdog() }
        // Shared unit (promotion overlap): the activation is recorded, the unit is
        // the 1:1 leg's until `oneToOneEnded()` takes it over.
        guard GroupAudioUnitDecisions.unitMayBeEnabled(ownsArm: owns) else {
            log?("grpaudio activated=1 shared=1")
            return
        }
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
        // Whoever released the session re-activates it (CallKit's own `didActivate`,
        // or the app's re-assert): the take-over must not ask for a second one.
        activationRequested = true
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
    /// shared unit down (its PeerConnection released the arm): take it over. The
    /// release has no completion signal and may land after this call, so the
    /// hand-over is looked at again once it has had time to finish (both passes
    /// are idempotent: an arm is only taken when nobody holds it, the unit is only
    /// enabled once, and the app is asked for a session at most once).
    public func oneToOneEnded() {
        takeOver()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + GroupAudioUnitDecisions.takeOverRecheckSeconds) { [weak self] in self?.takeOver() }
    }

    private func takeOver() {
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
        guard NativeAudioSessionGate.isArmed else { return }
        lock.lock()
        let nowOwns = ownsArm && NativeAudioSessionGate.isCurrent(token: token)
        lock.unlock()
        // Still the 1:1 leg's arm (its teardown has not run yet): the recheck follows.
        guard nowOwns else { return }
        if active {
            enable()
        } else {
            lock.lock()
            let needed = !activationRequested
            activationRequested = true
            lock.unlock()
            if needed { onNeedsSessionActivation?() }
        }
    }

    public func end() {
        cancelPendingEnable()
        cancelActivationWatchdog()
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
