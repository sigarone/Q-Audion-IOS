import Foundation

/// Drives an N-way audio-only group call over the server-side SFU.
/// Direct port of Android's `feature/feature-call/.../domain/GroupCallController.kt`,
/// using the SAME per-sender `GroupSession`/`GroupSenderKey` ratchet (already
/// live cross-platform for group TEXT CHAT) instead of the old insecure
/// server-decryptable shared room key (`SHA-256(callId || "qaudion-group-v1")`).
///
/// Responsibilities:
/// 1. Bridge to `BCryptoGroupCallManager` for the WebSocket protocol
///    (group_call_create / join / leave / forward) — VERIFIED against the
///    live `cmd/bcrypto-lite/main.go` handlers (2026-07-13), see that
///    file's header comment for the previous dead-protocol mismatch.
/// 2. Bootstrap + maintain one `GroupSession` per call: exactly one own
///    send chain, one recv chain per other participant, populated as
///    `sender_key_init`/`sender_key_rotate` control envelopes arrive.
/// 3. W-GRPREKEY: rekey our own send chain on ANY member departure,
///    converging on the server-canonical `sender_key_epoch` (same trick as
///    Android — see `handleDepartures`).
/// 4. On send: capture mic → Opus encode → seal under our OWN send chain
///    (single ciphertext, every recipient can open it) → ship via
///    `forwardAudioFrame` (server broadcasts to all, no per-recipient
///    targeting exists on the wire).
/// 5. On receive: open under the sender's recv chain (per-sender Opus
///    decoder state) → push PCM into the shared playback jitter buffer.
public final class GroupCallController: @unchecked Sendable {

    public enum State: Equatable {
        case idle
        case connecting(callId: String)
        case active(callId: String, participants: [String])
        case failed(reason: String)
    }

    public private(set) var state: State = .idle
    public var onStateChange: ((State) -> Void)?

    private let manager: BCryptoGroupCallManager
    private let lock = NSLock()
    private var muted = false
    /// Per-sender Opus decoders (one per peer; Opus state is stateful
    /// across frames — sharing one decoder across senders desyncs).
    private var perSenderDecoders: [String: OpusCodec] = [:]
    private let encoder: OpusCodec = OpusCodec()

    // ─── W-GRPSENDERKEY: per-sender group keying ───────────────────────

    private let groupSession = GroupSession()
    private var groupState: GroupState?
    private var activeCallId: String?
    private var senderKeysCapable: Set<String> = []
    /// Peers we've already sent our `sender_key_init` to this call — gates
    /// [sealForTransmit] so we never seal audio for a roster we haven't
    /// distributed keys to yet (mirrors Android's `initSentTo`).
    private var initSentTo: Set<String> = []

    // ─── Control-envelope transport: the SAME pairwise 1:1 crypto used for
    // chat (own Keychain-backed instances — `KeychainRatchetVault`/
    // `SovereignKeyVault` have no per-Swift-instance state, they read/write
    // the SAME physical Keychain items AppState's `sharedV4Ratchet` and
    // chat's send/receive paths use, so a v4/v3 session bootstrapped by a
    // prior 1:1 call or chat interaction with this peer is visible here
    // too). No v1/v2 legacy fallback: this is a brand-new wire shape
    // (`qa_grpcall_ctrl`) that only ever ships between clients that both
    // already run this code, so there is no old peer to interoperate with.
    // Matches FIX H1 (chat's own PSK-missing refusal): never falls back to
    // a server-derivable key — a peer with no real pairwise session/PSK
    // simply doesn't receive the control envelope (best-effort, logged).

    private static let ctrlRatchetVault: RatchetVault = KeychainRatchetVault()
    private static let ctrlRatchet = MessageRatchet(vault: ctrlRatchetVault)
    private static let ctrlPskVault = SovereignKeyVault()

    // W358: optional audio I/O pipeline. When set via
    // `attachAudioPipeline()`, the controller takes ownership of the
    // capture source (mic → PCM → encrypt → forward) and the playback
    // sink (incoming PCM → playback). Both are ManagedLifecycle: start
    // fires when the call enters .active, stop fires on teardown.
    private var capture: AudioCapture?
    private var playback: AudioPlayback?

    // XP-crackle — same fix as CallService's txAudioQueue: AudioCapture's
    // input tap runs on a dedicated real-time Core Audio thread, and
    // `sendOutgoingPcmFrame` used to run there synchronously (Opus encode +
    // seal + WS forward). Hand off to this dedicated SERIAL queue instead —
    // serial so frames are still processed in capture order.
    private let txAudioQueue = DispatchQueue(
        label: "com.bcrypto.qaudion.groupcall.tx-audio-encode", qos: .userInitiated)

    public init(manager: BCryptoGroupCallManager) {
        self.manager = manager
        wireManagerCallbacks()
    }

    // MARK: - Public API

    /// Create a new group call and invite the listed peers.
    /// Returns the freshly-minted call id (also held internally), or nil if
    /// the manager refused (already in a call).
    @discardableResult
    public func createCall(invitees: [String], title: String = "") -> String? {
        guard let callId = manager.createGroupCall(recipients: invitees, title: title) else {
            return nil
        }
        bootstrapGroupSession(callId: callId, initialPeers: invitees)
        setState(.connecting(callId: callId))
        return callId
    }

    public func join(callId: String) {
        bootstrapGroupSession(callId: callId, initialPeers: [])
        manager.joinGroupCall(callId: callId)
        setState(.connecting(callId: callId))
    }

    public func leave() {
        manager.leaveGroupCall()
        stopAudioPipeline()
        teardown()
    }

    public func endCallForAll() {
        manager.endGroupCall()
        stopAudioPipeline()
        teardown()
    }

    public func setMuted(_ muted: Bool) {
        lock.lock(); self.muted = muted; lock.unlock()
    }

    public var isMuted: Bool {
        lock.lock(); defer { lock.unlock() }; return muted
    }

    /// Hook for the audio-capture path: feed one captured Opus frame
    /// (already-encoded) to be sealed under our own sender-key send chain
    /// and shipped to every other participant via the SFU (single relay,
    /// no per-recipient targeting — see `BCryptoGroupCallManager.forwardAudioFrame`).
    public func sendOutgoingOpusFrame(_ opus: Data) {
        guard !isMuted else { return }
        guard let sealed = sealForTransmit(plaintext: opus) else { return }
        manager.forwardAudioFrame(sealed)
    }

    /// Convenience wrapper: encode raw PCM → seal → forward in one step.
    public func sendOutgoingPcmFrame(_ pcm: Data) {
        guard let opus = encoder.encode(pcm) else { return }
        sendOutgoingOpusFrame(opus)
    }

    /// PCM frames produced from the inbound stream are surfaced through
    /// this callback — the AppState wires this into the AudioPlayback
    /// jitter buffer (one shared buffer; multiple talkers interleave at
    /// frame granularity until a real N-source mixer lands).
    public var onIncomingPcmFrame: ((String, Data) -> Void)?

    /// W358: bind the in-process AudioCapture (mic) and AudioPlayback
    /// (speaker) lifecycles to this call.
    public func attachAudioPipeline(capture: AudioCapture, playback: AudioPlayback) {
        lock.lock()
        self.capture = capture
        self.playback = playback
        lock.unlock()
        capture.onFrame = { [weak self] pcm in
            // XP-crackle — off the real-time tap thread; see txAudioQueue kdoc.
            self?.txAudioQueue.async { [weak self] in
                self?.sendOutgoingPcmFrame(pcm)
            }
        }
        // Default sink: dump incoming PCM into the jitter buffer.
        onIncomingPcmFrame = { [weak self] _, pcm in
            self?.playback?.playFrame(pcm)
        }
    }

    /// Manually start the audio pipeline. Called from the state
    /// transition into .active; safe to invoke multiple times.
    public func startAudioPipeline() throws {
        lock.lock()
        let capture = self.capture
        let playback = self.playback
        lock.unlock()
        if let playback = playback {
            try? playback.start()
        }
        if let capture = capture {
            try capture.start()
        }
    }

    /// Stop the audio pipeline. Idempotent.
    public func stopAudioPipeline() {
        lock.lock()
        let capture = self.capture
        let playback = self.playback
        lock.unlock()
        capture?.stop()
        playback?.stop()
    }

    /// Receive side of the `qa_grpcall_ctrl` opaque-message wrapper (see
    /// `AppState.dispatchInboundOpaque`, Path C). The app layer decrypts the
    /// outer 1:1 envelope (it owns the WS/opaque_message plumbing) and hands
    /// us the PLAINTEXT `{qa_grp:1, t:..., g:..., e:..., seed:..., idx:?}`
    /// JSON string plus the sender id. Silently ignores anything not for
    /// THIS active call — chat's own `qa_grp:1` envelopes never reach here
    /// (they ride the regular message channel, not opaque_message).
    public func onGroupCallControlEnvelope(json: String, fromUserId: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
        guard (obj["qa_grp"] as? NSNumber)?.intValue == 1 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let gs = groupState, let callId = activeCallId else { return }
        let expectedG = GroupSenderKey.toHex(Data(callId.utf8))
        guard obj["g"] as? String == expectedG else { return }
        switch obj["t"] as? String {
        case "sender_key_init":
            guard let e = (obj["e"] as? NSNumber)?.uint32Value,
                  let seed = obj["seed"] as? String,
                  let idx = (obj["idx"] as? NSNumber)?.uint64Value else { return }
            let env = SenderKeyInitEnvelope(g: expectedG, e: e, seed: seed, idx: idx)
            do {
                try groupSession.handleSenderKeyInit(state: gs, env: env, fromUserId: fromUserId)
            } catch {
                print("[GroupCallController] handleSenderKeyInit failed sender=\(fromUserId): \(error)")
            }
        case "sender_key_rotate":
            guard let e = (obj["e"] as? NSNumber)?.uint32Value,
                  let seed = obj["seed"] as? String else { return }
            let env = SenderKeyRotateEnvelope(g: expectedG, e: e, seed: seed)
            do {
                try groupSession.handleSenderKeyRotate(state: gs, env: env, fromUserId: fromUserId)
            } catch {
                print("[GroupCallController] handleSenderKeyRotate failed sender=\(fromUserId): \(error)")
            }
        default:
            break // not ours
        }
    }

    /// Send-side hook the app layer calls to actually ship a control
    /// envelope (it owns `BCryptoWebSocketClient.sendOpaqueMessage`). We
    /// build the plaintext JSON + seal it via the shared pairwise ratchet;
    /// the app layer wraps the result in `{qa_grpcall_ctrl:1,cmid,blob}` and
    /// sends it. Kept as a pure function (no WS dependency) so this engine
    /// target never needs to import the App-layer WS client.
    public func sealControlEnvelope(peer: String, selfId: String, envelopeJson: String) -> (clientMsgId: String, wire: Data)? {
        let msgId = UUID().uuidString
        let plaintext = Data(envelopeJson.utf8)
        if Self.ctrlRatchet.hasV4Session(peer) {
            guard let frame = Self.ctrlRatchet.encryptV4Routed(peerId: peer, plaintext: plaintext),
                  let first = frame.first, first == MessageRatchet.magicV4 else {
                print("[GroupCallController] control envelope v4 encrypt failed peer=\(peer)")
                return nil
            }
            return (msgId, frame)
        }
        guard let psk = Self.resolvePsk(peer: peer) else {
            print("[GroupCallController] no pairwise session/PSK for \(peer) — control envelope dropped")
            return nil
        }
        do {
            let session = try Self.ctrlRatchet.ensureSession(
                epochId: "v1", selfId: selfId, peerId: peer, pskRoot: psk)
            let aad = MessageRatchet.buildMessageAD(senderId: selfId, recipientId: peer, clientMsgId: msgId)
            let wire = try Self.ctrlRatchet.encrypt(session: session, plaintext: plaintext, aad: aad, clientMsgId: msgId)
            return (msgId, wire)
        } catch {
            print("[GroupCallController] control envelope v3 encrypt failed peer=\(peer): \(error)")
            return nil
        }
    }

    /// Receive-side counterpart of `sealControlEnvelope`: unwraps the
    /// pairwise ciphertext into the plaintext `qa_grp:1` JSON string. The
    /// app layer (which already parsed the `qa_grpcall_ctrl` wrapper and
    /// base64-decoded `blob`) calls this, then forwards the result to
    /// `onGroupCallControlEnvelope`.
    public static func openControlEnvelope(wire: Data, senderId: String, selfId: String, clientMsgId: String) -> String? {
        if MessageWireFormat.detect(wire) == .v4 {
            guard let plain = ctrlRatchet.decryptV4Routed(peerId: senderId, frame: wire) else { return nil }
            return String(data: plain, encoding: .utf8)
        }
        guard let psk = resolvePsk(peer: senderId) else { return nil }
        guard let session = try? ctrlRatchet.ensureSession(
            epochId: "v1", selfId: selfId, peerId: senderId, pskRoot: psk) else { return nil }
        let aad = MessageRatchet.buildMessageAD(senderId: senderId, recipientId: selfId, clientMsgId: clientMsgId)
        guard let plain = ctrlRatchet.decrypt(session: session, wire: wire, aad: aad) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    // MARK: - Internals

    /// Forwards `BCryptoGroupCallManager`'s raw state 1:1, for UI consumers
    /// (`GroupCallViewModel`) that want the manager's simple state machine
    /// rather than this controller's richer `State`. `manager.onStateChanged`
    /// is a single-slot closure — this controller MUST be its sole owner, so
    /// any other consumer (the ViewModel) observes THIS passthrough instead
    /// of touching `manager.onStateChanged` directly. Without this
    /// indirection, constructing a `GroupCallViewModel` against the same
    /// manager after this controller would silently overwrite
    /// `manager.onStateChanged` and break the audio-pipeline start/teardown
    /// logic below (this exact conflict was latent — never exercised —
    /// because neither type had a real call site until now).
    public var onManagerStateChanged: ((BCryptoGroupCallManager.State) -> Void)?
    /// Same passthrough rationale as `onManagerStateChanged`, for
    /// `manager.onParticipantsChanged`.
    public var onParticipantsChanged: (([BCryptoGroupCallManager.Participant]) -> Void)?

    private func wireManagerCallbacks() {
        manager.onStateChanged = { [weak self] s in
            guard let self = self else { return }
            self.onManagerStateChanged?(s)
            switch s {
            case .creating:
                if case .connecting = self.state { /* keep */ }
                else if let cid = self.manager.callId {
                    self.setState(.connecting(callId: cid))
                }
            case .active:
                if let cid = self.manager.callId {
                    let parts = self.manager.participants.map(\.id)
                    self.setState(.active(callId: cid, participants: parts))
                    do { try self.startAudioPipeline() }
                    catch { print("[GroupCallController] startAudioPipeline failed: \(error)") }
                }
            case .ended:
                self.stopAudioPipeline()
                self.teardown()
            case .idle:
                self.setState(.idle)
            }
        }
        manager.onParticipantsChanged = { [weak self] list in
            self?.onParticipantsChanged?(list)
        }
        manager.onGroupUpdate = { [weak self] callId, participants, capable, epoch in
            self?.onUpdate(callId: callId, participants: participants, senderKeysCapable: capable, senderKeyEpoch: epoch)
        }
        manager.onAudioFrame = { [weak self] senderId, frame in
            self?.handleIncomingFrame(senderId: senderId, sealed: frame)
        }
    }

    /// W-GRPSENDERKEY: bootstrap any newly-seen capable member into our
    /// GroupSession roster + ship them our current sender_key_init.
    /// W-GRPREKEY: rekey our own send chain on ANY member departure.
    ///
    /// All `groupState` reads/mutations happen under `lock`; the actual
    /// control-envelope sends (which invoke the app-layer
    /// `onSendControlEnvelope` closure — real crypto + a network call) are
    /// deferred until AFTER `lock` is released, so a slow/blocking send
    /// never holds up a concurrent `sendOutgoingOpusFrame`/`handleIncomingFrame`
    /// on another queue.
    private func onUpdate(callId: String, participants: [String], senderKeysCapable: Set<String>, senderKeyEpoch: Int64) {
        let selfId = manager.selfUserId
        var initsToSend: [(peer: String, env: SenderKeyInitEnvelope)] = []
        var rotatesToSend: [(peer: String, env: SenderKeyRotateEnvelope)] = []

        lock.lock()
        if callId == activeCallId {
            self.senderKeysCapable = senderKeysCapable
            if let gs = groupState {
                for peer in senderKeysCapable where peer != selfId {
                    if !gs.members.contains(peer),
                       let pkg = try? groupSession.handleMemberAdded(state: gs, newMember: peer) {
                        initsToSend.append((peer, pkg.initForNewMember))
                    }
                }
                // See bcrypto-server `GroupCall.SenderKeyEpoch` kdoc + Android's
                // `handleDepartures` for the full race rationale: independent
                // clients each bumping "their own local epoch + 1" on detecting
                // a departure could diverge onto different epoch numbers and get
                // silently rejected by each other's strict
                // `env.e == state.groupEpoch` check. Pre-setting our local epoch
                // to `serverEpoch - 1` before the (always-exactly-+1)
                // `handleMemberRemoved` bump forces every survivor to converge
                // on the SAME server-canonical value regardless of
                // detection-order jitter.
                let departed = Set(gs.members).subtracting(participants).subtracting([selfId])
                if !departed.isEmpty {
                    var lastPkg: GroupRotatePackage?
                    for removed in departed where gs.members.contains(removed) {
                        let target = senderKeyEpoch > 0
                            ? UInt32(truncatingIfNeeded: senderKeyEpoch - 1) : gs.groupEpoch
                        gs.groupEpoch = target
                        if let pkg = try? groupSession.handleMemberRemoved(state: gs, removed: removed) {
                            lastPkg = pkg
                        }
                    }
                    if let pkg = lastPkg {
                        for peer in gs.members where peer != selfId {
                            rotatesToSend.append((peer, pkg.rotateEnvelope))
                        }
                    }
                }
            }
        }
        lock.unlock()

        for item in initsToSend {
            sendSenderKeyEnvelope(peer: item.peer, selfId: selfId, env: item.env)
        }
        for item in rotatesToSend {
            sendSenderKeyRotateEnvelope(peer: item.peer, selfId: selfId, env: item.env)
        }
    }

    private func handleIncomingFrame(senderId: String, sealed: Data) {
        lock.lock()
        guard let gs = groupState else { lock.unlock(); return }
        var decoder = perSenderDecoders[senderId]
        if decoder == nil {
            decoder = OpusCodec()
            perSenderDecoders[senderId] = decoder
        }
        let opus = groupSession.decryptFromGroup(state: gs, senderId: senderId, wire: sealed)
        lock.unlock()
        guard let decoder = decoder else { return }
        guard let opus = opus else {
            print("[GroupCallController] open failed sender=\(senderId)")
            return
        }
        guard let pcm = decoder.decode(opus) else {
            print("[GroupCallController] opus decode failed sender=\(senderId)")
            return
        }
        onIncomingPcmFrame?(senderId, pcm)
    }

    /// Bootstrap this call's own `GroupState` from a fresh random 32-byte
    /// secret — never derivable by the server. `groupIdBytes` is the
    /// callId's raw UTF-8 bytes, matching Android/Desktop's convention for
    /// CALLS specifically (ephemeral, not bound to any chat-group identity).
    private func bootstrapGroupSession(callId: String, initialPeers: [String]) {
        let selfId = manager.selfUserId
        let members = (initialPeers + [selfId]).reduce(into: [String]()) { acc, id in
            if !acc.contains(id) { acc.append(id) }
        }
        let newState: GroupState?
        do {
            newState = try groupSession.create(
                groupIdBytes: Data(callId.utf8),
                members: members,
                selfId: selfId
            )
        } catch {
            print("[GroupCallController] GroupSession bootstrap failed — call has no E2E keying: \(error)")
            newState = nil
        }
        lock.lock()
        activeCallId = callId
        groupState = newState
        lock.unlock()
    }

    /// Seal `plaintext` (an Opus frame) under our own send chain. Refuses
    /// (returns nil) until we've distributed our `sender_key_init` to every
    /// currently-capable peer — mirrors Android's TX gate so we never ship
    /// audio a fresh peer can't yet decrypt.
    private func sealForTransmit(plaintext: Data) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard case .active = state, let gs = groupState else { return nil }
        let pending = senderKeysCapable.subtracting(initSentTo).subtracting([manager.selfUserId])
        guard pending.isEmpty else {
            return nil
        }
        return try? groupSession.encryptForGroup(state: gs, plaintext: plaintext).wire
    }

    private func sendSenderKeyEnvelope(peer: String, selfId: String, env: SenderKeyInitEnvelope) {
        guard let json = Self.encodeInitEnvelope(env),
              let onSend = onSendControlEnvelope else { return }
        if onSend(peer, selfId, json) {
            lock.lock(); initSentTo.insert(peer); lock.unlock()
        }
    }

    private func sendSenderKeyRotateEnvelope(peer: String, selfId: String, env: SenderKeyRotateEnvelope) {
        guard let json = Self.encodeRotateEnvelope(env),
              let onSend = onSendControlEnvelope else { return }
        _ = onSend(peer, selfId, json)
    }

    /// App-layer hook: given (peer, selfId, plaintext envelope JSON), seal
    /// via `sealControlEnvelope` + ship as an `opaque_message`, returning
    /// whether the send actually went out. Injected rather than hard-wired
    /// so this engine target never depends on `BCryptoWebSocketClient`
    /// directly — the app layer (which owns the live WS connection) sets
    /// this once at construction time (see `AppState.ensureGroupCallController`).
    public var onSendControlEnvelope: ((_ peer: String, _ selfId: String, _ envelopeJson: String) -> Bool)?

    private func teardown() {
        lock.lock()
        perSenderDecoders.removeAll()
        muted = false
        groupState = nil
        activeCallId = nil
        senderKeysCapable.removeAll()
        initSentTo.removeAll()
        lock.unlock()
        setState(.idle)
    }

    private func setState(_ newState: State) {
        lock.lock(); state = newState; lock.unlock()
        onStateChange?(newState)
    }

    // MARK: - Wire format helpers

    private static func encodeInitEnvelope(_ env: SenderKeyInitEnvelope) -> String? {
        let obj: [String: Any] = [
            "qa_grp": env.qa_grp, "t": env.t, "g": env.g,
            "e": env.e, "seed": env.seed, "idx": env.idx
        ]
        return try? Self.jsonString(obj)
    }

    private static func encodeRotateEnvelope(_ env: SenderKeyRotateEnvelope) -> String? {
        let obj: [String: Any] = [
            "qa_grp": env.qa_grp, "t": env.t, "g": env.g,
            "e": env.e, "seed": env.seed
        ]
        return try? Self.jsonString(obj)
    }

    private static func jsonString(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func resolvePsk(peer: String) -> Data? {
        let prefix = peer.count > 8 ? String(peer.prefix(8)) : peer
        let autoName = "auto:\(prefix):\(peer)"
        if let stored = (try? ctrlPskVault.loadPsk(name: autoName)) ?? nil, !stored.isEmpty {
            return stored
        }
        if let stored = (try? ctrlPskVault.loadPsk(name: peer)) ?? nil, !stored.isEmpty {
            return stored
        }
        return nil
    }
}
