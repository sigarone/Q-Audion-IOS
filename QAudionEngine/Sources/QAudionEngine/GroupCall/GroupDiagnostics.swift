import Foundation

/// Group-call diagnosis lines for the phone log (RTLog tag "group"), 2026-10-02.
///
/// The group path of the iPhone left almost nothing readable in the shipped logs: the
/// engine's own `print` lines are mostly masked by the phone-log shipper
/// (`scripts/ship-ios-logs.py`, fail-closed), nothing recorded what the group screen was
/// doing, which error the user was shown, how a 1:1 -> group hand-over went, whether the
/// camera ever published or whether the iPhone received any audio. Every line built here
/// uses only words the shipper already knows and numeric values, and each shape is pinned
/// verbatim in `scripts/test_ship_ios_redactor_hardening.py` (it must ship unchanged).
///
/// Never an id, a pseudonym, a key, a token, a fingerprint, an address or free text: only
/// enum codes and counters. Pure functions: `GroupDiagnosticsTests`.
public enum GroupDiagnostics {

    /// Largest number a line carries: the shipper keeps a value of at most 7 digits.
    static let maxValue = 9_999_999

    static func clamp(_ value: Int) -> Int { min(max(value, 0), maxValue) }

    // MARK: - Call state (the group screen's state machine)

    /// `GroupCallController.State` as a number: 0 idle, 1 connecting, 2 active, 3 failed.
    public static func stateCode(_ state: GroupCallController.State) -> Int {
        switch state {
        case .idle: return 0
        case .connecting: return 1
        case .active: return 2
        case .failed: return 3
        }
    }

    static func participantCount(_ state: GroupCallController.State) -> Int {
        if case .active(_, let participants) = state { return participants.count }
        return 0
    }

    /// `grp state=<0-3> old=<0-3> count=<participants>`
    public static func stateLine(_ state: GroupCallController.State, old: GroupCallController.State) -> String {
        "grp state=\(stateCode(state)) old=\(stateCode(old)) count=\(clamp(participantCount(state)))"
    }

    // MARK: - Errors shown to the user

    /// The numeric code of a media error (the toast it shows is chosen by
    /// `GroupCallViewModel.toastText(for:)`).
    public static func errorCode(_ error: GroupCallMediaError) -> Int {
        switch error {
        case .cameraPermissionDenied: return 1
        case .cameraUnavailable: return 2
        case .full: return 3
        case .noNode: return 4
        case .roomCreateFailed: return 5
        case .notMember: return 6
        case .entitlementRequired: return 7
        case .transportPolicy: return 8
        case .mediaLost: return 9
        case .other: return 10
        }
    }

    /// `grp error code=<n>`: an error the user was shown.
    public static func errorLine(_ error: GroupCallMediaError) -> String {
        "grp error code=\(errorCode(error))"
    }

    // MARK: - 1:1 -> group hand-over

    public enum PromotionPhase: Int, Sendable {
        /// The group call was created from the live 1:1 call.
        case begun = 1
        /// The group media path connected.
        case mediaConnected = 2
        /// The promoted peer is in the group.
        case peerJoined = 3
        /// The 1:1 leg was ended (make-before-break done).
        case handedOver = 4
        /// 1.5 s after the hand-over: the route is sampled again (`grp route out= vol=`
        /// follows). Nothing is re-asserted here.
        case routeSampled = 5
        /// The group media never came up: the 1:1 call goes on.
        case abandoned = 8
        /// The peer never showed up: hand-over forced by the timeout.
        case forced = 9
        /// An attested promotion invite was joined with no ring (invitee side).
        case autoJoined = 6
        /// The peer's invite is over (declined, ring timeout): the hand-over goes ahead.
        case peerInviteOver = 7
        /// The 1:1 leg ended by itself while the hand-over was pending.
        case oneToOneEnded = 10
        /// The group ended while the hand-over was pending: the 1:1 call stays.
        case aborted = 11
    }

    /// `grp swap phase=<n> ms=<since the hand-over began>`
    public static func promotionLine(_ phase: PromotionPhase, ms: Int) -> String {
        "grp swap phase=\(phase.rawValue) ms=\(clamp(ms))"
    }

    // MARK: - Ring, lone call, admission (spec 27-31)

    public enum RingPhase: Int, Sendable {
        /// An invite rings.
        case shown = 1
        /// An invite was dropped as busy (`code` = `BusyCode`).
        case busyDrop = 2
        /// The 45 s ring timer ran out here.
        case timedOut = 3
        /// The user declined.
        case declined = 4
        /// The server ended the ring (`code` = `endReasonCode`).
        case endedByServer = 5
        /// An attested promotion invite was joined with no ring.
        case autoJoin = 6
        /// The user accepted.
        case accepted = 7
    }

    /// Why an invite was dropped as busy: 1 a 1:1 call is live or ringing, 3 a group call is live.
    public enum BusyCode: Int, Sendable {
        case oneToOne = 1
        case groupCall = 3
    }

    /// `grp ring phase=<1-7> code=<n>`
    public static func ringLine(_ phase: RingPhase, code: Int = 0) -> String {
        "grp ring phase=\(phase.rawValue) code=\(clamp(code))"
    }

    /// The `group_call_ended` reason as a number: 1 ring_timeout, 2 declined,
    /// 3 answered_elsewhere, 4 ended, 5 alone, 9 anything else.
    public static func endReasonCode(_ reason: String) -> Int {
        switch reason {
        case "ring_timeout": return 1
        case "declined": return 2
        case "answered_elsewhere": return 3
        case "ended": return 4
        case "alone": return 5
        default: return 9
        }
    }

    public enum AlonePhase: Int, Sendable {
        /// The roster became only this device with nobody ringing: the 50 s timer is armed.
        case armed = 1
        /// A join, another participant or a ringing invitee: the timer is cancelled.
        case cancelled = 2
        /// The timer ran out and this device left.
        case left = 3
        /// The timer ran out and this device, the creator, ended the call.
        case ended = 4
    }

    /// `grp alone phase=<1-4> ms=<n>` (`ms` = the timer's length)
    public static func aloneLine(_ phase: AlonePhase, ms: Int) -> String {
        "grp alone phase=\(phase.rawValue) ms=\(clamp(ms))"
    }

    /// `grp ringing n=<invitees still ringing> roster=<participants>`
    public static func ringingLine(count: Int, roster: Int) -> String {
        "grp ringing n=\(clamp(count)) roster=\(clamp(roster))"
    }

    public enum AdmissionPhase: Int, Sendable {
        /// "Leave the group?" was asked before placing a 1:1 call.
        case askedToDial = 1
        /// "Leave the group?" was asked before accepting a 1:1 call.
        case askedToAnswer = 2
        /// The user chose to leave: the group is left, then the 1:1 call goes ahead.
        case confirmed = 3
        /// The user chose to stay: nothing happens, an incoming 1:1 call is declined as busy.
        case cancelled = 4
        /// The incoming call the question was about is over: the question is withdrawn, the group stays.
        case withdrawn = 5
        /// A 1:1 call asked for from the car (CarPlay, Siri) while a group call is live: refused, no question is asked
        /// on the phone, the car screen says the call did not start.
        case refusedFromCar = 6
    }

    /// `grp busy why=<1-6> roster=<participants of the group call>`
    public static func admissionLine(_ phase: AdmissionPhase, roster: Int) -> String {
        "grp busy why=\(phase.rawValue) roster=\(clamp(roster))"
    }

    public enum ExitReason: Int, Sendable {
        /// The lone-call timer.
        case alone = 1
        /// A 1:1 call was placed or accepted.
        case oneToOne = 2
        /// Another group call was accepted.
        case acceptOther = 3
        /// The 1:1 call ended while the hand-over was pending and nobody else is in the group.
        case oneToOneEndedAlone = 4
        /// The hang-up of the group screen or of the system (CallKit End, headset button).
        case hangUp = 5
        /// The promoted peer's invite is over and this device is alone with nobody ringing: the
        /// promotion is aborted, the 1:1 call stays.
        case promotionAborted = 6
        /// The roster of an automatically joined call went outside what the promotion token listed.
        case rosterMismatch = 7
        /// The group media never came up during a promotion.
        case mediaNotUp = 8
    }

    /// `grp end why=<1-4> role=<0|1>` (role 1 = this device ends the call for all)
    public static func exitLine(_ why: ExitReason, endsForAll: Bool) -> String {
        "grp end why=\(why.rawValue) role=\(endsForAll ? 1 : 0)"
    }

    // MARK: - Promotion token (docs/GROUP_CALLS_V2_SPEC.md item 32)

    /// `grp promo tx=<1|2> n=<invitees>`: the creator sent its promotion token (1) or re-sent the same
    /// bytes once after a socket re-authentication (2).
    public static func promoSentLine(resend: Bool, invitees: Int) -> String {
        "grp promo tx=\(resend ? 2 : 1) n=\(clamp(invitees))"
    }

    /// `grp promo tx=0 n=<recipients>`: no token was sent (a precondition of the token, GROUP_CALLS_V2 2.7, failed),
    /// the group was created as before and the peer rings.
    public static func promoNotSentLine(invitees: Int) -> String {
        "grp promo tx=0 n=\(clamp(invitees))"
    }

    /// The `code=` of a received token: 0 stored, 1-15 a `GroupPromotionToken.Drop`, 16 stored and the
    /// oldest held token was evicted.
    public static let promoStoredEvictingCode = 16

    /// `grp promo rx=1 ok=<0|1> code=<n>`: a token arrived (never the token, a signature, a key or an id).
    public static func promoReceivedLine(ok: Bool, code: Int) -> String {
        "grp promo rx=1 ok=\(ok ? 1 : 0) code=\(clamp(code))"
    }

    /// The outcome of the auto-join decision as a number.
    public enum PromoDecision: Int, Sendable {
        case auto = 1
        case hold = 2
        case ring = 3
        case convert = 4
        case fallback = 5
    }

    /// `grp promo dec=<1-5> why=<1-10>` (`GroupPromotionDecision.Why`)
    public static func promoDecisionLine(_ decision: PromoDecision, why: GroupPromotionDecision.Why) -> String {
        "grp promo dec=\(decision.rawValue) why=\(why.rawValue)"
    }

    /// `grp promo roster=0 n=<people the token did not list>`: the roster rule failed, the device leaves.
    public static func promoRosterLine(extra: Int) -> String {
        "grp promo roster=0 n=\(clamp(extra))"
    }

    /// The audio unit driver of a group call (`GroupAudioUnitDriver`).
    public enum AudioDriverPhase: Int, Sendable {
        /// The call began (`shared` = the 1:1 leg already holds the arm).
        case begun = 1
        /// No session activation arrived in time: the app is asked for one.
        case watchdog = 2
        /// A session activation arrived while the 1:1 leg holds the unit.
        case activatedShared = 3
        /// The driver took the arm over after the 1:1 leg released it.
        case rearmed = 4
    }

    /// `grp audio phase=<1-4> shared=<0|1>`
    public static func audioDriverLine(_ phase: AudioDriverPhase, shared: Bool) -> String {
        "grp audio phase=\(phase.rawValue) shared=\(shared ? 1 : 0)"
    }

    /// The 1:1 audio start was refused because a group call owns the audio unit (RTLog tag
    /// "call", level warn): `audioIO skip=1 gate=1 nat=<0|1> en=<0|1>`. `nat` = the 1:1 call
    /// negotiated native audio, `en` = WebRTC's unit is enabled right now. With `nat=1 en=0` the
    /// 1:1 call has no audio unit running at all, which is what the line is there to show.
    public static func audioStartRefusedLine(native: Bool, unitEnabled: Bool) -> String {
        "audioIO skip=1 gate=1 nat=\(native ? 1 : 0) en=\(unitEnabled ? 1 : 0)"
    }

    // MARK: - Camera publish

    public enum VideoPhase: Int, Sendable {
        /// The camera switch was asked for.
        case requested = 1
        /// The capturer's outcome (`code` = `cameraCode`).
        case camera = 2
        /// `configure video:<on>` sent to the publisher.
        case configureSent = 3
        /// Janus answered the `configure` (ok=1) or the request failed (ok=0).
        case configureAnswered = 4
        /// The first encoded frame left the encoder (ok=0: none within the timeout).
        case firstFrame = 5
        /// There was no media link to switch.
        case noLink = 6
        /// A connected publisher's encoder produced no frame for too long: the sender was
        /// re-configured to the l layer alone (`GroupVideoEncoderWatchdog`); `ms` = how long it
        /// had been silent.
        case singleLayerFallback = 7
    }

    /// `GroupCameraResult` as a number: 0 started, 1 stopped, 2 permission denied,
    /// 3 no camera, 4 not ready.
    public static func cameraCode(_ result: GroupCameraResult) -> Int {
        switch result {
        case .started: return 0
        case .stopped: return 1
        case .permissionDenied: return 2
        case .noCamera: return 3
        case .notReady: return 4
        }
    }

    /// `grp video camera=<0|1> phase=<n> ok=<0|1> code=<n> ms=<n>`
    public static func videoLine(camera: Bool, phase: VideoPhase, ok: Bool, code: Int = 0, ms: Int = 0) -> String {
        "grp video camera=\(camera ? 1 : 0) phase=\(phase.rawValue) ok=\(ok ? 1 : 0) code=\(clamp(code)) ms=\(clamp(ms))"
    }

    /// `grp audio cap n=<encodings> min=<bps> max=<bps> apt=<0|1> ok=<0|1>`: what the published audio sender's
    /// parameters read back as after the 32 kbps / fixed-packet-time / DSCP pin. `ok` = 1 when the read-back equals what
    /// was set (bitrate min = max, fixed packet time, high priority). A value that could not be read is 0 (and then
    /// `ok` is 0): the line keeps its shape, which is what the phone-log shipper's gate accepts. A sender without any
    /// encoding gives `n=0 min=0 max=0 apt=0 ok=0`.
    public static func audioSenderLine(encodings: Int, minBps: Int, maxBps: Int, adaptivePacketTime: Int, ok: Bool) -> String {
        let adaptive: Int = adaptivePacketTime == 1 ? 1 : 0
        var out: String = "grp audio cap"
        out += " n=\(clamp(encodings))"
        out += " min=\(clamp(minBps))"
        out += " max=\(clamp(maxBps))"
        out += " apt=\(adaptive)"
        out += ok ? " ok=1" : " ok=0"
        return out
    }

    // MARK: - Heartbeat (every `GroupMediaSession.Config.heartbeatSeconds`)

    /// `GroupPcState` as a number: 0 new, 1 connecting, 2 connected, 3 disconnected,
    /// 4 failed, 5 closed, 9 no PeerConnection.
    public static func pcStateCode(_ state: GroupPcState?) -> Int {
        guard let state = state else { return 9 }
        switch state {
        case .new: return 0
        case .connecting: return 1
        case .connected: return 2
        case .disconnected: return 3
        case .failed: return 4
        case .closed: return 5
        }
    }

    /// `grp hb ice send=<pc code> recv=<pc code>`: publisher / subscriber PeerConnection.
    public static func iceLine(publisher: GroupPcState?, subscriber: GroupPcState?) -> String {
        "grp hb ice send=\(pcStateCode(publisher)) recv=\(pcStateCode(subscriber))"
    }

    /// The subscriber mid as a number (Janus multistream mids are "0", "1", ...); `index`
    /// when it is not one.
    static func midNumber(_ mid: String, index: Int) -> Int {
        if let value = Int(mid), value >= 0, value <= 99_999 { return value }
        return clamp(index)
    }

    /// `grp hb audio mid=<n> bytes=<delta> lost=<delta> rxlvl=<0-100>`: one remote audio
    /// stream since the previous heartbeat. bytes=0 while the call is up = this phone
    /// hears nothing from that participant.
    public static func rxAudioLine(mid: String, index: Int, bytes: Int, lost: Int, level: Double) -> String {
        let percent = Int((min(max(level, 0), 1) * 100).rounded())
        return "grp hb audio mid=\(midNumber(mid, index: index)) bytes=\(clamp(bytes)) lost=\(clamp(lost)) rxlvl=\(percent)"
    }

    /// `grp hb tx audio=<bytes delta> video=<bytes delta> frames=<encoded delta>`: what this
    /// phone published since the previous heartbeat.
    public static func txLine(audioBytes: Int, videoBytes: Int, framesEncoded: Int) -> String {
        "grp hb tx audio=\(clamp(audioBytes)) video=\(clamp(videoBytes)) frames=\(clamp(framesEncoded))"
    }

    // MARK: - Audio route

    /// The output port as a number: 1 earpiece, 2 loudspeaker, 3 Bluetooth, 4 wired,
    /// 5 car, 9 anything else, 0 none. `portType` is `AVAudioSession.Port.rawValue`.
    public static func outputCode(portType: String?) -> Int {
        guard let port = portType else { return 0 }
        switch port {
        case "Receiver": return 1
        case "Speaker": return 2
        case "BluetoothHFP", "BluetoothA2DPOutput", "BluetoothLE": return 3
        case "Headphones", "LineOut", "USBAudio": return 4
        case "CarAudio": return 5
        default: return 9
        }
    }

    /// The output volume as 0-100 (a value the system cannot produce maps to 0).
    static func volumePercent(_ volume: Float) -> Int {
        guard volume.isFinite else { return 0 }
        return Int((min(max(volume, 0), 1) * 100).rounded())
    }

    /// `grp route out=<output code> vol=<0-100>`: a SAMPLE of the output now.
    public static func routeLine(portType: String?, volume: Float) -> String {
        "grp route out=\(outputCode(portType: portType)) vol=\(volumePercent(volume))"
    }

    /// `grp route why=<reason> old=<output code> out=<output code> vol=<0-100>`: ONE audio
    /// route change while a group call is live, from `AVAudioSession.routeChangeNotification`.
    /// `reason` is the raw value of `AVAudioSession.RouteChangeReason` (0 unknown, 1 new
    /// device, 2 old device gone, 3 category change, 4 override, 6 wake from sleep, 7 no
    /// suitable route, 8 route configuration change), `old` the output the route left,
    /// `out` the output it reached, `vol` the output volume then. The samples above cannot
    /// show a flip that happens between two of them: a loudspeaker -> earpiece ->
    /// loudspeaker blip is two of these lines (`old=2 out=1`, then `old=1 out=2`).
    public static func routeChangeLine(reason: Int, previousPortType: String?, portType: String?, volume: Float) -> String {
        "grp route why=\(clamp(reason)) old=\(outputCode(portType: previousPortType)) out=\(outputCode(portType: portType)) vol=\(volumePercent(volume))"
    }
}
