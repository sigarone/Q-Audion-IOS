#if canImport(SwiftUI)
import SwiftUI
import CryptoKit

public struct NfcExchangeView: View {
    @StateObject private var driver = NfcExchangeDriver()

    public init() {}

    public var body: some View {
        VStack(spacing: 28) {
            Spacer()
            stateIcon
            stateLabel
            stateHelp
            Spacer()
            actionButton
            Spacer().frame(height: 32)
        }
        .padding()
        .navigationTitle("NFC Pairing")
    }

    private var stateIcon: some View {
        Group {
            switch driver.state {
            case .idle:        Image(systemName: "wave.3.right.circle")
            case .waiting:     Image(systemName: "antenna.radiowaves.left.and.right")
            case .exchanging:  Image(systemName: "arrow.triangle.2.circlepath")
            case .success:     Image(systemName: "checkmark.shield.fill")
            case .error:       Image(systemName: "exclamationmark.triangle.fill")
            }
        }
        .font(.system(size: 64))
        .foregroundStyle(stateColor)
    }

    private var stateColor: Color {
        switch driver.state {
        case .idle: return .secondary
        case .waiting, .exchanging: return .blue
        case .success: return .green
        case .error: return .red
        }
    }

    private var stateLabel: some View {
        Text(stateLabelText).font(.title3.weight(.semibold))
    }

    private var stateLabelText: String {
        switch driver.state {
        case .idle: return "Ready to pair"
        case .waiting: return "Hold your iPhone near the Android device"
        case .exchanging: return "Exchanging keys\u{2026}"
        case .success(let peer): return "Paired with \(peer)"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    private var stateHelp: some View {
        Text("iPhone acts as the NFC reader. Android device must have Q-Audion\u{2019}s HCE service enabled.")
            .font(.caption)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch driver.state {
        case .idle, .error:
            Button(action: driver.start) {
                Label("Start pairing", systemImage: "play.fill")
                    .font(.title3).padding()
                    .frame(maxWidth: 240)
                    .background(.blue).foregroundStyle(.white).clipShape(Capsule())
            }
        case .waiting, .exchanging:
            Button(action: driver.cancel) {
                Label("Cancel", systemImage: "xmark")
                    .font(.title3).padding()
                    .frame(maxWidth: 240)
                    .background(.gray).foregroundStyle(.white).clipShape(Capsule())
            }
        case .success:
            Button(action: driver.reset) {
                Label("Done", systemImage: "checkmark")
                    .font(.title3).padding()
                    .frame(maxWidth: 240)
                    .background(.green).foregroundStyle(.white).clipShape(Capsule())
            }
        }
    }
}

@MainActor
private final class NfcExchangeDriver: ObservableObject {
    @Published private(set) var state: NfcExchangeViewModel.State = .idle

    // Phase 14c (identity-bound) or anonymous fallback.
    private var apduExchange: NfcApduExchange?
    private var anonExchange: NfcCollaborativeExchange?

    init() {
        let idManager = SovereignIdentityManager()
        if let identity = idManager.loadIdentity(), identity.signingPublic.count == 32 {
            setupApduExchange(identityPub: identity.signingPublic)
        } else {
            setupAnonExchange()
        }
    }

    // MARK: - Setup

    private func setupApduExchange(identityPub: Data) {
        let exchange = NfcApduExchange()
        exchange.localIdentityPublicKey = identityPub
        exchange.onStateChanged = { [weak self] apduState in
            let mapped = Self.mapApduState(apduState)
            Task { @MainActor [weak self] in
                self?.state = mapped
            }
        }
        exchange.onPskDerived = { psk, peerIdPub in
            try Self.persistPsk(psk, peerIdPub: peerIdPub)
        }
        apduExchange = exchange
    }

    private func setupAnonExchange() {
        let exchange = NfcCollaborativeExchange()
        exchange.onPskDerivedDelegate = { psk, peerPub in
            try Self.persistPsk(psk, peerIdPub: peerPub)
        }
        exchange.onStateChanged = { [weak self] newState in
            Task { @MainActor [weak self] in
                self?.state = newState
            }
        }
        anonExchange = exchange
    }

    // MARK: - Lifecycle

    func start() {
        state = .idle
        if let ex = apduExchange {
            ex.start()
        } else if let ex = anonExchange {
            ex.start()
            state = ex.viewModel.state
        }
    }

    func cancel() {
        apduExchange?.cancel()
        if let ex = anonExchange {
            ex.cancel()
            state = ex.viewModel.state
        } else {
            if case .waiting = state { state = .idle }
            if case .exchanging = state { state = .idle }
        }
    }

    func reset() {
        cancel()
        state = .idle
    }

    // MARK: - Helpers (nonisolated for use in non-actor closures)

    private static func mapApduState(_ s: NfcApduExchange.State) -> NfcExchangeViewModel.State {
        switch s {
        case .idle:                         return .idle
        case .waiting:                      return .waiting
        case .exchanging:                   return .exchanging
        case .success(let peer):            return .success(peerDeviceName: peer)
        case .error(let msg):               return .error(message: msg)
        }
    }

    /// Persist the derived PSK into SovereignKeyVault under the peer pubkey fingerprint.
    private static func persistPsk(_ psk: Data, peerIdPub: Data) throws {
        let hexChars: [String] = peerIdPub.map { byte in
            let s: String = String(format: "%02x", byte)
            return s
        }
        let fingerprint: String = hexChars.joined()
        let prefix: Substring = fingerprint.prefix(16)
        let name: String = "nfc-" + prefix
        let vault = SovereignKeyVault()
        try vault.storePsk(name: name, key: psk, fingerprint: fingerprint)
    }
}

#Preview {
    NavigationStack { NfcExchangeView() }
}
#endif
