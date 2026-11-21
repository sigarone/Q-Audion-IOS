import Foundation

/// Which rule set the machine runs: the verification rules for an Enrolled contact, the call-local rules for a contact in
/// Learning or Provisional.
enum VoiceCheckMode {
    case verify
    case callLocal
}

/// The block-rule constants of one mode. `tMatch` is nil in call-local mode: no Matches.
struct EvidenceConfig {
    let t: Double
    let tailSlope: Double
    let negMin: Int
    let mMin: Double
    let maxBlock: Int
    let deltaNew: Double
    let blockWindows: Int
    let tMatch: Double?
    let recentWindows: Int
    let matchMinWindows: Int
    let matchPartialFloor: Double
    let weakFrac: Double

    /// `evidence` for `.verify`; `call_local` (t_change, tail_slope, neg_min, m_min, max_block, delta_new 0) for the other.
    static func of(_ c: VoiceScoringConstants, mode: VoiceCheckMode) -> EvidenceConfig {
        let e = c.evidence
        switch mode {
        case .verify:
            return EvidenceConfig(
                t: e.tDiffers, tailSlope: e.tailSlope, negMin: e.negMin, mMin: e.mMin, maxBlock: e.maxBlock,
                deltaNew: e.deltaNew, blockWindows: e.blockWindows, tMatch: e.tMatch, recentWindows: e.recentWindows,
                matchMinWindows: e.matchMinWindows, matchPartialFloor: e.matchPartialFloor, weakFrac: e.weakFrac
            )
        case .callLocal:
            let cl = c.callLocal
            return EvidenceConfig(
                t: cl.tChange, tailSlope: cl.tailSlope, negMin: cl.negMin, mMin: cl.mMin, maxBlock: cl.maxBlock,
                deltaNew: 0, blockWindows: e.blockWindows, tMatch: nil, recentWindows: e.recentWindows,
                matchMinWindows: e.matchMinWindows, matchPartialFloor: e.matchPartialFloor, weakFrac: e.weakFrac
            )
        }
    }
}

/// The timings of the displayed state, in nanoseconds on the engine's clock, and the Cannot verify (audio) rule.
struct DisplayConfig {
    let dwellNs: Int64
    let holdNs: Int64
    let lookbackNs: Int64
    let minVadMs: Int64

    static func of(_ c: VoiceScoringConstants) -> DisplayConfig {
        let e = c.evidence
        let nsPerMs: Int64 = 1_000_000
        return DisplayConfig(
            dwellNs: e.dwellMs * nsPerMs, holdNs: e.differsHoldMs * nsPerMs, lookbackNs: e.noverLookbackMs * nsPerMs,
            minVadMs: e.noverMinVadMs
        )
    }
}

enum VoiceCandidate: String {
    case checking
    case matches
    case differs
}

enum VoiceShown: String {
    case off
    case learning
    case changed
    case checking
    case matches
    case differs
    case cannotVerify = "cannot_verify"
}

/// Why the engine cannot verify (without the audio rule, which the machine derives from the ticks).
enum VoiceFault: String {
    case path
    case model
    case constants
    case locked
    case cpu
}

/// The detail of a shown state: a fault or `.audio` for Cannot verify, `.deviceNew` for Differs, `.differentSetup` for Checking.
enum VoiceDetail: String {
    case deviceNew = "device_new"
    case differentSetup = "different_setup"
    case audio
    case path
    case model
    case constants
    case locked
    case cpu

    init(_ fault: VoiceFault) {
        switch fault {
        case .path: self = .path
        case .model: self = .model
        case .constants: self = .constants
        case .locked: self = .locked
        case .cpu: self = .cpu
        }
    }
}

enum VoiceContactState: String {
    case enrolled
    case needsRefresh = "needs_refresh"
    case learning
}

/// What the machine is told about the call; every field persists until set again and all reset at media start.
struct VoiceCallContext: Equatable {
    /// A consent message with allow = 1 was received in this call. Nothing is computed without it.
    var consent = false
    var fault: VoiceFault?
    /// 0, 1 or 2. Matches needs at least 1; Differs is allowed on tier 0.
    var tier = 0
    var routeCovered = true
    var deviceCovered = true
    var contact = VoiceContactState.enrolled
    /// `display.differs` and `display.change` of the constants.
    var displayDiffers = false
    var displayChange = false
}

/// The block that a window closed: `S`, `neg`, `med`, `T_b` and the two decisions.
struct ClosedBlock {
    let b: Int
    let s: Double
    let neg: Int
    let med: Double
    let tB: Double
    let differs: Bool
    let weakBlock: Bool
    let worst: Double
}

/// The state after one event.
struct VoiceRecord {
    let b: Int
    let blockN: Int
    let blockSum: Double
    let r: Double
    let recentN: Int
    /// T_(b+1) at the current device coverage.
    let tNext: Double
    let worst: Double
    /// A Differs candidate or a weak block has occurred in this call.
    let blocked: Bool
    let closed: ClosedBlock?
    let cand: VoiceCandidate
    let shown: VoiceShown
    let detail: VoiceDetail?
    /// The shown state changed at this event.
    let changed: Bool
    /// The target differs from the shown state and a dwell or hold timer keeps it back.
    let pending: Bool
    /// A Differs candidate that is not shown as Differs (or Changed): counted in the shadow counters.
    let shadow: Bool
    /// Differs or Changed was shown in this call: sticky until media start.
    let differed: Bool
}

/// The accumulator: b, block, recent, worst and the flags of the last block. Pure; every sum adds left to right in float64.
/// Single-thread (see `VoiceCallMachine`).
final class VoiceEvidence {
    private let cfg: EvidenceConfig
    private(set) var b = 0
    private var block: [Double] = []
    private var recent: [Double] = []
    private(set) var worst = 0.0
    private var lastDiffers = false
    private var lastWeak = false
    private var everDiffers = false
    private var everWeak = false

    init(_ cfg: EvidenceConfig) {
        self.cfg = cfg
    }

    var blocked: Bool { everDiffers || everWeak }
    var blockCount: Int { block.count }
    var recentCount: Int { recent.count }
    var maxBlock: Int { cfg.maxBlock }

    func mediaStart() {
        b = 0
        block.removeAll()
        recent.removeAll()
        worst = 0
        lastDiffers = false
        lastWeak = false
        everDiffers = false
        everWeak = false
    }

    /// Accumulator reset: the partial block is discarded; b, recent, worst and the flags of the last block are kept.
    func reset() {
        block.removeAll()
    }

    /// T_b = t + (2 / tail_slope) ln(b) + (0 if the device is covered else delta_new).
    func threshold(_ b: Int, deviceCovered: Bool) -> Double {
        cfg.t + (2.0 / cfg.tailSlope) * log(Double(b)) + (deviceCovered ? 0.0 : cfg.deltaNew)
    }

    /// One disjoint scoring-eligible window with clipped LLR `x`; returns the block it closed, if any.
    func window(_ x: Double, certain: Bool, deviceCovered: Bool) -> ClosedBlock? {
        recent.append(x)
        while recent.count > cfg.recentWindows { recent.removeFirst() }
        if !certain { return nil }
        block.append(x)
        if block.count != cfg.blockWindows { return nil }
        b += 1
        var s = 0.0
        for v in block { s += v }
        var neg = 0
        for v in block where v < 0.0 { neg += 1 }
        let sorted = block.sorted()
        let m = sorted.count / 2
        let med = (sorted[m - 1] + sorted[m]) / 2.0
        let tb = threshold(b, deviceCovered: deviceCovered)
        lastDiffers = s <= -tb && neg >= cfg.negMin && med <= -cfg.mMin
        lastWeak = s <= -cfg.weakFrac * tb
        everDiffers = everDiffers || lastDiffers
        everWeak = everWeak || lastWeak
        worst = max(worst, -s / tb)
        block.removeAll()
        return ClosedBlock(b: b, s: s, neg: neg, med: med, tB: tb, differs: lastDiffers, weakBlock: lastWeak, worst: worst)
    }

    func recentSum() -> Double {
        var r = 0.0
        for v in recent { r += v }
        return r
    }

    func blockSum() -> Double {
        var p = 0.0
        for v in block { p += v }
        return p
    }

    /// Differs, Matches or Checking after the last event. Call-local mode never gives Matches.
    func candidate(deviceCovered: Bool) -> VoiceCandidate {
        if lastDiffers { return .differs }
        guard let tMatch = cfg.tMatch else { return .checking }
        if recentSum() >= tMatch && recent.count >= cfg.matchMinWindows && !lastWeak
            && blockSum() > -cfg.matchPartialFloor * threshold(b + 1, deviceCovered: deviceCovered) {
            return .matches
        }
        return .checking
    }
}

/// The state machine of one call. Pure: times are int64 nanoseconds on any one clock, passed by the caller, which also
/// serialises the calls. After every event the display is re-evaluated at that event's time, and the returned `VoiceRecord`
/// is the state after it.
///
///  - `mediaStart`: every state is reset (display Off, context defaults).
///  - `setContext`: consent, fault, tier, coverage, contact state and the display flags.
///  - `window`: one disjoint scoring-eligible window; ignored while consent is false (nothing is computed).
///  - `reset`: the accumulator reset.
///  - `tick`: re-evaluates the timers and gives the final VAD speech of the last 30 s in ms (the Cannot verify (audio) rule).
///
/// The displayed state changes at most once per dwell (10 s), Differs and Changed stay at least the hold (20 s), entering or
/// leaving Off is immediate, the display flags false show Checking (Learning in call-local mode) with the candidate counted as
/// shadow, Matches needs tier 1 or more, and Cannot verify overrides Checking but never Matches or Differs.
///
/// THREADING: `VoiceEvidence`, `VoiceCallMachine` and `CallLocalReference` hold plain mutable state with no lock. They are
/// single-thread objects: the call integration must drive all three from ONE serial queue per call, never from the audio
/// callback and the UI thread at once.
final class VoiceCallMachine {
    private let mode: VoiceCheckMode
    private let display: DisplayConfig
    private let ev: VoiceEvidence
    private var ctx = VoiceCallContext()
    private var lastScoredNs: Int64?
    private var speechMs: Int64 = 0

    private var shown = VoiceShown.off
    private var shownDetail: VoiceDetail?
    private var lastChangeNs: Int64?
    private var shownSinceNs: Int64 = 0
    private var differed = false

    init(mode: VoiceCheckMode, evidence: EvidenceConfig, display: DisplayConfig) {
        self.mode = mode
        self.display = display
        self.ev = VoiceEvidence(evidence)
    }

    convenience init(constants: VoiceScoringConstants, mode: VoiceCheckMode) {
        self.init(mode: mode, evidence: EvidenceConfig.of(constants, mode: mode), display: DisplayConfig.of(constants))
    }

    private struct Target {
        let state: VoiceShown
        let detail: VoiceDetail?
        let shadow: Bool
    }

    @discardableResult
    func mediaStart(_ tNs: Int64) -> VoiceRecord {
        ev.mediaStart()
        ctx = VoiceCallContext()
        lastScoredNs = nil
        speechMs = 0
        shown = .off
        shownDetail = nil
        lastChangeNs = nil
        shownSinceNs = 0
        differed = false
        return evaluate(tNs, closed: nil)
    }

    @discardableResult
    func setContext(_ tNs: Int64, _ update: (inout VoiceCallContext) -> Void) -> VoiceRecord {
        update(&ctx)
        return evaluate(tNs, closed: nil)
    }

    /// One window. A non-finite `x` is a bug upstream and throws `VoiceScoringError.invalidInput`; nothing is accumulated.
    @discardableResult
    func window(_ tNs: Int64, x: Double, certain: Bool) throws -> VoiceRecord {
        guard x.isFinite else { throw VoiceScoringError.invalidInput("clipped LLR must be finite") }
        var closed: ClosedBlock?
        if ctx.consent {
            closed = ev.window(x, certain: certain, deviceCovered: ctx.deviceCovered)
            lastScoredNs = tNs
        }
        return evaluate(tNs, closed: closed)
    }

    @discardableResult
    func reset(_ tNs: Int64) -> VoiceRecord {
        ev.reset()
        return evaluate(tNs, closed: nil)
    }

    @discardableResult
    func tick(_ tNs: Int64, speechMs30s: Int64) -> VoiceRecord {
        speechMs = speechMs30s
        return evaluate(tNs, closed: nil)
    }

    private func target(_ cand: VoiceCandidate, _ tNs: Int64) -> Target {
        let c = ctx
        if !c.consent { return Target(state: .off, detail: nil, shadow: false) }
        if mode == .callLocal {
            if cand == .differs && c.displayChange && ev.b <= ev.maxBlock {
                return Target(state: .changed, detail: nil, shadow: false)
            }
            return Target(state: .learning, detail: nil, shadow: cand == .differs)
        }
        var shadow = false
        if cand == .differs {
            if c.displayDiffers && ev.b <= ev.maxBlock && c.contact != .needsRefresh && c.routeCovered {
                return Target(state: .differs, detail: c.deviceCovered ? nil : .deviceNew, shadow: false)
            }
            shadow = true
        }
        if cand == .matches && c.tier >= 1 { return Target(state: .matches, detail: nil, shadow: false) }
        var reason: VoiceDetail?
        if let fault = c.fault { reason = VoiceDetail(fault) }
        if reason == nil && speechMs >= display.minVadMs {
            if let last = lastScoredNs {
                if tNs - last >= display.lookbackNs { reason = .audio }
            } else {
                reason = .audio
            }
        }
        if let reason = reason { return Target(state: .cannotVerify, detail: reason, shadow: shadow) }
        if cand == .differs && !c.routeCovered { return Target(state: .checking, detail: .differentSetup, shadow: shadow) }
        return Target(state: .checking, detail: nil, shadow: shadow)
    }

    private func evaluate(_ tNs: Int64, closed: ClosedBlock?) -> VoiceRecord {
        let cand = ev.candidate(deviceCovered: ctx.deviceCovered)
        let tg = target(cand, tNs)
        var changed = false
        if tg.state != shown {
            var ok: Bool
            if shown == .off || tg.state == .off {
                ok = true
            } else {
                if let lc = lastChangeNs {
                    ok = tNs - lc >= display.dwellNs
                } else {
                    ok = true
                }
                if ok && (shown == .differs || shown == .changed) { ok = tNs - shownSinceNs >= display.holdNs }
            }
            if ok {
                if shown != .off && tg.state != .off { lastChangeNs = tNs }
                shown = tg.state
                shownDetail = tg.detail
                shownSinceNs = tNs
                changed = true
                if tg.state == .differs || tg.state == .changed { differed = true }
            }
        } else {
            shownDetail = tg.detail
        }
        return VoiceRecord(
            b: ev.b, blockN: ev.blockCount, blockSum: ev.blockSum(), r: ev.recentSum(), recentN: ev.recentCount,
            tNext: ev.threshold(ev.b + 1, deviceCovered: ctx.deviceCovered), worst: ev.worst, blocked: ev.blocked,
            closed: closed, cand: cand, shown: shown, detail: shownDetail, changed: changed, pending: tg.state != shown,
            shadow: tg.shadow, differed: differed
        )
    }
}
