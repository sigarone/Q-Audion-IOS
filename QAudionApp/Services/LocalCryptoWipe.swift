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
        // The call history of the account that is leaving: without this the next account on the
        // device saw the previous account's calls (the encrypted file and its copies, the Keychain
        // key and the legacy UserDefaults copy were all left alone).
        wipeCallHistory()
        // XC-2: the identity-key publish confirmed-fingerprint (AppState
        // .publishIdentityKeyWithRetry) must not survive a wipe — a stale
        // entry here would make the next account's first sweep skip
        // publishing if it happened to reuse the same device id.
        UserDefaults.standard.removeObject(forKey: "com.qaudion.identity.published_fingerprint")
        print("[LocalCryptoWipe] wipeAll completed")
    }

    /// `PersistentCallRecordStore` is main-actor isolated and every caller of `wipeAll()` (logout,
    /// the remote_wipe handler, account deletion) already runs on the main thread, so the wipe is
    /// synchronous there. From any other thread it is handed to the main queue instead of crashing:
    /// it still happens, just after this function has returned. Internal, not private, so the unit
    /// tests can exercise the wiring without the Keychain vaults the rest of `wipeAll()` touches.
    static func wipeCallHistory() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                PersistentCallRecordStore.shared.wipeAccountHistory()
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    PersistentCallRecordStore.shared.wipeAccountHistory()
                }
            }
        }
    }
}
