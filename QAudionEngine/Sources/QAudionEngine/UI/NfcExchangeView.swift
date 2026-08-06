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
            if case .sasConfirm(let sas, _) = driver.state {
                sasDigitsCode(sas)
            } else {
                stateHelp
            }
            Spacer()
            actionButton
            Spacer().frame(height: 32)
        }
        .padding()
        .navigationTitle("Associazione NFC")
    }

    private var stateIcon: some View {
        Group {
            switch driver.state {
            case .idle:        Image(systemName: "wave.3.right.circle")
            case .waiting:     Image(systemName: "antenna.radiowaves.left.and.right")
            case .exchanging:  Image(systemName: "arrow.triangle.2.circlepath")
            case .sasConfirm:  Image(systemName: "text.magnifyingglass")
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
        case .sasConfirm: return .orange
        case .success: return .green
        case .error: return .red
        }
    }

    private var stateLabel: some View {
        Text(stateLabelText).font(.title3.weight(.semibold))
    }

    private var stateLabelText: String {
        switch driver.state {
        case .idle: return "Pronto per l\u{2019}associazione"
        case .waiting: return "Avvicina l\u{2019}iPhone al dispositivo Android"
        case .exchanging: return "Scambio chiavi\u{2026}"
        case .sasConfirm(_, let peer): return "Confronta questo codice con \(peer)"
        case .success(let peer): return "Associato con \(peer)"
        case .error(let msg): return "Errore: \(msg)"
        }
    }

    private var stateHelp: some View {
        Text("L\u{2019}iPhone funge da lettore NFC. Il dispositivo Android deve avere il servizio HCE di Q-Audion attivo.")
            .font(.caption)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
    }

    /// W-NFCSAS — the tap-time SAS confirm screen. Shows the 6-digit code
    /// (`NfcSasComputation`, byte-exact with Android's `SasComputation.kt`)
    /// grouped in pairs for readability — this module has no access to the
    /// app's design-system environment values, so it uses plain SwiftUI
    /// styling consistent with this view's OWN existing conventions rather
    /// than importing app-specific tokens.
    private func sasDigitsCode(_ sas: String) -> some View {
        let grouped = stride(from: 0, to: sas.count, by: 2).map { i -> String in
            let start = sas.index(sas.startIndex, offsetBy: i)
            let end = sas.index(start, offsetBy: 2, limitedBy: sas.endIndex) ?? sas.endIndex
            return String(sas[start..<end])
        }.joined(separator: " ")
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
        case .waiting, .exchanging:
            Button(action: driver.cancel) {
                Label("Annulla", systemImage: "xmark")
                    .font(.title3).padding()
                    .frame(maxWidth: 240)
                    .background(.gray).foregroundStyle(.white).clipShape(Capsule())
            }
        case .sasConfirm:
            // W-NFCSAS — confirm/reject, mirroring the in-call SAS ceremony's
            // own "confirm or it stays unconfirmed" shape. Rejecting routes
            // through `driver.rejectSas()` -> `NfcApduExchange.rejectSas()`,
            // which throws BEFORE `onPskDerived` -- no key is ever persisted
            // for a rejected tap.
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
        case .success:
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

    // The only reader we can actually run. See init() for why the anonymous
    // exchange this used to fall back to is gone entirely (deleted, not just
    // unwired).
    private var apduExchange: NfcApduExchange?

    init() {
        let idManager = SovereignIdentityManager()
        if let identity = idManager.loadIdentity(), identity.signingPublic.count == 32 {
            setupApduExchange(identityPub: identity.signingPublic)
        } else {
            // W-NFCIOS — an anonymous X25519-over-INS-0xCA fallback used to run
            // here (`NfcCollaborativeExchange`, deleted — confirmed dead: zero
            // production call sites once this identity-required path replaced
            // it). It could never succeed against anything: its exchange step
            // was INS 0xCA (GET DATA) and the only peer that exists, the
            // Android HCE service, dispatches SELECT / 0xC4 / 0xC5 / 0x01 and
            // answers SW_INS_NOT_SUPPORTED to everything else
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
        // 2026-08-06 fix: this used to set state = .idle BEFORE checking
        // apduExchange, so when identity init failed (line ~184's honest
        // Italian error) tapping "Start pairing" silently discarded that
        // error and reset to a blank "ready" screen with no explanation --
        // recoverable only by dismissing and reopening the sheet. Check
        // the guard first so a real init failure stays visible instead of
        // being wiped by a no-op tap.
        guard let ex = apduExchange else { return }
        state = .idle
        ex.start()
    }

    func cancel() {
        apduExchange?.cancel()
        if case .waiting = state { state = .idle }
        if case .exchanging = state { state = .idle }
        if case .sasConfirm = state { state = .idle }
    }

    func reset() {
        cancel()
        state = .idle
    }

    /// W-NFCSAS — user confirmed the SAS words match. No-op if not
    /// currently at `.sasConfirm`.
    func confirmSas() {
        apduExchange?.confirmSas()
    }

    /// W-NFCSAS — user rejected the SAS (or the words didn't match).
    /// `NfcApduExchange` throws before `onPskDerived` is ever called, so
    /// nothing is persisted; the ceremony surfaces as `.error` via the
    /// normal `onStateChanged` -> failure path, same as any other abort.
    func rejectSas() {
        apduExchange?.rejectSas()
    }

    // MARK: - Helpers (nonisolated for use in non-actor closures)

    private static func mapApduState(_ s: NfcApduExchange.State) -> NfcExchangeViewModel.State {
        switch s {
        case .idle:                         return .idle
        case .waiting:                      return .waiting
        case .exchanging:                   return .exchanging
        case .sasConfirm(let sas, let peer): return .sasConfirm(sas: sas, peerDeviceName: peer)
        case .success(let peer):            return .success(peerDeviceName: peer)
        case .error(let msg):               return .error(message: msg)
        }
    }

    /// Persist the derived PSK into SovereignKeyVault. The Keychain entry
    /// NAME still keys off the peer pubkey (unique per-peer, unrelated to
    /// the wire protocol) — but the stored `fingerprint` label MUST be
    /// `PskAdvertising.canonicalFingerprint(forPsk: psk)` (`lc_hex(SHA-256(psk))`),
    /// the same value `pskIfFingerprintMatches`/the OFFER advertiser compute
    /// fresh from the raw material and the ONLY form Android/Desktop ever
    /// show for the same key. Storing `hex(peerIdPub)` here instead (the
    /// prior bug) meant the Settings vault list displayed the PEER'S
    /// IDENTITY PUBKEY hex as if it were the PSK's fingerprint — never equal
    /// to the SHA-256(psk) shown on the other platform for the byte-identical
    /// shared secret, even when the handshake itself matched correctly (the
    /// real matching path never reads this label, so the bug was display-only,
    /// but it made a correct NFC pairing look broken to the user).
    private static func persistPsk(_ psk: Data, peerIdPub: Data) throws {
        let peerHex: String = peerIdPub.map { String(format: "%02x", $0) }.joined()
        let name: String = "nfc-" + peerHex.prefix(16)
        let fingerprint: String = PskAdvertising.canonicalFingerprint(forPsk: psk)
        let vault = SovereignKeyVault()
        // W-NFCBIND — record the provenance at write time. Without it the entry
        // relies on `PskOrigin.inferred`, which reads the "nfc-" prefix of this
        // very name; that fallback exists for keys stored before the tag did,
        // and a renamed convention should not be able to quietly turn an NFC
        // key back into an exportable one.
        //
        // W-NFCIDBIND (2026-07-29) — `peerIdPub` (the full 32-byte Ed25519
        // identity captured at THIS tap, per `NfcApduExchange.onPskDerived`'s
        // own contract) is now ALSO persisted verbatim in the vault blob, not
        // just truncated to 16 hex chars in the entry name. `resolveNfcMixInputs`'s
        // `nfcBound` check needs the real captured identity to compare against
        // the peer's verified identity key at call time, and a 16-hex-char
        // (8-byte) prefix is not a sound basis for that comparison — this app's
        // security floor elsewhere is full 256-bit fingerprints and 32-byte
        // identity keys throughout, never a truncated one.
        try vault.storePsk(name: name, key: psk, fingerprint: fingerprint,
                           keyClass: nil, origin: .nfc, nfcPeerIdentityKey: peerIdPub)
    }
}

#Preview {
    NavigationStack { NfcExchangeView() }
}
#endif
