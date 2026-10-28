import QAudionEngine
import Foundation

/// What a share into the app puts in a chat: the files (already moved into the app's temporary folder) and the text.
struct ShareHandoff: Equatable {
    let peerUserId: String
    let accountId: String
    let plan: ShareHandoffPlan
    let createdAt: Date
    /// The temporary folder that holds the files of the plan.
    let folder: URL
}

extension AppState {

    /// Takes the oldest share waiting in the queue of the share extension and opens its chat. The files are moved out of the
    /// shared container into the temporary folder of the app, so nothing stays in the shared container after this.
    func takeShareQueue() {
        #if QAUDION_SHARE
        expireShareHandoffIfStale()
        sweepSharedTemporaryFolders()
        guard isAuthenticated, let accountId = currentUserId, !accountId.isEmpty,
              !(isAppLocked?() ?? false), pendingShareHandoff == nil else { return }
        let store = ShareQueueStore()
        let blocked = BlockedContactsStore.loadBlockedIds()
        for next in store.pendingEntries() {
            // The block list is read again here: a contact blocked after the share was queued gets nothing.
            if BlockPolicy.isBlocked(next.entry.peerUserId, in: blocked) {
                store.remove(folder: next.folder)
                continue
            }
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("shared-" + next.entry.id, isDirectory: true)
            guard let plan = store.take(next.entry, from: next.folder, into: destination), !plan.isEmpty else {
                store.remove(folder: next.folder)
                return
            }
            let conversationId = resolveOrCreateConversationId(forPeerUserId: next.entry.peerUserId)
            pendingShareHandoff = ShareHandoff(peerUserId: next.entry.peerUserId, accountId: accountId, plan: plan,
                                               createdAt: Date(), folder: destination)
            pendingDeepLinkConversationId = conversationId
            // A handoff nobody picked up is dropped with its files once it is no longer fresh.
            DispatchQueue.main.asyncAfter(deadline: .now() + ShareHandoffPolicy.maxAge + 1) { [weak self] in
                self?.expireShareHandoffIfStale()
            }
            return
        }
        #endif
    }

    /// Drops the pending handoff and its files.
    func discardShareHandoff() {
        guard let handoff = pendingShareHandoff else { return }
        pendingShareHandoff = nil
        try? FileManager.default.removeItem(at: handoff.folder)
    }

    /// A handoff that is too old, or that belongs to another account, is dropped: it would otherwise block the queue.
    func expireShareHandoffIfStale(now: Date = Date()) {
        guard let handoff = pendingShareHandoff else { return }
        if ShareHandoffPolicy.isStale(handoff, accountId: currentUserId ?? "", now: now) { discardShareHandoff() }
    }

    /// Removes the folders of earlier handoffs that were left in the temporary folder (a send that ended, an app that was
    /// closed in between).
    private func sweepSharedTemporaryFolders(now: Date = Date()) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let names = try? fm.contentsOfDirectory(atPath: tmp.path) else { return }
        for name in names where name.hasPrefix("shared-") {
            let url = tmp.appendingPathComponent(name, isDirectory: true)
            let created = (try? fm.attributesOfItem(atPath: url.path)[.creationDate] as? Date) ?? nil
            if ShareHandoffPolicy.shouldSweep(folder: url, created: created, now: now,
                                              protectedFolders: [pendingShareHandoff?.folder, activeShareFolder]) {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Sign-out, remote wipe or account lock: nothing of the share container or of a pending handoff stays.
    func wipeShareContainer() {
        discardShareHandoff()
        activeShareFolder = nil
        #if QAUDION_SHARE
        ShareQueueStore().removeEverything()
        #endif
    }

    /// Keeps the list of recent chats the share extension offers (names only), in builds that contain the extension.
    func refreshShareRecentChats() {
        #if QAUDION_SHARE
        // Never wipes here: before the session is restored `isAuthenticated` is still false, and the queue must survive that.
        // The queue is removed when a session ends (`wipeShareContainer`).
        guard isAuthenticated else { return }
        let store = ShareQueueStore()
        // With the app lock on, the extension shows no chat names.
        if PrivacyGate.appLockEnabled {
            store.writeRecentChats([])
            store.setRecentsHidden(true)
            return
        }
        store.setRecentsHidden(false)
        let blocked = BlockedContactsStore.loadBlockedIds()
        let chats: [ShareRecentChat] = ConversationStore().loadConversations()
            .filter { $0.kind == .oneToOne && !BlockPolicy.isBlocked($0.peerUserId, in: blocked) }
            .map { ShareRecentChat(peerUserId: $0.peerUserId, displayName: $0.peerDisplayName, lastActivity: $0.lastActivity) }
        store.writeRecentChats(chats)
        #endif
    }
}

/// How a handoff becomes sends. Pure, so it is tested without a chat screen.
enum ShareHandoffPolicy {

    static let maxAge: TimeInterval = 10 * 60

    /// Whether a `shared-*` temporary folder is removed by the sweep: only when it is old enough and is not the folder of the
    /// pending handoff or of the share the chat screen is still working through.
    static func shouldSweep(folder: URL, created: Date?, now: Date, protectedFolders: [URL?],
                            maxAge: TimeInterval = ShareHandoffPolicy.maxAge) -> Bool {
        let target = folder.standardizedFileURL
        if protectedFolders.contains(where: { $0?.standardizedFileURL == target }) { return false }
        guard let created else { return false }
        return now.timeIntervalSince(created) > maxAge
    }

    /// A handoff that is past its lifetime or belongs to an account that is no longer the signed-in one.
    static func isStale(_ handoff: ShareHandoff, accountId: String, now: Date, maxAge: TimeInterval = ShareHandoffPolicy.maxAge) -> Bool {
        handoff.accountId != accountId || now.timeIntervalSince(handoff.createdAt) > maxAge
    }

    /// A handoff is shown only in the chat of its peer, for the account that was signed in when it was taken, and only
    /// while it is fresh.
    static func applies(_ handoff: ShareHandoff?, peerUserId: String, accountId: String, now: Date,
                        maxAge: TimeInterval = ShareHandoffPolicy.maxAge) -> Bool {
        guard let handoff else { return false }
        return handoff.peerUserId == peerUserId && handoff.accountId == accountId
            && now.timeIntervalSince(handoff.createdAt) <= maxAge
    }

    /// The temporary files of a handoff, for removal when it is dropped.
    static func files(of plan: ShareHandoffPlan) -> [URL] { plan.images + plan.videos + plan.files }
}
