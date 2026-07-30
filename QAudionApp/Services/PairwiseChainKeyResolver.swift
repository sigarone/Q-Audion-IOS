import Foundation
import CryptoKit
import QAudionEngine

/// Shared, fail-closed pairwise-PSK ladder + domain-separated chain-key
/// derivation.
///
/// FIX H1-PARITY (2026-07-30): `ChatAttachAnnounceSender` and
/// `ChatAttachAnnounceReceiver` each had their OWN copy-pasted
/// `deterministicChainKey` — one of which quietly derived its "key"
/// from the two public userIds alone (no real secret), the exact
/// vulnerability class `ChatMessageSendService` already fixed once
/// under the name FIX H1. Two independent copies of the same
/// resolution logic is exactly the failure mode this project keeps
/// tripping over (see the 17-copies-of-DisplayName.forUser sweep) —
/// this is the THIRD near-identical PSK-ladder implementation about to
/// be written (for `AvatarAnnounceSender`/`Receiver`), so it is factored
/// out once here instead of copy-pasted again.
///
/// `infoLabel` provides HKDF domain separation between features that
/// share the same underlying PSK (e.g. `"attach-chain-v1"` vs.
/// `"avatar-chain-v1"`) — every caller MUST use a distinct, stable
/// label so a key derived for one purpose can never double as a valid
/// key for another, even though both derive from the same PSK.
enum PairwiseChainKeyResolver {

    enum ResolveError: Error, LocalizedError, Equatable {
        /// No real pairwise PSK bound yet for this peer (checked both
        /// the ContactKeyExchange `auto:<prefix>:<peerId>` name and the
        /// legacy bare `peerId` name). Callers must trigger a key
        /// exchange and fail the operation — NEVER fall back to a
        /// derivation of the public userIds alone.
        case pskMissing

        var errorDescription: String? {
            switch self {
            case .pskMissing: return "Scambio chiavi in corso — riprova tra poco."
            }
        }
    }

    /// Same lookup ladder as `ChatMessageSendService`:
    /// 1. `auto:<peerIdPrefix8>:<peerId>` (ContactKeyExchange-derived PSK).
    /// 2. Bare `peerId` (legacy / manually-bound).
    /// Throws `.pskMissing` — never a guessable fallback — when neither
    /// is bound.
    static func resolvePsk(peerId: String, vault: SovereignKeyVault) throws -> Data {
        let prefix = peerId.count > 8 ? String(peerId.prefix(8)) : peerId
        let autoName = "auto:\(prefix):\(peerId)"
        if let stored = try vault.loadPsk(name: autoName), !stored.isEmpty {
            return stored
        }
        if let stored = try vault.loadPsk(name: peerId), !stored.isEmpty {
            return stored
        }
        throw ResolveError.pskMissing
    }

    /// Resolves the real pairwise PSK (throws `.pskMissing` if none
    /// bound) and derives a 32-byte chain key via
    /// `HKDF-SHA256(psk, salt: "qaudion-attach-salt-v1", info: "<infoLabel>:<sortedPair>")`.
    /// `selfId`/`peerId` order doesn't matter — the sorted-pair tuple
    /// makes both ends derive the same bytes.
    static func deriveChainKey(
        selfId: String, peerId: String, infoLabel: String, vault: SovereignKeyVault
    ) throws -> Data {
        let psk = try resolvePsk(peerId: peerId, vault: vault)
        let pair = [selfId, peerId].sorted().joined(separator: ":")
        let info = Data("\(infoLabel):\(pair)".utf8)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: psk),
            salt: Data("qaudion-attach-salt-v1".utf8),
            info: info,
            outputByteCount: 32
        )
        return derived.withUnsafeBytes { Data($0) }
    }
}
