import Foundation
import QAudionEngine

/// P0-5 (2026-08-05, coordinated fix plan cluster 5) — consolidated local
/// wipe for `remote_wipe` and account deletion. Neither path used to clear
/// ANY on-device crypto material: `AppState`'s `remote_wipe` handler only
/// called `authService.clearToken()`, and `AccountSettingsViewModel
/// .deleteAccount()`'s own comment claimed "Local logout — clears the
/// keychain + tokens" while its actual call (`accountApi.logout()`) is just
/// `DELETE /api/v1/auth/logout` — a network call, nothing local at all.
///
/// Every store this touches either already had NO bulk-clear method (the
/// three vault types, and the sovereign identity manager had no delete
/// method whatsoever — added alongside this file) or already had one that
/// was simply never invoked from any wipe path (`PeerIdentityPinStore`,
/// `ContactsStore`, `ConversationStore`, `ThreatReportLogStore` — all
/// confirmed working, all dead code until now).
///
/// Deliberately free functions taking no `AppState` parameter (see this
/// repo's CLAUDE.md §16 — a new file that takes `AppState` as a parameter
/// type has silently broken the TestFlight build before) so both call sites
/// (`AppState.swift`'s WS handler and `AccountSettingsViewModel`, two
/// different targets-adjacent contexts) can call it with zero coupling
/// between them.
///
/// Best-effort: every step is independent and failures are logged, never
/// thrown — a wipe that stops halfway because ONE store's Keychain call
/// failed would be worse than a wipe that keeps going and leaves that one
/// item as the only survivor. Order doesn't matter; there are no
/// cross-store dependencies here.
enum LocalCryptoWipe {
    static func wipeAll() {
        do {
            try SovereignIdentityManager().deleteIdentity()
        } catch {
            print("[LocalCryptoWipe] SovereignIdentityManager.deleteIdentity failed: \(error)")
        }
        do {
            try SovereignKeyVault().clearAll()
        } catch {
            print("[LocalCryptoWipe] SovereignKeyVault.clearAll failed: \(error)")
        }
        KeychainRatchetVault().wipeAll()
        KeychainGroupSessionVault().wipeAll()
        PeerIdentityPinStore().wipeAll()
        ContactsStore().wipeAll()
        ConversationStore().wipeAll()
        ThreatReportLogStore().wipeAll()
        print("[LocalCryptoWipe] wipeAll completed")
    }
}
