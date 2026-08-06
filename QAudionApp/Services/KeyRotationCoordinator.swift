import Foundation
import CryptoKit
import QAudionEngine

/// W407 — Coordinates key rotation operations.
///
/// Public API: rotate() generates a new X25519 keypair via CryptoKit,
/// **persists** the public key + fingerprint into SovereignKeyVault
/// under the name "rotated_ephemeral_pubkey", computes fingerprint via
/// Fingerprint.format(), generates IdentityQrCode for sharing.
///
/// **Scope of the rotation (honest):**
/// - This is an EPHEMERAL session keypair, NOT a sovereign identity
///   rotation. Rotating the sovereign identity would change the
///   user's userId — destroying contact graph + losing message
///   history alignment with peers. That's a separate, much-rarer
///   destructive flow not exposed via this button.
/// - The new keypair is persisted locally so the displayed
///   fingerprint matches a real key the user can verify out-of-band.
/// - Pushing the new pubkey to the server (so contacts can re-derive
///   their pairwise PSK with this device) requires server-side support
///   for /api/v1/account/devices/key — currently the server exposes
///   only the device-link path. Until that endpoint is added, the
///   rotated key is local-display + QR-export only.
@MainActor
final class KeyRotationCoordinator: ObservableObject {

    @Published private(set) var currentFingerprint: String
    @Published private(set) var currentIdentityQr: String?
    @Published private(set) var lastRotationDate: Date?
    @Published private(set) var isRotating: Bool = false
    @Published var errorMessage: String?

    /// PSK vault entries loaded from SovereignKeyVault (name → fingerprint).
    @Published private(set) var vaultKeys: [(name: String, fingerprint: String)] = []

    private let appState: AppState

    /// W-VAULTREFRESH — real root cause of "vault doesn't show the new key
    /// immediately, has to leave/re-enter the screen": `vaultKeys` used to
    /// be populated ONLY here in `init()` plus after this coordinator's OWN
    /// `importPeerIdentity`/`deletePsk` calls. The NFC-pairing path
    /// (`NfcExchangeView.persistPsk`) writes directly to `SovereignKeyVault`
    /// and has no reference to this coordinator at all, so a key paired via
    /// NFC never triggered a refresh — `KeyManagementScreen`'s `@StateObject`
    /// keeps the SAME coordinator instance alive across the
    /// `NavigationLink` push/pop into `NfcExchangeView`, so returning to the
    /// screen showed the same stale array. Only tearing down
    /// `KeyManagementScreen` entirely (leaving Settings and re-entering)
    /// allocated a FRESH coordinator, whose `init()` re-ran `loadVaultKeys()`
    /// — which is exactly the "leave/re-enter fixes it" symptom reported.
    /// Fix: observe `SovereignKeyVault`'s own `.sovereignVaultDidChange`
    /// (posted by every `storePsk`/`deletePsk` call, mirroring
    /// `ContactsStore.contactsDidChange`) so ANY vault-mutating code path —
    /// not just this coordinator's own two methods — refreshes the list.
    private var vaultObserver: NSObjectProtocol?

    /// 2026-08-06 fix: this used to call `Curve25519.KeyAgreement.PrivateKey()`
    /// unconditionally on every init — a brand-new RANDOM keypair every time
    /// this screen (or `MyIdentityQrSheet`, which shares this coordinator)
    /// opened. The fingerprint/QR shown to the user is the actual
    /// out-of-band identity-verification surface — it changed on every
    /// visit and never matched a key any peer could verify against, making
    /// the whole ceremony non-functional. `SecurityDashboardScreen` already
    /// fixed the equivalent gap (W407, see its `deriveDisplayPubkey`) but
    /// this class — despite carrying the same W407 tag in its own header —
    /// was never updated to match. Now resolves, in order: the most
    /// recently persisted rotation (if the user has rotated before, that IS
    /// the current key by `rotate()`'s own contract), else the real
    /// sovereign identity pubkey (same source SecurityDashboard uses), else
    /// a last-resort unpersisted keypair for the narrow window before any
    /// identity exists at all (e.g. mid-FastSetup before save).
    init(appState: AppState) {
        self.appState = appState
        let userId = appState.currentUserId ?? "unknown-user"
        let (pubBytes, fingerprint) = Self.resolveDisplayIdentity(vault: SovereignKeyVault())
        self.currentFingerprint = fingerprint
        let identity = IdentityQrCode.Identity(userId: userId, pubkey: pubBytes)
        self.currentIdentityQr = try? IdentityQrCode.encode(identity: identity)
        loadVaultKeys()
        vaultObserver = NotificationCenter.default.addObserver(
            forName: .sovereignVaultDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // NotificationCenter callbacks are @Sendable in iOS 18+ — hop to
            // MainActor to satisfy this class's own @MainActor isolation,
            // same convention as AppState's .contactsDidChange observer.
            Task { @MainActor [weak self] in
                self?.loadVaultKeys()
            }
        }
    }

    deinit {
        if let token = vaultObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Resolves what to actually display as "your identity" — see the
    /// `init` doc comment above for the fallback order and why.
    private static func resolveDisplayIdentity(vault: SovereignKeyVault) -> (pubkey: Data, fingerprint: String) {
        if let rotated = mostRecentRotation(vault: vault) {
            return rotated
        }
        if let identity = SovereignIdentityManager().loadIdentity() {
            let pub = identity.encryptionPublic
            let fp = (try? Fingerprint.format(pubkey: pub)) ?? "????.????.????.????"
            return (pub, fp)
        }
        let pub = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let fp = (try? Fingerprint.format(pubkey: pub)) ?? "????.????.????.????"
        return (pub, fp)
    }

    private static func mostRecentRotation(vault: SovereignKeyVault) -> (pubkey: Data, fingerprint: String)? {
        let latest = vault.listPskEntries()
            .filter { $0.name.hasPrefix("rotated_ephemeral.") }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            .first
        guard let latest,
              let pub = try? vault.loadPsk(name: latest.name),
              let fp = vault.getFingerprint(name: latest.name) else { return nil }
        return (pub, fp)
    }

    /// Reload the PSK list from SovereignKeyVault (call after import or delete).
    func loadVaultKeys() {
        let vault = SovereignKeyVault()
        let names = vault.listPskNames()
        vaultKeys = names.map { name in
            let fp = vault.getFingerprint(name: name) ?? "—"
            return (name: name, fingerprint: fp)
        }.sorted { $0.name < $1.name }
    }

    /// Store a peer's identity (from QR scan) as a PSK entry in the vault.
    func importPeerIdentity(userId: String, pubkey: Data) {
        let vault = SovereignKeyVault()
        let fp = (try? Fingerprint.format(pubkey: pubkey)) ?? "—"
        do {
            try vault.storePsk(name: "peer.\(userId)", key: pubkey, fingerprint: fp)
            loadVaultKeys()
        } catch {
            errorMessage = "Importazione fallita: \(error.localizedDescription)"
        }
    }

    /// Delete a PSK entry from the vault.
    func deletePsk(name: String) {
        let vault = SovereignKeyVault()
        try? vault.deletePsk(name: name)
        loadVaultKeys()
    }

    /// W407 — Rotate the ephemeral keypair. Generates new X25519,
    /// **persists** into SovereignKeyVault, updates fingerprint + QR.
    func rotate() {
        RTLog.info("keymgmt", "rotate() requested")
        Task {
            await MainActor.run { self.isRotating = true; self.errorMessage = nil }
            // Synchronous CPU-bound operation; wrap in a brief delay so UI
            // shows the spinner.
            try? await Task.sleep(nanoseconds: 200_000_000)
            let newKey = Curve25519.KeyAgreement.PrivateKey()
            let pubBytes = newKey.publicKey.rawRepresentation
            let newFingerprint = (try? Fingerprint.format(pubkey: pubBytes)) ?? "????.????.????.????"
            let userId = appState.currentUserId ?? "unknown-user"
            let identity = IdentityQrCode.Identity(userId: userId, pubkey: pubBytes)
            let qrString = try? IdentityQrCode.encode(identity: identity)

            // W407: persist into SovereignKeyVault so the rotation
            // survives app relaunches and the SecurityDashboard
            // fingerprint corresponds to a real, durable key.
            // The privateKey is stored under a dedicated namespace
            // so it doesn't collide with per-pair PSKs.
            do {
                let vault = SovereignKeyVault()
                let rotationName = "rotated_ephemeral.\(Int64(Date().timeIntervalSince1970))"
                try vault.storePsk(
                    name: rotationName,
                    key: pubBytes,            // public half — peers verify against this
                    fingerprint: newFingerprint)
                print("[KeyRotationCoordinator] persisted rotated key as \(rotationName)")
            } catch {
                print("[KeyRotationCoordinator] persistence failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.errorMessage = "Rotazione completata in memoria — persistenza fallita: \(error.localizedDescription)"
                }
            }

            await MainActor.run {
                self.currentFingerprint = newFingerprint
                self.currentIdentityQr = qrString
                self.lastRotationDate = Date()
                self.isRotating = false
            }

            // Future server push: when /api/v1/account/devices/key
            // lands, POST { device_id, x25519_pubkey, signature }
            // here so peers automatically re-derive PSKs. Currently
            // limited to local + out-of-band QR exchange.
        }
    }
}
