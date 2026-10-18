import Foundation
import UIKit
import QAudionEngine

@MainActor
final class TransportDiagnostics: ObservableObject {

    enum ConnectionStatus: Equatable {
        case unknown
        case healthy(latencyMs: Int)
        case degraded(latencyMs: Int)
        case unreachable
    }

    /// The transport check of the selected mode (`checkMode`): not run yet,
    /// running, or finished with what it found.
    enum ModeCheckState: Equatable {
        case idle
        case running
        case finished(TransportCheckResult)
    }

    @Published private(set) var serverStatus: ConnectionStatus = .unknown
    @Published private(set) var lastChecked: Date?
    @Published private(set) var isChecking: Bool = false
    @Published var errorMessage: String?

    /// Last-known round trip of the relay-list request (set when
    /// /calling/relays returned). This is the time the SERVER takes to answer
    /// that request, not a TURN round trip.
    @Published private(set) var lastTurnRoundTripMs: Int = 0
    @Published private(set) var preferredTurnUrl: URL?

    @Published private(set) var modeCheck: ModeCheckState = .idle
    /// The user's last "Confermo" (mode, verdict and date), from `TransportCheckConfirmationStore`.
    @Published private(set) var confirmation: TransportCheckConfirmation?
    /// The technical summary was copied to the pasteboard after the last check.
    @Published private(set) var reportCopied: Bool = false

    private let appState: AppState
    private let confirmationStore = TransportCheckConfirmationStore()
    /// SECURITY C-6 — cert-pinned session for transport diagnostics.
    private lazy var session: URLSession = PinnedURLSession.make(for: appState.serverUrl)

    init(appState: AppState) {
        self.appState = appState
        // Load from SettingsStore so the displayed values match what the user
        // configured in W9.A wiring.
        let stored = SettingsStore().loadTransport()
        self.preferredTurnUrl = stored.preferredTurnServerUrl
        self.confirmation = confirmationStore.load()
    }

    /// Ping `/api/v1/health` and measure round-trip.
    func checkServer() async {
        isChecking = true
        errorMessage = nil
        defer { Task { @MainActor in self.isChecking = false; self.lastChecked = Date() } }

        guard let url = URL(string: appState.serverUrl)?.appendingPathComponent("api/v1/health") else {
            errorMessage = "Invalid server URL"
            serverStatus = .unreachable
            return
        }

        let startedAt = Date()
        do {
            let (_, response) = try await session.data(from: url)
            let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                serverStatus = (latencyMs < 200) ? .healthy(latencyMs: latencyMs) : .degraded(latencyMs: latencyMs)
            } else {
                serverStatus = .unreachable
            }
        } catch {
            errorMessage = error.localizedDescription
            serverStatus = .unreachable
        }
    }

    /// Fetch /calling/relays and measure how long the server takes to answer.
    func fetchTurnRelays() async {
        guard let token = appState.authService.loadToken(), !token.isEmpty else { return }
        guard let url = URL(string: appState.serverUrl)?.appendingPathComponent("api/v1/calling/relays") else {
            return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let started = Date()
        do {
            let (_, response) = try await session.data(for: req)
            let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                lastTurnRoundTripMs = latencyMs
            }
        } catch {
            // Don't surface — TURN unreachable is informational only.
        }
    }

    /// The transport check: gathers ICE candidates with the configuration a
    /// call in `mode` would use (the engine's `TransportPlan`, through
    /// `TransportCandidateProbe`), without starting a call, and keeps what it
    /// found. It never keeps an address: only the candidate types are counted.
    func checkMode(_ mode: TransportSettingsViewModel.Mode, customTurnUrl: URL?) async {
        modeCheck = .running
        reportCopied = false
        #if canImport(WebRTC)
        let provider = appState.ensureRelayProvider()
        let token = appState.currentAccessToken
        let pinned = appState.liveProvider?.callingApi.pinnedUrlSession()
        let result = await TransportCandidateProbe.run(
            mode: mode,
            customTurnUrl: customTurnUrl,
            relayProvider: provider,
            accessToken: token,
            pinnedSession: pinned)
        modeCheck = .finished(result)
        #else
        modeCheck = .idle
        errorMessage = "Transport check unavailable in this build"
        #endif
    }

    /// "Confermo": remembers that the user confirmed the checked mode, what the check found, and when. The verdict is
    /// recorded whether it was OK or not, so the line "Ultima conferma" says which one the user confirmed.
    func confirmCheck() {
        guard case .finished(let result) = modeCheck else { return }
        confirmationStore.record(result: result)
        confirmation = confirmationStore.load()
    }

    /// "Segnala problema": copies the technical summary (mode, route, candidate
    /// types, outcome; no address) to the pasteboard.
    func copyReport() {
        guard case .finished(let result) = modeCheck else { return }
        UIPasteboard.general.string = result.summary
        reportCopied = true
    }

    /// Persist user transport changes (mode + URL) into SettingsStore.
    /// W411: also writes to TransportGate so the WebRTC bridge sees
    /// the user's choice at peer-connection creation time.
    ///
    /// The gate goes first: it keeps the address in UserDefaults and the user name and password in the Keychain. If the
    /// Keychain refuses them nothing is saved anywhere (`false`), so the older copy below never says something the calls
    /// do not use.
    @discardableResult
    func saveTransport(mode: TransportSettingsViewModel.Mode,
                       preferredUrl: URL?) -> Bool {
        // W411: surface to TransportGate for live consumption.
        guard TransportGate.save(mode: mode, customTurnUrl: preferredUrl) else { return false }
        let store = SettingsStore()
        let current = store.loadTransport()
        // A Save before any check must not wipe the value saved earlier.
        let turnMs = lastTurnRoundTripMs > 0 ? lastTurnRoundTripMs : current.lastTurnRoundTripMs
        // The calls read the server (with its password) from TransportGate; this older copy in SettingsStore is
        // not read for the calls, so it keeps the address without user name and password.
        let addressWithoutCredentials = preferredUrl.flatMap { TransportCustomTurn.parse($0.absoluteString).server?.urlWithoutCredentials }
        let updated = TransportSettingsViewModel(
            mode: mode,
            preferredTurnServerUrl: addressWithoutCredentials,
            lastConnectionMs: current.lastConnectionMs,
            lastTurnRoundTripMs: turnMs
        )
        store.saveTransport(updated)
        self.preferredTurnUrl = addressWithoutCredentials
        return true
    }
}
