import Foundation

/// The single entry point of the effect and its small state machine: one scene running, at most `maxQueue` waiting,
/// everything beyond that shows its result at once.
///
/// Contract with the rest of the app:
/// - `play` is called AFTER the real cipher produced its result. It receives two strings and the outcome the cipher
///   already computed; it has no access to keys, nonces or any crypto state and never calls back into them.
/// - It never blocks and never throws: any inconsistency disables the effect for the session and the caller simply keeps
///   showing the normal text (`EnigmaAdmission.immediate`).
/// - It keeps no copy of any text once a scene ends (the strings are dropped), and nothing runs while it is idle.
///
/// Not thread-safe: it is driven from the main thread (the display link of the chat screen).
public final class EnigmaEffect {
    public static let maxQueue: Int = 3
    /// Stalls (a held-back row whose scene never came) after which the effect is off for the session.
    public static let maxStalls: Int = 2
    /// Longest time a scene may wait behind the ones already running or queued: the sum of the full durations of the running
    /// scene, the queued ones and the new one must not exceed this, otherwise the new message shows its result at once. Keeps a
    /// burst coherent now that scenes are long (a queued row shows its plain text until its turn). About three typical scenes
    /// (30 characters: send 3610 ms, receive 2640 ms; two longest sends, 2 x 5800 ms, still fit). Was 11_000 before the
    /// scenes were lengthened; same value as Android.
    public static let maxBacklogMs: Int64 = 12_000
    public static let fullIntervalMs: Int64 = 33
    public static let liteIntervalMs: Int64 = 66
    /// Display jitter allowance so a 32.9 ms gap still counts as a 33 ms frame.
    private static let toleranceMs: Int64 = 3
    private static let nanosPerMs: Int64 = 1_000_000

    private final class Entry {
        let id: String
        var scene: EnigmaScene?
        let seed: UInt64
        let totalMs: Int64

        init(id: String, scene: EnigmaScene?, seed: UInt64) {
            self.id = id
            self.scene = scene
            self.seed = seed
            self.totalMs = scene?.totalMs ?? 0
        }

        func release() { scene = nil }
    }

    public let governor: EnigmaGovernor
    private let environment: () -> EnigmaEnvironment
    private let seedSource: () -> UInt64
    private let maxQueue: Int

    // ---- configuration ------------------------------------------------------------------------------------------

    private var flagOn = false
    private var userLevel: EnigmaLevel = .off

    // ---- observable state (read by the screen after each onFrame) ------------------------------------------------

    /// The row whose bubble is currently drawn by the effect, or nil.
    public private(set) var activeId: String?
    /// The one string of the current frame.
    public private(set) var frameText: String = ""
    /// Overall progress 0...1 of the running scene.
    public private(set) var progress: Double = 0
    /// Revealed units of the current phase.
    public private(set) var reveal: Int = 0
    /// Continuous advance index of the whole scene: the only input of the decorative drums (see `EnigmaRotors`).
    public private(set) var rotorIndex: Double = 0
    /// The level the running scene is drawn at (full draws the rotors and the bar).
    public private(set) var runLevel: EnigmaLevel = .off
    public private(set) var labelKind: EnigmaLabelKind = .sealed
    public private(set) var packetBytes: Int = 0
    /// True once an inconsistency was caught: the effect stays off until the process restarts.
    public private(set) var disabled: Bool = false
    /// Times a received row was held back for a scene that never came (see `noteStall`).
    public private(set) var stalls: Int = 0

    public var hasWork: Bool { activeId != nil }

    /// Number of scenes holding strings (running + queued): 0 when idle.
    public var retainedScenes: Int { (activeId != nil ? 1 : 0) + queue.count }

    /// Number of scenes waiting behind the running one.
    public var queuedCount: Int { queue.count }

    private var active: Entry?
    private var queue: [Entry] = []
    private var startNanos: Int64 = -1
    private var lastFrameNanos: Int64 = -1
    private var lastRenderNanos: Int64 = -1
    private var frameIndex = 0
    private var builder = ""
    private var info = EnigmaFrameInfo()

    /// Whether the row `id` is still visible, asked when a queued scene is about to start.
    public var isVisible: (String) -> Bool = { _ in true }

    public init(
        environment: @escaping () -> EnigmaEnvironment,
        seedSource: @escaping () -> UInt64 = { UInt64.random(in: UInt64.min...UInt64.max) },
        governor: EnigmaGovernor = EnigmaGovernor(),
        maxQueue: Int = EnigmaEffect.maxQueue
    ) {
        self.environment = environment
        self.seedSource = seedSource
        self.governor = governor
        self.maxQueue = max(0, maxQueue)
    }

    // ---- API ------------------------------------------------------------------------------------------------------

    /// The user's choice (already off when the feature flag is off). A change gives the governor its full cap back.
    public func configure(flagOn: Bool, userLevel: EnigmaLevel) {
        let changed = flagOn != self.flagOn || userLevel != self.userLevel
        self.flagOn = flagOn
        self.userLevel = userLevel
        if changed {
            governor.resetCap()
            if !flagOn || userLevel == .off { cancelAll() }
        }
    }

    /// The level a scene would run at right now.
    public func currentLevel() -> EnigmaLevel {
        EnigmaPolicy.effective(flagOn: flagOn, user: userLevel, governorCap: governor.cap, env: environment())
    }

    /// Whether a scene could start now: the effect is not disabled and the effective level is not off. A received row is
    /// held back only when this is true, so with the effect off (setting, governor, Reduce Motion) nothing is ever hidden.
    public func wouldAnimate() -> Bool {
        !disabled && currentLevel() != .off
    }

    /// A received row was held back for a scene and the scene never came within the time limit. The row is shown normally
    /// at once (the caller's job); a second time means something is wrong with the hand-off and the effect is switched off
    /// for the session, so a bug of the decoration can never keep costing the user a message.
    public func noteStall() {
        stalls += 1
        if stalls >= EnigmaEffect.maxStalls { disableForSession() }
    }

    /// An inconsistency was caught outside the effect (the screen side): same fail-safe as one inside.
    public func reportFailure() {
        disableForSession()
    }

    /// Plays the effect for the row `id`. `from` and `to` are plain -> cipher for `.send` and cipher -> plain for
    /// `.receive`; `result` is the verdict the cipher already reached. `visible` tells whether the row is on screen with
    /// the chat in front.
    ///
    /// Returns `.immediate` when nothing will be animated: the caller then shows the normal text.
    @discardableResult
    public func play(
        id: String,
        direction: EnigmaDirection,
        from: String,
        to: String,
        result: EnigmaResult,
        visible: Bool = true
    ) -> EnigmaAdmission {
        if disabled { return .immediate }
        // A failed verification never gets a scene (and so never a "verified" label).
        guard case .ok = result else { return .immediate }
        if !visible || from.isEmpty || to.isEmpty { return .immediate }
        if id == activeId || queue.contains(where: { $0.id == id }) { return .immediate }
        let level = currentLevel()
        if level == .off { return .immediate }
        if active != nil && queue.count >= maxQueue { return .immediate }
        guard let scene = EnigmaScene.build(direction: direction, from: from, to: to, result: result) else {
            return .immediate
        }
        let entry = Entry(id: id, scene: scene, seed: seedSource())
        if active == nil {
            begin(entry, level: level)
            return .active
        }
        // A burst degrades by time as well as by count: scenes are long, so what would wait too long shows at once.
        var backlogMs: Int64 = (active?.totalMs ?? 0) + entry.totalMs
        for waiting in queue { backlogMs += waiting.totalMs }
        if backlogMs > EnigmaEffect.maxBacklogMs { return .immediate }
        queue.append(entry)
        return .queued
    }

    /// Advances the running scene to the frame time `nowNanos` (a display link callback). Returns true when something the
    /// screen shows changed. Intervals between calls feed the governor (normalized by the display's own nominal interval,
    /// `nominalFrameMs`); a new frame is drawn only every 33 ms (full) or 66 ms (lite).
    @discardableResult
    public func onFrame(nowNanos: Int64, nominalFrameMs: Double = EnigmaGovernor.referenceFrameMs) -> Bool {
        guard let entry = active else { return false }
        if lastFrameNanos >= 0 {
            let dtMs = Double(nowNanos - lastFrameNanos) / 1_000_000.0
            let judged = EnigmaGovernor.normalizedInterval(dtMs: dtMs, nominalMs: nominalFrameMs)
            switch governor.onFrameInterval(judged) {
            case .abortAndDegrade:
                finishActive()
                return true
            case .degraded:
                runLevel = EnigmaLevel.lowest(runLevel, governor.cap)
            case .ok:
                break
            }
        }
        lastFrameNanos = nowNanos
        runLevel = EnigmaLevel.lowest(runLevel, governor.cap)
        if runLevel == .off {
            finishActive()
            return true
        }
        if startNanos < 0 { startNanos = nowNanos }
        let elapsedMs = (nowNanos - startNanos) / EnigmaEffect.nanosPerMs
        guard let scene = entry.scene, elapsedMs < scene.totalMs else {
            finishActive()
            return true
        }
        let intervalMs = runLevel == .full ? EnigmaEffect.fullIntervalMs : EnigmaEffect.liteIntervalMs
        if lastRenderNanos >= 0 && (nowNanos - lastRenderNanos) / EnigmaEffect.nanosPerMs < intervalMs - EnigmaEffect.toleranceMs {
            return false
        }
        lastRenderNanos = nowNanos
        draw(entry, scene: scene, elapsedMs: elapsedMs)
        return true
    }

    /// The app left the foreground, the chat closed or the setting went off: show every result now.
    public func cancelAll() {
        active?.release()
        active = nil
        for entry in queue { entry.release() }
        queue.removeAll()
        clearObservable()
    }

    /// Governor notice, true once per setting change.
    public func takeDegradeNotice() -> Bool {
        governor.takeNotice()
    }

    // ---- internals --------------------------------------------------------------------------------------------------

    private func begin(_ entry: Entry, level: EnigmaLevel) {
        active = entry
        activeId = entry.id
        runLevel = level
        startNanos = -1
        lastFrameNanos = -1
        lastRenderNanos = -1
        frameIndex = 0
        governor.clearWindow()
        guard let scene = entry.scene else { return }
        labelKind = scene.labelKind
        packetBytes = scene.packetBytes
        draw(entry, scene: scene, elapsedMs: 0)
    }

    private func draw(_ entry: Entry, scene: EnigmaScene, elapsedMs: Int64) {
        scene.render(
            elapsedMs: elapsedMs,
            full: runLevel == .full,
            seed: entry.seed,
            frameIndex: frameIndex,
            out: &builder,
            info: &info
        )
        frameIndex = frameIndex &+ 1
        frameText = builder
        progress = info.progress
        reveal = info.reveal
        rotorIndex = info.rotorIndex
    }

    private func finishActive() {
        active?.release()
        active = nil
        clearObservable()
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if !isVisible(next.id) {
                next.release()
                continue
            }
            let level = currentLevel()
            if level == .off {
                next.release()
                continue
            }
            begin(next, level: level)
            return
        }
    }

    private func clearObservable() {
        activeId = nil
        frameText = ""
        progress = 0
        reveal = 0
        rotorIndex = 0
        builder = ""
        info = EnigmaFrameInfo()
    }

    private func disableForSession() {
        disabled = true
        cancelAll()
    }
}
