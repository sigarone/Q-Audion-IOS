import AVFoundation
import Foundation
import WebRTC

/// Audio session handling for the ring and the ringtone preview, which play outside a call.
///
/// The caller says whether a call is in progress (from the app's call state, never from the session's current
/// category: a stale category says nothing about a call). In a call the session belongs to the call and is not
/// touched at all. Outside a call the category is set under `RTCAudioSession`'s configuration lock, like the other
/// session changes in the app, and `end()` puts the call category back (play-and-record, voice chat), the same
/// state the voice-note player restores, so the next call finds the session as it expects.
///
/// The session is only ever given back if it is still in the category this object set: if a call or a voice note
/// took it meanwhile, it is left exactly as that user configured it.
public final class RingAudioSession {

    /// A category, mode and options, as set or read back.
    public struct Config: Equatable {
        public let category: AVAudioSession.Category
        public let mode: AVAudioSession.Mode
        public let options: AVAudioSession.CategoryOptions
        public init(category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                    options: AVAudioSession.CategoryOptions) {
            self.category = category
            self.mode = mode
            self.options = options
        }
    }

    private var changed = false
    private var applied: Config?
    /// Bumped by every `begin`; a delayed restore only runs for the `begin` it was scheduled for.
    private var generation = 0

    public init() {}

    // MARK: - Pure decisions (tested without an audio device)

    /// The session is still the one this object set (nothing else reconfigured it).
    public static func stillOurs(current: Config, applied: Config?) -> Bool {
        guard let applied else { return false }
        // Options are compared only for ducking: iOS adds options of its own to some categories (ambient mixes).
        return current.category == applied.category && current.mode == applied.mode
            && current.options.contains(.duckOthers) == applied.options.contains(.duckOthers)
    }

    /// What giving the session back does.
    public enum EndAction: Equatable {
        /// Leave the session exactly as it is.
        case none
        /// Deactivate it (so the user's music resumes) but do not reset the category: something else configured it.
        case deactivateOnly
        /// Deactivate it and put the call category back.
        case deactivateAndReset
    }

    /// Never touch the session while a call or ring is in flight or call audio runs. When the session is still the
    /// one this object set, deactivate it and reset the category. When WebRTC pre-warm already put it in the call
    /// category (play-and-record, voice chat), still deactivate it so the user's music resumes, but leave the category.
    /// When another voice feature (a voice note, the voice unlock) has it, leave it alone.
    public static func endAction(callInFlight: Bool, callAudioActive: Bool, stillOurs: Bool,
                                 inCallCategory: Bool) -> EndAction {
        if callInFlight || callAudioActive { return .none }
        if stillOurs { return .deactivateAndReset }
        return inCallCategory ? .deactivateOnly : .none
    }

    /// What a delayed restore does at each look: nothing if a newer `begin` happened, wait while a call or ring is in
    /// flight (up to `attemptsLeft` more looks), otherwise `endAction`.
    public enum RestoreStep: Equatable {
        case drop
        case retry
        case run(EndAction)
    }

    public static func restoreStep(token: Int, currentGeneration: Int, callInFlight: Bool, callAudioActive: Bool,
                                   stillOurs: Bool, inCallCategory: Bool, attemptsLeft: Int) -> RestoreStep {
        guard token == currentGeneration else { return .drop }
        if callInFlight || callAudioActive { return attemptsLeft > 0 ? .retry : .drop }
        return .run(endAction(callInFlight: false, callAudioActive: false, stillOurs: stillOurs,
                              inCallCategory: inCallCategory))
    }

    private static func currentConfig() -> Config {
        let s = AVAudioSession.sharedInstance()
        return Config(category: s.category, mode: s.mode, options: s.categoryOptions)
    }

    /// True while the WebRTC audio session is active, i.e. a call's audio is running.
    public static var isCallAudioActive: Bool { RTCAudioSession.sharedInstance().isActive }

    // MARK: - Session

    /// Prepares playback. `ignoreSilentSwitch` is for the preview, which the user starts on purpose.
    /// `duckOthers` lowers the user's music for a short tone instead of pausing it.
    /// Does nothing in a call. Returns whether the category was changed.
    @discardableResult
    public func begin(inCall: Bool, ignoreSilentSwitch: Bool, duckOthers: Bool = false) -> Bool {
        guard !inCall else { return false }
        generation += 1
        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }
        let category: AVAudioSession.Category = ignoreSilentSwitch ? .playback : .ambient
        let options: AVAudioSession.CategoryOptions = duckOthers ? [.duckOthers] : []
        do {
            try rtc.setCategory(category, mode: .default, options: options)
            applied = Config(category: category, mode: .default, options: options)
            changed = true
        } catch {
            applied = nil
            changed = false
        }
        return changed
    }

    /// A call or its ring is taking the session: leave it alone now and look again after `delay`, and then every 2 s
    /// (for up to 10 minutes) while a call or ring is still in flight. When none is, and no newer `begin` happened,
    /// the session is given back (see `endAction`), so a lowered music does not stay lowered and a declined or missed
    /// ring does not leave the session active.
    public func endAfterCall(delay: TimeInterval = 1.5, isCallActive: @escaping () -> Bool) {
        guard changed, let mine = applied else { return }
        changed = false
        applied = nil
        look(token: generation, mine: mine, after: delay, attemptsLeft: 300, isCallActive: isCallActive)
    }

    private func look(token: Int, mine: Config, after delay: TimeInterval, attemptsLeft: Int,
                      isCallActive: @escaping () -> Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let now = Self.currentConfig()
            let step = Self.restoreStep(token: token, currentGeneration: self.generation,
                                        callInFlight: isCallActive(), callAudioActive: Self.isCallAudioActive,
                                        stillOurs: Self.stillOurs(current: now, applied: mine),
                                        inCallCategory: Self.isCallCategory(now), attemptsLeft: attemptsLeft)
            switch step {
            case .drop: return
            case .retry:
                self.look(token: token, mine: mine, after: 2, attemptsLeft: attemptsLeft - 1, isCallActive: isCallActive)
            case .run(let action): Self.perform(action)
            }
        }
    }

    /// Releases the session if `begin` changed it (see `endAction`).
    public func end(inCall: Bool) {
        guard changed else { return }
        let mine = applied
        changed = false
        applied = nil
        let now = Self.currentConfig()
        Self.perform(Self.endAction(callInFlight: inCall, callAudioActive: Self.isCallAudioActive,
                                    stillOurs: Self.stillOurs(current: now, applied: mine),
                                    inCallCategory: Self.isCallCategory(now)))
    }

    /// Play-and-record with voice chat: the category of a call, which the app also keeps outside calls.
    public static func isCallCategory(_ config: Config) -> Bool {
        config.category == .playAndRecord && config.mode == .voiceChat
    }

    private static func perform(_ action: EndAction) {
        switch action {
        case .none: return
        case .deactivateOnly:
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        case .deactivateAndReset: restoreCallCategory()
        }
    }

    private static func restoreCallCategory() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }
        #if os(iOS) && !targetEnvironment(simulator)
        let options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .interruptSpokenAudioAndMixWithOthers]
        #else
        let options: AVAudioSession.CategoryOptions = [.interruptSpokenAudioAndMixWithOthers]
        #endif
        try? rtc.setCategory(.playAndRecord, mode: .voiceChat, options: options)
    }
}
