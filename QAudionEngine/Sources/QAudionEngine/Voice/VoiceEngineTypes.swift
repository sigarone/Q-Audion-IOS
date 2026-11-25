import Foundation

// The inputs, the environment and the outputs of the voice engine (VoiceEngine.swift). Every input of a call is an item with
// the instant at which it reaches the worker, on the tap clock: the engine has no clock of its own.

/// Whether the speaker model loaded (`ok`), failed (`fail`: Cannot verify (model)) or is not applicable (`na`: nothing is embedded).
enum VoiceModelStatus: String {
    case ok
    case fail
    case na
}

/// The media path of the call: SRTP, or the data-channel fallback (for the rest of the call once it is left).
enum VoicePath: String {
    case srtp
    case dc
}

/// The fields of a decoded consent message that the engine reads.
struct VoiceVcons {
    var seq: Int
    var allow: Bool
    var withdraw: Bool
    var routeClass: Int
}

enum VoiceEngineItem {
    /// Media start: every state of the media epoch is reset; `tNs` is the call's time zero. The first one starts the call.
    case mediaStart(atNs: Int64, tNs: Int64, tierInput: VoiceTierInput?)
    /// An RX block called at `tNs` with its samples at `rateHz`; `ticks` is the cumulative tap position after it and `dropped` the
    /// number of blocks that the queue dropped just before it.
    case rx(atNs: Int64, tNs: Int64, rateHz: Int, ticks: Int64, pcm: [Int16], dropped: Int)
    /// A stats delivery (its time is `snapshot.arriveNs`; `atNs` is when it reaches the worker, later when it is late).
    case stats(atNs: Int64, snapshot: VoiceStatsSnapshot)
    /// The local user's mute changed at tap clock `tNs`.
    case mute(atNs: Int64, tNs: Int64, muted: Bool)
    /// The peer's consent message, opened and decoded; `wallS` is the unix time at which it arrived.
    case vcons(atNs: Int64, vcons: VoiceVcons, wallS: Int)
    /// The peer's announced route class (a change starts an epoch).
    case route(atNs: Int64, routeClass: Int)
    /// The call is put on hold or resumed.
    case hold(atNs: Int64, held: Bool)
    /// The media path changed.
    case path(atNs: Int64, path: VoicePath)
    /// A moment at which the tier is evaluated.
    case tier(atNs: Int64, input: VoiceTierInput)
    /// Busy time that another component of the call reports to the process-wide budget.
    case busy(atNs: Int64, who: String, startNs: Int64, endNs: Int64)
    /// The owner's "It was <name>".
    case wasHim(atNs: Int64)
    /// A poll that cannot be used (no audio inbound row, more than one, or not Opus): the engine is inactive for the rest of the
    /// call and reports Cannot verify (audio).
    case audioFault(atNs: Int64)
    /// The call ends at tap clock `tNs`.
    case callEnd(atNs: Int64, tNs: Int64)
    /// A call, incoming or outgoing, starts: the post-call work of this one is cancelled (never resumed).
    case postCancel(atNs: Int64)

    var atNs: Int64 {
        switch self {
        case .mediaStart(let at, _, _): return at
        case .rx(let at, _, _, _, _, _): return at
        case .stats(let at, _): return at
        case .mute(let at, _, _): return at
        case .vcons(let at, _, _): return at
        case .route(let at, _): return at
        case .hold(let at, _): return at
        case .path(let at, _): return at
        case .tier(let at, _): return at
        case .busy(let at, _, _, _): return at
        case .wasHim(let at): return at
        case .audioFault(let at): return at
        case .callEnd(let at, _): return at
        case .postCancel(let at): return at
        }
    }
}

/// The environment of one call. `record` is the contact's record at the start of the call, or nil.
struct VoiceCallInfo {
    /// The first 8 characters go into the log lines.
    var callId: String
    var ownerOn: Bool
    var model: VoiceModelStatus
    var record: TemplateRecord?
    /// Unix time of the call's start.
    var tStartS: Int
    var utcOffsetS: Int
    /// The device tag of the peer's device.
    var deviceTag: Int
    /// The display flags of the call; the constants' when nil.
    var display: VoiceScoringConstants.Display?
    /// A unit vector: the leak counter `rown` (diagnostic only).
    var ownerTemplate: [Float]?
    /// False when the peer device is really unknown (an outgoing call whose answer named no device): the device is then not counted
    /// as new (no `newdev`, no "device not used" wording). The tier of such a call is 0 anyway.
    var deviceKnown = true
}

/// What a window embedding gives: the raw vector of the model and the busy time it cost (virtual in the replay, measured in the app).
struct VoiceEmbedding {
    var raw: [Float]
    var costNs: Int64
}

/// The embedder behind the engine (it runs on the engine's worker, never on the main thread). Nil, or a thrown error, means that
/// the window cannot be embedded (the fate `embed_failed`); a vector that is not 512 finite values with a norm above zero is the
/// same.
protocol VoiceWindowEmbedder: AnyObject {
    func embed(window: VoiceWindowResult) throws -> VoiceEmbedding?
}

/// The VAD of the call with the busy time of its last inference (every voice-model inference counts in the budget).
protocol TimedVadModel: VoiceVadModel {
    /// The time the last `step` took, in ns.
    var lastCostNs: Int64 { get }
}

/// What the finalizer did: the record that `endOfCall` was actually run on (`before`: the one loaded under the contact's lock,
/// which can differ from the one the call started with) and its answer. The lines of the learning step and of the update compare
/// `before` with the record written.
struct VoiceFinish {
    var before: TemplateRecord?
    var end: CallEnd
}

/// The end of the call, handed to the state functions: `record` is the record the call started with (nil when the contact had
/// none, or the peer withdrew in this call). The app runs `VoiceTemplateState.endOfCall` on the record that it loads under the
/// contact's lock and saves the result under that same lock (load, update and save are ONE operation per contact, never a record
/// loaded at the start of a call of minutes); the replay runs it on the record it is given and passes the result through the
/// codec. A throw means that nothing was written.
typealias VoiceCallFinalizer = (TemplateRecord?, StateCall) throws -> VoiceFinish

/// What one call adds to the daily counters: final display, shadow flags and the strata, with no identity.
struct VoiceCallSummary {
    /// `match`, `chk`, `diff`, `nover`, `chg`, `off` or `na` (the `res` of the end line).
    var res: String
    /// True for a call of an Enrolled or Needs-refresh contact (the verify mode).
    var verifyMode: Bool
    /// The shadow Differs (verify mode) or shadow change (call-local mode) flag was ever set.
    var shadow: Bool
    /// Seconds of final VAD speech.
    var speechS: Int64
    /// The worst block ratio bucket, 0 to 4.
    var margin: Int
    /// The route class of the call (0 unknown, 1 ear, 2 speaker, 3 bt, 4 wired, 5 car).
    var routeClass: Int
    /// Verify mode only: the device was not covered by the learned calls.
    var newDevice: Bool
}

/// A change of the displayed state, the instant on the injected clock.
struct VoiceTransition {
    var tNs: Int64
    var from: VoiceShown
    var shown: VoiceShown
    var detail: VoiceDetail?
    var cand: VoiceCandidate
    var b: Int
}

/// What the engine asks of the world beyond the display.
enum VoiceEffect: String {
    /// The peer withdrew its consent: the contact's record is deleted at once.
    case deleteRecord = "delete_record"
}

/// What the engine reports, on the worker's thread. Every method has an empty default. The lines are the `QA-VOICE` log lines
/// (`ev=...`) with their instant; `onWindow` is called when a window is cut, and the record is completed (fate, embedding times,
/// `l_c`) as the call goes on.
protocol VoiceEngineListener: AnyObject {
    func onLine(_ tNs: Int64, _ line: String)
    func onTransition(_ transition: VoiceTransition)
    func onEffect(_ tNs: Int64, _ effect: VoiceEffect)
    func onWindow(_ record: VoiceWindowRecord)
}

extension VoiceEngineListener {
    func onLine(_ tNs: Int64, _ line: String) {}
    func onTransition(_ transition: VoiceTransition) {}
    func onEffect(_ tNs: Int64, _ effect: VoiceEffect) {}
    func onWindow(_ record: VoiceWindowRecord) {}
}

/// What became of a window.
enum WindowFate: String {
    case pending
    case notNeeded = "not_needed"
    case droppedPending = "dropped_pending"
    case droppedBlocked = "dropped_blocked"
    case droppedPath = "dropped_path"
    case droppedInactive = "dropped_inactive"
    case embedFailed = "embed_failed"
    case embedded
    case postPlanned = "post_planned"
    case embeddedPostCall = "embedded_post_call"
    case droppedPostCall = "dropped_post_call"
    case droppedCancelled = "dropped_cancelled"
}

/// One window cut, with what the engine adds: filled in as its fate is decided.
final class VoiceWindowRecord {
    let n: Int
    let epoch: Int
    let w: Int
    let disjoint: Bool
    let ranges: [[Int]]
    let first: Int
    let last: Int
    let meanP: Double
    let speechP: Double
    let noiseP: Double
    let snrDb: Double
    let clipFrac: Double
    let plc: Double
    let plcEvents: Int
    let stretchEvents: Int
    let concUnknown: Bool
    let txUnknown: Bool
    let bw: Double
    let nb: Bool
    let enroll: Bool
    let score: Bool
    let certain: Bool
    let tCutNs: Int64
    let routeClass: Int

    var fate: WindowFate?
    var embedStartNs: Int64?
    var embedDoneNs: Int64?
    var embedMs: Int64?
    /// The clipped LLR when the window was scored as evidence.
    var lC: Double?
    /// The candidate of the machine after this window.
    var cand: VoiceCandidate?
    /// Call-local mode: true when the window went into the reference, false when it was not usable for it, nil otherwise.
    var ref: Bool?
    /// Cut from chunks of an earlier epoch: embedded and handed to learning, never evidence.
    var stale = false

    init(window w: VoiceWindowResult, tCutNs: Int64, routeClass: Int) {
        n = w.n
        epoch = w.epoch
        self.w = w.w
        disjoint = w.disjoint
        ranges = w.ranges
        first = w.first
        last = w.last
        meanP = w.meanP
        speechP = w.speechP
        noiseP = w.noiseP
        snrDb = w.snrDb
        clipFrac = w.clipFrac
        plc = w.plc
        plcEvents = w.plcEvents
        stretchEvents = w.stretchEvents
        concUnknown = w.concUnknown
        txUnknown = w.txUnknown
        bw = w.bw
        nb = w.narrowband
        enroll = w.enroll
        score = w.score
        certain = w.certain
        self.tCutNs = tCutNs
        self.routeClass = routeClass
    }
}

/// The state of the display at the end of the call (before the post-call work).
struct VoiceFinalState {
    var shown: VoiceShown
    var detail: VoiceDetail?
    var cand: VoiceCandidate
    var b: Int
    var worst: Double
    var blockN: Int
    var differed: Bool
    var scored: Int
    var unc: Int
    var speechMs: Int64
    var routeCovered: Bool
    var deviceCovered: Bool
}

/// How the call was flushed into the state functions. `info` is nil when they were not called, or when the finalizer threw
/// (`failed`).
struct VoiceFlushResult {
    var flushNs: Int64
    var cancelled: Bool
    var ran: Bool
    var failed: Bool
    var info: CallResult?
    var record: TemplateRecord?
}

/// Everything the engine reads that is not the call: the sections of `constants.json` (a replay case may overlay some), the
/// tables and the cohort.
struct VoiceEngineConfig {
    let constants: VoiceConstants
    let scoring: VoiceScoringConstants
    let state: VoiceStateConstants
    let engine: VoiceEngineConstants
    let tables: VoiceFbankTables
    let cohort: VoiceCohort

    init(constants: VoiceConstants, scoring: VoiceScoringConstants, state: VoiceStateConstants, engine: VoiceEngineConstants,
         tables: VoiceFbankTables, cohort: VoiceCohort) {
        self.constants = constants
        self.scoring = scoring
        self.state = state
        self.engine = engine
        self.tables = tables
        self.cohort = cohort
    }

    init(bundle: VoiceBundle, cohort: VoiceCohort) {
        self.init(
            constants: bundle.constants, scoring: bundle.scoring, state: bundle.state, engine: bundle.engine,
            tables: bundle.tables, cohort: cohort)
    }
}
