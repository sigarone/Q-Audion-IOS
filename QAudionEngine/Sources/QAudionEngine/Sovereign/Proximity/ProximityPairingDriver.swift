#if canImport(SwiftUI) && os(iOS)
import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// State holder behind `ProximityPairingDisplayerView` and
/// `ProximityPairingScannerView` (ProximityPairingViews.swift). One instance
/// drives one screen in one role: displayer when `scanPayload` is nil,
/// scanner otherwise.
///
/// Owns the session, its CoreBluetooth transport and the scheduler. On
/// `.completed` it stores the PSK with `ProximityPairingStore.persist` and
/// reports the result upward only if that write succeeded. The completed
/// session is handed to a one-shot release timer at once, so the driver keeps
/// no reference to it (or to the PSK inside its state) past the spec §9
/// link-drain grace.
///
/// Everything runs on the main actor: SwiftUI actions, session
/// `onStateChange` callbacks and `ProximityMainScheduler` timers. `epoch` is
/// bumped on every (re)start and stop, so a callback or timer that belongs to
/// a torn-down session is ignored.
@MainActor
final class ProximityPairingViewDriver: ObservableObject {

    /// Whether the account the peer claims actually published the Ed25519
    /// key its phone just proved (spec §12). Without it the userId, and so
    /// the name on the confirmation screen, is only the peer's own claim.
    enum ServerCheck: Equatable {
        /// No lookup configured by the host.
        case notAvailable
        /// Lookup running; "Coincide" waits for it (bounded by `serverCheckTimeout`).
        case checking
        /// The presented key is one the account published.
        case confirmed
        /// The account published keys and this is none of them.
        case mismatch
        /// Offline, nothing published, or the lookup timed out.
        case unknown
    }

    /// What the confirmation screen shows (spec §9: peer name + SAS).
    struct Confirmation: Equatable {
        let peerName: String
        /// The 6-digit SAS grouped as "123 456".
        let groupedSas: String
        let warning: String?
        let localConfirmed: Bool
        let serverCheck: ServerCheck
    }

    /// The session-provided half of a `Confirmation`, kept so the screen can
    /// be re-rendered when the server check finishes.
    private struct ConfirmationInputs {
        let sas: String
        let peer: ProximityPeerIdentity
        let warning: String?
        let localConfirmed: Bool
    }

    enum Phase: Equatable {
        case preparing
        /// Displayer only; the image is `qrImage`.
        case showingCode
        /// A spinner with this caption.
        case working(String)
        case confirming(Confirmation)
        /// Success caption.
        case completed(String)
        /// User-facing error message.
        case failed(String)
    }

    @Published private(set) var phase: Phase = .preparing
    /// Displayer only: the current frame's QR, nil whenever it must not be visible.
    @Published private(set) var qrImage: UIImage? = nil

    // MARK: Copy (Italian, user-facing)

    private static let displayerExchangingText: String = "Collegamento sicuro in corso…"
    private static let scannerConnectingText: String = "Connessione Bluetooth all'altro telefono…"
    private static let scannerExchangingText: String = "Scambio chiavi post-quantistiche…"
    private static let completedPrefix: String = "Chiave post-quantistica condivisa con "
    private static let qrUnavailableText: String = "Impossibile generare il codice QR. Riprova."
    private static let bluetoothPermissionText: String =
        "Consenti a Q-Audion di usare il Bluetooth: serve a verificare che l'altro telefono sia davvero qui."
    private static let screenCapturedText: String =
        "Lo schermo è registrato o condiviso: il codice resta nascosto finché non interrompi la registrazione "
        + "o la condivisione."

    // MARK: Tuning

    /// Upper bound on the server check before "Coincide" is offered anyway.
    private static let serverCheckTimeout: TimeInterval = 5.0
    /// Displayer: delay before a retryable failure shows a fresh code.
    private static let autoRestartDelay: TimeInterval = 3.0
    /// Extra time, on top of the session's own drain grace, before a completed
    /// session and its transport are released.
    private static let releaseMargin: TimeInterval = 0.5
    /// Integer upscale of the CoreImage QR (one module = 10 px).
    private static let qrScale: CGFloat = 10

    // MARK: Configuration

    private let localUserId: String
    private let scanPayload: ProximityQrPayload?
    private let displayName: (String) -> String
    private let onCompleted: (ProximityPairingSummary) -> Void
    private let onRescan: (() -> Void)?
    private let serverIdentityKeys: ((String) async -> Set<Data>)?
    private let scheduler: ProximityMainScheduler

    // MARK: Live objects

    private var displayerSession: ProximityDisplayerSession?
    private var displayerTransport: ProximityBleDisplayerTransport?
    private var scannerSession: ProximityScannerSession?
    private var scannerTransport: ProximityBleScannerTransport?

    private var isActive: Bool = false
    private var epoch: UInt64 = 0
    private var finished: Bool = false
    private var autoRestartTimer: ProximityCancellable?
    private var serverCheck: ServerCheck = .notAvailable
    /// The epoch whose peer the server check ran for (one lookup per session).
    private var serverCheckEpoch: UInt64?
    private var serverCheckTask: Task<Void, Never>?
    private var serverCheckTimer: ProximityCancellable?
    private var confirmationInputs: ConfirmationInputs?
    /// The idle-timer setting found on appear, restored on disappear: a
    /// pairing must not be suspended by auto-lock halfway through.
    private var savedIdleTimerDisabled: Bool?
    /// Read from the Keychain once per screen, not once per attempt: every
    /// read materialises the whole identity blob (both private keys) in
    /// memory Swift cannot scrub, so auto-restarts should not multiply it.
    private var cachedIdentity: ProximityLocalIdentity?
    /// Displayer: the screen is being recorded, mirrored or shared.
    private var screenCaptured: Bool = false
    /// A displayer session was stopped because the app went to the background.
    private var suspendedInBackground: Bool = false
    private var renderedSessionId: Data = Data()
    private var renderedFrameIndex: UInt32?
    private lazy var ciContext: CIContext = CIContext()

    init(localUserId: String,
         scanPayload: ProximityQrPayload?,
         displayName: @escaping (String) -> String,
         onCompleted: @escaping (ProximityPairingSummary) -> Void,
         onRescan: (() -> Void)?,
         serverIdentityKeys: ((String) async -> Set<Data>)?) {
        self.localUserId = localUserId
        self.scanPayload = scanPayload
        self.displayName = displayName
        self.onCompleted = onCompleted
        self.onRescan = onRescan
        self.serverIdentityKeys = serverIdentityKeys
        self.scheduler = ProximityMainScheduler()
    }

    var isDisplayer: Bool {
        return scanPayload == nil
    }

    // MARK: - Actions (called by the views)

    /// On appear. Starts a pairing unless one is live or the screen already
    /// shows a final result.
    func start() {
        isActive = true
        if savedIdleTimerDisabled == nil {
            savedIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        }
        guard case .preparing = phase else { return }
        guard displayerSession == nil, scannerSession == nil else { return }
        begin()
    }

    /// On disappear. Cancels a live pairing (the peer gets ABORT(cancelled)).
    func stop() {
        isActive = false
        suspendedInBackground = false
        cachedIdentity = nil
        if let saved = savedIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = saved
            savedIdleTimerDisabled = nil
        }
        epoch &+= 1
        cancelAutoRestart()
        tearDownSession()
        clearCode()
        resetServerCheck()
        switch phase {
        case .completed, .failed:
            break
        default:
            setPhase(.preparing)
        }
    }

    func confirm() {
        guard case .confirming(let info) = phase, !info.localConfirmed else { return }
        guard info.serverCheck != .checking else { return }
        displayerSession?.confirm()
        scannerSession?.confirm()
    }

    func reject() {
        displayerSession?.reject()
        scannerSession?.reject()
    }

    /// The failure screen's button: a fresh code on the displayer, back to the
    /// camera on the scanner (a scanned code is single-use).
    func retry() {
        if isDisplayer {
            guard isActive else { return }
            begin()
            return
        }
        if let rescan = onRescan {
            rescan()
        }
    }

    // MARK: - Screen capture and app lifecycle (spec §6)

    /// True while any connected screen is being recorded, mirrored (AirPlay,
    /// cable) or shared. `ScreenshotLockService` only blanks its own secure
    /// layer in a capture, not a sibling view like the QR, so the displayer
    /// has to stop showing the code itself.
    static func isScreenCaptured() -> Bool {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if windowScene.screen.isCaptured { return true }
        }
        return false
    }

    /// On appear and on `UIScreen.capturedDidChangeNotification`. Displayer
    /// only: a recording, mirror or screen share would carry the live code to
    /// someone who is not in the room (spec §2 A4), so the session stops
    /// while it lasts and a fresh one starts when it ends.
    func screenCaptureChanged(_ captured: Bool) {
        guard isDisplayer else { return }
        let wasCaptured: Bool = screenCaptured
        screenCaptured = captured
        guard isActive, captured != wasCaptured else { return }
        if captured {
            halt(showing: ProximityPairingViewDriver.screenCapturedText)
            return
        }
        if case .failed(let text) = phase, text == ProximityPairingViewDriver.screenCapturedText {
            begin()
        }
    }

    /// `UIApplication.userDidTakeScreenshotNotification`: the frame on screen
    /// now exists as an image, so the whole session (sessionId, secrets,
    /// frame keys) is replaced at once instead of waiting for it to age out.
    func screenshotTaken() {
        guard isDisplayer, isActive else { return }
        guard case .showingCode = phase else { return }
        begin()
    }

    /// `UIApplication.didEnterBackgroundNotification`: a pairing never goes on
    /// behind a locked screen or another app — its timers would stall and
    /// resume with a frame that is no longer fresh. The displayer starts a new
    /// session on return; the scanner's code was single-use.
    func appDidEnterBackground() {
        guard isActive else { return }
        switch phase {
        case .completed, .failed:
            return
        default:
            break
        }
        guard displayerSession != nil || scannerSession != nil else { return }
        if isDisplayer {
            halt(showing: nil)
            suspendedInBackground = true
        } else {
            halt(showing: ProximityPairingError.cancelled.userMessage)
        }
    }

    /// `UIApplication.willEnterForegroundNotification`.
    func appWillEnterForeground() {
        guard suspendedInBackground else { return }
        suspendedInBackground = false
        guard isActive, isDisplayer else { return }
        guard case .preparing = phase else { return }
        begin()
    }

    /// Ends the live session (ABORT(cancelled) to a locked peer) and shows
    /// `text` as a failure, or the neutral preparing state when nil.
    private func halt(showing text: String?) {
        epoch &+= 1
        cancelAutoRestart()
        tearDownSession()
        clearCode()
        if let message = text {
            setPhase(.failed(message))
        } else {
            setPhase(.preparing)
        }
    }

    private func bluetoothPermissionAnswered(epoch expected: UInt64) {
        guard expected == epoch, isActive else { return }
        guard case .working(let text) = phase, text == ProximityPairingViewDriver.bluetoothPermissionText else { return }
        begin()
    }

    // MARK: - Session setup

    private func begin() {
        epoch &+= 1
        cancelAutoRestart()
        tearDownSession()
        clearCode()
        resetServerCheck()
        finished = false
        setPhase(.preparing)
        if isDisplayer && screenCaptured {
            setPhase(.failed(ProximityPairingViewDriver.screenCapturedText))
            return
        }
        if ProximityBluetoothPermission.isUndetermined {
            // Answer the one-time prompt first; its time must not count
            // against a frame's 8 s window or the connect timeout.
            setPhase(.working(ProximityPairingViewDriver.bluetoothPermissionText))
            let expected: UInt64 = epoch
            ProximityBluetoothPermission.requestIfNeeded { [weak self] in
                self?.bluetoothPermissionAnswered(epoch: expected)
            }
            return
        }
        if cachedIdentity == nil {
            cachedIdentity = ProximityPairingStore.loadLocalIdentity(userId: localUserId)
        }
        guard let identity = cachedIdentity else {
            setPhase(.failed(ProximityPairingError.identityUnavailable.userMessage))
            return
        }
        if let payload = scanPayload {
            beginScanner(payload: payload, identity: identity)
        } else {
            beginDisplayer(identity: identity)
        }
    }

    private func beginDisplayer(identity: ProximityLocalIdentity) {
        let transport: ProximityBleDisplayerTransport = ProximityBleDisplayerTransport()
        let policy: (ProximityPeerIdentity) -> ProximityIdentityDecision =
            ProximityPairingStore.defaultIdentityPolicy(local: identity)
        let session: ProximityDisplayerSession = ProximityDisplayerSession(identity: identity,
                                                                          transport: transport,
                                                                          scheduler: scheduler,
                                                                          identityPolicy: policy)
        let sessionEpoch: UInt64 = epoch
        session.onStateChange = { [weak self] (state: ProximityDisplayerSession.State) in
            self?.handleDisplayerState(state, epoch: sessionEpoch)
        }
        displayerTransport = transport
        displayerSession = session
        session.start()
    }

    private func beginScanner(payload: ProximityQrPayload, identity: ProximityLocalIdentity) {
        let transport: ProximityBleScannerTransport = ProximityBleScannerTransport()
        let policy: (ProximityPeerIdentity) -> ProximityIdentityDecision =
            ProximityPairingStore.defaultIdentityPolicy(local: identity)
        let session: ProximityScannerSession = ProximityScannerSession(payload: payload,
                                                                      identity: identity,
                                                                      transport: transport,
                                                                      scheduler: scheduler,
                                                                      identityPolicy: policy)
        let sessionEpoch: UInt64 = epoch
        session.onStateChange = { [weak self] (state: ProximityScannerSession.State) in
            self?.handleScannerState(state, epoch: sessionEpoch)
        }
        scannerTransport = transport
        scannerSession = session
        setPhase(.working(ProximityPairingViewDriver.scannerConnectingText))
        session.start()
    }

    // MARK: - Session state

    private func handleDisplayerState(_ state: ProximityDisplayerSession.State, epoch stateEpoch: UInt64) {
        guard stateEpoch == epoch else { return }
        switch state {
        case .idle:
            clearCode()
            setPhase(.preparing)
        case .showing(let payload):
            showCode(payload)
        case .exchanging:
            clearCode()
            setPhase(.working(ProximityPairingViewDriver.displayerExchangingText))
        case .awaitingConfirmation(sas: let sas, peer: let peer, warning: let warning, localConfirmed: let localConfirmed):
            clearCode()
            showConfirmation(ConfirmationInputs(sas: sas, peer: peer, warning: warning,
                                                localConfirmed: localConfirmed))
        case .completed(let result):
            clearCode()
            finish(result)
        case .failed(let error):
            clearCode()
            setPhase(.failed(error.userMessage))
            if ProximityPairingViewDriver.restartsOnItsOwn(error) && isActive {
                scheduleAutoRestart()
            }
        }
    }

    private func handleScannerState(_ state: ProximityScannerSession.State, epoch stateEpoch: UInt64) {
        guard stateEpoch == epoch else { return }
        switch state {
        case .idle:
            setPhase(.preparing)
        case .connecting:
            setPhase(.working(ProximityPairingViewDriver.scannerConnectingText))
        case .exchanging:
            setPhase(.working(ProximityPairingViewDriver.scannerExchangingText))
        case .awaitingConfirmation(sas: let sas, peer: let peer, warning: let warning, localConfirmed: let localConfirmed):
            showConfirmation(ConfirmationInputs(sas: sas, peer: peer, warning: warning,
                                                localConfirmed: localConfirmed))
        case .completed(let result):
            finish(result)
        case .failed(let error):
            setPhase(.failed(error.userMessage))
        }
    }

    private func showConfirmation(_ inputs: ConfirmationInputs) {
        confirmationInputs = inputs
        startServerCheckIfNeeded(inputs.peer)
        renderConfirmation()
    }

    private func renderConfirmation() {
        guard let inputs = confirmationInputs else { return }
        let name: String = peerName(inputs.peer.userId)
        let grouped: String = ProximityPairingViewDriver.groupSas(inputs.sas)
        let info = Confirmation(peerName: name, groupedSas: grouped, warning: inputs.warning,
                                localConfirmed: inputs.localConfirmed, serverCheck: serverCheck)
        setPhase(.confirming(info))
    }

    // MARK: - Server check (spec §12)

    /// Once per session: does the claimed account's published key set contain
    /// the Ed25519 key this phone just proved? Runs while the users compare
    /// the SAS; "Coincide" waits for it, at most `serverCheckTimeout`.
    private func startServerCheckIfNeeded(_ peer: ProximityPeerIdentity) {
        guard serverCheckEpoch != epoch else { return }
        serverCheckEpoch = epoch
        guard let lookup = serverIdentityKeys else {
            serverCheck = .notAvailable
            return
        }
        serverCheck = .checking
        let expected: UInt64 = epoch
        let userId: String = peer.userId
        let presented: Data = Data(peer.signingPublicKey)
        serverCheckTask = Task { [weak self] in
            let published: Set<Data> = await lookup(userId)
            self?.serverKeysArrived(published, presented: presented, epoch: expected)
        }
        serverCheckTimer = scheduler.schedule(after: ProximityPairingViewDriver.serverCheckTimeout) { [weak self] in
            self?.serverCheckTimedOut(epoch: expected)
        }
    }

    private func serverKeysArrived(_ published: Set<Data>, presented: Data, epoch expected: UInt64) {
        guard expected == epoch, serverCheck == .checking else { return }
        serverCheckTimer?.cancel()
        serverCheckTimer = nil
        serverCheckTask = nil
        if published.isEmpty {
            serverCheck = .unknown
        } else if published.contains(presented) {
            serverCheck = .confirmed
        } else {
            serverCheck = .mismatch
        }
        refreshConfirmation()
    }

    private func serverCheckTimedOut(epoch expected: UInt64) {
        guard expected == epoch, serverCheck == .checking else { return }
        serverCheckTimer = nil
        serverCheckTask?.cancel()
        serverCheckTask = nil
        serverCheck = .unknown
        refreshConfirmation()
    }

    /// Re-renders only while the confirmation screen is up.
    private func refreshConfirmation() {
        guard case .confirming = phase else { return }
        renderConfirmation()
    }

    private func resetServerCheck() {
        serverCheckTask?.cancel()
        serverCheckTask = nil
        serverCheckTimer?.cancel()
        serverCheckTimer = nil
        serverCheck = .notAvailable
        serverCheckEpoch = nil
        confirmationInputs = nil
    }

    private func peerName(_ userId: String) -> String {
        let resolved: String = displayName(userId)
        if resolved.isEmpty { return userId }
        return resolved
    }

    /// Persist first; report upward only on success (spec §11: nothing is
    /// stored on any path other than completed, and a completion that could
    /// not be stored is not a completion for this device).
    private func finish(_ result: ProximityPairingResult) {
        guard !finished else { return }
        finished = true
        lingerCompletedSession()
        do {
            try ProximityPairingStore.persist(result, vault: SovereignKeyVault())
        } catch {
            setPhase(.failed(ProximityPairingError.cryptoFailure("persist").userMessage))
            return
        }
        let name: String = peerName(result.peer.userId)
        let text: String = ProximityPairingViewDriver.completedPrefix + name
        let serverConfirmed: Bool = serverCheck == .confirmed
        setPhase(.completed(text))
        // The PSK stops here: the host only ever sees the summary.
        onCompleted(ProximityPairingSummary(result, serverIdentityConfirmed: serverConfirmed))
    }

    // MARK: - QR (displayer)

    /// Renders only when the frame actually changed.
    private func showCode(_ payload: ProximityQrPayload) {
        let sameSession: Bool = renderedSessionId == payload.sessionId
        let sameFrame: Bool = renderedFrameIndex == payload.frameIndex
        let hasImage: Bool = qrImage != nil
        if !(sameSession && sameFrame && hasImage) {
            let text: String = payload.qrText
            guard let image = ProximityPairingViewDriver.renderQr(text, context: ciContext) else {
                abortForMissingCode()
                return
            }
            qrImage = image
            renderedSessionId = Data(payload.sessionId)
            renderedFrameIndex = payload.frameIndex
        }
        setPhase(.showingCode)
    }

    private func clearCode() {
        if qrImage != nil {
            qrImage = nil
        }
        renderedSessionId = Data()
        renderedFrameIndex = nil
    }

    /// Never leave a session advertising behind a code nobody can see.
    private func abortForMissingCode() {
        epoch &+= 1
        cancelAutoRestart()
        tearDownSession()
        clearCode()
        setPhase(.failed(ProximityPairingViewDriver.qrUnavailableText))
    }

    private static func renderQr(_ text: String, context: CIContext) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let transform: CGAffineTransform = CGAffineTransform(scaleX: qrScale, y: qrScale)
        let scaled: CIImage = output.transformed(by: transform)
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func groupSas(_ sas: String) -> String {
        guard sas.count == ProximityPairing.sasDigits else { return sas }
        let head: String = String(sas.prefix(3))
        let tail: String = String(sas.suffix(3))
        let grouped: String = head + " " + tail
        return grouped
    }

    // MARK: - Timers and teardown

    /// Only failures that say nothing about who was on the other end put a
    /// fresh code back on screen by themselves: the code aged out, the radio
    /// dropped, or another phone got to it first. A failed security check, a
    /// "codes don't match" from either side, or any other refusal stays on
    /// the error until the user taps "Nuovo codice" — so an attacker relaying
    /// the exchange never gets a new code handed to it without a person
    /// deciding to try again.
    private static func restartsOnItsOwn(_ error: ProximityPairingError) -> Bool {
        switch error {
        case .expiredQrCode, .timeout, .transportFailed, .sessionBusy:
            return true
        case .peerAborted(let raw):
            switch ProximityPairing.AbortReason(rawValue: raw) {
            case .frameExpired?, .timeout?:
                return true
            default:
                return false
            }
        default:
            return false
        }
    }

    private func scheduleAutoRestart() {
        autoRestartTimer?.cancel()
        let expected: UInt64 = epoch
        autoRestartTimer = scheduler.schedule(after: ProximityPairingViewDriver.autoRestartDelay) { [weak self] in
            self?.autoRestartFired(epoch: expected)
        }
    }

    private func autoRestartFired(epoch expected: UInt64) {
        autoRestartTimer = nil
        guard expected == epoch, isActive, isDisplayer else { return }
        guard case .failed = phase else { return }
        begin()
    }

    private func cancelAutoRestart() {
        autoRestartTimer?.cancel()
        autoRestartTimer = nil
    }

    /// Cancels a live session (ABORT to the peer where a link is locked) and
    /// releases the radio. Observers are detached first, so the resulting
    /// `.failed(.cancelled)` never reaches this driver.
    private func tearDownSession() {
        if let session = displayerSession {
            session.onStateChange = nil
            session.cancel()
        }
        if let session = scannerSession {
            session.onStateChange = nil
            session.cancel()
        }
        displayerTransport?.shutdown()
        scannerTransport?.cancel()
        displayerSession = nil
        displayerTransport = nil
        scannerSession = nil
        scannerTransport = nil
    }

    /// A completed session must keep its link for the spec §9 drain grace (our
    /// CONFIRM may be the last message in flight), so it is not cancelled now.
    /// The driver lets go of it at once; a one-shot timer that nothing cancels
    /// keeps it and its transport alive until the grace has passed, then
    /// releases them. That also drops the last reference this screen holds to
    /// the PSK inside the session's `.completed` state.
    private func lingerCompletedSession() {
        let displayer: ProximityDisplayerSession? = displayerSession
        let displayerRadio: ProximityBleDisplayerTransport? = displayerTransport
        let scanner: ProximityScannerSession? = scannerSession
        let scannerRadio: ProximityBleScannerTransport? = scannerTransport
        displayer?.onStateChange = nil
        scanner?.onStateChange = nil
        displayerSession = nil
        displayerTransport = nil
        scannerSession = nil
        scannerTransport = nil
        let delay: TimeInterval = ProximityPairing.completionLinkGrace + ProximityPairingViewDriver.releaseMargin
        scheduler.schedule(after: delay) {
            displayer?.cancel()
            displayerRadio?.shutdown()
            scanner?.cancel()
            scannerRadio?.cancel()
        }
    }

    private func setPhase(_ newPhase: Phase) {
        if phase != newPhase {
            phase = newPhase
        }
    }
}
#endif
