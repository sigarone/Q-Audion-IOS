import Foundation
import QAudionEngine

@MainActor
final class TransportDiagnostics: ObservableObject {

    enum ConnectionStatus: Equatable {
        case unknown
        case healthy(latencyMs: Int)
        case degraded(latencyMs: Int)
        case unreachable
    }

    @Published private(set) var serverStatus: ConnectionStatus = .unknown
    @Published private(set) var lastChecked: Date?
    @Published private(set) var isChecking: Bool = false
    @Published var errorMessage: String?

    /// Last-known TURN round-trip (set when /calling/relays returned).
    @Published private(set) var lastTurnRoundTripMs: Int = 0
    @Published private(set) var torEnabled: Bool = false
    @Published private(set) var preferredTurnUrl: URL?

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        // Load from SettingsStore so the displayed values match what the user
        // configured in W9.A wiring.
        let stored = SettingsStore().loadTransport()
        self.torEnabled = stored.torEnabled
        self.preferredTurnUrl = stored.preferredTurnServerUrl
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
            let (_, response) = try await URLSession.shared.data(from: url)
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

    /// Fetch /calling/relays to populate TURN diagnostics.
    func fetchTurnRelays() async {
        guard let token = appState.authService.loadToken(), !token.isEmpty else { return }
        guard let url = URL(string: appState.serverUrl)?.appendingPathComponent("api/v1/calling/relays") else {
            return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let started = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                lastTurnRoundTripMs = latencyMs
            }
        } catch {
            // Don't surface — TURN unreachable is informational only.
        }
    }

    /// Persist user transport changes (mode + Tor toggle + URL) into SettingsStore.
    func saveTransport(mode: TransportSettingsViewModel.Mode,
                       torEnabled: Bool,
                       preferredUrl: URL?) {
        let store = SettingsStore()
        let current = store.loadTransport()
        let updated = TransportSettingsViewModel(
            mode: mode,
            torEnabled: torEnabled,
            preferredTurnServerUrl: preferredUrl,
            lastConnectionMs: current.lastConnectionMs,
            lastTurnRoundTripMs: lastTurnRoundTripMs
        )
        store.saveTransport(updated)
        self.torEnabled = torEnabled
        self.preferredTurnUrl = preferredUrl
    }
}
