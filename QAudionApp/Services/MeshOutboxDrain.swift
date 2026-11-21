import Foundation
import QAudionEngine

/// Drives `MeshOutboxStore` (docs/mesh/MESH_LINK_SPEC.md section 10.2).
///
/// - A message that a first hop accepted is "sent", NOT delivered: it stays in the
///   outbox and is retransmitted every 20 s (a new packet around the same sealed shell, so
///   the receiver's duplicate check on the shell id makes a second copy harmless) until
///   a valid delivery receipt arrives (`acknowledged`).
/// - A message is never stranded here: when `MeshFallbackPolicy` says so (no receipt after 120 s and the
///   network is usable, the radio is off, or the one-hour limit) it leaves this outbox and becomes an
///   ordinary row of the network outbox (`handOver`), which seals and sends it like any other text. It is
///   never marked failed by this type.
/// - A receipt that cannot be sent right away is queued the same way, and leaves the
///   outbox once a first hop accepted it.
///
/// Owns the `ConversationStore` write for both outcomes directly, so a retry that lands
/// (or finally expires) updates the user's chat history even if that conversation isn't
/// the one on screen right now — mirrors Android's `PendingSendOrchestrator` draining
/// independently of any open chat.
///
/// `ConversationStore`, not `AppState`: this is a plain `Services/*.swift` type
/// instantiating `ConversationStore` directly, the same pattern
/// `BackupCoordinator`/`EphemeralMessageJanitor`/`LocalCryptoWipe` already use — see
/// CLAUDE.md §16 for why `AppState` itself is never taken as a parameter type in a new
/// file.
@MainActor
final class MeshOutboxDrain {
    static let shared = MeshOutboxDrain()

    private let outbox: MeshOutboxStore
    private let store: ConversationStore
    private var timer: Timer?
    private var inFlight: Set<String> = []
    private var lastReachable: Set<String> = []

    /// How often the outbox is looked at. An entry is retried once its own 20 s have passed
    /// (`MeshOutboxPolicy.retryMs`); this only bounds how late that can happen.
    private static let tickSeconds: TimeInterval = 5

    init(outbox: MeshOutboxStore = .shared, store: ConversationStore = ConversationStore()) {
        self.outbox = outbox
        self.store = store
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.drainAndSweep()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Queues a send and tries it right away. The entry stays until a delivery receipt (message) or a
    /// first-hop acceptance (receipt) says otherwise.
    func submit(_ entry: MeshOutboxEntry) {
        outbox.enqueue(entry)
        drainAndSweep()
    }

    /// A delivery or read receipt for `clientMsgId` arrived: the message has been delivered, so it leaves the outbox.
    func acknowledged(clientMsgId: String) {
        outbox.acknowledge(clientMsgId: clientMsgId)
        MeshBtPromptStore.shared.set(.idle, messageId: clientMsgId)
    }

    /// The set of reachable peers changed: a target that just became reachable is retried without waiting out
    /// the full interval.
    func reachabilityChanged() {
        let reachable = Set(MeshRuntime.shared.peers.filter { $0.connected }.map { $0.nodeHex })
        guard reachable != lastReachable else { return }
        lastReachable = reachable
        drainAndSweep()
    }

    /// The signalling socket authenticated again: rows past the deadline go to the network now.
    func networkReconnected() {
        drainAndSweep(trigger: .reconnect)
    }

    /// The antenna was switched off: nothing will send these over Bluetooth any more.
    func radioTurnedOff() {
        handOverDue(nowMs: Int64(Date().timeIntervalSince1970 * 1000), trigger: .timer)
    }

    /// An entry stored by an earlier build has no Bluetooth-only value. It gets the one the contact's current routing
    /// preference and armed target give; when that cannot be told it counts as Bluetooth only (held and asked about). A
    /// message that comes out Bluetooth only also gets the hold on its row.
    private func normalizeLegacyEntries() {
        outbox.normalizeLegacy { entry in
            guard !entry.peerUserId.isEmpty, !entry.conversationId.isEmpty else { return true }
            let only = MeshFallbackPolicy.isBluetoothOnly(
                preference: MeshRoutingPreferenceStore().preference(for: entry.peerUserId),
                armedMeshTarget: MeshRuntime.shared.activeTarget(for: entry.conversationId) != nil)
            if only, let mid = UUID(uuidString: entry.messageId) { store.setBluetoothHold(id: mid, hold: true) }
            return only
        }
    }

    private func handOverDue(nowMs: Int64, trigger: MeshFallbackPolicy.Trigger) {
        normalizeLegacyEntries()
        // At a cold start the socket can authenticate before the stored antenna mode is restored: until the app has decided
        // about the antenna, "no mode yet" is not "radio off" (`MeshFallbackPolicy.radioIsOff`).
        let radioOff = MeshFallbackPolicy.radioIsOff(
            featureEnabled: MeshFeature.enabled,
            modeRequested: MeshRuntime.shared.requestedMode != nil,
            decisionSettled: MeshRuntime.shared.antennaDecisionSettled)
        let usable = ChatOutboxDrain.shared.isTransportUsable
        // "Prefer Bluetooth": silent, automatic.
        for candidate in outbox.fallbackCandidates(nowMs: nowMs, networkUsable: usable, radioOff: radioOff, trigger: trigger) {
            handOver(candidate.entry, reason: candidate.reason)
        }
        // "Bluetooth only": never sent here. The user is asked, or the message is parked after the limit.
        let prompts = MeshBtPromptStore.shared
        for item in outbox.bluetoothOnlyActions(
            nowMs: nowMs, networkUsable: usable, radioOff: radioOff, stateOf: { prompts.state(messageId: $0) }) {
            switch item.action {
            case .prompt:
                prompts.set(.prompted, messageId: item.entry.id)
            case .park:
                prompts.set(.undelivered, messageId: item.entry.id)
            case .none:
                break
            }
            postChatRefresh(item.entry, conversationId: UUID(uuidString: item.entry.conversationId) ?? UUID())
        }
    }

    /// "Invia via internet": the user chose the internet for this message. Hands it to the network outbox (the same
    /// sealing and sending as any text). Works whether or not the mesh still holds an entry for it.
    func userChoseInternet(messageId: String) {
        MeshBtPromptStore.shared.set(.idle, messageId: messageId)
        if let entry = outbox.entry(id: messageId) {
            handOver(entry, reason: .userChoice)
            return
        }
        guard let found = store.findByClientMsgId(messageId),
              found.message.direction == .outgoing,
              found.message.status == .sending || found.message.status == .sent,
              let conversation = store.loadConversations().first(where: { $0.id == found.conversationId }) else { return }
        UserNetworkApprovalStore.shared.approve(messageId: messageId)
        store.setBluetoothHold(id: found.message.id, hold: false)
        store.updateMessageStatus(id: found.message.id, conversationId: found.conversationId, newStatus: .sending, viaMesh: false)
        NotificationCenter.default.post(
            name: AppState.chatRefreshNotification, object: nil,
            userInfo: ["peerUserId": conversation.peerUserId, "conversationId": found.conversationId])
        ChatOutboxDrain.shared.adoptFromMesh(row: found.message, peerUserId: conversation.peerUserId)
    }

    /// Whether the Bluetooth outbox holds an entry for this message.
    func hasEntry(messageId: String) -> Bool {
        outbox.entry(id: messageId) != nil
    }

    /// "No, continua via Bluetooth" (the prompt) or "Riprova via Bluetooth" (after the limit): the message stays on
    /// Bluetooth and the prompt is not shown again until the next one-hour limit. After the limit the entry gets a fresh
    /// clock and the same sealed shell, so it is sent again.
    func userKeptBluetooth(messageId: String) {
        guard let entry = outbox.entry(id: messageId) else {
            // No Bluetooth entry: the chat re-runs the routing from the stored row (`ChatContainer.keepOnBluetooth`); this is only
            // the fallback when it cannot, and the message stays held.
            MeshBtPromptStore.shared.set(.undelivered, messageId: messageId)
            return
        }
        let wasParked = MeshBtPromptStore.shared.state(messageId: messageId) == .undelivered
        MeshBtPromptStore.shared.set(.declined, messageId: messageId)
        if wasParked {
            outbox.enqueue(MeshOutboxEntry(
                id: entry.id, kind: entry.kind, messageId: entry.messageId, conversationId: entry.conversationId,
                peerUserId: entry.peerUserId, targetNodeHex: entry.targetNodeHex, payloadB64: entry.payloadB64,
                createdAtMs: Int64(Date().timeIntervalSince1970 * 1000), bluetoothOnly: true))
            drainAndSweep()
        }
        if let cid = UUID(uuidString: entry.conversationId) { postChatRefresh(entry, conversationId: cid) }
    }

    /// The message leaves the Bluetooth outbox and joins the network outbox: the row goes back to `.sending` (not via
    /// Bluetooth), and the normal drain seals and sends it. A row that is already delivered, read or gone is only dropped
    /// from this outbox.
    private func handOver(_ entry: MeshOutboxEntry, reason: MeshFallbackReason) {
        // Judged now, against the CURRENT policy: the hold on the stored row is authoritative, and so is a switch of the contact to
        // Bluetooth only after the message was queued. Either way the message stays on Bluetooth, the row is held and the user is
        // asked (parked at the one-hour limit); it goes to the network only by the user's answer.
        let currentlyBluetoothOnly = MeshFallbackPolicy.isBluetoothOnly(
            preference: MeshRoutingPreferenceStore().preference(for: entry.peerUserId),
            armedMeshTarget: MeshRuntime.shared.activeTarget(for: entry.conversationId) != nil)
        let rowHeld = store.findByClientMsgId(entry.id)?.message.bluetoothHold == true
        if case .hold(let prompt) = MeshFallbackPolicy.handOverDecision(
            reason: reason, rowHeld: rowHeld, currentlyBluetoothOnly: currentlyBluetoothOnly) {
            outbox.setBluetoothOnly(id: entry.id, true)
            if let mid = UUID(uuidString: entry.messageId) { store.setBluetoothHold(id: mid, hold: true) }
            let current = MeshBtPromptStore.shared.state(messageId: entry.id)
            if current == .idle || (prompt == .undelivered && current != .undelivered) {
                MeshBtPromptStore.shared.set(prompt, messageId: entry.id)
            }
            if let cid = UUID(uuidString: entry.conversationId) { postChatRefresh(entry, conversationId: cid) }
            return
        }
        outbox.remove(id: entry.id)
        let ph = MeshLog.payloadHash(Data(base64Encoded: entry.payloadB64) ?? Data())
        MeshLog.emit(.fallback, [("ph", ph), ("reason", reason.rawValue)])
        guard let mid = UUID(uuidString: entry.messageId),
              let cid = UUID(uuidString: entry.conversationId),
              let found = store.findByClientMsgId(entry.id),
              found.message.direction == .outgoing,
              found.message.status == .sending || found.message.status == .sent else { return }
        if reason == .userChoice {
            UserNetworkApprovalStore.shared.approve(messageId: entry.id)
            store.setBluetoothHold(id: mid, hold: false)
        }
        store.updateMessageStatus(id: mid, conversationId: cid, newStatus: .sending, viaMesh: false)
        MeshBtPromptStore.shared.set(.idle, messageId: entry.id)
        postChatRefresh(entry, conversationId: cid)
        ChatOutboxDrain.shared.adoptFromMesh(row: found.message, peerUserId: entry.peerUserId)
    }

    func drainAndSweep(trigger: MeshFallbackPolicy.Trigger = .timer) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        handOverDue(nowMs: nowMs, trigger: trigger)
        let reachable = Set(MeshRuntime.shared.peers.filter { $0.connected }.map { $0.nodeHex })
        let due = outbox.due(nowMs: nowMs, reachableTargets: reachable)
        var retried = 0
        for entry in due where !inFlight.contains(entry.id) {
            if entry.attempts > 0 { retried += 1 }
            attempt(entry)
        }
        let gaveUp = sweepExpired(nowMs: nowMs)
        let pending = outbox.pendingCount()
        if pending > 0 || gaveUp > 0 {
            MeshLog.emit(.outbox, [("pending", String(pending)), ("retried", String(retried)), ("gaveUp", String(gaveUp))])
        }
    }

    private func sweepExpired(nowMs: Int64) -> Int {
        let expired = outbox.expired(nowMs: nowMs)
        for entry in expired {
            // A Bluetooth-only message is parked with a persistent state at the limit, never handed over or failed.
            if entry.kind == .message, entry.bluetoothOnly == true { continue }
            if entry.kind == .message {
                // Normally already handed over by `handOverDue`; a message is never failed here.
                handOver(entry, reason: .giveup)
            } else {
                outbox.remove(id: entry.id)
                logApp(entry, state: "failed", attempt: entry.attempts)
            }
        }
        return expired.count
    }

    private func attempt(_ entry: MeshOutboxEntry) {
        guard let payload = Data(base64Encoded: entry.payloadB64) else {
            // An undecodable payload can never succeed over Bluetooth: a message goes to the network path (a Bluetooth-only
            // one asks the user first), a receipt is dropped.
            if entry.kind == .message, entry.bluetoothOnly == true {
                outbox.remove(id: entry.id)
                MeshBtPromptStore.shared.set(.undelivered, messageId: entry.id)
            } else if entry.kind == .message {
                handOver(entry, reason: .giveup)
            } else {
                outbox.remove(id: entry.id)
                logApp(entry, state: "failed", attempt: entry.attempts)
            }
            return
        }
        inFlight.insert(entry.id)
        MeshRuntime.shared.sendData(toNodeHex: entry.targetNodeHex, payload: payload, type: entry.packetType) { [weak self] report in
            Task { @MainActor in
                self?.attempted(entry, report: report)
            }
        }
    }

    private func attempted(_ entry: MeshOutboxEntry, report: MeshSendReport) {
        inFlight.remove(entry.id)
        var accepted = false
        switch report.result {
        case .sentDirect, .sentViaRelay:
            accepted = true
        case .queued, .failed:
            accepted = false
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let outcome = outbox.recordAttempt(id: entry.id, nowMs: nowMs, accepted: accepted)
        let attemptNumber = entry.attempts + 1
        switch outcome {
        case .firstAcceptance:
            markSent(entry)
            logApp(entry, state: "sent", attempt: attemptNumber)
        case .removed:
            // A receipt a first hop accepted, or an entry that left the outbox while this attempt was in flight
            // (its receipt arrived first).
            if accepted { logApp(entry, state: "sent", attempt: attemptNumber) }
        case .retained:
            logApp(entry, state: accepted ? "sent" : "queued", attempt: attemptNumber)
        }
    }

    /// A first hop accepted the message: "sent" (one tick). The second tick still comes from the peer's own
    /// `MeshReceipt`, so a message that is only sent stays in the outbox.
    private func markSent(_ entry: MeshOutboxEntry) {
        guard entry.kind == .message,
              let mid = UUID(uuidString: entry.messageId),
              let cid = UUID(uuidString: entry.conversationId) else { return }
        store.updateMessageStatus(id: mid, conversationId: cid, newStatus: .sent, viaMesh: true)
        postChatRefresh(entry, conversationId: cid)
    }

    private func postChatRefresh(_ entry: MeshOutboxEntry, conversationId: UUID) {
        NotificationCenter.default.post(
            name: AppState.chatRefreshNotification, object: nil,
            userInfo: ["peerUserId": entry.peerUserId, "conversationId": conversationId]
        )
    }

    private func logApp(_ entry: MeshOutboxEntry, state: String, attempt: Int) {
        let kind = entry.kind == .message ? "msg" : "rcpt"
        let ph = MeshLog.payloadHash(Data(base64Encoded: entry.payloadB64) ?? Data())
        MeshLog.emit(.appTx, [("ph", ph), ("kind", kind), ("state", state), ("attempt", String(attempt))])
    }
}
