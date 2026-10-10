import Foundation
import UIKit
import CryptoKit
import QAudionEngine

/// E2EE avatar transport — the ONE place that decides "should I
/// opportunistically send my avatar to this peer right now", and the ONE
/// place that applies an inbound `avatar_announce`.
///
/// **Direct port of Android's `AvatarAnnounceCoordinator.kt`**
/// (`feature-chat/.../domain/usecase/AvatarAnnounceCoordinator.kt`, plus the
/// receive half of `ReceiveMessageUseCase.handleInboundAvatarAnnounce`).
/// Android is the only platform where a call between two devices reliably
/// exchanged avatars; this file reproduces the three properties that make
/// it work, each of which iOS was missing (2026-08-02):
///
///  1. **Send only when needed.** The triggers below are MOMENTS at which
///     the state is checked, not reasons to send. `markSent` only ever
///     proves the send LEFT the device, so the old answer to "did they get
///     it" was a periodic re-send at the same version (3 days, then 2
///     minutes for calls): the same picture went out again at every call,
///     twice, and each send is a new file plus a chat message for the
///     recipient. Now the content hash of the last avatar sent to each
///     contact is remembered, and the avatar is sent only if the content
///     changed, the contact is new (or its pair key changed), the user
///     picked a new photo, or, later, the contact reports it is missing
///     one. See `AvatarAnnouncePolicy` for the rule, what it costs, and the
///     start-of-call guard.
///  2. **Per-peer serialisation.** Both the send and the receive side run
///     one peer's work at a time (Android: a `Mutex` map on each side).
///     Without it, two triggers for the SAME peer that overlap — a call
///     connecting exactly as a queued message from that peer decrypts —
///     both pass the check-then-act version guard before either marks
///     itself sent, and on the receive side an older, slower-finishing
///     announce can overwrite a newer one's bytes in the peer avatar cache
///     even though its own contact-row write is correctly rejected.
///  3. **Mark-on-success only.** The mark is written after an outcome that
///     actually left the device, never optimistically before the upload.
///     The burst that optimistic marking was introduced to suppress (the
///     pending-sync replay loop calling this once per buffered message) is
///     handled by (2) instead: the second call runs after the first
///     finished and sees the updated bookkeeping.
///
/// Everything below the trigger decision (encrypt under the peer's own
/// pairwise chain key, tus upload, recipient capability token, `qa_ctl:1`
/// envelope) is unchanged and still lives in `AvatarAnnounceSender` /
/// `AvatarAnnounceReceiver`.
@MainActor
final class AvatarAnnounceCoordinator {

    /// What caused this check of the avatar state. Same set as the other apps'
    /// `Trigger` enum, plus the two triggers only iOS has (`keyExchange`,
    /// `avatarChanged`). Only `avatarChanged` is an explicit user action that
    /// always sends; the others send only when `AvatarAnnouncePolicy` says so.
    enum Trigger: String {
        /// A chat message from this peer decrypted successfully — proof a
        /// real pairwise PSK exists with them right now. Fires often.
        case chatDecrypt
        /// A call with this peer reached the connected/encrypted state.
        case callConnect
        /// A `ContactKeyExchange` OFFER/ACCEPT just completed, so a PSK
        /// exists where a moment ago there was none.
        case keyExchange
        /// The user just picked a new photo; `broadcastAvatarToKnownPeers`
        /// is fanning it out. An explicit action: always sends.
        case avatarChanged

        /// Compact numeric form for the remote log. The shipper's fail-closed
        /// redactor blobs any token it cannot prove structured —
        /// `trigger=callConnect` and `reason=already-marked-sent` both arrive
        /// as `[REDACTED:blob]`, which is how a whole call's worth of avatar
        /// evidence turned out to be unreadable in a log pull. `trig=2`
        /// survives intact, so every line below carries a numeric tail
        /// alongside the human-readable prose (the prose still shows in the
        /// on-device ring buffer and the Xcode console).
        var code: Int {
            switch self {
            case .chatDecrypt:   return 1
            case .callConnect:   return 2
            case .keyExchange:   return 3
            case .avatarChanged: return 4
            }
        }
    }

    private unowned let appState: AppState
    /// What already left the device, per contact (content hash, pair key, version, time).
    private let ledger: AvatarSentLedger
    /// Injectable clock and pair-key reader, so the decision is testable.
    private let now: () -> Date
    private let pairKeyId: (String) -> String
    /// When the call in progress became active (`noteCall`), nil with no call: the policy does not send in its first seconds.
    private var callActiveSince: Date?
    /// Contacts with a re-check already scheduled for when the start-of-call guard ends (one per contact is enough).
    private var guardRecheckPending: Set<String> = []

    /// Tail of the per-peer serialisation chain. A new unit of work awaits
    /// the previous one for the SAME peer before running, so check-then-act
    /// on the version bookkeeping is atomic per peer.
    private var sendChain: [String: Task<Void, Never>] = [:]
    private var receiveChain: [String: Task<Void, Never>] = [:]

    init(
        appState: AppState,
        ledger: AvatarSentLedger = AvatarSentLedger(),
        now: @escaping () -> Date = { Date() },
        pairKeyId: @escaping (String) -> String = { AvatarSentLedger.vaultPairKeyId(peerId: $0) }
    ) {
        self.appState = appState
        self.ledger = ledger
        self.now = now
        self.pairKeyId = pairKeyId
    }

    // MARK: - Send

    /// Fire-and-forget opportunistic announce. Every early return inside is
    /// a legitimate "nothing to do yet" state (no self avatar set, already
    /// sent this version recently, no PSK bound to this peer yet), not an
    /// error — nothing here ever propagates into the caller's own critical
    /// path (message receive / call connect).
    func maybeAnnounce(to peerId: String, trigger: Trigger) {
        guard !peerId.isEmpty else { return }
        _ = enqueueSend(peerId: peerId, trigger: trigger)
    }

    /// Same as ``maybeAnnounce(to:trigger:)`` but awaits completion — used
    /// by the avatar-change broadcast, which paces itself between peers.
    func announce(to peerId: String, trigger: Trigger) async {
        guard !peerId.isEmpty else { return }
        await enqueueSend(peerId: peerId, trigger: trigger).value
    }

    @discardableResult
    private func enqueueSend(peerId: String, trigger: Trigger) -> Task<Void, Never> {
        let previous = sendChain[peerId]
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            await self?.performAnnounce(to: peerId, trigger: trigger)
        }
        sendChain[peerId] = task
        return task
    }

    /// The call hook (`AppState.callConnectAvatarObserver`) reports whether a call is active, so the policy can keep the first seconds
    /// of a call free of avatar traffic. A change of state that is still active keeps the original start.
    func noteCall(active: Bool) {
        if active {
            if callActiveSince == nil { callActiveSince = now() }
        } else {
            callActiveSince = nil
        }
    }

    private func callAgeSec() -> TimeInterval? {
        guard let since = callActiveSince else { return nil }
        return max(0, now().timeIntervalSince(since))
    }

    private func performAnnounce(to peerId: String, trigger: Trigger) async {
        let peer8 = String(peerId.prefix(8))
        let trigCode = trigger.code
        let version = appState.selfAvatarVersion
        // W-AVATARSHIP2 (2026-08-02): these two skip lines were `.debug`, and
        // the device→Loki pipeline ships zero DEBUG records in practice (104
        // records across a full call: 103 INFO, 1 WARN). So the decisive
        // branch — the one that says WHY nothing was sent — was invisible in
        // every log pull, leaving "ran and skipped" indistinguishable from
        // "never ran" all over again. They are `.info` now: two lines per
        // call at most, worth their weight.
        guard version > 0 else {
            RTLog.info("avatar", "skip no-self-avatar to=\(peer8) code=1 trig=\(trigCode) selfver=0")
            return
        }
        guard let cacheURL = AvatarUploader.selfAvatarCacheURL,
              let avatarBytes = try? Data(contentsOf: cacheURL), !avatarBytes.isEmpty else {
            // Reachable state, not a corner case: a photo chosen in a build
            // that predates the E2EE transport left a server avatar_url and
            // NO local self.jpg. The user has to re-pick it once — same on
            // Android, whose AvatarFileStore has no backfill either.
            RTLog.warn("avatar", "skip self-file-missing to=\(peer8) code=3 trig=\(trigCode) selfver=\(version)")
            return
        }
        let contentHash = AvatarContentHash.hex(of: avatarBytes)
        let pairKey = pairKeyId(peerId)
        var prior = ledger.sentState(toPeer: peerId)
        if prior.contentHash == nil, ledger.lastVersionSent(toPeer: peerId) >= version {
            // Sent before the content hash was recorded, at the version of now: the same picture (the version changes with every
            // new photo). Adopt today's hash as the starting point instead of sending again to every contact after an update.
            ledger.adoptBaseline(contentHash: contentHash, pairKey: pairKey, toPeer: peerId)
            prior = ledger.sentState(toPeer: peerId)
        }
        let verdict = AvatarAnnouncePolicy.decide(
            trigger: trigger, currentHash: contentHash, currentPairKey: pairKey, prior: prior, callAgeSec: callAgeSec())
        switch verdict {
        case .skip(let cause):
            if cause == .same, prior.pairKey != pairKey, prior.pairKey == nil || prior.pairKey == AvatarSentLedger.noPairKey {
                // Nothing to send, but now there is a pair key to compare against from here on.
                ledger.recordPairKey(pairKey, toPeer: peerId)
            }
            Self.logSkip(cause, peer8: peer8, trigCode: trigCode, bytes: avatarBytes.count,
                         callAgeSec: Int(callAgeSec() ?? 0))
            if cause == .callGuard, trigger != .avatarChanged {
                scheduleGuardRecheck(for: peerId, trigger: trigger)
            }
        case .send(let cause):
            await sendEnvelope(to: peerId, peer8: peer8, trigCode: trigCode, avatarBytes: avatarBytes,
                               avatarFile: cacheURL, version: version, contentHash: contentHash, pairKey: pairKey,
                               why: cause.rawValue)
        }
    }

    /// The start-of-call guard skipped a check: look once more when it ends, if the call is still on. If the call is over by then the
    /// check is dropped on purpose: the key exchange that follows a call checks again after its own quiet period, which is the better
    /// moment than the instant a call closes.
    private func scheduleGuardRecheck(for peerId: String, trigger: Trigger) {
        guard !guardRecheckPending.contains(peerId) else { return }
        guardRecheckPending.insert(peerId)
        let wait = max(1, AvatarAnnouncePolicy.callGuardSec - (callAgeSec() ?? 0) + 1)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self else { return }
            self.guardRecheckPending.remove(peerId)
            guard self.callActiveSince != nil else { return }
            self.maybeAnnounce(to: peerId, trigger: trigger)
        }
    }

    /// The avatar goes to the contact as a file transfer v2 file of kind `avatar` (`FileV2AvatarSender`): uploaded with a key of its
    /// own for this contact and announced by a descriptor that is the body of an end-to-end encrypted chat message. The content hash
    /// is recorded ONLY when the server accepted that message (see `AvatarAnnouncePolicy` for what that does and does not prove), and
    /// a contact the chat cannot seal a message for yet is skipped (nothing is recorded, the next check tries again).
    private func sendEnvelope(
        to peerId: String,
        peer8: String,
        trigCode: Int,
        avatarBytes: Data,
        avatarFile: URL,
        version: Int,
        contentHash: String,
        pairKey: String,
        why: Int
    ) async {
        let outcome = await FileV2AvatarSender.send(avatarFile: avatarFile, to: peerId, appState: appState)
        switch outcome {
        case .sent:
            ledger.markSent(version: version, contentHash: contentHash, pairKey: pairKey, toPeer: peerId, at: now())
            Self.logSent(peer8: peer8, trigCode: trigCode, why: why, bytes: avatarBytes)
        case .noChannel:
            // Fail-closed, like Android's send path: nothing to seal under yet. The caller that owns the relationship (the
            // call-connect hook) triggers the key exchange; doing it from here as well would make every avatar attempt chatty.
            RTLog.warn("avatar", "send ok=0 code=2 to=\(peer8) version=\(version) trig=\(trigCode)")
        case .failed(let code):
            RTLog.warn("avatar", "send ok=0 code=3 to=\(peer8) version=\(version) trig=\(trigCode) v2=\(code)")
        }
    }

    // MARK: - Receive

    /// Downloads + decrypts an inbound `avatar_announce`, caches the
    /// plaintext, and stamps the contact row. Serialised per sender: the
    /// contact-row guard inside `ContactsStore.setAvatarLocalPath` protects
    /// the ROW, not the bytes written to the peer avatar cache file (a
    /// fixed path keyed only on senderId, identical across versions), so
    /// without this an older, slower announce could overwrite a newer
    /// file's bytes while its own row write is correctly rejected — the
    /// avatar visibly regresses while every stored field claims the newer
    /// version is present. Android closes the same window with
    /// `avatarLockFor(senderId)`.
    func handleInbound(_ envelope: AvatarAnnounceEnvelope, senderId: String) {
        guard !senderId.isEmpty else { return }
        let previous = receiveChain[senderId]
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            await self?.performInbound(envelope, senderId: senderId)
        }
        receiveChain[senderId] = task
    }

    private func performInbound(_ envelope: AvatarAnnounceEnvelope, senderId: String) async {
        let peer8 = String(senderId.prefix(8))
        let version = envelope.att.version
        // Version dedup INSIDE the lock (Android does the same). The caller
        // may also pre-check to avoid queueing work at all, but only this
        // one is race-free against a concurrent announce from the same peer.
        let cached = ContactsStore().load()
            .first(where: { $0.userId == senderId })?.avatarVersion ?? -1
        guard version > cached else {
            RTLog.info("avatar", "recv applied=0 code=1 from=\(peer8) version=\(version) cached=\(cached)")
            return
        }
        do {
            try envelope.att.validate()
        } catch {
            RTLog.warn("avatar", "recv applied=0 code=2 from=\(peer8) error=\(error)")
            return
        }
        await downloadAndApply(envelope, senderId: senderId, peer8: peer8, version: version, isRetry: false)
    }

    // MARK: - Receive (file transfer v2)

    /// An avatar that arrived as a v2 file of kind `avatar`, the body of a chat message from `senderId`: downloads, verifies and
    /// decrypts it, checks it is an image, and keeps it as the picture of the contact. Serialised per sender like the old announce
    /// (the same file of the peer avatar cache is written). The descriptor carries no version, so the picture is applied as the
    /// newest the contact announced: its version is the time it arrived, never below the last one.
    func handleInboundFileV2(body: String, senderId: String) {
        guard !senderId.isEmpty else { return }
        let previous = receiveChain[senderId]
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            await self?.performInboundFileV2(body: body, senderId: senderId)
        }
        receiveChain[senderId] = task
    }

    private func performInboundFileV2(body: String, senderId: String) async {
        let peer8 = String(senderId.prefix(8))
        guard let descriptor = FileV2ChatBody.descriptor(ofBody: body), descriptor.kind == .avatar,
              FileV2AutoDownloadPolicy.isAutomatic(kind: .avatar, size: descriptor.size) else {
            RTLog.warn("avatar", "recv applied=0 code=6 from=\(peer8)")
            return
        }
        // The download lands in a directory of its own in the caches directory, removed whatever happens.
        let directory = FileV2LocalFiles.directory(base: FileV2DownloadCenter.cachesBase, rowKey: "avatar-" + senderId)
        let downloaded = directory.appendingPathComponent("avatar.jpg")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let server = FileV2AppServices.makeServer(appState: appState)
            try await FileV2Receiver(server: server).download(descriptor, to: downloaded)
            let data = try Data(contentsOf: downloaded)
            let fileURL = try Self.peerAvatarFileURL(senderId: senderId)
            let outcome = try makeInboundApplier(senderId: senderId, fileURL: fileURL).apply(data)
            Self.logInbound(outcome, peer8: peer8, bytes: data.count)
        } catch let failure as FileV2Failure {
            RTLog.warn("avatar", "recv applied=0 code=5 from=\(peer8) v2=\(failure.code)")
        } catch {
            RTLog.warn("avatar", "recv applied=0 code=5 from=\(peer8) v2=io")
        }
    }

    /// The applier wired to the real file, contact store and view refresh of one sender.
    private func makeInboundApplier(senderId: String, fileURL: URL) -> AvatarInboundApplier {
        return AvatarInboundApplier(
            decodes: { UIImage(data: $0) != nil },
            readCurrent: { try? Data(contentsOf: fileURL) },
            write: { try $0.write(to: fileURL, options: [.atomic]) },
            cachedVersion: { ContactsStore().load().first(where: { $0.userId == senderId })?.avatarVersion ?? -1 },
            setLocalPath: { ContactsStore().setAvatarLocalPath(userId: senderId, path: fileURL, version: $0) },
            notify: { Self.postChatRefresh(senderId: senderId) },
            now: now)
    }

    private static func postChatRefresh(senderId: String) {
        NotificationCenter.default.post(
            name: AppState.chatRefreshNotification,
            object: nil,
            userInfo: ["peerUserId": senderId]
        )
    }

    /// Numeric tails only, in the vocabulary the log shipper lets through verbatim (`scripts/test_ship_ios_display_vocab.py`).
    /// code=7 not an image, code=8 image cut short (kind 1 JPEG, 2 PNG), code=9 same picture as the one already kept.
    private static func logInbound(_ outcome: AvatarInboundApplier.Outcome, peer8: String, bytes: Int) {
        switch outcome {
        case .applied(let version):
            RTLog.info("avatar", "recv applied=1 from=\(peer8) version=\(version) v2=1 bytes=\(bytes)")
        case .identical:
            RTLog.info("avatar", "recv applied=0 code=9 bytes=\(bytes)")
        case .incomplete(let kind):
            RTLog.warn("avatar", "recv applied=0 code=8 kind=\(kind) bytes=\(bytes)")
        case .undecodable:
            RTLog.warn("avatar", "recv applied=0 code=7 from=\(peer8) bytes=\(bytes)")
        case .notPersisted(let version):
            RTLog.info("avatar", "recv applied=0 code=3 from=\(peer8) version=\(version) bytes=\(bytes)")
        }
    }

    // MARK: - Inner-payload buffer+retry (W-AVATARPAYLOADRETRY, 2026-09-18)
    //
    // The OUTER chat ciphertext carrying this envelope already decrypted
    // fine (that failure mode is W-AVATARPOLLUTE's job, above). This is a
    // SEPARATE, later failure: `AvatarAnnounceReceiver.downloadAndDecrypt`
    // exhausted every PSK candidate bound to `senderId` and still could not
    // open the attachment AEAD — same race as W-AVATARPSKPICK (a call
    // rebinds a fresh PSK on both ends at slightly different moments), just
    // with nothing retrying the ALREADY-DOWNLOADED ciphertext afterward.
    // Before this, recovery depended entirely on the SENDER re-broadcasting
    // on its own cooldown (up to 1 hour) — this buffers the one envelope
    // that revealed the desync and replays it the instant a fresh PSK
    // lands for that sender, mirroring `bufferedOneToOneCiphertexts` /
    // `retryBufferedOneToOneMessages` exactly.
    private struct BufferedAvatarAnnounce {
        let envelope: AvatarAnnounceEnvelope
        let version: Int
    }
    private static let maxBufferedAvatarAnnouncesPerSender = 4
    private var bufferedAvatarAnnounces: [String: [BufferedAvatarAnnounce]] = [:]

    private func bufferAvatarAnnounce(_ envelope: AvatarAnnounceEnvelope, senderId: String, version: Int) {
        var list = bufferedAvatarAnnounces[senderId] ?? []
        list.append(BufferedAvatarAnnounce(envelope: envelope, version: version))
        if list.count > Self.maxBufferedAvatarAnnouncesPerSender {
            list.removeFirst()
        }
        bufferedAvatarAnnounces[senderId] = list
    }

    /// Replay every buffered avatar_announce for `senderId` — called
    /// alongside `retryBufferedOneToOneMessages` the moment this device's
    /// `ContactKeyExchange` completes for them (see `AppState
    /// .dispatchInboundOpaque`). A wire that still fails on retry is simply
    /// dropped (already logged once at first failure); this is exactly one
    /// extra attempt, never an unbounded loop.
    func retryBufferedAvatarAnnounces(for senderId: String) {
        guard let list = bufferedAvatarAnnounces.removeValue(forKey: senderId), !list.isEmpty else { return }
        let peer8 = String(senderId.prefix(8))
        Task { @MainActor [weak self] in
            guard let self else { return }
            for buffered in list {
                await self.downloadAndApply(
                    buffered.envelope, senderId: senderId, peer8: peer8,
                    version: buffered.version, isRetry: true)
            }
        }
    }

    private func downloadAndApply(
        _ envelope: AvatarAnnounceEnvelope,
        senderId: String,
        peer8: String,
        version: Int,
        isRetry: Bool
    ) async {
        do {
            let plaintext = try await AvatarAnnounceReceiver(appState: appState)
                .downloadAndDecrypt(envelope: envelope, senderId: senderId)
            let fileURL = try Self.peerAvatarFileURL(senderId: senderId)
            try plaintext.write(to: fileURL, options: [.atomic])
            let applied = ContactsStore().setAvatarLocalPath(
                userId: senderId, path: fileURL, version: version)
            guard applied else {
                // code=3 now covers BOTH "stale/duplicate announce" and "the
                // store refused to persist" — `setAvatarLocalPath` stopped
                // reporting success for a write it only attempted (see
                // ContactsStore.persisted). The plaintext is already on disk
                // at this point, so a later announce at a higher version
                // still recovers it.
                RTLog.info("avatar", "recv applied=0 code=3 from=\(peer8) version=\(version)")
                return
            }
            let retryTag: String = isRetry ? " retry=1" : ""
            RTLog.info("avatar", "recv applied=1 from=\(peer8) version=\(version)" + retryTag)
            NotificationCenter.default.post(
                name: AppState.chatRefreshNotification,
                object: nil,
                userInfo: ["peerUserId": senderId]
            )
        } catch AvatarAnnounceReceiver.ReceiveError.pskMissing {
            RTLog.warn("avatar", "recv applied=0 code=4 from=\(peer8)")
            if !isRetry {
                bufferAvatarAnnounce(envelope, senderId: senderId, version: version)
            }
            appState.triggerKeyExchange(with: senderId)
        } catch {
            let retryTag: String = isRetry ? " retry=1" : ""
            RTLog.error("avatar", "recv applied=0 code=5 from=\(peer8): \(error)" + retryTag)
            if !isRetry {
                bufferAvatarAnnounce(envelope, senderId: senderId, version: version)
            }
        }
    }

    /// Local plaintext cache file for a peer's decrypted avatar. The
    /// directory is created on demand and excluded from iCloud/iTunes
    /// backup — decrypted E2EE avatar plaintext must never ride into a
    /// device backup. `senderId` is a server-issued UUID (the server
    /// overwrites `sender_id` with the authenticated connection's own
    /// userID before relay), but it is still validated before being used
    /// as a filename component, mirroring Android's `AvatarFileStore
    /// .peerAvatarFile` defense-in-depth.
    private static func peerAvatarFileURL(senderId: String) throws -> URL {
        let cacheDir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("qaudion/avatars", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        AvatarUploader.excludeFromBackup(cacheDir)
        let safeName = UUID(uuidString: senderId) != nil
            ? senderId
            : Self.sha256Hex(senderId)
        return cacheDir.appendingPathComponent("\(safeName).jpg")
    }

    private static func sha256Hex(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Extracted so the log lines are built at statement level rather than
    /// as a long interpolation inside a closure (SWIFT6_PATTERNS.md rule 1).
    /// Numbers and short keys only, in the vocabulary the shipper lets through verbatim (`scripts/test_ship_ios_display_vocab.py`).
    /// "Ran and skipped" must never be indistinguishable from "never ran" in a log pull.
    ///
    /// Send: `why` 1 sent because the picture changed, 2 new contact device (never sent, or the pair key changed), 3 asked for
    /// (reserved); `bytes` is the size of the file sent, `side` its long side and `min` its short side in pixels.
    private static func logSent(peer8: String, trigCode: Int, why: Int, bytes: Data) {
        let size = AvatarImageGeometry.measure(bytes)
        let head: String = "send ok=1 del=0 to=" + peer8 + " trig=\(trigCode) why=\(why)"
        let body: String = " bytes=\(bytes.count) side=\(size?.longSide ?? 0) min=\(size?.shortSide ?? 0)"
        RTLog.info("avatar", head + body)
    }

    /// Skip: code 4 same picture already sent to that contact, code 5 inside the first seconds of a call (`age` is the call age).
    private static func logSkip(
        _ cause: AvatarAnnouncePolicy.SkipCause,
        peer8: String,
        trigCode: Int,
        bytes: Int,
        callAgeSec: Int
    ) {
        switch cause {
        case .same:
            let line: String = "skip same to=" + peer8 + " code=\(cause.rawValue) trig=\(trigCode) bytes=\(bytes)"
            RTLog.info("avatar", line)
        case .callGuard:
            let line: String = "skip call to=" + peer8 + " code=\(cause.rawValue) trig=\(trigCode) age=\(callAgeSec)"
            RTLog.info("avatar", line)
        }
    }
}
