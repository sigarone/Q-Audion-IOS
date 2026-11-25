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
        // A sign-out waiting for the server belongs to the session being wiped (remote wipe, account deletion):
        // there is nothing left to send it with. `AppState.logout()` stores its own after this call.
        TokenVault.clearPendingLogout()
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
        // What is remembered in memory about the chat sessions' bindings went with them.
        MessageRatchet.bindingsVaultWiped()
        // What was learned about the account's contacts from the server goes too.
        ContactShieldPublished.forgetAccount()
        KeychainGroupSessionVault().wipeAll()
        PeerIdentityPinStore().wipeAll()
        // The capability pins are account data: logout, remote wipe and account deletion all come through here. The arming flag
        // is not: only the full-wipe call sites clear it (`CapsPinBook.clearAll`).
        CapsPinBook.shared.clearPins()
        ContactsStore().wipeAll()
        // The "address book imported" mark belongs to the account that is leaving (logout, remote wipe and account deletion all
        // come through here): the next account must run "Importa" itself before a refresh scans anything.
        PhonebookImportGate().clear()
        ConversationStore().wipeAll()
        // The live-share records, the tombstones, the sender's journal and the keys of the shares: the deletion of the whole local
        // store, which is the one thing that takes the ids of the starts with it (WIRE_SPEC 14.6.2 step 1).
        GRDBLocationShareStore.wipeEverything()
        ThreatReportLogStore().wipeAll()
        // The owner voice ("Voce come chiave") learned from the account that is leaving: the template, the learning record
        // (windows, account, final mark) and, through the learner's generation, the windows of a call that is still running.
        // The next account must not start from this account's voice. Reported like any other failed step.
        wipeOwnerVoice()
        // The voices learned of the contacts of the account that is leaving: every running or post-call engine is stopped first,
        // then the records, the meta file and the key are deleted under the lock of the store. A failure is reported.
        wipeContactVoice()
        // The call history of the account that is leaving: without this the next account on the
        // device saw the previous account's calls (the encrypted file and its copies, the Keychain
        // key and the legacy UserDefaults copy were all left alone).
        wipeCallHistory()
        // The custom TURN server of the account that is leaving: its address and its credentials in the Keychain.
        TransportPreferences().clearAll()
        // XC-2: the identity-key publish confirmed-fingerprint (AppState
        // .publishIdentityKeyWithRetry) must not survive a wipe — a stale
        // entry here would make the next account's first sweep skip
        // publishing if it happened to reuse the same device id.
        UserDefaults.standard.removeObject(forKey: "com.qaudion.identity.published_fingerprint")
        // The fixed created_ms of this device's extra signature certificate and the keys of peers kept in memory belong
        // to the account that is leaving.
        UserDefaults.standard.removeObject(forKey: "com.qaudion.identity.mldsa_xc_created_v1")
        PeerMldsaStore.clear()
        MldsaOwnPublicationState.reset()
        // The notification key and the list of names and avatars of the notification extension.
        NotifyKeychain.production()?.delete()
        if let directory = NotifyRubricaFiles.defaultDirectory() { NotifyRubricaFiles.clear(in: directory) }
        // The log shipper's queue on disk belongs to the account that is leaving (logout, account switch, account
        // deletion and remote wipe all come through here).
        clearLiveLogQueue()
        // The decrypted attachment copies on disk (caches and temporary files) of the account that is leaving.
        AttachmentCacheCleaner.clearAllCaches()
        print("[LocalCryptoWipe] wipeAll completed")
    }

    /// Removes everything of the owner's voice that the phone keeps and reads each item again. Every removal is tried; what is
    /// still there (or cannot be read to tell) is printed like any failed step of the wipe. `true` when nothing is left. The
    /// learner is a parameter so a test can aim it at memory.
    @discardableResult
    static func wipeOwnerVoice(_ learner: OwnerVoiceLearner = OwnerVoiceLearner()) -> Bool {
        let left = learner.wipe()
        if !left.isEmpty {
            print("[LocalCryptoWipe] OwnerVoiceLearner.wipe left: \(left.map(\.rawValue).joined(separator: ","))")
        }
        return left.isEmpty
    }

    /// Removes the voices that the phone learned of the contacts (the contact-voice check): the engines of the calls that are running
    /// or doing their post-call work are stopped and discarded, then the records, `meta.bin` and the key are deleted. `true` when
    /// nothing is left; a failure is printed like any failed step and returned, never swallowed.
    @discardableResult
    static func wipeContactVoice() -> Bool {
        let clean = VoiceCallWiring.wipeAll()
        if !clean {
            print("[LocalCryptoWipe] the contact voice wipe left something")
        }
        return clean
    }

    /// Deletes the saved log queue so lines of the account that leaves cannot be uploaded under the next one.
    /// The queue is a parameter so a test can aim it at a temporary file.
    static func clearLiveLogQueue(_ queue: LiveLogDiskQueue = LiveLogDiskQueue.inCaches()) {
        queue.delete()
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
