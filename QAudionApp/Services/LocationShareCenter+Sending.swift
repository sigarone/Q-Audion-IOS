import Foundation
import UIKit
import UserNotifications
import QAudionEngine

/// The SENDER side of location sharing (WIRE_SPEC 14.6.1): the pin, and the live share started on this device.
///
/// One `LocationShareSender` per share is the only owner of the share key and the counter of the next frame, and the only sealer of it
/// (rule 9). The key is never written anywhere: it lives in the engine object, and the full start body that carries it lives only in the
/// row of the outbox until the `msg_sent` echo, after which the row is rewritten to the local form (no key). A process that starts again
/// never resumes a share (rule 10): `recoverSendsAfterRestart` sends the stop only.
///
/// Frames ride the socket (`eph_relay`) on a fixed tick, 30 seconds (60 in Low Power Mode), whatever the position does; sampling of the
/// location is adaptive and a local matter (`LocationSamplingPolicy`). No frame is built while the socket is down.

enum LocationStartFailure: Error {
    case disabled
    case notSignedIn
    case permission
    case blocked
    case senderUnavailable
    case refused(LocationBuildRefusal)
}

struct LocationFrameWriteFailure: Error {}

extension LocationShareCenter {

    static let chatRefreshName = Notification.Name("qaudion.chat.refresh")

    // MARK: Pin

    /// The body of a pin, or the refusal (`age` when the fix is older than two minutes, and so on). The caller sends it as a chat message
    /// and shows the fixed label as its preview.
    func buildPin(reading: LocationReading) -> Result<String, LocationBuildRefusal> {
        LocationCodec.buildPin(fix: reading.engineFix())
    }

    // MARK: Live: start

    /// A share the user just confirmed. `dispatch` writes the row and sends the start message through the normal durable path under
    /// `messageId` (its client message id is the id of the share); the key is held by the sender object and by nothing else.
    func startLive(reading: LocationReading, duration: Int64, peerUserId: String, conversationId: UUID,
                   dispatch: (_ body: String, _ preview: String, _ messageId: UUID) -> Void) -> Result<Void, LocationStartFailure> {
        guard Self.isFeatureEnabled else { return .failure(.disabled) }
        guard let env = environment, let selfId = env.currentUserId(), !selfId.isEmpty else { return .failure(.notSignedIn) }
        let permitted: Bool = authorizationOverride ?? LocationService.shared.isAuthorized
        guard permitted else { return .failure(.permission) }
        guard !BlockedContactsStore.isBlocked(peerUserId) else { return .failure(.blocked) }

        // Everything the new share needs is built and checked FIRST: a start that is refused (a fix that is too old, no sender to be had)
        // leaves the share that is running exactly as it is. Only when the new start can go does the previous share of the conversation
        // end (rule 6), just before the new one takes its place.
        let secrets = LocationShareSecrets.generate()
        let startedAt: Int64 = Self.nowUnix()
        let fix: LocationFix = reading.engineFix()
        let body: String
        switch LocationCodec.buildLiveStart(fix: fix, sid: secrets.sid, key: secrets.key, startedAt: startedAt, duration: duration) {
        case .success(let text):
            body = text
        case .failure(let refusal):
            return .failure(.refused(refusal))
        }
        guard let senderFix = Self.senderFix(from: reading, now: startedAt) else { return .failure(.refused(.fix)) }

        let messageId = UUID()
        let clientMsgId: String = messageId.uuidString
        let effects = Self.senderEffects()
        guard let sender = LocationShareSender(
            startClientMsgId: clientMsgId, selfId: selfId, peerId: peerUserId, sid: secrets.sid, shareKey: secrets.key,
            startedAt: startedAt, duration: duration, fix: senderFix, effects: effects, journal: journal) else {
            return .failure(.senderUnavailable)
        }
        // Rule 6: starting a share in a conversation ends the previous one first (final frame and stop).
        stopShares(forPeer: peerUserId, reason: "superseded", final: .now)

        if !env.socketReady() { _ = sender.socketWentDown() }
        // The interval in force from the first frame: 60 seconds in Low Power Mode, 30 otherwise (`iv` of a frame announces it).
        sender.setLowPower(lowPower)
        let run = SendRun(sender: sender, startClientMsgId: clientMsgId, peerUserId: peerUserId, conversationId: conversationId,
                          startedAt: startedAt, duration: duration)
        runs[clientMsgId] = run
        peerByStart[clientMsgId] = peerUserId
        // The socket is held open for as long as a share runs (the app does not drop it a few seconds after going to the background).
        if connectionToken == nil { connectionToken = env.requestConnection() }
        publishActiveShares()

        dispatch(body, LocationLabels.text(.live), messageId)

        installLiveHandlers()
        LocationService.shared.beginLiveSampling()
        armTimers(startClientMsgId: clientMsgId)
        ensureHousekeeping()
        LocationTelemetry.liveStarted(durationPreset: Self.presetLabel(duration))
        let startLine: String = "loc event=start dur=" + String(describing: duration)
        RTLog.info("chat", startLine)
        didChange()
        return .success(())
    }

    /// The conversion of a platform fix into what the sender holds (WIRE_SPEC 14.4): E7 integers, the accuracy in metres, the moment of
    /// the fix on the clock of `now`.
    static func senderFix(from reading: LocationReading, now: Int64) -> LocationSenderFix? {
        guard case .success(let lat) = LocationConversion.e7(degrees: reading.latitude, axis: .latitude),
              case .success(let lon) = LocationConversion.e7(degrees: reading.longitude, axis: .longitude),
              case .success(let acc) = LocationConversion.accuracy(metres: reading.horizontalAccuracy) else { return nil }
        let age: Int64 = max(0, Int64(Date().timeIntervalSince(reading.timestamp)))
        return LocationSenderFix(latE7: lat, lonE7: lon, accuracy: UInt16(clamping: acc), approximate: reading.reducedAccuracy,
                                 capturedAt: now - age)
    }

    static func presetLabel(_ duration: Int64) -> String {
        switch duration {
        case 900: return "15m"
        case 3_600: return "1h"
        case 28_800: return "8h"
        case 86_400: return "24h"
        default: return "other"
        }
    }

    // MARK: Live: fixes and timers

    /// What the engine's sender asks of the app: the stop through the durable control path, the withdrawal of an unsent start. The
    /// engine calls these on the main thread, from inside this class's own calls, so they run at once (a stop is handed to the durable
    /// path in the same turn, and the choice between holding it and dropping it is made while the account is still the one that left).
    static func senderEffects() -> LocationShareSenderEffects {
        LocationShareSenderEffects(
            sendStop: { id, ts in
                MainActor.assumeIsolated { LocationShareCenter.shared.shipStop(startClientMsgId: id, ts: ts) }
            },
            withdrawStart: { id in
                MainActor.assumeIsolated { LocationShareCenter.shared.withdrawStart(startClientMsgId: id) }
            })
    }

    private func installLiveHandlers() {
        LocationService.shared.onLiveFix = { reading in
            Task { @MainActor in LocationShareCenter.shared.liveFix(reading) }
        }
        LocationService.shared.onAuthorizationChange = {
            Task { @MainActor in LocationShareCenter.shared.authorizationChanged() }
        }
    }

    func liveFix(_ reading: LocationReading) {
        let now: Int64 = Self.nowUnix()
        guard let fix = Self.senderFix(from: reading, now: now) else { return }
        for run in runs.values {
            run.sender.update(fix: fix)
        }
    }

    func armTimers(startClientMsgId id: String) {
        guard let run = runs[id] else { return }
        // One timer per share: the old one is cancelled before a new one is made, so a re-arm can never leave two ticking.
        tickTimers[id]?.invalidate()
        let interval: TimeInterval = TimeInterval(lowPower ? LocationWire.txIntervalLowPower : LocationWire.txInterval)
        let tickTimer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in LocationShareCenter.shared.tick(startClientMsgId: id) }
        }
        RunLoop.main.add(tickTimer, forMode: .common)
        tickTimers[id] = tickTimer
        if endTimers[id] == nil {
            let remaining: Double = Double(run.startedAt + run.duration) - Date().timeIntervalSince1970
            let endTimer = Timer(timeInterval: max(0.5, remaining + 0.5), repeats: false) { _ in
                Task { @MainActor in LocationShareCenter.shared.tick(startClientMsgId: id) }
            }
            RunLoop.main.add(endTimer, forMode: .common)
            endTimers[id] = endTimer
        }
    }

    func applyLowPowerToRuns() {
        for run in runs.values {
            run.sender.setLowPower(lowPower)
            armTimers(startClientMsgId: run.startClientMsgId)
        }
    }

    /// The socket changed state: no frame is built while it is down (rule 5), and a final frame that waited for its tick is dropped.
    func socketStateChanged(authenticated: Bool) {
        for run in runs.values {
            if authenticated {
                _ = run.sender.socketCameUp()
            } else {
                _ = run.sender.socketWentDown()
            }
            finishIfDone(run)
        }
    }

    private func syncSocket(_ run: SendRun) {
        let ready: Bool = environment?.socketReady() ?? false
        if ready {
            _ = run.sender.socketCameUp()
        } else {
            _ = run.sender.socketWentDown()
        }
    }

    func tick(startClientMsgId id: String) {
        guard let run = runs[id] else {
            tickTimers[id]?.invalidate()
            tickTimers[id] = nil
            endTimers[id]?.invalidate()
            endTimers[id] = nil
            return
        }
        syncSocket(run)
        if LocationService.hasInstance { LocationService.shared.noteClockTick() }
        let peer: String = run.peerUserId
        let outcome: LocationSenderOutcome = run.sender.tick(now: Self.nowUnix()) { sealed in
            try self.writeFrame(sealed, to: peer)
        }
        recordTelemetry(outcome)
        if outcome.stop != nil {
            // The end time was reached on this tick: the engine sent the stop and the final frame.
            LocationTelemetry.liveEnded(reason: "expired")
            postEndedNoticeIfBackground()
        }
        finishIfDone(run)
    }

    private func writeFrame(_ sealed: LocationFrameCodec.Sealed, to peerId: String) throws {
        guard let env = environment, env.sendEphemeral(peerId, sealed.base64) else { throw LocationFrameWriteFailure() }
    }

    private func recordTelemetry(_ outcome: LocationSenderOutcome) {
        if outcome.frame != nil {
            LocationTelemetry.frameSent()
        } else if let refusal = outcome.refusal, refusal != .ended {
            LocationTelemetry.frameDropped(refusal.rawValue)
        }
    }

    // MARK: Live: stop

    /// The user, or an end trigger, ends the share. `final == .onTick` builds the final frame on the next regular tick (the cadence is
    /// not disturbed); `.now` builds it at once, while the socket is up (the process is going away, or the share is replaced).
    func stopShare(startClientMsgId id: String, reason: String, final: LocationFinalFrameMode) {
        guard let run = runs[id] else { return }
        let peer: String = run.peerUserId
        let outcome: LocationSenderOutcome = run.sender.stop(now: Self.nowUnix(), final: final) { sealed in
            try self.writeFrame(sealed, to: peer)
        }
        if outcome.refusal == nil { LocationTelemetry.liveEnded(reason: reason) }
        recordTelemetry(outcome)
        let stopLine: String = "loc event=stop reason=" + reason
        RTLog.info("chat", stopLine)
        publishActiveShares()
        finishIfDone(run)
        didChange()
    }

    func stopShares(forPeer peerId: String, reason: String, final: LocationFinalFrameMode) {
        for run in runs.values where run.peerUserId == peerId {
            stopShare(startClientMsgId: run.startClientMsgId, reason: reason, final: final)
        }
    }

    func stopAllShares(reason: String, final: LocationFinalFrameMode) {
        for run in runs.values {
            stopShare(startClientMsgId: run.startClientMsgId, reason: reason, final: final)
        }
    }

    /// "Interrompi tutte" of the settings list, and the strip's own button for one conversation.
    func stopAllFromUser() {
        stopAllShares(reason: "user", final: .onTick)
    }

    /// A share is over when its key is gone (the engine deletes it on every end, once the final frame was built or given up).
    private func finishIfDone(_ run: SendRun) {
        guard !run.sender.keyHeld else { return }
        let id: String = run.startClientMsgId
        tickTimers[id]?.invalidate()
        tickTimers[id] = nil
        endTimers[id]?.invalidate()
        endTimers[id] = nil
        runs[id] = nil
        if withdrawnStarts.contains(id) {
            // The start never left and was withdrawn (its row is gone): no echo will come, so nothing is parked to wait for one, and no
            // row is left to follow the timer.
            echoedStarts.remove(id)
            peerByStart[id] = nil
        } else {
            // The stop may still be held until the echo of the start (rule 2): keep the sender, which holds no key, to give it the echo.
            if echoedStarts.contains(id) {
                // The echo already arrived, so the stop already went: nothing is waited for and nothing needs the peer any more.
                echoedStarts.remove(id)
                peerByStart[id] = nil
            } else {
                waitingForEcho[id] = run.sender
            }
            // The row of the share follows the timer of its conversation from the moment the share ended.
            ownEnded[id] = Self.nowUnix()
        }
        publishActiveShares()
        if runs.isEmpty {
            endSamplingIfAny()
            connectionToken = nil
        }
        sweepEndedExpiries()
        didChange()
    }

    func publishActiveShares() {
        var list: [ActiveShare] = []
        // A share the user just stopped is over for every screen at once, even while its final frame waits for the next tick.
        for run in runs.values where !run.sender.isEnded {
            list.append(ActiveShare(
                id: run.startClientMsgId, peerUserId: run.peerUserId, conversationId: run.conversationId,
                startedAt: Date(timeIntervalSince1970: Double(run.startedAt)),
                endAt: Date(timeIntervalSince1970: Double(run.startedAt + run.duration))))
        }
        list.sort { $0.startedAt < $1.startedAt }
        activeShares = list
    }

    // MARK: Start message: progress of the row

    /// Called by both send paths (the live send and the outbox drain) right BEFORE the bytes of a message are handed to the socket, with
    /// its client message id. For the start of a live share it moves the sender to "possibly left" (phase sent, journal written): from
    /// here a stop is held until the echo, whatever the send does next, so a stop that arrives during the send never withdraws a start
    /// that then leaves anyway (WIRE_SPEC 14.6.1 rule 2). Returns `false` when the start was withdrawn in the meantime (the user stopped
    /// while the send was being prepared): the caller then sends nothing. For any other message it returns `true` and does nothing.
    func startBeingSent(clientMsgId id: String) -> Bool {
        if withdrawnStarts.contains(id) { return false }
        if let run = runs[id] { _ = run.sender.startLeftDevice() }
        return true
    }

    /// The hand-over announced by `startBeingSent` failed before any byte was written: the start did not leave. A share that still runs
    /// goes back to "not left", so that a stop withdraws the start; a share that ended while the send was in flight withdraws the start and
    /// sends no stop. A start that a previous process left (the recovery) is never taken back.
    func startNotSent(clientMsgId id: String) {
        if let run = runs[id] {
            _ = run.sender.startNotSent()
        } else if let waiting = waitingForEcho[id] {
            let outcome: LocationSenderOutcome = waiting.startNotSent()
            if outcome.outboxWithdrawn {
                waitingForEcho[id] = nil
                peerByStart[id] = nil
                echoedStarts.remove(id)
                ownEnded[id] = nil
            }
        }
    }

    /// `msg_sent`: the server acknowledged a message of this device. The server id is bound to the row only when an outgoing row
    /// carries that client message id (a service message has none, and binding it would fail and be retried for nothing), and the echo goes
    /// to the center only for a start it knows.
    func handleMsgSent(clientMsgId: String, serverMsgId: String, bindServerId: (_ clientMsgId: String, _ serverMsgId: String) -> Void) {
        if !serverMsgId.isEmpty, ports.rows.hasOutgoingRow(clientMsgId: clientMsgId) {
            bindServerId(clientMsgId, serverMsgId)
        }
        messageEchoed(clientMsgId: clientMsgId)
    }

    /// The server acknowledged the start message (`msg_sent`): frames may be built, a stop that waited goes out, and the row is
    /// rewritten to its local form, without the key. An acknowledgement of a message the center does not know is not for it.
    func messageEchoed(clientMsgId: String) {
        guard runs[clientMsgId] != nil || waitingForEcho[clientMsgId] != nil else { return }
        let now: Int64 = Self.nowUnix()
        if runs[clientMsgId] != nil || waitingForEcho[clientMsgId] != nil { echoedStarts.insert(clientMsgId) }
        if let run = runs[clientMsgId] {
            _ = run.sender.startAcknowledged(now: now)
        }
        if let waiting = waitingForEcho.removeValue(forKey: clientMsgId) {
            _ = waiting.startAcknowledged(now: now)
            // The stop that waited has gone (a stop to an unknown peer would have been dropped above): the share is forgotten.
            echoedStarts.remove(clientMsgId)
            if runs[clientMsgId] == nil { peerByStart[clientMsgId] = nil }
        }
        rewriteStartRowToLocalForm(clientMsgId: clientMsgId)
    }

    /// The outbox gave up on the start message: it never left, the share ends and the row (which holds the key) goes.
    func startFailed(clientMsgId: String) {
        // An attempt that was in flight did not leave: the start is taken back before the share ends, so that it is withdrawn.
        startNotSent(clientMsgId: clientMsgId)
        guard runs[clientMsgId] != nil else { return }
        stopShare(startClientMsgId: clientMsgId, reason: "failed", final: .now)
    }

    func rewriteStartRowToLocalForm(clientMsgId: String) {
        guard let row = ports.rows.row(forClientMsgId: clientMsgId), row.outgoing,
              case .live(let live)? = LocationRowForm.parse(row.plaintext) else { return }
        let local: String = LocationRowForm.localForm(sid: live.sid, startedAt: live.startedAt, duration: live.duration)
        guard local != row.plaintext else { return }
        ports.rows.replaceContent(rowId: row.rowId, plaintext: local, mediaMimeType: row.mediaMimeType)
        NotificationCenter.default.post(name: Self.chatRefreshName, object: nil, userInfo: ["clientMsgId": clientMsgId])
    }

    // MARK: Effects of the engine

    /// The `loc_stop` goes out through the durable CONTROL path (held until a control session and the socket exist).
    func shipStop(startClientMsgId id: String, ts: Int64) {
        guard let peer = peerForStart(id) else { return }
        guard case .success(let json) = LocationStopControl.build(target: id, ts: ts) else { return }
        // Held until a control session and the socket exist; but when the account itself is leaving, a stop that cannot go at once is
        // dropped: it must never be flushed under the next account.
        ports.sendStop(peer, json, !accountClosing)
    }

    /// A start that never left the device is withdrawn: the row (which holds the key) and its outbox entry are removed.
    func withdrawStart(startClientMsgId id: String) {
        // Remembered: a send that was being prepared when the share ended finds the start withdrawn and sends nothing.
        withdrawnStarts.insert(id)
        if let row = ports.rows.row(forClientMsgId: id) {
            ports.rows.removeRow(rowId: row.rowId, conversationId: row.conversationId)
            NotificationCenter.default.post(name: Self.chatRefreshName, object: nil, userInfo: ["conversationId": row.conversationId])
        }
        ports.rows.removeOutboxEntry(clientMsgId: id)
    }

    private func peerForStart(_ id: String) -> String? {
        if let peer = peerByStart[id] { return peer }
        return ports.rows.row(forClientMsgId: id)?.peerUserId
    }

    // MARK: Restart (WIRE_SPEC 14.6.1 rule 10)

    /// A process that starts and finds a share that was live when the previous one died builds NO frame for it: the key and the counter
    /// died with that process. The stop is sent (held until the echo of the start if that never arrived; a start that never left is
    /// withdrawn), nothing of the share is kept, and the user is told. The share is never resumed.
    func recoverSendsAfterRestart() {
        let entries: [LocationShareJournalEntry] = journal.entries()
        guard !entries.isEmpty else { return }
        let effects = Self.senderEffects()
        let now: Int64 = Self.nowUnix()
        for entry in entries where runs[entry.startClientMsgId] == nil && waitingForEcho[entry.startClientMsgId] == nil {
            let recovered = LocationShareSender.recoverAfterRestart(entry: entry, now: now, effects: effects, journal: journal)
            if entry.phase == .sent {
                // The echo of the start is waited for: the row goes back to the outbox, which sends the same message under the same
                // client message id; its echo then releases the stop. The row follows the timer from now: the share is over.
                waitingForEcho[entry.startClientMsgId] = recovered.sender
                requeueStartRow(clientMsgId: entry.startClientMsgId)
                ownEnded[entry.startClientMsgId] = now
            } else if entry.phase == .echoed {
                rewriteStartRowToLocalForm(clientMsgId: entry.startClientMsgId)
                ownEnded[entry.startClientMsgId] = now
            }
            LocationTelemetry.liveEnded(reason: "restart")
        }
        interruptedNotice = true
        postInterruptedNotice()
        didChange()
        sweepEndedExpiries()
    }

    private func requeueStartRow(clientMsgId: String) {
        guard let row = ports.rows.row(forClientMsgId: clientMsgId), row.outgoing else { return }
        ports.rows.requeue(rowId: row.rowId, conversationId: row.conversationId)
    }

    // MARK: Notice

    /// The notice is for a person who is not looking at the app: with the app in front, the strip and the card already say so.
    func postEndedNoticeIfBackground() {
        guard !Self.suppressNotices else { return }
        if UIApplication.shared.applicationState != .active { postEndedNotice() }
    }

    /// One quiet local notification at the next process start after a share was found that the previous process had left running: it
    /// was ended with the stop only (WIRE_SPEC 14.6.1 rule 10) and the user is told.
    func postInterruptedNotice() {
        guard !Self.suppressNotices else { return }
        let content = UNMutableNotificationContent()
        content.title = LocationCardStrings.interruptedTitle
        content.body = LocationCardStrings.interruptedBody
        content.sound = nil
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .passive
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// One quiet local notice that a share ended by itself (its time ran out), without any position.
    func postEndedNotice() {
        guard !Self.suppressNotices else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "location.notice.ended.title", defaultValue: "Posizione in tempo reale", comment: "Title of the quiet notification shown when a live location share you started has ended.")
        content.body = String(localized: "location.notice.ended.body", defaultValue: "La condivisione della posizione è terminata.", comment: "Body of the quiet notification shown when a live location share you started has ended.")
        content.sound = nil
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .passive
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false))
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
