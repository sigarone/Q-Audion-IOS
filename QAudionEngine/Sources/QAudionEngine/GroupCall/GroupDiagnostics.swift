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
        /// The group's loudspeaker route was re-asserted after the 1:1 teardown.
        case routeKept = 5
        /// The group media never came up: the 1:1 call goes on.
        case abandoned = 8
        /// The peer never showed up: hand-over forced by the timeout.
        case forced = 9
    }

    /// `grp swap phase=<n> ms=<since the hand-over began>`
    public static func promotionLine(_ phase: PromotionPhase, ms: Int) -> String {
        "grp swap phase=\(phase.rawValue) ms=\(clamp(ms))"
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

    /// `grp route out=<output code> vol=<0-100>`
    public static func routeLine(portType: String?, volume: Float) -> String {
        let percent = Int((min(max(volume, 0), 1) * 100).rounded())
        return "grp route out=\(outputCode(portType: portType)) vol=\(percent)"
    }
}
