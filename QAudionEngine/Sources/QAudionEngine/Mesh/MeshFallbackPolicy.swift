import Foundation

/// Why a message left the Bluetooth outbox for the network outbox. The raw values are the closed vocabulary of the
/// `fallback` log line (`reason=`).
public enum MeshFallbackReason: String, CaseIterable, Sendable {
    /// No delivery receipt after ``MeshFallbackPolicy/fallbackMs`` and the network can carry the message.
    case deadline
    /// The radio is off or the mesh is disabled: nothing will ever send it over Bluetooth.
    case radioOff = "radio_off"
    /// The outbox's one-hour limit. The message is handed over, never marked failed here.
    case giveup
    /// The same deadline check, run because the network just came back.
    case reconnect
    /// A message set to Bluetooth only, handed over because the user chose to send it through the internet.
    case userChoice = "user_choice"
}

/// Where a message set to Bluetooth only stands with the user. Persisted per message id by the app.
public enum MeshBtOnlyState: String, Codable, CaseIterable, Sendable {
    /// Nothing shown yet.
    case idle
    /// Bluetooth could not deliver: the prompt "send through the internet?" is on the message and waits for an answer.
    case prompted
    /// The user said no: it stays on Bluetooth and the prompt is not shown again until the one-hour limit.
    case declined
    /// The one-hour limit passed: a persistent "not delivered over Bluetooth" state with the two actions.
    case undelivered
}

/// What to do now with a message set to Bluetooth only. It is never a hand-over: only the user's answer sends it through
/// the internet.
public enum MeshBtOnlyAction: Equatable, Sendable {
    case none
    /// Show the prompt on the message.
    case prompt
    /// The one-hour limit: keep the message parked and show the persistent state (never failed, never sent).
    case park
}

/// When a message that waits on the Bluetooth mesh is handed to the network path.
///
/// A message is never stranded on the mesh: Bluetooth is an extra path, not a dead end. For "prefer Bluetooth" the
/// hand-over is silent and automatic. For "Bluetooth only" (and a target armed on the radar) it is never automatic:
/// the user is asked. Pure on purpose (no clock, no radio, no storage), so the rules are testable with plain numbers.
public enum MeshFallbackPolicy {
    /// A message with no delivery receipt after this long goes to the server path (or, for Bluetooth only, to the
    /// prompt), when the network can carry it.
    public static let fallbackMs: Int64 = 120_000

    /// The kinds of user content a chat can send. Only text can travel over the Bluetooth mesh.
    public enum ContentKind: String, CaseIterable, Sendable {
        case text, attachment, image, voiceNote, video, liveLocation

        /// The content kind of a file transfer kind (`FileV2Descriptor.Kind` raw value).
        public static func ofFileKind(_ raw: String) -> ContentKind {
            switch raw {
            case "image": return .image
            case "voice": return .voiceNote
            case "video": return .video
            default: return .attachment
            }
        }
    }

    /// Whether a send is held at once instead of started: in a Bluetooth-only chat, anything the mesh cannot carry (every
    /// kind but text) is held and the user is asked; it reaches the network only through the user's answer.
    public static func holdsContent(kind: ContentKind, preference: MeshRoutingPreference, armedMeshTarget: Bool) -> Bool {
        kind != .text && isBluetoothOnly(preference: preference, armedMeshTarget: armedMeshTarget)
    }

    /// What a hand-over from the Bluetooth outbox does, judged at the moment it would happen against the CURRENT policy (the
    /// contact may have been switched to Bluetooth only after the message was queued).
    public enum HandOverDecision: Equatable, Sendable {
        case handOver
        /// Keep it on Bluetooth, hold the row, and show this state (the prompt, or the parked state at the one-hour limit).
        case hold(prompt: MeshBtOnlyState)
    }

    public static func handOverDecision(
        reason: MeshFallbackReason, rowHeld: Bool, currentlyBluetoothOnly: Bool
    ) -> HandOverDecision {
        if reason == .userChoice { return .handOver }
        if rowHeld || currentlyBluetoothOnly { return .hold(prompt: reason == .giveup ? .undelivered : .prompted) }
        return .handOver
    }

    /// What the network send of user content does: it goes only with the user's explicit "send over the internet" answer when the
    /// conversation is Bluetooth only. Otherwise the message is held and the user is asked; it is never dropped and never sent.
    public enum UserContentSend: Equatable, Sendable {
        case send
        case holdAndPrompt
    }

    public static func userContentSend(hasUserChoice: Bool, bluetoothOnly: Bool) -> UserContentSend {
        (bluetoothOnly && !hasUserChoice) ? .holdAndPrompt : .send
    }

    /// What "No, continue over Bluetooth" / "Try Bluetooth again" does. It is never a network send.
    public enum KeepPlan: Equatable, Sendable {
        /// The Bluetooth outbox still holds the message: it keeps it there.
        case keepEntry
        /// No entry: the routing runs again from the stored row and the text is sealed again.
        case reroute
        /// No entry and still no route: the message stays held and the state stays on the bubble.
        case stayHeld
    }

    public static func keepPlan(hasEntry: Bool, routeAvailable: Bool) -> KeepPlan {
        if hasEntry { return .keepEntry }
        return routeAvailable ? .reroute : .stayHeld
    }

    /// What ran the check.
    public enum Trigger: Sendable {
        /// The outbox's own periodic tick.
        case timer
        /// The signalling socket just authenticated again.
        case reconnect
    }

    /// Whether a message is "Bluetooth only": the contact is set to Bluetooth only, or a target is armed on the radar.
    public static func isBluetoothOnly(preference: MeshRoutingPreference, armedMeshTarget: Bool) -> Bool {
        armedMeshTarget || preference == .meshOnly
    }

    /// Whether the retry of a failed message takes the network whatever the routing preference says. Never for a
    /// Bluetooth-only message: its retry goes through the normal routing again, and the internet only by the user's answer.
    public static func retryForcesNetwork(preference: MeshRoutingPreference, armedMeshTarget: Bool) -> Bool {
        !isBluetoothOnly(preference: preference, armedMeshTarget: armedMeshTarget)
    }

    /// Whether the antenna counts as off for the fallback check. A kill switch is final. Otherwise the antenna is only
    /// off once the app has decided about it: at a cold start the network socket can authenticate before the stored
    /// antenna mode is restored, and that must not read as "radio off".
    public static func radioIsOff(featureEnabled: Bool, modeRequested: Bool, decisionSettled: Bool) -> Bool {
        if !featureEnabled { return true }
        guard decisionSettled else { return false }
        return !modeRequested
    }

    /// The reason to hand a "prefer Bluetooth" message over now, or nil to keep it on the mesh. The first rule that
    /// applies wins: radio off, then the one-hour limit (handed over whether or not the network is usable right now,
    /// since the network outbox owns every later retry and failure), then the deadline (only while the network is usable).
    public static func reason(
        createdAtMs: Int64,
        nowMs: Int64,
        networkUsable: Bool,
        radioOff: Bool,
        trigger: Trigger = .timer
    ) -> MeshFallbackReason? {
        if radioOff { return .radioOff }
        let age = nowMs - createdAtMs
        if age > MeshOutboxPolicy.giveUpMs { return .giveup }
        if age >= fallbackMs, networkUsable {
            return trigger == .reconnect ? .reconnect : .deadline
        }
        return nil
    }

    /// What to do with a Bluetooth-only message: show the prompt (radio off at once; no delivery after the deadline while
    /// the network is usable), park it at the one-hour limit, or nothing. Never a hand-over.
    public static func bluetoothOnlyAction(
        createdAtMs: Int64,
        nowMs: Int64,
        networkUsable: Bool,
        radioOff: Bool,
        state: MeshBtOnlyState
    ) -> MeshBtOnlyAction {
        if state == .undelivered { return .none }
        if nowMs - createdAtMs > MeshOutboxPolicy.giveUpMs { return .park }
        guard state == .idle else { return .none }
        if radioOff { return .prompt }
        if nowMs - createdAtMs >= fallbackMs, networkUsable { return .prompt }
        return .none
    }
}

extension MeshOutboxQueue {
    /// The "prefer Bluetooth" MESSAGE entries to hand to the network path now, oldest first, each with its reason.
    /// Receipts are never handed over, and a Bluetooth-only message (or one whose value is unknown) is never in this list,
    /// whatever the age, the radio or the network.
    public func fallbackCandidates(
        nowMs: Int64,
        networkUsable: Bool,
        radioOff: Bool,
        trigger: MeshFallbackPolicy.Trigger = .timer
    ) -> [(entry: MeshOutboxEntry, reason: MeshFallbackReason)] {
        entries
            // Only an entry known NOT to be Bluetooth only is handed over on its own: a missing value (an entry stored by an
            // earlier build) is treated as Bluetooth only until the app has worked out the real one.
            .filter { $0.kind == .message && $0.bluetoothOnly == false }
            .sorted { $0.createdAtMs < $1.createdAtMs }
            .compactMap { entry in
                MeshFallbackPolicy.reason(
                    createdAtMs: entry.createdAtMs, nowMs: nowMs,
                    networkUsable: networkUsable, radioOff: radioOff, trigger: trigger
                ).map { (entry: entry, reason: $0) }
            }
    }

    /// The Bluetooth-only MESSAGE entries that need the user now (prompt or park), oldest first.
    public func bluetoothOnlyActions(
        nowMs: Int64,
        networkUsable: Bool,
        radioOff: Bool,
        stateOf: (String) -> MeshBtOnlyState
    ) -> [(entry: MeshOutboxEntry, action: MeshBtOnlyAction)] {
        entries
            .filter { $0.kind == .message && $0.bluetoothOnly != false }
            .sorted { $0.createdAtMs < $1.createdAtMs }
            .compactMap { entry in
                let action = MeshFallbackPolicy.bluetoothOnlyAction(
                    createdAtMs: entry.createdAtMs, nowMs: nowMs, networkUsable: networkUsable,
                    radioOff: radioOff, state: stateOf(entry.id))
                return action == .none ? nil : (entry: entry, action: action)
            }
    }
}
