import Foundation
import CryptoKit

/// What one call adds to the daily counters. It carries no id: the contact enters only as a number that is made here from a salt of
/// this install, to count distinct contacts, and it is never written to a log.
struct VoiceDailyCall {
    var summary: VoiceCallSummary
    var contactId: String
    /// Unix time at the end of the call and the local UTC offset, to find the local day.
    var endS: Int
    var utcOffsetS: Int
}

/// One local day of counters.
struct VoiceDayCounters: Codable, Equatable {
    struct Stratum: Codable, Equatable {
        var calls = 0
        var sdiff = 0
        var m1 = 0
        var m2 = 0
        var m3 = 0
        var m4 = 0
    }

    var calls = 0
    var off = 0
    var match = 0
    var chk = 0
    var nover = 0
    var diff = 0
    var sdiff = 0
    var chg = 0
    var schg = 0
    var hs = 0
    var spk = 0
    var hf = 0
    var unk = 0
    var newdev = 0
    var mk = 0
    /// Distinct Enrolled contacts verified this day, and distinct contacts in Learning, as numbers of this install only.
    var enr: Set<UInt32> = []
    var lrn: Set<UInt32> = []
    var strata = [Stratum](repeating: Stratum(), count: 4)
}

/// The persisted state: the counters of the days that were not emitted yet, the instant at which each is to be written, the
/// contacts seen at all, and the salt of this install.
struct VoiceDailyState: Codable, Equatable {
    var salt: [UInt8] = []
    var days: [Int: VoiceDayCounters] = [:]
    var emitAtS: [Int: Int] = [:]
    var enrolledEver: Set<UInt32> = []
}

protocol VoiceDailyStorage: AnyObject {
    func load() -> Data?
    func save(_ data: Data)
    func clear()
}

final class VoiceDefaultsDailyStorage: VoiceDailyStorage {
    static let key = "qaudion.voice.daily.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> Data? { defaults.data(forKey: Self.key) }
    func save(_ data: Data) { defaults.set(data, forKey: Self.key) }
    func clear() { defaults.removeObject(forKey: Self.key) }
}

/// The id-free daily counters of the contact-voice check (the `ev=day` and `ev=dstr` lines): what each call adds, the lines of the
/// previous local days, and the moment at which they are written. The moment is random within the following day, so that a line
/// cannot be lined up with a call. Thread safe.
final class VoiceDailyCounters: @unchecked Sendable {
    static let secondsPerDay = 86_400

    private let storage: VoiceDailyStorage
    private let random: () -> Int
    private let lock = NSLock()
    private var state: VoiceDailyState
    /// Counts the wipes. A call remembers the value it began with; its day is not written when a wipe came after that.
    private var wipeEpoch = 0

    /// `random` gives a number in `0..<secondsPerDay`.
    init(storage: VoiceDailyStorage = VoiceDefaultsDailyStorage(),
         random: @escaping () -> Int = { Int.random(in: 0..<VoiceDailyCounters.secondsPerDay) }) {
        self.storage = storage
        self.random = random
        if let data = storage.load(), let loaded = try? JSONDecoder().decode(VoiceDailyState.self, from: data) {
            state = loaded
        } else {
            state = VoiceDailyState()
        }
    }

    static func dayIndex(_ unixS: Int, utcOffsetS: Int) -> Int {
        VoiceTags.dayIndex(startS: unixS, utcOffsetS: utcOffsetS)
    }

    // MARK: recording

    /// The number of wipes so far: read when a call begins, given back to `record`.
    var epoch: Int {
        lock.lock()
        defer { lock.unlock() }
        return wipeEpoch
    }

    /// Adds a call. With `ifEpoch`, nothing is written when a wipe came after that value was read (checked inside the lock, so a
    /// wipe either comes after this write and clears it, or before it and this call leaves nothing).
    func record(_ call: VoiceDailyCall, ifEpoch expected: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let expected, expected != wipeEpoch { return }
        let day = Self.dayIndex(call.endS, utcOffsetS: call.utcOffsetS)
        var counters = state.days[day] ?? VoiceDayCounters()
        let key = contactKey(call.contactId)
        let s = call.summary
        if s.verifyMode {
            counters.calls += 1
            counters.enr.insert(key)
            state.enrolledEver.insert(key)
            switch s.res {
            case "match": counters.match += 1
            case "chk": counters.chk += 1
            case "nover": counters.nover += 1
            case "diff": counters.diff += 1
            case "off": counters.off += 1
            case "chg": counters.chg += 1
            default: break
            }
            if s.shadow { counters.sdiff += 1 }
            switch Self.routeGroup(ofClass: s.routeClass) {
            case .handset: counters.hs += 1
            case .loudspeaker: counters.spk += 1
            case .handsFree: counters.hf += 1
            case .unknown: counters.unk += 1
            }
            if s.newDevice { counters.newdev += 1 }
            let stratum = Self.stratum(speechS: s.speechS)
            counters.strata[stratum].calls += 1
            if s.shadow { counters.strata[stratum].sdiff += 1 }
            if s.margin >= 1 { counters.strata[stratum].m1 += 1 }
            if s.margin >= 2 { counters.strata[stratum].m2 += 1 }
            if s.margin >= 3 { counters.strata[stratum].m3 += 1 }
            if s.margin >= 4 { counters.strata[stratum].m4 += 1 }
        } else {
            counters.lrn.insert(key)
            if s.res == "chg" { counters.chg += 1 }
            if s.shadow { counters.schg += 1 }
        }
        state.days[day] = counters
        if state.emitAtS[day] == nil {
            state.emitAtS[day] = (day + 1) * Self.secondsPerDay - call.utcOffsetS + max(0, min(Self.secondsPerDay - 1, random()))
        }
        persist()
    }

    /// The group of the daily counters: the route groups of `constants.json` (`conditions.route_groups`), by the codes of
    /// `route_class_codes`: ear (1) and wired (4) are the handset, speaker (2) the loudspeaker, bt (3) and car (5) hands-free, and
    /// unknown (0, or a code that the table does not have) its own group. A test reads the bundle and fails when they drift apart.
    enum RouteGroup: Equatable {
        case unknown, handset, loudspeaker, handsFree
    }

    static func routeGroup(ofClass code: Int) -> RouteGroup {
        switch code {
        case 1, 4: return .handset
        case 2: return .loudspeaker
        case 3, 5: return .handsFree
        default: return .unknown
        }
    }

    /// The stratum of a call by its seconds of speech: up to 2, 2 to 10, 10 to 30, over 30 minutes.
    static func stratum(speechS: Int64) -> Int {
        let minutes = Double(speechS) / 60.0
        if minutes <= 2 { return 0 }
        if minutes <= 10 { return 1 }
        if minutes <= 30 { return 2 }
        return 3
    }

    // MARK: emission

    /// The lines of every day that is over and whose moment has come, each day once. The counters of a day are dropped when
    /// they are given out.
    func dueLines(nowS: Int, utcOffsetS: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let today = Self.dayIndex(nowS, utcOffsetS: utcOffsetS)
        var out: [String] = []
        for day in state.days.keys.sorted() where day < today {
            guard let at = state.emitAtS[day], at <= nowS, let counters = state.days[day] else { continue }
            out.append(contentsOf: Self.lines(counters, enrolledEver: state.enrolledEver.count))
            state.days.removeValue(forKey: day)
            state.emitAtS.removeValue(forKey: day)
        }
        if !out.isEmpty { persist() }
        return out
    }

    /// The counters of a day as the lines of the log.
    static func lines(_ c: VoiceDayCounters, enrolledEver: Int) -> [String] {
        func cap(_ v: Int, _ limit: Int) -> Int { min(max(0, v), limit) }
        var out: [String] = []
        out.append(
            "QA-VOICE v=1 ev=day calls=\(cap(c.calls, 9999)) off=\(cap(c.off, 9999)) match=\(cap(c.match, 9999)) chk=\(cap(c.chk, 9999)) "
                + "nover=\(cap(c.nover, 9999)) diff=\(cap(c.diff, 9999)) sdiff=\(cap(c.sdiff, 9999)) chg=\(cap(c.chg, 9999)) "
                + "schg=\(cap(c.schg, 9999)) hs=\(cap(c.hs, 9999)) spk=\(cap(c.spk, 9999)) hf=\(cap(c.hf, 9999)) unk=\(cap(c.unk, 9999)) "
                + "newdev=\(cap(c.newdev, 9999)) enr=\(cap(c.enr.count, 999)) enrtot=\(cap(enrolledEver, 9999)) lrn=\(cap(c.lrn.count, 999)) "
                + "mk=\(cap(c.mk, 999))")
        for (i, s) in c.strata.enumerated() {
            out.append(
                "QA-VOICE v=1 ev=dstr st=\(i + 1) calls=\(cap(s.calls, 9999)) sdiff=\(cap(s.sdiff, 9999)) m1=\(cap(s.m1, 9999)) "
                    + "m2=\(cap(s.m2, 9999)) m3=\(cap(s.m3, 9999)) m4=\(cap(s.m4, 9999))")
        }
        return out
    }

    // MARK: wipe

    /// Forgets everything (logout, wipe): the counters, the moments, the contacts seen and the salt.
    func wipe() {
        lock.lock()
        state = VoiceDailyState()
        wipeEpoch += 1
        storage.clear()
        lock.unlock()
    }

    // MARK: private

    private func contactKey(_ contactId: String) -> UInt32 {
        if state.salt.isEmpty {
            state.salt = (0..<16).map { _ in UInt8.random(in: 0...255) }
        }
        var h = SHA256()
        h.update(data: Data(state.salt))
        h.update(data: Data(contactId.lowercased().utf8))
        let d = Array(h.finalize())
        return UInt32(d[0]) | (UInt32(d[1]) << 8) | (UInt32(d[2]) << 16) | (UInt32(d[3]) << 24)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) { storage.save(data) }
    }
}
