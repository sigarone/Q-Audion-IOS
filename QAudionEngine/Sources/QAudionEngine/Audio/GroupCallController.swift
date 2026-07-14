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

    /// Locked computed property — a review of today's work found ONE bare
    /// unlocked read of the old stored `state` property racing concurrent
    /// writers (`wireManagerCallbacks`'s `.creating` case, fired from the
    /// manager's own callback thread, vs `setState` from other threads).
    /// `_state` is the lock-protected backing field; every internal site
    /// that already holds `lock` reads/writes `_state` directly (reading
    /// the public property here would self-deadlock, NSLock is
    /// non-reentrant), every other site goes through this getter.
    private var _state: State = .idle
    public var state: State { lock.lock(); defer { lock.unlock() }; return _state }
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
    /// Peers we've successfully delivered our `sender_key_init` to this
    /// call. Drives the W-GRPSENDERKEY-RETRY loop in `onUpdate` (re-sends
    /// to any capable peer not yet in this set on every roster update) —
    /// mirrors Android's `initSentTo`. No longer gates `sealForTransmit`
    /// (see that method's kdoc): a peer missing from this set just can't
    /// decrypt our audio yet, it doesn't block sending to everyone else.
    private var initSentTo: Set<String> = []

    // ─── W-GRPLIVEKIT: LiveKit SFU media transport (capability-gated) ──
    // When `usingSfu` (default true), an active call first requests a
    // LiveKit access token; media rides the SFU with native per-participant
    // E2EE keyed from `groupSession`'s `currentSendKey`/`currentRecvKey`
    // (SK_0, pinned — the send chain is never advanced by `encryptForGroup`
    // while under the SFU). On `group_call_sfu_unavailable`, or if the
    // token round-trip / room connect fails, this flips to false and the
    // call falls back to the pre-existing WS-relay mesh path below
    // (`sealForTransmit`/`handleIncomingFrame`) — soft fallback, never a
    // hard failure. Mirrors Desktop's `GroupCallController` (main process)
    // `usingSfu`/`groupState`/`emitSelfMediaKey`/`emitRemoteMediaKey`.
    private var usingSfu = true
    private var sfuRoom: LiveKitGroupCallRoom?
    private static let livekitKeyringSize: UInt32 = 16

    /// A remote participant's SFU audio/video track was subscribed
    /// (type-erased `RemoteAudioTrack`/`RemoteVideoTrack` — see
    /// `LiveKitGroupCallRoom`'s doc comment for why). App layer attaches
    /// these to `VideoView`/audio rendering. Only fires when the call is
    /// actually running over the SFU.
    public var onRemoteAudioTrack: ((_ identity: String, _ track: AnyObject) -> Void)?
    public var onRemoteVideoTrack: ((_ identity: String, _ track: AnyObject) -> Void)?
    /// SFU-specific participant presence (independent of `onParticipantsChanged`,
    /// which reflects the WS roster regardless of media transport).
    public var onSfuParticipant: ((_ identity: String, _ present: Bool) -> Void)?
    public var onSfuError: ((Error) -> Void)?

    // ─── Control-envelope transport ───────────────────────────────────
    // Deliberately NOT owned here. An earlier version of this file kept its
    // OWN `MessageRatchet`/`SovereignKeyVault` static instances for the
    // pairwise 1:1 crypto used to seal `qa_grpcall_ctrl` envelopes — but
    // those instances read/write the SAME physical Keychain-backed ratchet
    // session as AppState's single shared `sharedV4Ratchet`/`ratchet`
    // instances (used for chat + every other opaque_message consumer).
    // TWO independent `MessageRatchet` objects driven concurrently (this
    // controller's callbacks fire off the WS client's own background queue,
    // chat fires on MainActor) can each load the same persisted session
    // before either saves its advance — the second save silently clobbers
    // the first's chain-index advance, risking an AEAD (key,nonce) reuse or
    // a legitimate peer message getting rejected as a replay. This is
    // exactly the multi-instance clobber hazard AppState's own doc comment
    // says was already fixed for v4 by unifying send+receive into ONE
    // shared instance — a second, separate instance here reintroduced it.
    // Fix: `onSendControlEnvelope` (below) and the receive-side decrypt in
    // `AppState.dispatchInboundOpaque` Path C both route through AppState's
    // SAME shared `Self.ratchet`/`Self.sharedV4Ratchet` instances instead.

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
    ///
    /// W-GRPRING — `callType` / `groupId` / `groupName` are relayed by the
    /// server onto every invitee's `group_call_invite` AND the wake-up push
    /// (see `BCryptoGroupCallManager.createGroupCall`). Pass the real group
    /// context whenever the call is started from a persisted group; the
    /// contact-picker (ad-hoc) path leaves them empty.
    @discardableResult
    public func createCall(
        invitees: [String],
        title: String = "",
        callType: String = "audio",
        groupId: String = "",
        groupName: String = ""
    ) -> String? {
        guard let callId = manager.createGroupCall(
            recipients: invitees,
            title: title,
            callType: callType,
            groupId: groupId,
            groupName: groupName
        ) else {
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
    /// transition into .active; safe to invoke multiple times. Holds
    /// `lock` across the ENTIRE start (not just the field reads) — a
    /// review found that releasing the lock before calling
    /// `.start()`/`.stop()` on the escaped `capture`/`playback` references
    /// let a concurrent `stopAudioPipeline()` (e.g. from `.ended`/`leave()`
    /// racing the `.active` transition) invoke `.stop()` on the SAME
    /// instance with no mutual exclusion between the two calls. Calls into
    /// this pair are rare (call start/end), so serializing them fully is a
    /// clean fix with no meaningful throughput cost.
    public func startAudioPipeline() throws {
        lock.lock()
        defer { lock.unlock() }
        if let playback = playback {
            try? playback.start()
        }
        if let capture = capture {
            try capture.start()
        }
    }

    /// Stop the audio pipeline. Idempotent. See `startAudioPipeline` for
    /// why this holds `lock` across the calls, not just the field reads.
    public func stopAudioPipeline() {
        lock.lock()
        defer { lock.unlock() }
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
        guard let gs = groupState, let callId = activeCallId else { lock.unlock(); return }
        let expectedG = GroupSenderKey.toHex(Data(callId.utf8))
        guard obj["g"] as? String == expectedG else { lock.unlock(); return }
        // W-GRPLIVEKIT: set on a successful install so we can push the fresh
        // SK_0 into the SFU key provider AFTER releasing `lock` below —
        // `applySfuRemoteKey` takes the lock itself (NSLock is non-reentrant,
        // see the kdoc on `_state`/`lock` near the top of this file).
        var installedSenderId: String?
        switch obj["t"] as? String {
        case "sender_key_init":
            guard let e = (obj["e"] as? NSNumber)?.uint32Value,
                  let seed = obj["seed"] as? String,
                  let idx = (obj["idx"] as? NSNumber)?.uint64Value else { lock.unlock(); return }
            let env = SenderKeyInitEnvelope(g: expectedG, e: e, seed: seed, idx: idx)
            do {
                try groupSession.handleSenderKeyInit(state: gs, env: env, fromUserId: fromUserId)
                installedSenderId = fromUserId
            } catch {
                print("[GroupCallController] handleSenderKeyInit failed sender=\(fromUserId): \(error)")
            }
        case "sender_key_rotate":
            guard let e = (obj["e"] as? NSNumber)?.uint32Value,
                  let seed = obj["seed"] as? String else { lock.unlock(); return }
            let env = SenderKeyRotateEnvelope(g: expectedG, e: e, seed: seed)
            do {
                try groupSession.handleSenderKeyRotate(state: gs, env: env, fromUserId: fromUserId)
                installedSenderId = fromUserId
            } catch {
                print("[GroupCallController] handleSenderKeyRotate failed sender=\(fromUserId): \(error)")
            }
        default:
            break // not ours
        }
        lock.unlock()
        if let senderId = installedSenderId {
            applySfuRemoteKey(senderId: senderId)
        }
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
                    self.lock.lock()
                    let attemptSfu = self.usingSfu && self.sfuRoom == nil
                    self.lock.unlock()
                    if attemptSfu {
                        // Hold off on the WS-relay mic/speaker pipeline until
                        // the SFU round-trip resolves — starting BOTH would
                        // briefly double-capture the mic (see
                        // LiveKitGroupCallRoom's dependency-comment on the
                        // separate AVAudioSession wrapper each WebRTC engine
                        // owns). `handleSfuToken`/`handleSfuUnavailable`
                        // start the mesh pipeline themselves if SFU doesn't
                        // pan out.
                        self.manager.requestSfuToken(callId: cid)
                    } else {
                        do { try self.startAudioPipeline() }
                        catch { print("[GroupCallController] startAudioPipeline failed: \(error)") }
                    }
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
        manager.onSfuTokenReceived = { [weak self] callId, _, url, token in
            self?.handleSfuToken(callId: callId, url: url, token: token)
        }
        manager.onSfuUnavailable = { [weak self] callId, reason in
            self?.handleSfuUnavailable(callId: callId, reason: reason)
        }
    }

    // MARK: - W-GRPLIVEKIT: SFU lifecycle (capability-gated, soft fallback)

    /// The server minted a LiveKit token for `callId` — try to connect the
    /// SFU room. On success: push every currently-known media key
    /// (self + installed remotes) and skip the WS-relay mic pipeline
    /// entirely. On failure: flip `usingSfu` off and fall back to the
    /// pre-existing mesh pipeline, exactly as `handleSfuUnavailable` does.
    private func handleSfuToken(callId: String, url: String, token: String) {
        lock.lock()
        let stillCurrent = (callId == activeCallId) && usingSfu && sfuRoom == nil
        lock.unlock()
        guard stillCurrent else { return }

        let room = LiveKitGroupCallRoom(video: false)
        room.onRemoteAudioTrack = { [weak self] id, track in self?.onRemoteAudioTrack?(id, track) }
        room.onRemoteVideoTrack = { [weak self] id, track in self?.onRemoteVideoTrack?(id, track) }
        room.onParticipant = { [weak self] id, present in self?.onSfuParticipant?(id, present) }
        room.onError = { [weak self] err in self?.onSfuError?(err) }

        lock.lock()
        sfuRoom = room
        lock.unlock()

        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await room.connect(url: url, token: token)
                self.resendMediaKeysToSfu()
            } catch {
                print("[GroupCallController] LiveKit connect failed, falling back to WS-relay mesh: \(error)")
                self.lock.lock()
                self.usingSfu = false
                self.sfuRoom = nil
                self.lock.unlock()
                await room.disconnect()
                do { try self.startAudioPipeline() }
                catch { print("[GroupCallController] fallback startAudioPipeline failed: \(error)") }
            }
        }
    }

    /// Server declined the SFU for `callId` (`group_call_sfu_unavailable`) —
    /// soft-fall-back to the WS-relay mesh path. Never a hard failure: the
    /// call proceeds exactly as it did before this feature existed.
    private func handleSfuUnavailable(callId: String, reason: String) {
        lock.lock()
        guard callId == activeCallId else { lock.unlock(); return }
        usingSfu = false
        lock.unlock()
        print("[GroupCallController] SFU unavailable (\(reason)) — using WS-relay mesh")
        do { try startAudioPipeline() }
        catch { print("[GroupCallController] fallback startAudioPipeline failed: \(error)") }
    }

    /// Push our own key (a fresh COPY of the current send-chain SK_0) into
    /// the SFU key provider at `groupEpoch % 16`. `graceMs`, when set, is
    /// ONLY used right after a member-leave rekey (see `onUpdate`) so
    /// in-flight frames keyed under the OLD slot still decrypt during the
    /// ~3s hand-off window.
    private func applySfuSelfKey(graceMs: Double? = nil) {
        lock.lock()
        guard usingSfu, let gs = groupState, let ck = groupSession.currentSendKey(state: gs) else {
            lock.unlock(); return
        }
        let selfId = manager.selfUserId
        let keyIndex = Int32(gs.groupEpoch % Self.livekitKeyringSize)
        let keyB64 = ck.base64EncodedString()
        let room = sfuRoom
        lock.unlock()
        room?.applyKey(GroupMediaKey(identity: selfId, keyIndex: keyIndex, keyB64: keyB64, graceMs: graceMs))
    }

    /// Push `senderId`'s installed recv-chain key (SK_0 from their init/
    /// rotate) into the SFU key provider. No-op until the SFU is connected
    /// AND that sender's bootstrap envelope has been installed.
    private func applySfuRemoteKey(senderId: String) {
        lock.lock()
        guard usingSfu, let gs = groupState, let ck = groupSession.currentRecvKey(state: gs, senderId: senderId) else {
            lock.unlock(); return
        }
        let keyIndex = Int32(gs.groupEpoch % Self.livekitKeyringSize)
        let keyB64 = ck.base64EncodedString()
        let room = sfuRoom
        lock.unlock()
        room?.applyKey(GroupMediaKey(identity: senderId, keyIndex: keyIndex, keyB64: keyB64))
    }

    /// Re-push every currently-known media key (self + each installed
    /// remote) once the SFU room just connected — covers keys that were
    /// already installed into `groupState` before the room existed.
    private func resendMediaKeysToSfu() {
        lock.lock()
        let senders = groupState?.recvChains.map { $0.0 } ?? []
        lock.unlock()
        applySfuSelfKey()
        for senderId in senders { applySfuRemoteKey(senderId: senderId) }
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
            if let gs = groupState {
                for peer in senderKeysCapable where peer != selfId {
                    if !gs.members.contains(peer) {
                        if let pkg = try? groupSession.handleMemberAdded(state: gs, newMember: peer) {
                            initsToSend.append((peer, pkg.initForNewMember))
                        }
                    } else if !initSentTo.contains(peer) {
                        // W-GRPSENDERKEY-RETRY: peer was added to the roster on
                        // a PREVIOUS onUpdate (so `handleMemberAdded` would now
                        // throw .alreadyMember), but our sender_key_init to
                        // them never landed — e.g. no pairwise PSK/v4 session
                        // existed at the time. Re-derive the SAME envelope
                        // handleMemberAdded would have returned (current send
                        // chain's seed/idx) and retry the send. Without this,
                        // a single peer with a persistently-failing control
                        // channel would never receive init, and — before this
                        // fix — that also permanently blocked ALL outgoing
                        // audio (see sealForTransmit).
                        let retryEnv = SenderKeyInitEnvelope(
                            g: GroupSenderKey.toHex(gs.groupIdBytes),
                            e: gs.groupEpoch,
                            seed: gs.sendChain.ck.base64EncodedString(),
                            idx: gs.sendChain.nextIdx
                        )
                        initsToSend.append((peer, retryEnv))
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
                //
                // W-GRPREKEY-PARITY: mirrors Android's explicit bailout for a
                // legacy/pre-W-GRPREKEY server that never sends a positive
                // epoch — Android skips rekey-on-leave entirely rather than
                // guessing, since computing a "target" from a stale local
                // epoch would resurrect the very independent-per-client-
                // increment race this mechanism exists to prevent. The
                // deployed server always sends epoch>=1 today, so this branch
                // is not currently reachable — it exists so a future
                // divergent decode path degrades safely instead of silently.
                let departed = senderKeyEpoch > 0
                    ? Set(gs.members).subtracting(participants).subtracting([selfId])
                    : Set<String>()
                if !departed.isEmpty {
                    var lastPkg: GroupRotatePackage?
                    for removed in departed where gs.members.contains(removed) {
                        let target = UInt32(truncatingIfNeeded: senderKeyEpoch - 1)
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
        // W-GRPLIVEKIT: a non-empty `rotatesToSend` means `handleMemberRemoved`
        // just reseeded OUR send chain (departure rekey) — push the fresh
        // self key into the SFU with a ~3s grace so in-flight frames keyed
        // under the OLD slot still decrypt during the hand-off window.
        // Mirrors Desktop's `rekeyOnLeave` -> `emitSelfMediaKey(3000)`.
        if !rotatesToSend.isEmpty {
            applySfuSelfKey(graceMs: 3000)
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

    /// Seal `plaintext` (an Opus frame) under our own send chain.
    ///
    /// A review of today's work found the PREVIOUS version of this method
    /// blocked ALL outgoing audio (not just to one peer — to EVERYONE) until
    /// `sender_key_init` had been successfully delivered to EVERY currently-
    /// capable peer, with no retry: if delivery to even one peer permanently
    /// failed (no pairwise PSK/v4 session with them yet), the call's audio
    /// was silently dead for its entire duration. There is no actual crypto
    /// reason to withhold from PEERS WHO ARE READY just because one other
    /// peer isn't — the scheme is per-sender broadcast, so a peer without
    /// our init simply can't decrypt yet (drops our frames, same as any
    /// unknown-sender frame) until their init/retry lands (see the
    /// W-GRPSENDERKEY-RETRY loop in `onUpdate`). So this method now only
    /// requires OUR OWN send chain to exist — external security review
    /// (2026-07-13) confirmed this removes an availability bug without any
    /// confidentiality regression, and does NOT reintroduce Android's
    /// legacy-shared-key fallback (this project's stance is no silent
    /// weak-crypto fallback, ever).
    private func sealForTransmit(plaintext: Data) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard case .active = _state, let gs = groupState else { return nil }
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
    /// via the shared pairwise 1:1 ratchet + ship as an `opaque_message`,
    /// returning whether the send actually went out. Injected rather than
    /// hard-wired so this engine target never depends on
    /// `BCryptoWebSocketClient` directly, AND so the seal happens through
    /// AppState's single shared `MessageRatchet` instance rather than a
    /// second one owned here (see the control-envelope-transport comment
    /// near the top of this file). Set once at construction time in
    /// `AppState.connectPersistentSocket()`.
    public var onSendControlEnvelope: ((_ peer: String, _ selfId: String, _ envelopeJson: String) -> Bool)?

    private func teardown() {
        lock.lock()
        perSenderDecoders.removeAll()
        muted = false
        groupState = nil
        activeCallId = nil
        initSentTo.removeAll()
        let room = sfuRoom
        sfuRoom = nil
        usingSfu = true // reset the capability flag for the NEXT call
        lock.unlock()
        if let room = room {
            Task { await room.disconnect() }
        }
        setState(.idle)
    }

    private func setState(_ newState: State) {
        lock.lock(); _state = newState; lock.unlock()
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
}
