import Foundation
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
///  1. **Per-trigger cooldown.** A re-announce is allowed even when
///     `version` has not changed, because `markSent` only ever proves the
///     send LEFT the device — never that the recipient's download+decrypt
///     succeeded. iOS used a single 3-DAY interval for every trigger,
///     which is the same value Android measured (commit `1bb68750`, read
///     off the A36's `qaudion_avatar_prefs.xml`) to be a mathematically
///     guaranteed no-op for both peers of any call inside a normal usage
///     session: a cooldown only bounds a silent failure if it can expire
///     while the user is still using the app. A real CALL is rare,
///     explicit, and exactly the moment the peer's avatar is on screen, so
///     it gets a 2-minute floor (kept non-zero only to collapse duplicates
///     across back-to-back reconnects of the same conversation); the
///     background chat-decrypt trigger keeps 1 hour.
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

    /// What caused this announce attempt — governs the re-announce
    /// cooldown. Mirrors Android's `Trigger` enum, plus the two triggers
    /// only iOS has (`keyExchange`, `avatarChanged`).
    enum Trigger: String {
        /// A chat message from this peer decrypted successfully — proof a
        /// real pairwise PSK exists with them right now. Fires often, so
        /// it keeps the long cooldown.
        case chatDecrypt
        /// A call with this peer reached the connected/encrypted state.
        case callConnect
        /// A `ContactKeyExchange` OFFER/ACCEPT just completed, so a PSK
        /// exists where a moment ago there was none. As rare and as
        /// explicit as a call — same short cooldown.
        case keyExchange
        /// The user just picked a new photo; `broadcastAvatarToKnownPeers`
        /// is fanning it out. `version` has just been bumped, so the
        /// cooldown is not what gates this one.
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

    /// Background trigger ceiling — see the class doc, point 1.
    private static let chatResendIntervalSec: TimeInterval = 60 * 60
    /// Call / key-exchange trigger ceiling — see the class doc, point 1.
    private static let callResendIntervalSec: TimeInterval = 2 * 60

    // W-AVATARSTUCK (2026-07-31) — `.v2` keys; the pre-tus-fix entries under
    // the old names are deliberately orphaned, never migrated.
    private static let sentVersionsKey = "qaudion.avatarSentVersions.v2"
    private static let sentAtKey = "qaudion.avatarSentAt.v2"

    private unowned let appState: AppState

    /// Tail of the per-peer serialisation chain. A new unit of work awaits
    /// the previous one for the SAME peer before running, so check-then-act
    /// on the version bookkeeping is atomic per peer.
    private var sendChain: [String: Task<Void, Never>] = [:]
    private var receiveChain: [String: Task<Void, Never>] = [:]

    init(appState: AppState) {
        self.appState = appState
    }

    private static func cooldownSec(for trigger: Trigger) -> TimeInterval {
        switch trigger {
        case .chatDecrypt:  return chatResendIntervalSec
        case .callConnect:  return callResendIntervalSec
        case .keyExchange:  return callResendIntervalSec
        case .avatarChanged: return 0
        }
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
        let priorSent = Self.lastVersionSent(toPeer: peerId)
        let priorSentAt = Self.lastSentAt(toPeer: peerId)
        let cooldown = Self.cooldownSec(for: trigger)
        let staleEnoughToRetry = priorSentAt.map {
            Date().timeIntervalSince($0) >= cooldown
        } ?? true
        if priorSent >= version && !staleEnoughToRetry {
            let ageSec: Int = priorSentAt.map { Int(Date().timeIntervalSince($0)) } ?? -1
            Self.logSkipAlreadySent(
                peer8: peer8, trigCode: trigCode, priorSent: priorSent,
                version: version, ageSec: ageSec, cooldownSec: Int(cooldown))
            return
        }
        guard let cacheURL = AvatarUploader.selfAvatarCacheURL,
              let jpegBytes = try? Data(contentsOf: cacheURL) else {
            // Reachable state, not a corner case: a photo chosen in a build
            // that predates the E2EE transport left a server avatar_url and
            // NO local self.jpg. The user has to re-pick it once — same on
            // Android, whose AvatarFileStore has no backfill either.
            RTLog.warn("avatar", "skip self-file-missing to=\(peer8) code=3 trig=\(trigCode) selfver=\(version)")
            return
        }
        await sendEnvelope(to: peerId, peer8: peer8, trigCode: trigCode,
                           jpegBytes: jpegBytes, version: version)
    }

    /// Extracted so the send body stays one `do/catch` deep — see
    /// SWIFT6_PATTERNS.md rule 4.
    private func sendEnvelope(
        to peerId: String,
        peer8: String,
        trigCode: Int,
        jpegBytes: Data,
        version: Int
    ) async {
        do {
            let json = try await AvatarAnnounceSender(appState: appState).prepareEnvelopeJson(
                avatarJpegBytes: jpegBytes, recipientUserId: peerId, version: version)
            let outcome = await ChatMessageSendService(appState: appState).sendEncrypted(
                messageId: UUID(), peerUserId: peerId, plaintext: json)
            // `sendEncrypted` NEVER throws — every failure (WS down, auth
            // timeout, PSK missing, crypto error) is a RETURNED `.failed`.
            // Only an outcome that actually left the device may be marked.
            switch outcome {
            case .delivered, .sent:
                Self.markSent(version: version, toPeer: peerId)
                // W-AVATARDELIVERY (2026-08-13) — `.delivered` (peer
                // confirmed) and `.sent` (queued/left the device, no
                // delivery confirmation) used to collapse into the same
                // `ok=1` — indistinguishable from here whether the peer's
                // device ever actually got this. Reported live:
                // `AvatarAnnounceCoordinator` shows a clean `send ok=1` for
                // a peer that ALSO never shows a single `recv applied=`
                // line at that version, hours later. `del` separates
                // "confirmed reaching them" from "left here, unconfirmed"
                // without a new log line.
                let delivered: Int = { if case .delivered = outcome { return 1 }; return 0 }()
                RTLog.info("avatar", "send ok=1 del=\(delivered) to=\(peer8) version=\(version) trig=\(trigCode)")
            case .failed(let reason):
                RTLog.warn("avatar", "send ok=0 code=1 to=\(peer8) version=\(version) trig=\(trigCode) reason=\(reason)")
            }
        } catch AvatarAnnounceSender.SendError.pskMissing {
            // Fail-closed, exactly like Android's send path: no PSK bound to
            // this contact yet, so there is nothing to encrypt under. The
            // caller that owns the relationship (the call-connect hook)
            // triggers the key exchange; doing it from here as well would
            // make every avatar attempt wire-chatty.
            RTLog.warn("avatar", "send ok=0 code=2 to=\(peer8) version=\(version) trig=\(trigCode)")
        } catch {
            RTLog.warn("avatar", "send ok=0 code=3 to=\(peer8) version=\(version) trig=\(trigCode) error=\(error)")
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
        await downloadAndApply(envelope, senderId: senderId, peer8: peer8, version: version)
    }

    private func downloadAndApply(
        _ envelope: AvatarAnnounceEnvelope,
        senderId: String,
        peer8: String,
        version: Int
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
            RTLog.info("avatar", "recv applied=1 from=\(peer8) version=\(version)")
            NotificationCenter.default.post(
                name: AppState.chatRefreshNotification,
                object: nil,
                userInfo: ["peerUserId": senderId]
            )
        } catch AvatarAnnounceReceiver.ReceiveError.pskMissing {
            RTLog.warn("avatar", "recv applied=0 code=4 from=\(peer8)")
            appState.triggerKeyExchange(with: senderId)
        } catch {
            RTLog.error("avatar", "recv applied=0 code=5 from=\(peer8): \(error)")
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

    // MARK: - Sent-version bookkeeping
    //
    // Same UserDefaults keys and same semantics as Android's
    // `AvatarFileStore` sent-version prefs: the pair records that a send
    // LEFT the device at a given version and time — never that the
    // recipient decrypted it, which is why the cooldown above exists.

    private static func lastVersionSent(toPeer peerId: String) -> Int {
        let dict = UserDefaults.standard.dictionary(forKey: sentVersionsKey) as? [String: Int] ?? [:]
        return dict[peerId] ?? -1
    }

    private static func lastSentAt(toPeer peerId: String) -> Date? {
        let dict = UserDefaults.standard.dictionary(forKey: sentAtKey) as? [String: Double] ?? [:]
        guard let ts = dict[peerId] else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    private static func markSent(version: Int, toPeer peerId: String, at: Date = Date()) {
        var dict = UserDefaults.standard.dictionary(forKey: sentVersionsKey) as? [String: Int] ?? [:]
        dict[peerId] = version
        UserDefaults.standard.set(dict, forKey: sentVersionsKey)
        var atDict = UserDefaults.standard.dictionary(forKey: sentAtKey) as? [String: Double] ?? [:]
        atDict[peerId] = at.timeIntervalSince1970
        UserDefaults.standard.set(atDict, forKey: sentAtKey)
    }

    /// Extracted so the skip line is built at statement level rather than
    /// as a six-segment interpolation inside a closure (SWIFT6_PATTERNS.md
    /// rule 1). Logged because this is the exact state that cost days of
    /// investigation on Android: "ran and skipped" must never be
    /// indistinguishable from "never ran" in a log pull.
    private static func logSkipAlreadySent(
        peer8: String,
        trigCode: Int,
        priorSent: Int,
        version: Int,
        ageSec: Int,
        cooldownSec: Int
    ) {
        let head: String = "skip already-sent to=" + peer8 + " code=2"
        let body: String = " trig=\(trigCode) priorsent=\(priorSent) version=\(version)"
        let tail: String = " age=\(ageSec) cd=\(cooldownSec)"
        RTLog.info("avatar", head + body + tail)
    }
}
