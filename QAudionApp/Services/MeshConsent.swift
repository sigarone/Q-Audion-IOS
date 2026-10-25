import Foundation
import QAudionEngine

/// The answer to the one-time Bluetooth mesh consent screen, about one thing: may this phone relay the encrypted
/// messages of OTHER app users who are nearby (it cannot read them)?
///
/// Using the user's device for the benefit of other people needs the user's explicit consent, so the radio never starts
/// on its own and never relays by default:
///   - the relay alert's "Consenti" (`accepted`): this phone finds nearby contacts, exchanges its own messages with them
///     and relays other people's encrypted messages (full mesh);
///   - "Continua" on the screen before the Bluetooth permission request (`declined`): this phone finds nearby contacts and
///     exchanges its own messages with them (direct mode) but never forwards anyone else's;
///   - not answered yet (`undecided`): nothing starts and no Bluetooth permission is asked for.
/// The rules for which mode each answer allows live in the engine (`MeshModePolicy`).
typealias MeshConsentState = MeshRelayConsent

/// Where the answer is kept. The `UserDefaults` is a parameter so the rules can
/// be tested against a throwaway suite. Anything stored that is not one of the
/// three known values counts as "never answered".
struct MeshConsentStore {
    static let key: String = "qaudion.mesh.consent.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var state: MeshConsentState {
        guard let raw = defaults.string(forKey: Self.key),
              let parsed = MeshConsentState(rawValue: raw) else {
            return .undecided
        }
        return parsed
    }

    func record(_ state: MeshConsentState) {
        defaults.set(state.rawValue, forKey: Self.key)
    }
}

/// The two decisions the app takes from the feature gate and the consent. Plain values in, plain answer out, so the rules
/// are tested without a radio.
enum MeshStartGate {

    /// The radio may be brought up in SOME mode when the feature is available (compiled on and not switched off by the
    /// remote kill switch) AND the consent screen was answered. "Undecided" keeps it off; "declined" allows the
    /// non-relaying modes only (`mayStart(featureEnabled:consent:mode:)`).
    static func mayStart(featureEnabled: Bool, consent: MeshConsentState) -> Bool {
        featureEnabled && consent != .undecided
    }

    /// The radio may be brought up in `mode`: full mesh needs the consent to relay.
    static func mayStart(featureEnabled: Bool, consent: MeshConsentState, mode: MeshAntennaMode) -> Bool {
        MeshModePolicy.mayStart(featureEnabled: featureEnabled, consent: consent, mode: mode)
    }

    /// The consent screen is offered on its own only while the feature is available and the user has not answered yet. Whether
    /// it is on screen right now also depends on the call: an incoming or running call is never covered by a sheet
    /// (`MeshConsentPresentation.sheetShown`).
    static func consentIsWanted(featureEnabled: Bool, consent: MeshConsentState) -> Bool {
        featureEnabled && consent == .undecided
    }
}

/// What the Settings switch says about the radio, under the switch itself. The switch only ever shows the consent to relay;
/// this says what the antenna is doing because of it, so a user who gave the consent and then turned the antenna off in the
/// mesh panel is not told the phone is relaying, and a user who declined relaying is told the phone still talks to nearby
/// contacts.
enum MeshSettingsStatus: Equatable {
    /// The consent screen was never answered: nothing is on.
    case notAllowed
    /// The antenna is off.
    case radioOff
    /// The antenna is on in "Visibile": nearby phones can see this one, it opens no link and relays nothing.
    case visibleOnly
    /// The antenna is on in "Diretta": it finds nearby contacts and exchanges its own messages, relaying nothing.
    case direct
    /// The antenna is on in "Mesh completa" (or coming up): this phone relays.
    case on

    static func resolve(consent: MeshConsentState, antennaOn: Bool, mode: MeshAntennaMode?) -> MeshSettingsStatus {
        guard consent != .undecided else { return .notAllowed }
        guard antennaOn else { return .radioOff }
        switch mode {
        case .visibleOnly: return .visibleOnly
        case .direct: return .direct
        case .fullMesh: return consent == .accepted ? .on : .direct
        case nil: return consent == .accepted ? .on : .direct
        }
    }
}

/// Who goes first when the consent screen and a call both want the screen: the call, always.
///
/// The consent screen is a sheet; a ringing, connecting or running call is shown by a full-screen cover at the root. Two
/// presentations changing in the same update is where SwiftUI may drop one of them, and the one at risk must never be the
/// call. So the order is decided here, in plain values, and the views only obey it:
///   - the sheet is shown only while somebody wants the question asked AND no call is busy (`sheetShown`);
///   - a call that arrives while the sheet is up first takes the sheet down, and the call cover waits until the sheet is
///     gone from the screen (`callCoverShown`, fed by `MeshConsentArbiter`), with a bounded wait so a sheet that never
///     reports back cannot hold a call hostage (`maxWaitForSheet`);
///   - after a call the sheet waits a moment (`settleAfterCall`) so it does not appear while the call cover is still
///     sliding away, and then comes back by itself because the question was never answered.
enum MeshConsentPresentation {

    /// A call is ringing, being set up or running. The facts are the ones the app keeps about calls: the 1:1 flag, the 1:1
    /// state, the 1:1 ring screen, a pending group invite and the group call controller.
    static func callIsBusy(isInCall: Bool,
                           callIdle: Bool,
                           oneToOneRinging: Bool,
                           groupInvitePending: Bool,
                           groupCallIdle: Bool) -> Bool {
        isInCall || !callIdle || oneToOneRinging || groupInvitePending || !groupCallIdle
    }

    /// The consent sheet is on screen only for a question somebody wants asked, and never while a call is busy.
    static func sheetShown(wanted: Bool, callBusy: Bool) -> Bool {
        wanted && !callBusy
    }

    /// The call cover may present once no consent sheet is on screen (or still sliding away).
    static func callCoverShown(callWanted: Bool, consentSheetOnScreen: Bool) -> Bool {
        callWanted && !consentSheetOnScreen
    }

    /// How long the consent sheet stays away after a call ended, in seconds: about twice the time a cover takes to leave.
    static let settleAfterCall: TimeInterval = 0.8

    /// The longest the call cover waits for a consent sheet to leave the screen, in seconds. A dismissal takes about a third
    /// of a second; past this the sheet is written off as gone and the call is shown.
    static let maxWaitForSheet: TimeInterval = 1.5
}

/// Which consent sheets are on screen, or still sliding away. One entry per sheet, keyed by a token its owner keeps, so a
/// sheet reported twice counts once and a sheet reported gone twice cannot make the count negative.
struct MeshConsentSheetTracker: Equatable {
    private(set) var onScreen: Set<UUID> = []

    var isUp: Bool { !onScreen.isEmpty }

    mutating func appeared(_ token: UUID) { onScreen.insert(token) }

    mutating func gone(_ token: UUID) { onScreen.remove(token) }

    /// Writes every sheet off (the bounded wait ran out).
    mutating func clear() { onScreen.removeAll() }
}

/// The meeting point of the consent sheets and the call cover, one per process (`shared`). The root mirrors "a call is busy"
/// into it for the sheets that cannot see `AppState` (Settings, the mesh panel), and every consent sheet reports here when it
/// is requested and when it is gone, so the root's call cover can wait for it.
@MainActor
final class MeshConsentArbiter: ObservableObject {

    static let shared = MeshConsentArbiter()

    @Published private(set) var callBusy: Bool = false
    @Published private(set) var tracker = MeshConsentSheetTracker()

    var consentSheetOnScreen: Bool { tracker.isUp }

    func setCallBusy(_ busy: Bool) {
        if callBusy != busy { callBusy = busy }
    }

    func sheetAppeared(_ token: UUID) {
        guard !tracker.onScreen.contains(token) else { return }
        tracker.appeared(token)
    }

    func sheetGone(_ token: UUID) {
        guard tracker.onScreen.contains(token) else { return }
        tracker.gone(token)
    }

    func clearSheets() {
        guard tracker.isUp else { return }
        tracker.clear()
    }
}

/// Observable holder of the consent, one per process (`shared`). Views observe it
/// so a switch in Settings and the sheet always agree.
@MainActor
final class MeshConsent: ObservableObject {

    static let shared = MeshConsent()

    @Published private(set) var state: MeshConsentState

    private let store: MeshConsentStore

    init(store: MeshConsentStore = MeshConsentStore()) {
        self.store = store
        self.state = store.state
    }

    var isAccepted: Bool { state == .accepted }

    func accept() {
        store.record(.accepted)
        state = .accepted
    }

    /// "Continua" on the screen before the permission request, or the Settings switch turned off: relaying is not allowed. Direct mode stays available.
    func decline() {
        store.record(.declined)
        state = .declined
    }
}
