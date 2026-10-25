import Foundation
import QAudionEngine

/// The app's side of location sharing (WIRE_SPEC section 14, docs/LOCATION_SHARING.md): where the engine's state machines
/// (`LocationShareSender`, `LocationShareReceiver`) meet the socket, the database, the keychain, the location service and the
/// screens. All the rules live in the engine; this class only wires them.
///
/// Primitive values and closures only (CLAUDE.md section 16): `AppState.initialize()` calls `configure` with closures that read the
/// current user id and the current socket at call time.
///
/// - The RECEIVER side (this file): one `LocationShareReceiver` per 1:1 conversation, built lazily over `GRDBLocationShareStore`;
///   `handleInboundBody` feeds it the live start before the row is written, `handleFrame` the `eph_relay` frames, `handleStop` and
///   `handleDeleteForEveryone` the controls, and the end triggers of 14.6.6 (block, clear, delete for me, wipe) end the shares.
/// - The SENDER side (`LocationShareCenter+Sending.swift`): one `LocationShareSender` per live share started on this device, the tick
///   timer, the location service, the stop and the recovery after a restart.
///
/// Everything the center touches outside the engine's own state (the receiver's store, the message rows and the outbox, the durable
/// path of the stop) goes through `Ports`, whose defaults are the real stores: the app tests replace them with fakes.
///
/// Nothing here logs, prints or describes a position, a key, a body or a frame: only event names, counters and short row ids.
@MainActor
final class LocationShareCenter: ObservableObject {

    static let shared = LocationShareCenter()

    /// The remote kill switch (docs/LOCATION_SHARING.md 1.9): the feature is compiled ON and the public flags file can only switch it OFF.
    static let flagKey: String = "location_share.enabled"

    /// What the build ships with: location sharing is part of the release.
    static let compiledDefault: Bool = true

    /// Whether location sharing is available: the entry points, the live strip and the settings list appear only when it is. A
    /// hidden feature must not be reachable: every way to start a share asks this first. Received cards render regardless.
    static var isFeatureEnabled: Bool {
        featureOverride ?? FeatureFlags.killSwitch(flagKey, compiledDefault: compiledDefault)
    }

    /// Test seams (internal, set only by `QAudionAppTests`): the remote switch, whether the location permission is granted, the clock in
    /// unix seconds, and the quiet notices. Production code never sets them.
    static var featureOverride: Bool?
    static var nowOverride: Int64?
    static var suppressNotices: Bool = false
    var authorizationOverride: Bool?

    // MARK: Environment

    struct Environment {
        /// The user id of this account, exactly as the server issued it (36-character lowercase UUID text).
        let currentUserId: @MainActor () -> String?
        /// Whether the persistent socket is authenticated right now.
        let socketReady: @MainActor () -> Bool
        /// Hands one `eph_relay` frame to the socket; `false` when the socket did not take it. The payload is the base64 text.
        let sendEphemeral: @MainActor (_ recipientId: String, _ payload: String) -> Bool
        /// Takes out a reason to keep the persistent socket open (W-CONNWANT): the socket stays up, in the background too, for as long as
        /// the returned token is held, and is let go when the token is released or dropped. `nil` when there is no socket to hold.
        let requestConnection: @MainActor () -> AnyObject?
    }

    var environment: Environment?

    // MARK: Ports

    /// What the center needs from the rest of the app that is not the engine's pure state. The defaults are the real database, keychain,
    /// message table, outbox and durable control path.
    @MainActor
    struct Ports {
        /// The durable store of the receiver of the shares of one conversation.
        var receiverStore: (_ peerUserId: String) -> LocationShareStore = { GRDBLocationShareStore(peerUserId: $0) }
        /// The peers that have a live record in the store (launch).
        var peersWithRecords: () -> [String] = {
            let rows = GRDBLocationShareStore.activeShares(writer: QAudionDatabase.shared.writer)
            return Array(Set(rows.map { $0.peerUserId }))
        }
        /// Forgets the ended records whose ids need no keeping any more (launch).
        var purgeEnded: (_ now: Int64) -> Void = { GRDBLocationShareStore.purgeEnded(now: $0) }
        /// The message rows and the outbox.
        var rows: LocationRowStore = ConversationLocationRows()
        /// Hands the `loc_stop` control (its JSON) for `peerUserId` to the durable control path: held until a control session and the socket
        /// exist when `held`, dropped when it cannot go at once otherwise.
        var sendStop: (_ peerUserId: String, _ json: String, _ held: Bool) -> Void = { peer, json, held in
            let delivery: ServiceSendCoordinator.Delivery = held ? .hold : .bestEffort
            Task { @MainActor in
                _ = await ServiceSendHub.shared.submit(peerId: peer, plaintext: json, label: "loc_stop", delivery: delivery)
            }
        }
    }

    var ports = Ports()

    // MARK: Published state

    /// A live share this device is sending, for the strip, the chip of the conversation list and the settings list.
    struct ActiveShare: Identifiable, Equatable {
        let id: String
        let peerUserId: String
        let conversationId: UUID
        let startedAt: Date
        let endAt: Date
    }

    @Published var activeShares: [ActiveShare] = []
    /// Bumped whenever a card could look different (a frame, a stop, an end): the views that draw cards observe it.
    @Published private(set) var revision: Int = 0
    /// A share of a previous run was found at launch and ended (WIRE_SPEC 14.6.1 rule 10): the user is told once.
    @Published var interruptedNotice: Bool = false

    // MARK: Receiver state

    var receivers: [String: LocationShareReceiver] = [:]
    /// The ids of the shares that were live the last time `refreshReceivers` looked, to notice the moment one ends.
    var liveReceived: [String: String] = [:]
    var housekeepingTimer: Timer?
    var observersInstalled: Bool = false
    var didStart: Bool = false
    var knownBlocked: Set<String> = []
    /// The received shares whose row already follows the timer of its conversation (or never will): they are not looked at again.
    var expirySettled: Set<String> = []

    // MARK: Sender state (see LocationShareCenter+Sending.swift)

    struct SendRun {
        let sender: LocationShareSender
        let startClientMsgId: String
        let peerUserId: String
        let conversationId: UUID
        let startedAt: Int64
        let duration: Int64
    }

    var runs: [String: SendRun] = [:]
    /// The peer of each start this device sent (the stop of a share that already ended still has to be addressed).
    var peerByStart: [String: String] = [:]
    var tickTimers: [String: Timer] = [:]
    var endTimers: [String: Timer] = [:]
    /// Senders that ended and still wait for the `msg_sent` echo of their start (a stop held until then, rule 2), and the senders the
    /// recovery after a restart built. They hold no key.
    var waitingForEcho: [String: LocationShareSender] = [:]
    /// The starts whose `msg_sent` echo already arrived (a share that ends afterwards has no stop to hold).
    var echoedStarts: Set<String> = []
    /// The starts that were withdrawn (they never left): a send that was being prepared when the share ended must send nothing.
    var withdrawnStarts: Set<String> = []
    /// Own shares that ended in this process (or were found ended at launch) and whose row has not yet been given the timer of its
    /// conversation: the client message id and the moment the share ended.
    var ownEnded: [String: Int64] = [:]
    var lowPower: Bool = false
    /// The reason held to keep the socket open while a share of this device runs: the frames ride that socket, also with the screen off.
    var connectionToken: AnyObject?
    /// True while `accountLeft` ends the shares: a stop is then dropped if it cannot go at once, never held for the next account.
    var accountClosing: Bool = false
    var journal: LocationShareJournal = GRDBLocationShareJournal()

    /// How long a row that is not found is waited for (an inbound row is written a moment after the share is created) before the share
    /// is given up as having no row to follow the timer.
    static let rowGraceSeconds: Int64 = 120

    private init() {}

    // MARK: Setup

    func configure(_ environment: Environment) {
        self.environment = environment
        installObserversIfNeeded()
    }

    private func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true
        knownBlocked = BlockedContactsStore.loadBlockedIds()
        let center = NotificationCenter.default
        center.addObserver(forName: .blockedContactsDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in LocationShareCenter.shared.blockListChanged(blockedNow: BlockedContactsStore.loadBlockedIds()) }
        }
        center.addObserver(forName: FeatureFlags.didRefreshNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in LocationShareCenter.shared.flagsRefreshed() }
        }
        center.addObserver(forName: PeerIdentityPinStore.didChangeNotification, object: nil, queue: .main) { note in
            let contactId: String = (note.userInfo?["contactId"] as? String) ?? ""
            Task { @MainActor in LocationShareCenter.shared.peerIdentityChanged(peerUserId: contactId) }
        }
        center.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in LocationShareCenter.shared.powerStateChanged() }
        }
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        // The location service itself is not touched here: it is created, and its callbacks bound, when the first share starts
        // (`installLiveHandlers`), so a build with the remote switch off never so much as creates a location manager.
    }

    static func nowUnix() -> Int64 {
        nowOverride ?? Int64(Date().timeIntervalSince1970)
    }

    func didChange() {
        revision += 1
    }

    // MARK: Receiver: building

    /// The receiver of the shares of the conversation with `peerId`, built over the database and the keychain on first use. `nil` when
    /// nobody is signed in or the store cannot be read.
    func shareReceiver(forPeer peerId: String) -> LocationShareReceiver? {
        if let existing = receivers[peerId] { return existing }
        guard let selfId = environment?.currentUserId(), !selfId.isEmpty, !peerId.isEmpty else { return nil }
        let store: LocationShareStore = ports.receiverStore(peerId)
        guard let built = try? LocationShareReceiver(selfId: selfId, peerId: peerId, store: store, now: Self.nowUnix()) else {
            return nil
        }
        if BlockedContactsStore.isBlocked(peerId) { built.blockPeer(now: Self.nowUnix()) }
        receivers[peerId] = built
        noteLiveShares(peerUserId: peerId)
        if !liveReceived.isEmpty { ensureHousekeeping() }
        return built
    }

    // MARK: Receiver: inbound start

    enum InboundDecision {
        /// Write the row (a pin, a live start whose share was created, a start that was created ended, a placeholder).
        case record
        /// Write nothing: a duplicate start, or a start that a delete for everyone overtook (no live-share card is ever shown for it).
        case skipRow
    }

    /// A decrypted chat body that begins with the location prefix, from `senderId`, BEFORE its row is written. It is given as the bytes
    /// exactly as decrypted (WIRE_SPEC 14.3.2): a body whose bytes are not valid UTF-8 is `bad_location`, never one that was repaired into
    /// text first. A valid live start is given to the receiver of that conversation (the key goes to the keychain, the record to the
    /// database: write first, then the row, so that a start redelivered after a crash is still a duplicate); a pin and a rejected body
    /// need nothing here (the write boundary of the store shows the fixed label or the placeholder). Never throws and never keeps the body.
    func handleInboundBody(_ body: Data, senderId: String, clientMsgId: String?, viaMesh: Bool) -> InboundDecision {
        let channel: LocationChannel = viaMesh ? .mesh : .chat
        switch LocationCodec.recognize(utf8: body, channel: channel) {
        case .notLocation:
            return .record
        case .rejected(let rejection):
            LocationTelemetry.rejected(rejection.rawValue)
            return .record
        case .location(let found):
            guard case .live(let start, let position) = found else { return .record }
            guard let clientId = clientMsgId, !clientId.isEmpty, let receiver = shareReceiver(forPeer: senderId) else {
                return .record
            }
            let now: Int64 = Self.nowUnix()
            let outcome: LocationReceiveOutcome = receiver.receiveStart(clientMsgId: clientId, live: start, position: position, now: now)
            noteLiveShares(peerUserId: senderId)
            didChange()
            ensureHousekeeping()
            if case .dropped = outcome { return .skipRow }
            if let view = receiver.share(id: clientId, now: now), view.noCard { return .skipRow }
            return .record
        }
    }

    /// The row of an inbound message was written: a start that was created already ended (expired on arrival, stopped before it came,
    /// superseded) has no moment at which it "ends" while the app looks, so its row starts to follow the timer now.
    func inboundStartRecorded() {
        sweepEndedExpiries()
    }

    // MARK: Receiver: frames and controls

    /// An `eph_relay` frame from `senderId` (the server stamps it), `payload` the base64 text.
    func handleFrame(senderId: String, payload: String) {
        guard !senderId.isEmpty, senderId != environment?.currentUserId(), let receiver = receivers[senderId] ?? shareReceiver(forPeer: senderId) else {
            return
        }
        let outcome: LocationReceiveOutcome = receiver.receiveFrame(payload: payload, now: Self.nowUnix())
        if case .dropped(let reason) = outcome {
            LocationTelemetry.frameDropped(reason.rawValue)
        }
        didChange()
        refreshReceivers()
    }

    /// A `loc_stop` control that `senderId` sent. The engine applies the author check and remembers a stop that overtook its start.
    func handleStop(senderId: String, target: String) {
        guard !senderId.isEmpty, senderId != environment?.currentUserId(), let receiver = shareReceiver(forPeer: senderId) else { return }
        _ = receiver.receiveStop(from: .peer, target: target, now: Self.nowUnix())
        didChange()
        refreshReceivers()
    }

    /// A delete for everyone that `senderId` sent for `target`, after the platform's own author check passed (or for a target that no
    /// row names, which the engine remembers for exactly TOMBSTONE_KEEP seconds).
    func handleDeleteForEveryone(senderId: String, target: String) {
        guard !senderId.isEmpty, senderId != environment?.currentUserId(), let receiver = shareReceiver(forPeer: senderId) else { return }
        _ = receiver.receiveDeleteForEveryone(from: .peer, target: target, now: Self.nowUnix())
        didChange()
        refreshReceivers()
    }

    // MARK: Receiver: local end triggers

    /// The conversation with `peerUserId` was cleared or deleted (from the chat or from the list): the shares end, those received and
    /// those sent, and their keys, positions and cards go; the two ids of each start stay (WIRE_SPEC 14.6.2 step 1).
    func conversationCleared(peerUserId: String) {
        shareReceiver(forPeer: peerUserId)?.endAllForLocalClear(now: Self.nowUnix())
        stopShares(forPeer: peerUserId, reason: "cleared", final: .now)
        didChange()
        refreshReceivers()
    }

    /// "Delete for me" of a row. A received start ends its share (the card goes, the ids stay); an own live row ends the share.
    func rowDeletedForMe(clientMsgId: String, peerUserId: String) {
        shareReceiver(forPeer: peerUserId)?.deleteForMe(id: clientMsgId, now: Self.nowUnix())
        if runs[clientMsgId] != nil { stopShare(startClientMsgId: clientMsgId, reason: "deleted", final: .onTick) }
        didChange()
        refreshReceivers()
    }

    /// The user deleted their own row for everyone: an own live row ends the share too.
    func ownRowDeletedForEveryone(clientMsgId: String) {
        if runs[clientMsgId] != nil { stopShare(startClientMsgId: clientMsgId, reason: "deleted", final: .onTick) }
        didChange()
    }

    /// The blocked list changed. `blockedNow` is the list as it is now.
    func blockListChanged(blockedNow now: Set<String>) {
        let added: Set<String> = now.subtracting(knownBlocked)
        let removed: Set<String> = knownBlocked.subtracting(now)
        knownBlocked = now
        for peer in added {
            receivers[peer]?.blockPeer(now: Self.nowUnix())
            if receivers[peer] == nil { shareReceiver(forPeer: peer)?.blockPeer(now: Self.nowUnix()) }
            stopShares(forPeer: peer, reason: "blocked", final: .now)
        }
        for peer in removed {
            receivers[peer]?.unblockPeer()
        }
        didChange()
        refreshReceivers()
    }

    /// The identity keys known for `peerUserId` changed (a rotation, or a device added to its account): the shares with it end.
    func peerIdentityChanged(peerUserId: String) {
        guard !peerUserId.isEmpty else { return }
        stopShares(forPeer: peerUserId, reason: "key_changed", final: .now)
    }

    /// Logout, remote wipe or account deletion: every share ends and everything held for the account is forgotten. The database and the
    /// keychain are wiped by `LocalCryptoWipe` (the deletion of the whole local store).
    func accountLeft() {
        accountClosing = true
        stopAllShares(reason: "logout", final: .now)
        accountClosing = false
        for timer in tickTimers.values { timer.invalidate() }
        for timer in endTimers.values { timer.invalidate() }
        tickTimers.removeAll()
        endTimers.removeAll()
        runs.removeAll()
        peerByStart.removeAll()
        waitingForEcho.removeAll()
        echoedStarts.removeAll()
        withdrawnStarts.removeAll()
        ownEnded.removeAll()
        expirySettled.removeAll()
        receivers.removeAll()
        liveReceived.removeAll()
        housekeepingTimer?.invalidate()
        housekeepingTimer = nil
        activeShares = []
        interruptedNotice = false
        connectionToken = nil
        // Ends the sampling of a share that ran; with none (the remote switch off, or no share ever started) there is no location
        // manager to touch, and none is made here.
        endSamplingIfAny()
        didChange()
    }

    // MARK: Receiver: housekeeping

    func ensureHousekeeping() {
        guard housekeepingTimer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            Task { @MainActor in LocationShareCenter.shared.refreshReceivers() }
        }
        RunLoop.main.add(timer, forMode: .common)
        housekeepingTimer = timer
    }

    /// Brings every receiver to the present (a share whose end time passed is ENDED whether or not anybody looked) and notices the
    /// shares that ended: their row starts to follow the timer of the conversation, `expiresAt = end + timer` (docs 1.3).
    func refreshReceivers() {
        let now: Int64 = Self.nowUnix()
        var stillLive: [String: String] = [:]
        for (peerId, receiver) in receivers {
            receiver.advance(now: now)
            for view in receiver.shares(now: now) {
                if view.state != .ended { stillLive[view.id] = peerId }
            }
        }
        var anyEnded = false
        for id in liveReceived.keys where stillLive[id] == nil { anyEnded = true }
        liveReceived = stillLive
        sweepEndedExpiries()
        if anyEnded { didChange() }
        if stillLive.isEmpty && runs.isEmpty {
            housekeepingTimer?.invalidate()
            housekeepingTimer = nil
        }
    }

    /// Notes the live shares a receiver holds (called after a start was created), so that their end is noticed.
    func noteLiveShares(peerUserId: String) {
        guard let receiver = receivers[peerUserId] else { return }
        for view in receiver.shares(now: Self.nowUnix()) where view.state != .ended {
            liveReceived[view.id] = peerUserId
        }
    }

    // MARK: The timer of an ended share

    /// The row of a share that ended starts to follow the timer of its conversation: `expiresAt = end + timer` (docs 1.3). Idempotent and
    /// state-based: it looks at the row, not at how the share came to end, so it covers a start created ended, a share that ended while
    /// the app was closed, an own share found ended at launch, and every end that happens in this process. A row that already has an
    /// expiry, a deleted row and a conversation without a timer are left as they are. Returns `false` only when there is no such row (yet).
    @discardableResult
    func applyEndedExpiry(clientMsgId: String, endedAt: Int64) -> Bool {
        guard let row = ports.rows.row(forClientMsgId: clientMsgId) else { return false }
        if row.deleted || row.hasExpiry { return true }
        guard let timer = row.timerSeconds, timer > 0 else { return true }
        let expiry: Date = Date(timeIntervalSince1970: Double(endedAt)).addingTimeInterval(Double(timer))
        ports.rows.setExpiresAt(rowId: row.rowId, to: expiry)
        return true
    }

    /// Gives the timer to every ended live row that does not follow it yet: the received shares that are ENDED and have a card, and the
    /// own shares that ended in this process. A share whose row is not found is tried again at the next sweep for a short while, then
    /// given up.
    func sweepEndedExpiries() {
        let now: Int64 = Self.nowUnix()
        for (_, receiver) in receivers {
            for view in receiver.shares(now: now) where view.state == .ended && !view.noCard && !expirySettled.contains(view.id) {
                let endedAt: Int64 = view.endedAt ?? now
                if applyEndedExpiry(clientMsgId: view.id, endedAt: endedAt) || now - endedAt > Self.rowGraceSeconds {
                    expirySettled.insert(view.id)
                }
            }
        }
        for (id, endedAt) in ownEnded {
            if applyEndedExpiry(clientMsgId: id, endedAt: endedAt) || now - endedAt > Self.rowGraceSeconds {
                ownEnded[id] = nil
            }
        }
    }

    // MARK: Launch

    /// Once per process: the temporary files of earlier runs are swept, the shares of a previous run of this device are ended (rule 10)
    /// and the receivers reconcile their stores.
    func startOnce() {
        guard !didStart else { return }
        didStart = true
        LocationCardActions.sweepGpxFolder()
        start()
    }

    /// Launch: the ids of the ended starts that no longer need keeping are forgotten, every receiver reconciles its store (a share whose
    /// counter or key cannot be read ends as `state_lost`), and the shares of a previous run of this device that were live are ended
    /// (rule 10). Every ended live row then follows the timer of its conversation.
    func start() {
        ports.purgeEnded(Self.nowUnix())
        recoverSendsAfterRestart()
        for peer in ports.peersWithRecords() {
            _ = shareReceiver(forPeer: peer)
        }
        for (peerId, _) in receivers { noteLiveShares(peerUserId: peerId) }
        refreshReceivers()
        if !liveReceived.isEmpty { ensureHousekeeping() }
    }

    // MARK: Observers' targets

    func flagsRefreshed() {
        if !Self.isFeatureEnabled {
            stopAllShares(reason: "flag_off", final: .now)
        }
    }

    private func powerStateChanged() {
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        applyLowPowerToRuns()
    }

    /// The location permission may have changed. Nothing is asked of the location service unless a share runs.
    func authorizationChanged() {
        guard !runs.isEmpty else { return }
        let permitted: Bool = authorizationOverride ?? LocationService.shared.isAuthorized
        if !permitted {
            stopAllShares(reason: "permission", final: .now)
        }
    }

    /// Ends the sampling of the location service, but only when the service exists: it is never created just to be told to stop.
    func endSamplingIfAny() {
        if LocationService.hasInstance { LocationService.shared.endLiveSampling() }
    }
}
