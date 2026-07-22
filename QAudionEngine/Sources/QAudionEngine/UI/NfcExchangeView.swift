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

    // The only reader we can actually run. See init() for why the anonymous
    // NfcCollaborativeExchange is no longer wired in as a fallback.
    private var apduExchange: NfcApduExchange?

    init() {
        let idManager = SovereignIdentityManager()
        if let identity = idManager.loadIdentity(), identity.signingPublic.count == 32 {
            setupApduExchange(identityPub: identity.signingPublic)
        } else {
            // W-NFCIOS — the anonymous fallback used to run here. It cannot
            // succeed against anything: its exchange step is INS 0xCA (GET DATA,
            // NfcCollaborativeExchange.swift:164-168) and the only peer that
            // exists, the Android HCE service, dispatches SELECT / 0xC4 / 0xC5 /
            // 0x01 and answers SW_INS_NOT_SUPPORTED to everything else
            // (NfcApduService.kt:141-153). iPhones cannot emulate a card, so
            // there is no iOS peer either. Running it produced a tap that
            // "did nothing" and then timed out, which reads as broken hardware
            // rather than as a missing prerequisite.
            //
            // Failing here instead is also the honest answer: without a local
            // identity there is nothing to bind the pairing to, and Android
            // refuses the mirror-image case for the same reason — its HCE
            // service returns SW_TECHNICAL_PROBLEM with "Identità non ancora
            // inizializzata" when its own identity provider has nothing
            // (NfcApduService.kt onGetIdentityKey).
            state = .error(message: "Identità non ancora inizializzata: completa la configurazione prima di scambiare una chiave via NFC")
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


    // MARK: - Lifecycle

    func start() {
        state = .idle
        guard let ex = apduExchange else { return }
        ex.start()
    }

    func cancel() {
        apduExchange?.cancel()
        if case .waiting = state { state = .idle }
        if case .exchanging = state { state = .idle }
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
        // W-NFCBIND — record the provenance at write time. Without it the entry
        // relies on `PskOrigin.inferred`, which reads the "nfc-" prefix of this
        // very name; that fallback exists for keys stored before the tag did,
        // and a renamed convention should not be able to quietly turn an NFC
        // key back into an exportable one.
        try vault.storePsk(name: name, key: psk, fingerprint: fingerprint,
                           keyClass: nil, origin: .nfc)
    }
}

#Preview {
    NavigationStack { NfcExchangeView() }
}
#endif
