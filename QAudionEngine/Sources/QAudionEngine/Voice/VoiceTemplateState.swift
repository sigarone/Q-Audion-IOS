import Foundation
import CryptoKit

/// The state machine of a contact's learned voice: sessions built from a call's windows with merging, the consensus and the
/// criteria of Learning / Provisional / Enrolled, the template update with its anchor check, Needs refresh, condition slots
/// with quarantine, and the sweeps (retention, purge, idle slots). Pure: no clock, no file, no logging; every function takes
/// the record and the call and returns a new record. Nothing in the engine calls it yet.
enum VoiceTags {
    static let dayS = 86_400

    /// floor((call start + UTC offset) / 86,400), a floor also below zero.
    static func dayIndex(startS: Int, utcOffsetS: Int) -> Int {
        let a = startS &+ utcOffsetS
        let q = a / dayS
        return (a % dayS != 0 && a < 0) ? q - 1 : q
    }

    /// The first 4 bytes of SHA-256(name_salt || UTF-8(device id)) as a little-endian u32.
    static func deviceTag(nameSalt: [UInt8], deviceId: String) -> Int {
        var h = SHA256()
        h.update(data: Data(nameSalt))
        h.update(data: Data(deviceId.utf8))
        let d = Array(h.finalize())
        return Int(d[0]) | (Int(d[1]) << 8) | (Int(d[2]) << 16) | (Int(d[3]) << 24)
    }
}

/// An input the state machine cannot work with (a window without its LLR when a consensus exists, a record without its anchor).
struct VoiceStateError: Error, Equatable {
    let message: String
}

/// One enrollment-eligible window of a call: its unit embedding, its accepted chunk ranges `[a, b)`, its clipped LLR, narrowband flag.
struct StateWindow {
    var emb: [Float]
    var chunks: [Range<Int>]
    var lC: Double?
    var nb: Bool

    func chunkSet() -> Set<Int> {
        var s = Set<Int>()
        for r in chunks { for c in r { s.insert(c) } }
        return s
    }
}

/// A session as it is built from a call. `kept` are the windows that the outlier rejection retained, in time order.
struct StateSession {
    var speechMs: Int
    var centroid: [Float]
    var nWindows: Int
    var conflict: Bool
    var nb: Int
    var kept: [StateWindow] = []
}

/// The build of a call's session, reported in the result: `speechMs` once step 3 was reached, `meanLlr` once step 5 ran.
struct BuildInfo: Equatable {
    var windowsIn: Int
    var taken: Int
    var dropped: Int
    var speechMs: Int?
    var meanLlr: Double?
    var why: String?
}

/// What the engine knows of the call's outcome for an Enrolled or Needs refresh contact.
struct StateOutcome {
    /// The unit mean of the disjoint enrollment-eligible windows; nil when there is none (then there are fewer windows than an
    /// update or a slot entry needs, and the rule that counts them fails first).
    var u: [Float]?
    var lC: [Double]
    var gateWindows: Int
    var matched: Bool
    var finalMatches: Bool
    var differsCandidate: Bool
    var blocked: Bool
    var matchWindows: Int
    var scoredWindows: Int
    var eligWindows: Int
    var authenticityElevated: Bool
    var wasHim: Bool
}

/// The end of a call, as the state machine reads it. `windows` and `session` are alternatives; `outcome` is for an Enrolled path.
struct StateCall {
    var tStartS: Int
    var tEndS: Int
    var utcOffsetS: Int
    var routeClass: Int
    var deviceTag: Int
    var consent: Bool
    var consentS: Int
    var tier: Int
    var learnBlocked: Bool
    var windows: [StateWindow]? = nil
    var session: StateSession? = nil
    var outcome: StateOutcome? = nil
}

struct RecomputeInfo: Equatable {
    var stateBefore: Int
    var state: Int
    var why: String?
    var consensus: [Int]
    var conflict: Bool
}

struct ContributedInfo: Equatable {
    var windows: Int
    var speechMs: Int
}

/// `template` is -1 for the base template, else the slot index.
struct CoverageInfo: Equatable {
    var route: Bool
    var device: Bool
    var template: Int
}

struct RefreshInfo: Equatable {
    var qualifying: Bool
    var entered: Bool
    var m: Double?
    var streak: Int?
    var gap: Bool?
}

struct UpdateInfo: Equatable {
    var updated: Bool
    var why: String?
    var w: Double?
}

struct SlotInfo: Equatable {
    var entered: Bool
    var why: String?
    var slot: Int?
    var action: String?
    var activated: Bool?
    var build: BuildInfo?
}

/// What a call did. Absent parts are nil.
struct CallResult {
    var effect: String
    var why: String? = nil
    var path: String? = nil
    var build: BuildInfo? = nil
    var created: Bool? = nil
    var merge: String? = nil
    var session: String? = nil
    var evicted: Int? = nil
    var contributed: ContributedInfo? = nil
    var recompute: RecomputeInfo? = nil
    var coverage: CoverageInfo? = nil
    var refresh: RefreshInfo? = nil
    var update: UpdateInfo? = nil
    var slot: SlotInfo? = nil
}

struct CallEnd {
    var record: TemplateRecord?
    var result: CallResult
}

struct SweepResult {
    var record: TemplateRecord?
    var deleted: String?
    var purged: [Int]
    var idleSlots: [Int]
    var recompute: RecomputeInfo?
}

/// Vector arithmetic of the state machine: float32 vectors, float64 accumulation, one rounding to float32 after a normalisation.
enum StateVec {
    static let dim = TemplateCodec.dim

    static func dot(_ a: [Float], _ b: [Float]) -> Double {
        var s = 0.0
        for i in 0..<dim { s += Double(a[i]) * Double(b[i]) }
        return s
    }

    static func wsum(_ ws: [Double], _ vs: [[Float]]) -> [Double] {
        var out = [Double](repeating: 0, count: dim)
        for k in vs.indices {
            let w = ws[k]
            let v = vs[k]
            for i in 0..<dim { out[i] += w * Double(v[i]) }
        }
        return out
    }

    /// v / ||v|| rounded once to float32; the zero vector stays zero.
    static func normalise(_ v: [Double]) -> [Float] {
        var s = 0.0
        for x in v { s += x * x }
        if s == 0.0 { return [Float](repeating: 0, count: dim) }
        let n = s.squareRoot()
        return v.map { Float($0 / n) }
    }

    static func sum(_ vs: [[Float]]) -> [Float] {
        normalise(wsum([Double](repeating: 1.0, count: vs.count), vs))
    }

    /// The exactly rounded sum (a sum equal to a limit must compare as the exact value does): a sum kept as a list of
    /// non-overlapping partials, rounded once at the end, half to even.
    static func exactSum(_ xs: [Double]) -> Double {
        if xs.contains(where: { !$0.isFinite }) { return xs.reduce(0.0, +) }
        var partials = [Double]()
        for value in xs {
            var x = value
            var i = 0
            for var y in partials {
                if abs(x) < abs(y) { swap(&x, &y) }
                let hi = x + y
                let lo = y - (hi - x)
                if lo != 0 {
                    partials[i] = lo
                    i += 1
                }
                x = hi
            }
            partials.removeSubrange(i...)
            partials.append(x)
        }
        var n = partials.count
        guard n > 0 else { return 0.0 }
        n -= 1
        var hi = partials[n]
        var lo = 0.0
        while n > 0 {
            let x = hi
            n -= 1
            let y = partials[n]
            hi = x + y
            let yr = hi - x
            lo = y - yr
            if lo != 0 { break }
        }
        if n > 0 && ((lo < 0 && partials[n - 1] < 0) || (lo > 0 && partials[n - 1] > 0)) {
            let y = lo * 2
            let x = hi + y
            let yr = x - hi
            if y == yr { hi = x }
        }
        return hi
    }
}

enum VoiceTemplateState {
    private static let chunkMs = 32
    private static let dayS = VoiceTags.dayS

    static func newRecord(cfg: VoiceStateConstants, nowS: Int) -> TemplateRecord {
        TemplateRecord(state: TemplateState.learning, modelId: cfg.modelId, constantsVersion: cfg.constantsVersion,
                       frontendVersion: cfg.frontendVersion, createdS: nowS, updatedS: nowS)
    }

    // MARK: building a session

    /// Step 1: the windows in time order while the set of their distinct chunks stays within `free`; the first that would
    /// exceed it and all later ones are left out.
    static func takeWithin(_ windows: [StateWindow], free: Int) -> (taken: [StateWindow], chunks: Int) {
        var seen = Set<Int>()
        var taken = [StateWindow]()
        for w in windows {
            let cs = w.chunkSet()
            let extra = cs.filter { !seen.contains($0) }.count
            if seen.count + extra > free { break }
            seen.formUnion(cs)
            taken.append(w)
        }
        return (taken, seen.count)
    }

    static func buildSession(windows: [StateWindow], freeChunks: Int, consensusExists: Bool,
                             cfg: VoiceStateConstants) throws -> (StateSession?, BuildInfo) {
        let en = cfg.enroll
        let taken = takeWithin(windows, free: freeChunks).taken
        var kept = Array(taken.indices)
        for _ in 0..<2 {
            if kept.count < 2 { break }
            var drop = Set<Int>()
            for pos in kept.indices {
                let i = kept[pos]
                var others = [[Float]]()
                for (q, idx) in kept.enumerated() where q != pos { others.append(taken[idx].emb) }
                let m = StateVec.sum(others)
                if StateVec.dot(taken[i].emb, m) < en.tauWin { drop.insert(i) }
            }
            kept = kept.filter { !drop.contains($0) }
        }
        let dropped = taken.count - kept.count
        if !taken.isEmpty && Double(dropped) > en.mixedFracMax * Double(taken.count) {
            return (nil, BuildInfo(windowsIn: windows.count, taken: taken.count, dropped: dropped, speechMs: nil, meanLlr: nil, why: "mixed"))
        }
        if taken.isEmpty {
            return (nil, BuildInfo(windowsIn: windows.count, taken: 0, dropped: dropped, speechMs: nil, meanLlr: nil, why: "short"))
        }
        var used = Set<Int>()
        for i in kept { used.formUnion(taken[i].chunkSet()) }
        let speechMs = used.count * chunkMs
        if !(speechMs >= en.sessionMinMs) {
            return (nil, BuildInfo(windowsIn: windows.count, taken: taken.count, dropped: dropped, speechMs: speechMs, meanLlr: nil, why: "short"))
        }
        var conflict = false
        var meanLlr: Double?
        if consensusExists {
            var ls = [Double]()
            for k in kept {
                guard let l = taken[k].lC else { throw VoiceStateError(message: "a window needs its LLR when a consensus exists") }
                ls.append(l)
            }
            let m = StateVec.exactSum(ls) / Double(kept.count)
            meanLlr = m
            conflict = !(m > 0.0)
        }
        let keptWindows = kept.map { taken[$0] }
        let session = StateSession(
            speechMs: speechMs,
            centroid: StateVec.sum(keptWindows.map { $0.emb }),
            nWindows: kept.count,
            conflict: conflict,
            nb: keptWindows.allSatisfy { $0.nb } ? 1 : 0,
            kept: keptWindows)
        return (session, BuildInfo(windowsIn: windows.count, taken: taken.count, dropped: dropped, speechMs: speechMs, meanLlr: meanLlr, why: nil))
    }

    /// What a call that merges adds: the retained windows taken against the free part of the cap, no rejection, no minimum.
    private struct Part {
        var speechMs: Int
        var centroid: [Float]?
        var nWindows: Int
    }

    private static func contribution(_ kept: [StateWindow], freeChunks: Int) -> Part {
        let (taken, n) = takeWithin(kept, free: freeChunks)
        if taken.isEmpty { return Part(speechMs: 0, centroid: nil, nWindows: 0) }
        return Part(speechMs: n * chunkMs, centroid: StateVec.sum(taken.map { $0.emb }), nWindows: taken.count)
    }

    // MARK: consensus and criteria

    /// For each consensus session: (m_-j, cos_j), m_-j = normalise(sum over the other consensus sessions of n_k c_k).
    private static func loo(_ ss: [TemplateSession], _ s: [Int]) -> [(m: [Float], cos: Double)] {
        s.indices.map { p -> (m: [Float], cos: Double) in
            var others = [Int]()
            for (q, idx) in s.enumerated() where q != p { others.append(idx) }
            let m: [Float]
            if others.isEmpty {
                m = [Float](repeating: 0, count: StateVec.dim)
            } else {
                m = StateVec.normalise(StateVec.wsum(others.map { Double(ss[$0].speechMs) }, others.map { ss[$0].centroid! }))
            }
            return (m, StateVec.dot(ss[s[p]].centroid!, m))
        }
    }

    private struct Consensus {
        var s: [Int]
        var conflict: Bool
        var aCur: [Float]?
    }

    private static func consensus(_ ss: [TemplateSession], _ cfg: VoiceStateConstants) -> Consensus {
        var s = Array(ss.indices)
        var conflict = false
        while s.count > 1 {
            let coss = loo(ss, s).map { $0.cos }
            var pmin = 0
            for p in 1..<s.count where coss[p] <= coss[pmin] { pmin = p } // the smallest cosine; on a tie the newer session
            if coss[pmin] >= cfg.enroll.tauSess { break }
            if s.count == 2 {
                conflict = true
                s.removeAll()
                break
            }
            s.remove(at: pmin)
        }
        let a: [Float]?
        if s.isEmpty {
            a = nil
        } else {
            a = StateVec.normalise(StateVec.wsum(s.map { Double(ss[$0].speechMs) }, s.map { ss[$0].centroid! }))
        }
        return Consensus(s: s, conflict: conflict, aCur: a)
    }

    private static func criteria(_ ss: [TemplateSession], _ c: Consensus, _ cfg: VoiceStateConstants) -> (Int, String?) {
        let en = cfg.enroll
        let s = c.s
        let total = s.reduce(0) { $0 + ss[$1].speechMs }
        if c.conflict || s.isEmpty { return (TemplateState.learning, c.conflict ? "conflict" : "empty") }
        if !(total >= en.provMs) { return (TemplateState.learning, "prov_ms") }
        if !(total >= en.enrMs) { return (TemplateState.provisional, "speech") }
        if !(s.count >= en.enrSessions) { return (TemplateState.provisional, "sessions") }
        if !(Set(s.map { ss[$0].dayIndex }).count >= en.enrDays) { return (TemplateState.provisional, "days") }
        let span = s.map { ss[$0].endS }.max()! &- s.map { ss[$0].startS }.min()!
        if !(span >= en.enrSpanS) { return (TemplateState.provisional, "span") }
        if !(Double(s.map { ss[$0].speechMs }.max()!) <= en.maxShare * Double(total)) { return (TemplateState.provisional, "share") }
        let l = loo(ss, s)
        for entry in l where !(entry.cos >= en.tauLoo) { return (TemplateState.provisional, "loo") }
        let a = c.aCur!
        for entry in l where !(1.0 - StateVec.dot(entry.m, a) <= en.deltaJk) { return (TemplateState.provisional, "jackknife") }
        return (TemplateState.enrolled, nil)
    }

    /// Consensus, flags, anchor and state of a Learning or Provisional record after its session list changed, and the
    /// Enrolled transition.
    @discardableResult
    private static func recompute(_ rec: TemplateRecord, _ cfg: VoiceStateConstants, _ now: Int) -> RecomputeInfo {
        let ss = rec.sessions
        let c = consensus(ss, cfg)
        for i in ss.indices { ss[i].inConsensus = c.s.contains(i) }
        rec.conflict = c.conflict
        rec.consensusSpeechMs = c.s.reduce(0) { $0 + ss[$1].speechMs }
        rec.nDaysConsensus = Set(c.s.map { ss[$0].dayIndex }).count
        let before = rec.state
        let (state, why) = criteria(ss, c, cfg)
        if state == TemplateState.enrolled {
            let keep = c.s.map { ss[$0] }
            for s in keep { s.centroid = nil }
            rec.sessions = keep
            rec.state = TemplateState.enrolled
            rec.anchorFrozen = true
            rec.anchor = c.aCur
            rec.adaptive = c.aCur
            rec.enrolledS = now
            rec.lastMatchS = now
            rec.updateCount = 0
            rec.lastUpdateS = [0, 0, 0]
            rec.refreshNegStreak = 0
        } else {
            rec.state = state
            rec.anchor = c.aCur
            rec.adaptive = c.aCur
        }
        return RecomputeInfo(stateBefore: before, state: state, why: why, consensus: c.s, conflict: c.conflict)
    }

    // MARK: the entry point

    /// The one entry point at the end of a call. `rec` is nil when the contact has no file. A call that is blocked for the
    /// contact (`StateCall.consent` false) changes nothing. The input record is not modified.
    static func endOfCall(_ rec: TemplateRecord?, _ call: StateCall, _ cfg: VoiceStateConstants) throws -> CallEnd {
        if !call.consent { return CallEnd(record: rec, result: CallResult(effect: "none", why: "no_consent")) }
        let r = rec?.deepCopy()
        if let r, r.state != TemplateState.learning, r.state != TemplateState.provisional {
            return try enrolledCall(r, call, cfg)
        }
        return try learningCall(r, call, cfg)
    }

    private static func learningCall(_ rec0: TemplateRecord?, _ call: StateCall, _ cfg: VoiceStateConstants) throws -> CallEnd {
        var rec = rec0
        let en = cfg.enroll
        let now = call.tEndS
        if call.tier < 1 { return CallEnd(record: rec, result: CallResult(effect: "none", why: "tier", path: "learning")) }
        if let rec { // a verified call: the retention clock, the consent time (the file is rewritten)
            rec.lastVerifiedCallS = now
            rec.peerConsentS = call.consentS
            rec.updatedS = now
            rec.constantsVersion = cfg.constantsVersion
        }
        let idle = rec == nil ? "none" : "clock"
        if call.learnBlocked { return CallEnd(record: rec, result: CallResult(effect: idle, why: "blocked", path: "learning")) }
        let capChunks = en.sessionCapMs / chunkMs
        let last = rec?.sessions.last
        let candidate = last != nil && (call.tStartS &- last!.endS) < en.mergeGapS
        let consensusExists = rec != nil && rec!.anchor != nil
        var candidateSession = call.session
        let built = candidateSession == nil && call.windows != nil
        var binfo: BuildInfo?
        if built {
            // a call is built as a call of its own, with the whole cap, merge candidate or not: the voice of the whole call decides
            let (s, bi) = try buildSession(windows: call.windows!, freeChunks: capChunks, consensusExists: consensusExists, cfg: cfg)
            candidateSession = s
            binfo = bi
        }
        guard let session = candidateSession else {
            return CallEnd(record: rec, result: CallResult(effect: idle, why: binfo?.why ?? "no_session", path: "learning", build: binfo))
        }
        var merged = false
        var mergeNote: String?
        if candidate, let last {
            // merged only into a session of the same voice; otherwise a new session, as built
            merged = last.centroid != nil && StateVec.dot(session.centroid, last.centroid!) >= en.tauSess
            if !merged { mergeNote = "disagree" }
        }
        var created: Bool?
        if rec == nil {
            let fresh = newRecord(cfg: cfg, nowS: now)
            fresh.lastVerifiedCallS = now
            fresh.peerConsentS = call.consentS
            rec = fresh
            created = true
        }
        let record = rec!
        let sessionNote: String
        var evicted: Int?
        var contributed: ContributedInfo?
        if merged {
            let prev = record.sessions.last!
            var speech = session.speechMs
            var centroid: [Float]? = session.centroid
            var nWin = session.nWindows
            if built {
                // only the part of the cap that the previous session leaves free is added, from the retained windows, in time order
                let part = contribution(session.kept, freeChunks: max(0, capChunks - prev.speechMs / chunkMs))
                speech = part.speechMs
                centroid = part.centroid
                nWin = part.nWindows
                contributed = ContributedInfo(windows: part.nWindows, speechMs: part.speechMs)
            }
            if let centroid { // a part of no window leaves speech, centroid and window count as they are
                let n = prev.speechMs + speech
                prev.centroid = StateVec.normalise(
                    StateVec.wsum([Double(prev.speechMs), Double(speech)], [prev.centroid!, centroid]))
                prev.speechMs = n
                prev.nWindows = min(65535, prev.nWindows + nWin)
            }
            prev.endS = max(prev.endS, call.tEndS)
            prev.merged = true
            prev.conflict = prev.conflict || session.conflict
            sessionNote = "merged"
        } else {
            if record.sessions.count >= en.maxSessions {
                let victim = record.sessions.firstIndex(where: { !$0.inConsensus }) ?? 0
                record.sessions.remove(at: victim)
                evicted = victim
            }
            record.sessions.append(TemplateSession(
                speechMs: session.speechMs, dayIndex: VoiceTags.dayIndex(startS: call.tStartS, utcOffsetS: call.utcOffsetS),
                startS: call.tStartS, endS: call.tEndS, deviceTag: call.deviceTag, routeClass: call.routeClass,
                conflict: session.conflict, nWindows: session.nWindows, centroid: session.centroid))
            // stable: an equal start keeps the arrival order
            record.sessions = record.sessions.enumerated()
                .sorted { ($0.element.startS, $0.offset) < ($1.element.startS, $1.offset) }
                .map { $0.element }
            record.sessionsSeenTotal = min(65535, record.sessionsSeenTotal + 1)
            sessionNote = "added"
        }
        record.updatedS = now
        let rc = recompute(record, cfg, now)
        return CallEnd(record: record, result: CallResult(
            effect: "written", path: "learning", build: binfo, created: created, merge: mergeNote, session: sessionNote,
            evicted: evicted, contributed: contributed, recompute: rc))
    }

    // MARK: Enrolled and Needs refresh

    struct Cov {
        var route: Bool
        var device: Bool
        var slot: Int?
    }

    private static func coverage(_ rec: TemplateRecord, _ call: StateCall, _ cfg: VoiceStateConstants) -> Cov {
        coverage(rec, routeClass: call.routeClass, deviceTag: call.deviceTag, cfg)
    }

    /// Whether the record covers the route group and the device of a call, and the index of the active slot that fits it.
    static func coverage(_ rec: TemplateRecord, routeClass: Int, deviceTag: Int, _ cfg: VoiceStateConstants) -> Cov {
        let g = cfg.conditions.routeGroup(routeClass)
        let tag = deviceTag
        let slotI = rec.slots.firstIndex(where: { $0.state == TemplateSlot.active && $0.routeGroup == g && $0.deviceTag == tag })
        let cons = rec.sessions.filter { $0.inConsensus }
        let route = slotI != nil || cons.contains(where: { cfg.conditions.routeGroup($0.routeClass) == g })
        let device = slotI != nil || cons.contains(where: { $0.deviceTag == tag })
        return Cov(route: route, device: device, slot: slotI)
    }

    private static func rateOk(_ rec: TemplateRecord, _ now: Int, _ cfg: VoiceStateConstants) -> Bool {
        rec.lastUpdateS.filter { $0 != 0 && now &- $0 < 7 * dayS }.count < cfg.update.maxPer7d
    }

    /// The rules that do not concern the coverage, in the order of their reason codes; the first that fails, or nil.
    private static func commonOk(_ rec: TemplateRecord, _ call: StateCall, _ out: StateOutcome, _ cfg: VoiceStateConstants,
                                 relaxed: Bool) -> String? {
        let up = cfg.update
        if !relaxed {
            if !out.finalMatches { return "no_match" }
            if out.differsCandidate { return "differs" }
            if out.blocked { return "weak" }
            if !(out.scoredWindows > 0 && Double(out.matchWindows) >= up.minMatchFrac * Double(out.scoredWindows)) { return "match_frac" }
        }
        if !(out.eligWindows >= up.minWindows) { return "windows" }
        if out.authenticityElevated { return "authenticity" }
        if !rateOk(rec, call.tEndS, cfg) { return "rate" }
        return nil
    }

    private static func tryUpdate(_ rec: TemplateRecord, _ call: StateCall, _ out: StateOutcome, _ slotI: Int?,
                                  _ cfg: VoiceStateConstants) throws -> UpdateInfo {
        let up = cfg.update
        let now = call.tEndS
        if let why = commonOk(rec, call, out, cfg, relaxed: false) { return UpdateInfo(updated: false, why: why, w: nil) }
        guard let u = out.u else { throw VoiceStateError(message: "an outcome with enough windows has its mean") }
        guard let target = slotI == nil ? rec.adaptive : rec.slots[slotI!].centroid else {
            throw VoiceStateError(message: "no template to update")
        }
        guard let a = rec.anchor else { throw VoiceStateError(message: "an enrolled record has an anchor") }
        if !(StateVec.dot(u, a) >= cfg.enroll.tauSess) || !(StateVec.dot(u, target) >= cfg.enroll.tauSess) {
            return UpdateInfo(updated: false, why: "bound", w: nil)
        }
        let m = StateVec.exactSum(out.lC)
        if !(m > up.theta) { return UpdateInfo(updated: false, why: "theta", w: nil) }
        let w = up.wMax * (1.0 - exp(-((m - up.theta) * (m - up.theta)) / (2.0 * up.b * up.b)))
        let mixed = StateVec.wsum([1.0 - w, w], [target, u])
        let fresh = StateVec.normalise(mixed)
        let floor = slotI == nil ? up.rhoMin : cfg.conditions.tauSlotAnchor
        if !(StateVec.dot(fresh, a) >= floor) { return UpdateInfo(updated: false, why: "bound", w: w) }
        if let slotI { rec.slots[slotI].centroid = fresh } else { rec.adaptive = fresh }
        rec.updateCount = min(65535, rec.updateCount + 1)
        rec.lastUpdateS = [now, rec.lastUpdateS[0], rec.lastUpdateS[1]]
        return UpdateInfo(updated: true, why: nil, w: w)
    }

    private static func trySlotEntry(_ rec: TemplateRecord, _ call: StateCall, _ out: StateOutcome,
                                     _ cfg: VoiceStateConstants) throws -> SlotInfo {
        let en = cfg.enroll
        let cond = cfg.conditions
        let now = call.tEndS
        var candidateSession = call.session
        var binfo: BuildInfo?
        if candidateSession == nil, let windows = call.windows {
            // steps 1 to 3 and 5 (no consensus mark) with the FULL cap, merging or not: the slot keeps only its total speech
            let (s, bi) = try buildSession(windows: windows, freeChunks: en.sessionCapMs / chunkMs, consensusExists: false, cfg: cfg)
            candidateSession = s
            binfo = bi
        }
        func no(_ why: String) -> SlotInfo {
            SlotInfo(entered: false, why: why, slot: nil, action: nil, activated: nil, build: binfo)
        }
        guard let session = candidateSession else { return no("no_session") }
        if let why = commonOk(rec, call, out, cfg, relaxed: out.wasHim) { return no(why) }
        guard let anchor = rec.anchor else { throw VoiceStateError(message: "an enrolled record has an anchor") }
        guard let u = out.u else { throw VoiceStateError(message: "an outcome with enough windows has its mean") }
        if !(StateVec.dot(u, anchor) >= cond.tauSlotAnchor) { return no("bound") }
        let g = cond.routeGroup(call.routeClass)
        let tag = call.deviceTag
        let day = VoiceTags.dayIndex(startS: call.tStartS, utcOffsetS: call.utcOffsetS)
        let slots = rec.slots
        var idx = slots.firstIndex(where: { $0.state != TemplateSlot.empty && $0.routeGroup == g && $0.deviceTag == tag })
        let n = session.speechMs
        let c = session.centroid
        let action: String
        if let found = idx {
            let sl = slots[found]
            if sl.state == TemplateSlot.active { return no("active") }
            guard let sc = sl.centroid else { throw VoiceStateError(message: "a quarantine slot has a centroid") }
            if !(StateVec.dot(c, sc) >= en.tauSess) { return no("disagree") }
            let merged = (call.tStartS &- sl.lastUsedS) < en.mergeGapS
            sl.centroid = StateVec.normalise(StateVec.wsum([Double(sl.speechMs), Double(n)], [sc, c]))
            sl.speechMs = min(0xFFFF_FFFF, sl.speechMs + n)
            if !merged { sl.nSessions = min(255, sl.nSessions + 1) }
            sl.firstDay = min(sl.firstDay, day)
            sl.lastDay = max(sl.lastDay, day)
            sl.lastUsedS = now
            action = merged ? "merged" : "added"
        } else {
            idx = slots.firstIndex(where: { $0.state == TemplateSlot.empty })
            var act = "created"
            if idx == nil {
                let q = slots.indices.filter { slots[$0].state == TemplateSlot.quarantine }
                if q.isEmpty { return no("full") }
                idx = q.min { a, b in
                    (slots[a].nSessions, slots[a].speechMs, slots[a].lastUsedS, a) < (slots[b].nSessions, slots[b].speechMs, slots[b].lastUsedS, b)
                }!
                act = "replaced"
            }
            let sl = slots[idx!]
            sl.state = TemplateSlot.quarantine
            sl.routeGroup = g
            sl.nb = session.nb != 0 ? 1 : 0
            sl.nSessions = 1
            sl.deviceTag = tag
            sl.firstDay = day
            sl.lastDay = day
            sl.speechMs = n
            sl.lastUsedS = now
            sl.centroid = c
            action = act
        }
        let sl = slots[idx!]
        var activated = false
        if sl.state == TemplateSlot.quarantine {
            let ok = sl.nSessions >= cond.slotMinSessions && (sl.lastDay - sl.firstDay + 1) >= cond.slotMinDays &&
                sl.speechMs >= cond.slotMinMs && StateVec.dot(sl.centroid!, anchor) >= cond.tauSlotAnchor
            if ok {
                sl.state = TemplateSlot.active
                activated = true
            }
        }
        return SlotInfo(entered: true, why: nil, slot: idx, action: action, activated: activated, build: binfo)
    }

    private static func enrolledCall(_ rec: TemplateRecord, _ call: StateCall, _ cfg: VoiceStateConstants) throws -> CallEnd {
        let rf = cfg.refresh
        let now = call.tEndS
        let path = rec.state == TemplateState.enrolled ? "enrolled" : "refresh"
        if call.tier < 1 { return CallEnd(record: rec, result: CallResult(effect: "none", why: "tier", path: path)) }
        guard let out = call.outcome else { throw VoiceStateError(message: "an Enrolled contact's call needs its outcome") }
        let cov = coverage(rec, call, cfg)
        let covInfo = CoverageInfo(route: cov.route, device: cov.device, template: cov.slot ?? -1)
        var refreshInfo: RefreshInfo?
        if rec.state == TemplateState.enrolled { // needs refresh, evaluated before this call's own match time is stored
            let n = out.lC.count
            let qualifying = cov.route && cov.device && n >= rf.minWindows && Double(out.gateWindows) > rf.gateFracMin * Double(n)
            if !qualifying {
                refreshInfo = RefreshInfo(qualifying: false, entered: false, m: nil, streak: nil, gap: nil)
            } else {
                let m = StateVec.exactSum(out.lC) / Double(n)
                rec.refreshNegStreak = m < 0.0 ? min(255, rec.refreshNegStreak + 1) : 0
                let gap = (call.tStartS &- rec.lastMatchS) > rf.gapDays * dayS
                var entered = false
                if rec.refreshNegStreak >= rf.negStreak || gap {
                    rec.state = TemplateState.needsRefresh
                    rec.refreshEnteredS = now
                    entered = true
                }
                refreshInfo = RefreshInfo(qualifying: true, entered: entered, m: m, streak: rec.refreshNegStreak, gap: gap)
            }
        }
        if out.matched { rec.lastMatchS = now }
        rec.lastVerifiedCallS = now
        rec.peerConsentS = call.consentS
        rec.constantsVersion = cfg.constantsVersion
        var update: UpdateInfo?
        var slot: SlotInfo?
        if rec.state == TemplateState.enrolled {
            if cov.route && cov.device {
                update = try tryUpdate(rec, call, out, cov.slot, cfg)
            } else {
                slot = try trySlotEntry(rec, call, out, cfg)
            }
        }
        if let s = cov.slot { rec.slots[s].lastUsedS = now }
        rec.updatedS = now
        return CallEnd(record: rec, result: CallResult(
            effect: "written", path: path, coverage: covInfo, refresh: refreshInfo, update: update, slot: slot))
    }

    // MARK: sweeps

    /// The periodic cleanup: the retention limit deletes the record; sessions outside the consensus older than `purge_days`
    /// and slots idle for `slot_idle_days` (quarantine or active) are deleted. The input record is not modified.
    static func sweep(_ rec: TemplateRecord?, nowS: Int, _ cfg: VoiceStateConstants) -> SweepResult {
        guard let rec else { return SweepResult(record: nil, deleted: nil, purged: [], idleSlots: [], recompute: nil) }
        if nowS &- rec.lastVerifiedCallS >= cfg.retentionDays * dayS {
            return SweepResult(record: nil, deleted: "retention", purged: [], idleSlots: [], recompute: nil)
        }
        let r = rec.deepCopy()
        var purged = [Int]()
        var keep = [TemplateSession]()
        for (i, s) in r.sessions.enumerated() {
            if !s.inConsensus && nowS &- s.endS >= cfg.enroll.purgeDays * dayS { purged.append(i) } else { keep.append(s) }
        }
        r.sessions = keep
        var idle = [Int]()
        for i in r.slots.indices {
            let sl = r.slots[i]
            if sl.state != TemplateSlot.empty && nowS &- sl.lastUsedS >= cfg.conditions.slotIdleDays * dayS {
                sl.clear()
                idle.append(i)
            }
        }
        var rc: RecomputeInfo?
        if !purged.isEmpty || !idle.isEmpty {
            r.updatedS = nowS
            if r.state == TemplateState.learning || r.state == TemplateState.provisional { rc = recompute(r, cfg, nowS) }
        }
        return SweepResult(record: r, deleted: nil, purged: purged, idleSlots: idle, recompute: rc)
    }

    /// The one more prompt after `reprompt_days` in Needs refresh. Returns the record and whether the prompt is due.
    static func reprompt(_ rec: TemplateRecord?, nowS: Int, _ cfg: VoiceStateConstants) -> (TemplateRecord?, Bool) {
        guard let rec, rec.state == TemplateState.needsRefresh, !rec.refreshReprompted else { return (rec, false) }
        if nowS &- rec.refreshEnteredS >= cfg.refresh.repromptDays * dayS {
            let r = rec.deepCopy()
            r.refreshReprompted = true
            r.updatedS = nowS
            return (r, true)
        }
        return (rec, false)
    }

    /// A record whose model id or front-end version differs from the running bundle is deleted (relearn); a constants
    /// version change alone keeps it.
    static func isCompatible(_ rec: TemplateRecord, modelId: [UInt8], frontendVersion: Int) -> Bool {
        rec.modelId == modelId && rec.frontendVersion == frontendVersion
    }
}
