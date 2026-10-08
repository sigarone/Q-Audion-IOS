import SwiftUI
import UIKit
import QAudionEngine

// Enigma mode (visual effect only), app side. The pure logic lives in QAudionEngine/Enigma (tested there); this file is the
// thin glue: the display link, the device conditions, and the state the bubbles observe.
//
// CLAUDE.md section 16: nothing in the Enigma files takes AppState (or any app type) as a parameter. They take primitives,
// closures and engine types.

/// The remote flag. Same key as Android (`enigma_mode.enabled`), default OFF. iOS reads ONLY the public flags file (the same
/// value for every install): the key is deliberately NOT in `FeatureFlags.overlayEligibleKeys`, because a visible feature that
/// differs by account is exactly what Guideline 5.6 forbids (see the note there).
@MainActor
enum EnigmaFeature {
    static var flagOn: Bool {
        FeatureFlags.bool(EnigmaSettings.flagKey, EnigmaSettings.flagDefault)
    }
}

/// The strings of the scene, localized once (the Italian text is the fallback and lives in the engine, next to its tests).
@MainActor
enum EnigmaStrings {
    static let verified: String = Bundle.main.localizedString(
        forKey: EnigmaLabels.verifiedKey, value: EnigmaLabels.verifiedDefault, table: nil)
    static let sealed: String = Bundle.main.localizedString(
        forKey: EnigmaLabels.sealedKey, value: EnigmaLabels.sealedDefault, table: nil)
    static let file: String = Bundle.main.localizedString(
        forKey: EnigmaLabels.fileKey, value: EnigmaLabels.fileDefault, table: nil)
    static let rotorsCaption: String = Bundle.main.localizedString(
        forKey: EnigmaLabels.rotorsCaptionKey, value: EnigmaLabels.rotorsCaptionDefault, table: nil)
    static let rejected: String = Bundle.main.localizedString(
        forKey: EnigmaLabels.rejectedKey, value: EnigmaLabels.rejectedDefault, table: nil)
    static let degraded: String = Bundle.main.localizedString(
        forKey: EnigmaLabels.degradedKey, value: EnigmaLabels.degradedDefault, table: nil)

    /// "file cifrato · AES-256-GCM · chiave 256 bit · N%" for the upload panel.
    static func fileLine(percent: Int) -> String {
        String(format: file, percent)
    }
}

/// The one string and the numbers of the running frame. Only the scene view observes it, so a new frame redraws that view
/// and nothing else. Values are written only when they change.
@MainActor
final class EnigmaFrameModel: ObservableObject {
    @Published private(set) var text: String = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var rotorIndex: Double = 0
    @Published private(set) var full: Bool = false
    @Published private(set) var labelKind: EnigmaLabelKind = .sealed
    @Published private(set) var packetBytes: Int = 0

    func update(from effect: EnigmaEffect) {
        let newText: String = effect.frameText
        if text != newText { text = newText }
        if progress != effect.progress { progress = effect.progress }
        if rotorIndex != effect.rotorIndex { rotorIndex = effect.rotorIndex }
        let isFull: Bool = effect.runLevel == .full
        if full != isFull { full = isFull }
        if labelKind != effect.labelKind { labelKind = effect.labelKind }
        if packetBytes != effect.packetBytes { packetBytes = effect.packetBytes }
    }

    func clear() {
        if !text.isEmpty { text = "" }
        if progress != 0 { progress = 0 }
        if rotorIndex != 0 { rotorIndex = 0 }
    }
}

/// Target of the display link (CADisplayLink retains its target, so this small object holds the host weakly).
@MainActor
private final class EnigmaLinkProxy: NSObject {
    weak var host: EnigmaHost?

    init(host: EnigmaHost) {
        self.host = host
        super.init()
    }

    @objc func tick(_ link: CADisplayLink) {
        host?.displayLinkTick(timestamp: link.timestamp, nominalSeconds: link.duration)
    }
}

/// Process-wide owner of the effect: the coordinator, the display link (alive only while a scene runs), the device
/// conditions and the state the bubbles observe. Main actor only.
///
/// Zero cost at rest: with the effect off nothing here is registered with the bus, no timer runs, no display link exists, and
/// the published values never change, so no bubble is ever invalidated.
@MainActor
final class EnigmaHost: ObservableObject {
    static let shared = EnigmaHost()

    /// The row whose bubble is drawn by the effect right now.
    @Published private(set) var activeId: String? = nil
    /// Received rows held back (invisible) while their scene is being decided: at most 500 ms each.
    @Published private(set) var hiddenIds: Set<String> = []
    /// The discreet "effect reduced" line (shown once after the governor steps down).
    @Published private(set) var showNotice: Bool = false

    let frame = EnigmaFrameModel()

    private let coordinator: EnigmaCoordinator
    private var rowsProvider: (() -> [EnigmaRow])?
    private var attachedCount: Int = 0
    private var busHeld: Bool = false
    private var foreground: Bool = true
    private var displayLink: CADisplayLink?
    private var linkProxy: EnigmaLinkProxy?
    private var watchdog: Timer?
    private var lastFrameWall: CFTimeInterval = 0
    private var uploadDecisions: [String: Bool] = [:]

    private init() {
        let effect = EnigmaEffect(environment: { EnigmaHost.readEnvironment() })
        self.coordinator = EnigmaCoordinator(effect: effect, clock: { EnigmaHost.nowMs() })
        self.foreground = UIApplication.shared.applicationState == .active
        EnigmaBus.shared.setSink { [weak self] event in
            self?.accept(event)
        }
        installObservers()
    }

    // MARK: - Device conditions

    static func readEnvironment() -> EnigmaEnvironment {
        let info = ProcessInfo.processInfo
        let thermal: Int = info.thermalState.rawValue
        return EnigmaEnvironment(
            reduceMotion: UIAccessibility.isReduceMotionEnabled,
            lowPowerMode: info.isLowPowerModeEnabled,
            thermalLevel: thermal
        )
    }

    static func nowMs() -> Int64 {
        Int64(ProcessInfo.processInfo.systemUptime * 1000.0)
    }

    private func installObservers() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.appLeftForeground() }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.appEnteredForeground() }
        }
        // A change of any brake while a scene runs: show the results now; the next scene reads the conditions again.
        let brakes: [Notification.Name] = [
            UIAccessibility.reduceMotionStatusDidChangeNotification,
            Notification.Name.NSProcessInfoPowerStateDidChange,
            ProcessInfo.thermalStateDidChangeNotification,
        ]
        for name in brakes {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stopAll() }
            }
        }
    }

    private func appLeftForeground() {
        foreground = false
        stopAll()
    }

    private func appEnteredForeground() {
        foreground = true
    }

    // MARK: - Chat screens

    /// A chat screen appeared. `conversationKey` is the conversation it shows; `rows` returns its newest rows.
    func attach(flagOn: Bool, conversationKey: String, rows: @escaping () -> [EnigmaRow]) {
        rowsProvider = rows
        coordinator.conversationKey = conversationKey
        attachedCount += 1
        applyConfiguration(flagOn: flagOn)
    }

    func detach(flagOn: Bool) {
        attachedCount = max(0, attachedCount - 1)
        if attachedCount == 0 {
            rowsProvider = nil
            coordinator.conversationKey = nil
            coordinator.reset()
            uploadDecisions.removeAll()
            syncAll()
        }
        applyConfiguration(flagOn: flagOn)
    }

    /// The setting or the flag changed (the settings screen, a chat screen coming back).
    func configurationChanged(flagOn: Bool) {
        applyConfiguration(flagOn: flagOn)
        uploadDecisions.removeAll()
    }

    /// The rows of the open chat changed: a packet announced before its row existed can now find it.
    func rowsChanged(flagOn: Bool) {
        applyConfiguration(flagOn: flagOn)
        if busHeld { resolveNow() }
    }

    private func applyConfiguration(flagOn: Bool) {
        let level: EnigmaLevel = EnigmaSettings.userLevel(flagOn: flagOn)
        coordinator.effect.configure(flagOn: level != .off, userLevel: level)
        let wanted: Bool = level != .off && attachedCount > 0
        if wanted && !busHeld {
            EnigmaBus.shared.acquire()
            busHeld = true
        } else if !wanted && busHeld {
            EnigmaBus.shared.release()
            busHeld = false
            coordinator.reset()
            syncAll()
        }
    }

    // MARK: - Events and scenes

    /// A packet was sealed (send) or opened (receive). Only the cheap part runs here, in the caller's turn: the packet is
    /// remembered and a received row is held back. Everything else (finding the row, building the scene) is one turn later.
    private func accept(_ event: EnigmaWireEvent) {
        coordinator.accept(event)
        syncHidden()
        scheduleHoldExpiry(rowId: event.rowId)
        Task { @MainActor [weak self] in
            self?.resolveNow()
        }
    }

    private func resolveNow() {
        let rows: [EnigmaRow] = rowsProvider?() ?? []
        coordinator.resolve(rows: rows, foreground: foreground)
        syncAll()
    }

    /// The hard limit on a held-back row, independent of every bubble: at the 500 ms mark the row is shown whatever the
    /// state of the scene.
    private func scheduleHoldExpiry(rowId: String) {
        let remaining: Int64 = coordinator.hiddenRemainingMs(rowId)
        if remaining <= 0 { return }
        let delay: DispatchTimeInterval = .milliseconds(Int(remaining) + 5)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor in self?.holdExpired() }
        }
    }

    private func holdExpired() {
        coordinator.expireHidden()
        syncHidden()
        syncAll()
        // A timer that fired a hair before the 500 ms mark (clock rounding) must not leave a row hidden: arm it again.
        for id in coordinator.hiddenIds {
            scheduleHoldExpiry(rowId: id)
        }
    }

    /// True while the row must stay invisible (its scene is being decided and the 500 ms limit has not run out).
    func isHeldBack(_ rowId: String) -> Bool {
        hiddenIds.contains(rowId) && coordinator.awaitsScene(rowId)
    }

    /// The upload panel (full level only) is decided once per row, when the upload is first seen; Lite and Off play nothing.
    func allowsUploadPanel(rowId: String) -> Bool {
        if let known = uploadDecisions[rowId] { return known }
        let ok: Bool = busHeld && coordinator.effect.wouldAnimate() && coordinator.effect.currentLevel() == .full
        if uploadDecisions.count > 64 { uploadDecisions.removeAll() }
        uploadDecisions[rowId] = ok
        return ok
    }

    private func stopAll() {
        if !busHeld && activeId == nil && hiddenIds.isEmpty { return }
        coordinator.stop()
        syncAll()
    }

    // MARK: - Mirror of the effect into the published state

    private func syncHidden() {
        let hidden: Set<String> = coordinator.hiddenIds
        if hiddenIds != hidden { hiddenIds = hidden }
    }

    private func syncAll() {
        let effect: EnigmaEffect = coordinator.effect
        let id: String? = effect.activeId
        if activeId != id { activeId = id }
        syncHidden()
        if id != nil {
            frame.update(from: effect)
            startClockIfNeeded()
        } else {
            frame.clear()
            stopClock()
        }
    }

    // MARK: - Display link (alive only while a scene runs)

    private func startClockIfNeeded() {
        if displayLink != nil { return }
        let proxy = EnigmaLinkProxy(host: self)
        let link = CADisplayLink(target: proxy, selector: #selector(EnigmaLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        linkProxy = proxy
        displayLink = link
        lastFrameWall = CACurrentMediaTime()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkWatchdog() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopClock() {
        displayLink?.invalidate()
        displayLink = nil
        linkProxy = nil
        watchdog?.invalidate()
        watchdog = nil
    }

    fileprivate func displayLinkTick(timestamp: CFTimeInterval, nominalSeconds: CFTimeInterval) {
        lastFrameWall = CACurrentMediaTime()
        if !timestamp.isFinite || timestamp < 0 { return }
        let nanos: Int64 = Int64(timestamp * 1_000_000_000.0)
        let nominalMs: Double = nominalSeconds.isFinite ? nominalSeconds * 1000.0 : EnigmaGovernor.referenceFrameMs
        let changed: Bool = coordinator.step(nowNanos: nanos, nominalFrameMs: nominalMs)
        if coordinator.effect.takeDegradeNotice() { showDegradeNotice() }
        if changed || !coordinator.effect.hasWork { syncAll() }
    }

    /// If the frames stop arriving while a scene is on (the link died, the process was suspended in a way no notification
    /// announced), the scene is dropped and the effect is switched off for the session: a bubble can never stay stuck on a
    /// frame instead of its text.
    private func checkWatchdog() {
        if displayLink == nil { return }
        if CACurrentMediaTime() - lastFrameWall > 0.6 {
            coordinator.effect.reportFailure()
            coordinator.stop()
            syncAll()
        }
    }

    private func showDegradeNotice() {
        showNotice = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            Task { @MainActor in self?.showNotice = false }
        }
    }
}
