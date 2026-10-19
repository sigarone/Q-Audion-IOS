import Foundation
import QAudionEngine

/// BLOCK — the single entry for blocking and unblocking a contact, used by every screen that offers it
/// (contact detail, contacts list and its blocked tab, the chat menu, the older contacts list).
///
/// It runs the shared `ContactBlockCoordinator`: the server is asked first and the local list
/// (`BlockedContactsStore`, which the receive paths read) changes only after the server accepted. A failure
/// changes nothing locally and is shown with a "Riprova" action that runs the same call again, so the app
/// never claims a block the server does not have.
///
/// Block semantics (the same on every platform): directional. Once the user blocked S, nothing S starts
/// reaches the user: private messages, calls, the pushes for them, private file announcements, group invites.
/// S cannot put the user into a group: the server refuses an add by S and an add into a group S manages, and
/// the device, as a second line, refuses an add only when the actor is S (the server is authoritative for adds
/// by other admins). A group call S created never rings on the device, whether or not the two share a group;
/// a group call created by someone else in which S takes part works as usual. Messages S writes in a group
/// both are already in still arrive (group content is not filtered), and so does the group key material that
/// carries them: from S the device accepts only the sender keys of a group the user is already in and the key
/// of a group call the user is in now. S is never told about the block.
@MainActor
final class ContactBlockService {

    static let shared = ContactBlockService()

    /// Where the coordinator finds the signed-in backend; bound by `AppState.initialize()`.
    private final class ApiSource {
        var provider: () -> ContactsApi? = { nil }
    }

    let coordinator: ContactBlockCoordinator
    private let source: ApiSource

    private init() {
        let box = ApiSource()
        self.source = box
        self.coordinator = ContactBlockCoordinator(api: { box.provider() }, storage: BlockedContactsStorage())
    }

    /// Point the service at the signed-in backend. Idempotent.
    func bind(contactsApi: @escaping () -> ContactsApi?) {
        source.provider = contactsApi
    }

    /// The refresh that is running or waiting to retry. A new request replaces it (the latest one wins), and
    /// `forgetAccount` ends it.
    private var refreshTask: Task<Void, Never>?

    /// Replace the local list by the server's (sign-in, a new backend, app start, every socket reconnect). At
    /// most once a minute. A failure, or no backend yet, is retried a few times with a growing delay
    /// (`BlockPolicy.refreshRetryDelays`), so a list that could not be fetched at sign-in does not
    /// stay empty until the next reconnect; the failed attempts leave the list as it was.
    func refreshFromServerIfDue() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            _ = await self.coordinator.refreshFromServerWithRetry()
        }
    }

    /// The account that was signed in is gone (sign-out, remote wipe, account deletion): its list goes too,
    /// the refresh it had running or waiting is ended, and an answer the server still owes it is discarded
    /// (`ContactBlockCoordinator.forgetSession`), so it cannot put the old list back for the next account.
    func forgetAccount() {
        refreshTask?.cancel()
        refreshTask = nil
        coordinator.forgetSession()
        BlockedContactsStore.clear()
    }

    /// Block (`blocked == true`) or unblock a contact and tell the user how it went. Returns true when the
    /// server and the local list now agree on the wanted state. The caller refreshes its own state from
    /// `BlockedContactsStore.isBlocked`, never from the result alone.
    @discardableResult
    func setBlocked(_ blocked: Bool,
                    userId: String,
                    displayName: String,
                    snackbar: QAudionSnackbarHostState?) async -> Bool {
        let outcome = await coordinator.setBlocked(blocked, userId: userId)
        switch outcome {
        case .applied:
            snackbar?.show(.init(text: Self.doneText(blocked: blocked, name: displayName), severity: .info))
            return true
        case .failed(.accountChanged):
            // The account that asked has signed out: nothing was changed and a retry would act on the next one.
            return false
        case .failed:
            snackbar?.show(.init(
                text: Self.failedText(blocked: blocked),
                severity: .error,
                actionLabel: Self.retryLabel,
                onAction: { [weak snackbar] in
                    Task { @MainActor in
                        await ContactBlockService.shared.setBlocked(
                            blocked, userId: userId, displayName: displayName, snackbar: snackbar)
                    }
                },
                durationSeconds: 8))
            return false
        }
    }

    // MARK: - Texts

    static func doneText(blocked: Bool, name: String) -> String {
        if blocked {
            return String(localized: "contact_detail.contact_blocked", defaultValue: "\(name) bloccato.", comment: "Snackbar — a contact was blocked, %@ is their display name")
        }
        return String(localized: "contact_detail.contact_unblocked", defaultValue: "\(name) sbloccato.", comment: "Snackbar — a contact was unblocked, %@ is their display name")
    }

    static func failedText(blocked: Bool) -> String {
        if blocked {
            return String(localized: "contact_block.block_failed", defaultValue: "Impossibile bloccare il contatto. Controlla la connessione e riprova.", comment: "Snackbar error — the block request did not reach the server, so nothing was blocked; shown with a Retry action.")
        }
        return String(localized: "contact_block.unblock_failed", defaultValue: "Impossibile sbloccare il contatto. Controlla la connessione e riprova.", comment: "Snackbar error — the unblock request did not reach the server, so the contact is still blocked; shown with a Retry action.")
    }

    static var retryLabel: String {
        String(localized: "chat_detail.retry_action", defaultValue: "Riprova", comment: "Snackbar action button label to retry sending a failed message.")
    }
}
