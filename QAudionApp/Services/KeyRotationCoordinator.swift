import Foundation
import CryptoKit
import QAudionEngine

/// Coordinates key rotation operations (display QR, rotate keys, view fingerprint).
///
/// Public API: rotate() generates a new X25519 keypair via CryptoKit,
/// computes fingerprint via Fingerprint.format(), generates IdentityQrCode
/// for sharing.
///
/// CAVEAT: Real persistence into SovereignKeyVault would require modifying
/// the USER WT integration layer. For now, coordinator just generates +
/// holds the new keys in memory and surfaces them to the UI. A follow-on
/// task wires this through to the vault once USER WT lands.
@MainActor
final class KeyRotationCoordinator: ObservableObject {

    @Published private(set) var currentFingerprint: String
    @Published private(set) var currentIdentityQr: String?
    @Published private(set) var lastRotationDate: Date?
    @Published private(set) var isRotating: Bool = false
    @Published var errorMessage: String?

    private let appState: AppState
    private var currentKeyPair: Curve25519.KeyAgreement.PrivateKey

    init(appState: AppState) {
        self.appState = appState
        // Generate a fresh keypair on init (placeholder until vault wires in).
        let keyPair = Curve25519.KeyAgreement.PrivateKey()
        self.currentKeyPair = keyPair
        let pubBytes = keyPair.publicKey.rawRepresentation
        self.currentFingerprint = (try? Fingerprint.format(pubkey: pubBytes)) ?? "????.????.????.????"
        // Compute initial QR.
        let userId = appState.currentUserId ?? "unknown-user"
        let identity = IdentityQrCode.Identity(userId: userId, pubkey: pubBytes)
        self.currentIdentityQr = try? IdentityQrCode.encode(identity: identity)
    }

    /// Rotate the keypair. Generates new X25519 + updates fingerprint + QR.
    func rotate() {
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

            await MainActor.run {
                self.currentKeyPair = newKey
                self.currentFingerprint = newFingerprint
                self.currentIdentityQr = qrString
                self.lastRotationDate = Date()
                self.isRotating = false
            }

            // Future: persist to SovereignKeyVault, send to /device/publickey
            // Both require USER WT BCryptoKmsClient public surface (commit c6e605e
            // already aligned the wire) — coordinator is ready to call when surface
            // is exposed.
        }
    }
}
