#if canImport(SwiftUI)
import SwiftUI
import CryptoKit

public struct NfcExchangeView: View {
    @StateObject private var driver: NfcExchangeDriver
    private let availability: NfcAvailability

    /// - Parameters:
    ///   - localUserId: this phone's account id, sent sealed to the other phone (empty: no account id).
    ///   - serverIdentityKeys: optional lookup of the identity keys an account publishes; a proven key that is not
    ///     among them adds a warning to the confirmation screen.
    public init(availability: NfcAvailability = .device,
                localUserId: String = "",
                serverIdentityKeys: ((String) async -> Set<Data>)? = nil) {
        self.availability = availability
        _driver = StateObject(wrappedValue: NfcExchangeDriver(localUserId: localUserId,
                                                              serverIdentityKeys: serverIdentityKeys))
    }

    public var body: some View {
        bodyContent
            .padding()
            .navigationTitle("Associazione NFC")
    }

    @ViewBuilder
    private var bodyContent: some View {
        if availability.isAvailable {
            pairingContent
        } else {
            unavailableContent
        }
    }

    /// Shown on a device that cannot read NFC tags: one neutral line, no
    /// actions and no error state.
    private var unavailableContent: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "wave.3.right.circle")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text(NfcAvailability.unavailableMessage)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private var pairingContent: some View {
        VStack(spacing: 28) {
            Spacer()
            stateIcon
            stateLabel
            if case .sasConfirm(let sas, _) = driver.state {
                sasDigitsCode(sas)
            } else {
                stateHelp
            }
            if let warning = driver.identityWarning {
                Text(warning)
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
            Spacer()
            actionButton
            Spacer().frame(height: 32)
        }
    }

    private var stateIcon: some View {
        Group {
            switch driver.state {
            case .idle:        Image(systemName: "wave.3.right.circle")
            case .waiting:     Image(systemName: "antenna.radiowaves.left.and.right")
            case .exchanging:  Image(systemName: "arrow.triangle.2.circlepath")
            case .sasConfirm:  Image(systemName: "text.magnifyingglass")
            case .holdAgain:   Image(systemName: "iphone.radiowaves.left.and.right")
            case .confirming:  Image(systemName: "arrow.triangle.2.circlepath")
            case .waitingForPeer: Image(systemName: "person.wave.2")
            case .success:     Image(systemName: "checkmark.shield.fill")
            case .peerRejected: Image(systemName: "xmark.shield.fill")
            case .error:       Image(systemName: "exclamationmark.triangle.fill")
            }
        }
        .font(.system(size: 64))
        .foregroundStyle(stateColor)
    }

    private var stateColor: Color {
        switch driver.state {
        case .idle: return .secondary
        case .waiting, .exchanging, .confirming: return .blue
        case .sasConfirm, .holdAgain, .waitingForPeer: return .orange
        case .success: return .green
        case .error, .peerRejected: return .red
        }
    }

    private var stateLabel: some View {
        Text(stateLabelText).font(.title3.weight(.semibold))
    }

    private var stateLabelText: String {
        switch driver.state {
        case .idle:
            return String(localized: "nfc.state.idle", defaultValue: "Pronto per l\u{2019}associazione", comment: "NFC pairing screen: ready to start.")
        case .waiting:
            return String(localized: "nfc.state.waiting", defaultValue: "Avvicina l\u{2019}iPhone al telefono Android", comment: "NFC pairing screen: waiting for the other phone to be tapped.")
        case .exchanging:
            return String(localized: "nfc.state.exchanging", defaultValue: "Scambio chiavi\u{2026}", comment: "NFC pairing screen: keys are being exchanged.")
        case .sasConfirm(_, let peer):
            return String(localized: "nfc.state.compare", defaultValue: "Confronta questo codice con \(peer)", comment: "NFC pairing screen: compare the 6-digit code with the one on the other phone; %@ is the other phone's name.")
        case .holdAgain:
            return String(localized: "nfc.state.hold_again", defaultValue: "Avvicina di nuovo l\u{2019}iPhone all\u{2019}altro telefono per terminare", comment: "NFC pairing screen: the code was confirmed here; hold the iPhone to the other phone again to finish.")
        case .confirming:
            return String(localized: "nfc.state.confirming", defaultValue: "Conferma in corso\u{2026}", comment: "NFC pairing screen: the second tap is running.")
        case .waitingForPeer:
            return String(localized: "nfc.state.waiting_peer", defaultValue: "In attesa dell\u{2019}altra persona", comment: "NFC pairing screen: the other person has not confirmed the code yet.")
        case .peerRejected:
            return String(localized: "nfc.state.peer_rejected", defaultValue: "L\u{2019}altra persona ha rifiutato", comment: "NFC pairing screen: the other person did not confirm the code; nothing was saved.")
        case .success(let peer):
            return String(localized: "nfc.state.success", defaultValue: "Associato con \(peer)", comment: "NFC pairing screen: pairing completed; %@ is the other phone's name.")
        case .error(let msg):
            return String(localized: "nfc.state.error", defaultValue: "Errore: \(msg)", comment: "NFC pairing screen: an error happened; %@ is the already localized reason.")
        }
    }

    private var stateHelp: some View {
        Text(stateHelpText)
            .font(.caption)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
    }

    private var stateHelpText: String {
        switch driver.state {
        case .holdAgain:
            return String(localized: "nfc.state.hold_again_help", defaultValue: "L\u{2019}altra persona deve confermare il codice sul suo telefono. Tieni i telefoni vicini fino alla fine.", comment: "NFC pairing screen help: both people confirm, the phones are held together a second time.")
        case .confirming, .waitingForPeer:
            return String(localized: "nfc.state.waiting_peer_help", defaultValue: "L\u{2019}altra persona deve confermare il codice sul suo telefono. Non allontanare i telefoni.", comment: "NFC pairing screen help: waiting for the other person to confirm.")
        default:
            return String(localized: "nfc.state.idle_help", defaultValue: "L\u{2019}iPhone funge da lettore NFC. Sul telefono Android apri l\u{2019}associazione NFC di Q-Audion e premi Pronto.", comment: "NFC pairing screen help: the iPhone reads, the Android phone must show its pairing screen in the ready state.")
        }
    }

    /// The code of the first tap, grouped in threes for readability (`123 456`, as on the other phone). This
    /// module has no access to the app's design-system environment values, so it uses plain SwiftUI styling.
    private func sasDigitsCode(_ sas: String) -> some View {
        let grouped = NfcApduExchange.groupedCode(sas)
        return VStack(spacing: 14) {
            Text("CONFRONTA QUESTO CODICE")
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.orange)
            Text(grouped)
                .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                .tracking(4)
            Text("Leggi ad alta voce e confronta con lo schermo dell\u{2019}altro dispositivo prima di confermare.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Text(String(localized: "nfc.state.after_confirm_hint", defaultValue: "Conferma solo se i due schermi mostrano lo stesso codice nello stesso momento. Dopo la conferma, avvicina di nuovo l\u{2019}iPhone all\u{2019}altro telefono.", comment: "NFC pairing screen: confirm only when both screens show the same code; a second hold of the phones finishes the pairing."))
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch driver.state {
        case .idle, .error:
            Button(action: driver.start) {
                Label("Avvia associazione", systemImage: "play.fill")
                    .font(.title3).padding()
                    .frame(maxWidth: 240)
                    .background(.blue).foregroundStyle(.white).clipShape(Capsule())
            }
        case .waiting, .exchanging, .confirming, .waitingForPeer:
            Button(action: driver.cancel) {
                Label("Annulla", systemImage: "xmark")
                    .font(.title3).padding()
                    .frame(maxWidth: 240)
                    .background(.gray).foregroundStyle(.white).clipShape(Capsule())
            }
        case .sasConfirm:
            // Confirming opens the second tap; rejecting sends nothing and discards everything, so no key is ever
            // stored for a rejected code.
            VStack(spacing: 12) {
                Button(action: driver.confirmSas) {
                    Label("Coincidono, conferma", systemImage: "checkmark")
                        .font(.title3).padding()
                        .frame(maxWidth: 280)
                        .background(.green).foregroundStyle(.white).clipShape(Capsule())
                }
                Button(action: driver.rejectSas) {
                    Label("Non coincidono", systemImage: "xmark")
                        .font(.subheadline).padding(.vertical, 8)
                        .frame(maxWidth: 280)
                        .foregroundStyle(.red)
                }
            }
        case .holdAgain:
            VStack(spacing: 12) {
                Button(action: driver.holdAgain) {
                    Label("Avvicina di nuovo", systemImage: "iphone.radiowaves.left.and.right")
                        .font(.title3).padding()
                        .frame(maxWidth: 280)
                        .background(.blue).foregroundStyle(.white).clipShape(Capsule())
                }
                Button(action: driver.cancel) {
                    Label("Annulla", systemImage: "xmark")
                        .font(.subheadline).padding(.vertical, 8)
                        .frame(maxWidth: 280)
                        .foregroundStyle(.red)
                }
            }
        case .success, .peerRejected:
            Button(action: driver.reset) {
                Label("Fatto", systemImage: "checkmark")
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
    @Published private(set) var identityWarning: String?

    // The only reader we can actually run: NFC pairing v2 (docs/security/NFC_PAIRING_V2.md), iPhone as the reader.
    private var apduExchange: NfcApduExchange?

    init(localUserId: String, serverIdentityKeys: ((String) async -> Set<Data>)?) {
        let idManager = SovereignIdentityManager()
        if let identity = idManager.loadIdentity(), identity.signingPublic.count == 32 {
            setupApduExchange(identityPub: identity.signingPublic, localUserId: localUserId,
                              serverIdentityKeys: serverIdentityKeys)
        } else {
            // Without a local identity there is nothing to bind the pairing to, and the other phone refuses the
            // mirror-image case for the same reason.
            state = .error(message: String(localized: "nfc.error.identity_not_initialized", defaultValue: "Identità non ancora inizializzata: completa la configurazione prima di scambiare una chiave via NFC", comment: "NFC pairing error: this phone has no identity yet, finish the setup first."))
        }
    }

    // MARK: - Setup

    private func setupApduExchange(identityPub: Data, localUserId: String,
                                   serverIdentityKeys: ((String) async -> Set<Data>)?) {
        let exchange = NfcApduExchange()
        exchange.localIdentityPublicKey = identityPub
        exchange.localUserId = localUserId
        exchange.serverIdentityKeys = serverIdentityKeys
        exchange.onStateChanged = { [weak self, weak exchange] apduState in
            let mapped = Self.mapApduState(apduState)
            let warning = exchange?.identityWarning
            Task { @MainActor [weak self] in
                self?.state = mapped
                self?.identityWarning = warning
            }
        }
        exchange.onPskDerived = { psk, peerIdPub in
            try Self.persistPsk(psk, peerIdPub: peerIdPub)
        }
        apduExchange = exchange
    }

    // MARK: - Lifecycle

    func start() {
        // Check the guard first so a real init failure stays visible instead of being wiped by a no-op tap.
        guard let ex = apduExchange else { return }
        state = .idle
        ex.start()
    }

    func cancel() {
        apduExchange?.cancel()
        switch state {
        case .waiting, .exchanging, .sasConfirm, .holdAgain, .confirming, .waitingForPeer:
            state = .idle
            identityWarning = nil
        default:
            break
        }
    }

    func reset() {
        cancel()
        state = .idle
        identityWarning = nil
    }

    /// The user confirmed the codes match: opens the second tap. No-op unless the code is on screen.
    func confirmSas() {
        apduExchange?.confirmSas()
    }

    /// The user rejected the code (or it did not match). Nothing is sent and nothing is stored.
    func rejectSas() {
        apduExchange?.rejectSas()
    }

    /// Opens the second tap again.
    func holdAgain() {
        apduExchange?.holdAgain()
    }

    // MARK: - Helpers (nonisolated for use in non-actor closures)

    private static func mapApduState(_ s: NfcApduExchange.State) -> NfcExchangeViewModel.State {
        switch s {
        case .idle:                         return .idle
        case .waiting:                      return .waiting
        case .exchanging:                   return .exchanging
        case .sasConfirm(let sas, let peer): return .sasConfirm(sas: sas, peerDeviceName: peer)
        case .holdAgain(let peer):          return .holdAgain(peerDeviceName: peer)
        case .confirming(let peer):         return .confirming(peerDeviceName: peer)
        case .waitingForPeer(let peer):     return .waitingForPeer(peerDeviceName: peer)
        case .success(let peer):            return .success(peerDeviceName: peer)
        case .peerRejected(let peer):       return .peerRejected(peerDeviceName: peer)
        case .error(let msg):               return .error(message: msg)
        }
    }

    /// Stores and finalizes the key of a confirmed pairing in the SovereignKeyVault (docs/security/NFC_PAIRING_V2.md
    /// section 9, F1). Called by `NfcApduExchange` once, and only after this phone's user confirmed and the other
    /// phone proved, with its confirmation tag, that it stored the key: a rejected, cancelled or timed-out
    /// ceremony never gets here, so an earlier key stays as it was.
    ///
    /// The Keychain entry NAME keys off the peer identity key and the first 8 hex characters of the key's
    /// fingerprint; the stored `fingerprint` label is `PskAdvertising.canonicalFingerprint(forPsk:)`
    /// (`lc_hex(SHA-256(psk))`), the only form the other platforms show for the same key.
    private static func persistPsk(_ psk: Data, peerIdPub: Data) throws -> NfcApduExchange.StoreOutcome {
        let peerHex: String = peerIdPub.map { String(format: "%02x", $0) }.joined()
        let fingerprint: String = PskAdvertising.canonicalFingerprint(forPsk: psk)
        let device: String = "nfc-" + peerHex.prefix(16)
        let name: String = CallKeyPriority.inPersonAccountName(device: device, keyFingerprint: fingerprint)
        let vault = SovereignKeyVault()
        let hadEarlierKey: Bool = vault.listPskNames().contains { CallKeyPriority.inPersonDevice(ofAccount: $0) == device }
        // W-NFCBIND: the provenance is recorded at write time, and the full 32-byte identity key of the peer that
        // was proven at THIS ceremony is kept in the blob (W-NFCIDBIND), not a prefix of it.
        try vault.storePsk(name: name, key: psk, fingerprint: fingerprint,
                           keyClass: nil, origin: .nfc, nfcPeerIdentityKey: peerIdPub)
        // Store: the new key takes the place and the "placed by hand" mark of the device's highest-ranked key; the
        // earlier key stays directly below it (CALL_KEY_PRIORITY.md section 4a). Finalize (F1): the other phone
        // proved it holds the new key, so the keys of that device stored before it are deleted.
        let order = CallKeyPriorityStore.live(vault: vault)
        order.syncWithVault()
        let finalized = order.finalize(name)
        return NfcApduExchange.StoreOutcome(replaced: hadEarlierKey, deleted: finalized.deleted.count)
    }
}

#Preview {
    NavigationStack { NfcExchangeView() }
}
#endif
