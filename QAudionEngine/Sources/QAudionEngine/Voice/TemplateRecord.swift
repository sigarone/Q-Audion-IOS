import Foundation

/// The state of a contact's template: 1 Learning, 2 Provisional, 3 Enrolled, 4 Needs refresh.
enum TemplateState {
    static let learning = 1
    static let provisional = 2
    static let enrolled = 3
    static let needsRefresh = 4
}

/// One session entry of a record. `centroid` is present while the record is Learning or Provisional.
final class TemplateSession {
    var speechMs: Int
    var dayIndex: Int
    var startS: Int
    var endS: Int
    var deviceTag: Int
    var routeClass: Int
    var inConsensus: Bool
    var conflict: Bool
    var merged: Bool
    var nWindows: Int
    var centroid: [Float]?

    init(speechMs: Int, dayIndex: Int, startS: Int, endS: Int, deviceTag: Int, routeClass: Int,
         inConsensus: Bool = false, conflict: Bool = false, merged: Bool = false, nWindows: Int, centroid: [Float]?) {
        self.speechMs = speechMs
        self.dayIndex = dayIndex
        self.startS = startS
        self.endS = endS
        self.deviceTag = deviceTag
        self.routeClass = routeClass
        self.inConsensus = inConsensus
        self.conflict = conflict
        self.merged = merged
        self.nWindows = nWindows
        self.centroid = centroid
    }

    func copy() -> TemplateSession {
        TemplateSession(speechMs: speechMs, dayIndex: dayIndex, startS: startS, endS: endS, deviceTag: deviceTag,
                        routeClass: routeClass, inConsensus: inConsensus, conflict: conflict, merged: merged,
                        nWindows: nWindows, centroid: centroid)
    }
}

/// A condition slot. State 0 is empty and carries no other field.
final class TemplateSlot {
    static let empty = 0
    static let quarantine = 1
    static let active = 2

    var state: Int
    var routeGroup: Int
    var nb: Int
    var nSessions: Int
    var deviceTag: Int
    var firstDay: Int
    var lastDay: Int
    var speechMs: Int
    var lastUsedS: Int
    var centroid: [Float]?

    init(state: Int = TemplateSlot.empty, routeGroup: Int = 0, nb: Int = 0, nSessions: Int = 0, deviceTag: Int = 0,
         firstDay: Int = 0, lastDay: Int = 0, speechMs: Int = 0, lastUsedS: Int = 0, centroid: [Float]? = nil) {
        self.state = state
        self.routeGroup = routeGroup
        self.nb = nb
        self.nSessions = nSessions
        self.deviceTag = deviceTag
        self.firstDay = firstDay
        self.lastDay = lastDay
        self.speechMs = speechMs
        self.lastUsedS = lastUsedS
        self.centroid = centroid
    }

    func clear() {
        state = TemplateSlot.empty
        routeGroup = 0
        nb = 0
        nSessions = 0
        deviceTag = 0
        firstDay = 0
        lastDay = 0
        speechMs = 0
        lastUsedS = 0
        centroid = nil
    }

    func copy() -> TemplateSlot {
        TemplateSlot(state: state, routeGroup: routeGroup, nb: nb, nSessions: nSessions, deviceTag: deviceTag,
                     firstDay: firstDay, lastDay: lastDay, speechMs: speechMs, lastUsedS: lastUsedS, centroid: centroid)
    }
}

/// The template record of one contact, in memory: vectors are float32 arrays (the exact value of the stored binary16 words),
/// an absent vector is nil. `n_sessions` and `n_centroids` of the header are not fields here: they follow from `sessions`
/// and `state`. The state machine works on a copy and the codec is the only way to a file.
final class TemplateRecord {
    var state: Int
    var conflict: Bool
    var anchorFrozen: Bool
    var refreshReprompted: Bool
    var modelId: [UInt8]
    var constantsVersion: Int
    var frontendVersion: Int
    var createdS: Int
    var updatedS: Int
    var enrolledS: Int
    var lastMatchS: Int
    var lastVerifiedCallS: Int
    var peerConsentS: Int
    var lastUpdateS: [Int]
    var refreshEnteredS: Int
    var consensusSpeechMs: Int
    var sessionsSeenTotal: Int
    var updateCount: Int
    var nDaysConsensus: Int
    var refreshNegStreak: Int
    var anchor: [Float]?
    var adaptive: [Float]?
    var slots: [TemplateSlot]
    var sessions: [TemplateSession]

    init(state: Int, conflict: Bool = false, anchorFrozen: Bool = false, refreshReprompted: Bool = false,
         modelId: [UInt8], constantsVersion: Int, frontendVersion: Int, createdS: Int = 0, updatedS: Int = 0,
         enrolledS: Int = 0, lastMatchS: Int = 0, lastVerifiedCallS: Int = 0, peerConsentS: Int = 0,
         lastUpdateS: [Int] = [0, 0, 0], refreshEnteredS: Int = 0, consensusSpeechMs: Int = 0, sessionsSeenTotal: Int = 0,
         updateCount: Int = 0, nDaysConsensus: Int = 0, refreshNegStreak: Int = 0, anchor: [Float]? = nil,
         adaptive: [Float]? = nil, slots: [TemplateSlot] = [TemplateSlot(), TemplateSlot()],
         sessions: [TemplateSession] = []) {
        self.state = state
        self.conflict = conflict
        self.anchorFrozen = anchorFrozen
        self.refreshReprompted = refreshReprompted
        self.modelId = modelId
        self.constantsVersion = constantsVersion
        self.frontendVersion = frontendVersion
        self.createdS = createdS
        self.updatedS = updatedS
        self.enrolledS = enrolledS
        self.lastMatchS = lastMatchS
        self.lastVerifiedCallS = lastVerifiedCallS
        self.peerConsentS = peerConsentS
        self.lastUpdateS = lastUpdateS
        self.refreshEnteredS = refreshEnteredS
        self.consensusSpeechMs = consensusSpeechMs
        self.sessionsSeenTotal = sessionsSeenTotal
        self.updateCount = updateCount
        self.nDaysConsensus = nDaysConsensus
        self.refreshNegStreak = refreshNegStreak
        self.anchor = anchor
        self.adaptive = adaptive
        self.slots = slots
        self.sessions = sessions
    }

    func deepCopy() -> TemplateRecord {
        TemplateRecord(
            state: state, conflict: conflict, anchorFrozen: anchorFrozen, refreshReprompted: refreshReprompted,
            modelId: modelId, constantsVersion: constantsVersion, frontendVersion: frontendVersion, createdS: createdS,
            updatedS: updatedS, enrolledS: enrolledS, lastMatchS: lastMatchS, lastVerifiedCallS: lastVerifiedCallS,
            peerConsentS: peerConsentS, lastUpdateS: lastUpdateS, refreshEnteredS: refreshEnteredS,
            consensusSpeechMs: consensusSpeechMs, sessionsSeenTotal: sessionsSeenTotal, updateCount: updateCount,
            nDaysConsensus: nDaysConsensus, refreshNegStreak: refreshNegStreak, anchor: anchor, adaptive: adaptive,
            slots: slots.map { $0.copy() }, sessions: sessions.map { $0.copy() })
    }

    /// What the engine may rely on after a load: an Enrolled or Needs refresh record has its anchor and its adaptive vector,
    /// a Learning or Provisional one has a centroid per session, an active or quarantine slot has a centroid. The codec
    /// accepts a record without these (the format allows them), so the store checks this before it hands a record out.
    func isUsable() -> Bool {
        if state == TemplateState.enrolled || state == TemplateState.needsRefresh {
            if anchor == nil || adaptive == nil { return false }
        }
        if state == TemplateState.learning || state == TemplateState.provisional {
            if sessions.contains(where: { $0.centroid == nil }) { return false }
        }
        return !slots.contains(where: { $0.state != TemplateSlot.empty && $0.centroid == nil })
    }
}

/// The record or its bytes are malformed; `reason` is a diagnostic, never compared by a caller.
struct TemplateFormatError: Error, Equatable {
    let reason: String
    let detail: String

    init(_ reason: String, _ detail: String = "") {
        self.reason = reason
        self.detail = detail
    }
}

/// Template record v3: plaintext layout and strict, all-or-nothing codec. Little endian, vectors as 512 binary16 words
/// through `Fp16`. The decoder accepts exactly what the encoder writes, so every accepted input re-encodes to the same bytes.
enum TemplateCodec {
    static let dim = 512
    static let vecBytes = 2 * dim
    static let headerBytes = 192
    static let nSlots = 2
    static let slotBytes = vecBytes + 32
    static let maxSessions = 8
    static let sessionBytes = 32
    static let bodyFixed = headerBytes + 2 * vecBytes + nSlots * slotBytes + maxSessions * sessionBytes // 4,608
    static let formatVersion = 3
    static let maxRouteClass = 5
    private static let offAnchor = headerBytes
    private static let offAdaptive = offAnchor + vecBytes
    private static let offSlots = offAdaptive + vecBytes
    private static let offSessions = offSlots + nSlots * slotBytes
    private static let offCentroids = offSessions + maxSessions * sessionBytes
    private static let magic: [UInt8] = [0x51, 0x41, 0x56, 0x54] // QAVT

    /// Plaintext size in bytes (the file adds a 12-byte nonce and a 16-byte tag).
    static func sizeOf(state: Int, nSessions: Int) -> Int {
        bodyFixed + vecBytes * centroidsFor(state: state, nSessions: nSessions)
    }

    private static func centroidsFor(state: Int, nSessions: Int) -> Int {
        (state == TemplateState.learning || state == TemplateState.provisional) ? nSessions : 0
    }

    private static func range(_ name: String, _ v: Int, _ lo: Int, _ hi: Int) throws -> Int {
        if v < lo || v > hi { throw TemplateFormatError("encode", "\(name) out of range") }
        return v
    }

    private static func words(_ v: [Float]?) throws -> [Int] {
        guard let v else { return [Int](repeating: 0, count: dim) }
        if v.count != dim { throw TemplateFormatError("encode", "vector length") }
        let w = v.map { Fp16.fromFloat($0) }
        if !w.allSatisfy({ Fp16.isFinite($0) }) { throw TemplateFormatError("encode", "non-finite or overflowing vector value") }
        return w
    }

    /// Little-endian writer over a fixed buffer.
    private struct Writer {
        var bytes: [UInt8]
        var pos = 0

        init(count: Int) { bytes = [UInt8](repeating: 0, count: count) }

        mutating func u8(_ v: Int) { bytes[pos] = UInt8(truncatingIfNeeded: v); pos += 1 }
        mutating func raw(_ v: [UInt8]) { for b in v { bytes[pos] = b; pos += 1 } }
        mutating func u16(_ v: Int) { u8(v); u8(v >> 8) }
        mutating func u32(_ v: Int) { u16(v); u16(v >> 16) }
        mutating func u64(_ v: Int) { u32(v); u32(v >> 32) }
        mutating func skip(_ n: Int) { pos += n }
        mutating func vector(_ w: [Int]) { for x in w { u16(x) } }
    }

    static func encode(_ rec: TemplateRecord) throws -> [UInt8] {
        let n = rec.sessions.count
        let state = try range("state", rec.state, 1, 4)
        if n > maxSessions { throw TemplateFormatError("encode", "more than 8 sessions") }
        let nCentroids = centroidsFor(state: state, nSessions: n)
        let hasC = rec.sessions.map { $0.centroid != nil }
        if (nCentroids > 0 && !hasC.allSatisfy({ $0 })) || (nCentroids == 0 && hasC.contains(true)) {
            throw TemplateFormatError("encode", "session centroids present or absent against the state")
        }
        if rec.modelId.count != 16 { throw TemplateFormatError("encode", "model_id") }
        if rec.lastUpdateS.count != 3 { throw TemplateFormatError("encode", "last_update_s") }
        if rec.slots.count != nSlots { throw TemplateFormatError("encode", "slots") }
        var b = Writer(count: sizeOf(state: state, nSessions: n))
        b.raw(magic)
        b.u16(formatVersion)
        b.u8(state)
        b.u8((rec.conflict ? 1 : 0) | (rec.anchorFrozen ? 2 : 0) | (rec.refreshReprompted ? 4 : 0))
        b.raw(rec.modelId)
        b.u32(try range("constants_version", rec.constantsVersion, 0, 0xFFFF_FFFF))
        b.u16(try range("frontend_version", rec.frontendVersion, 0, 65535))
        b.u8(n)
        b.u8(nCentroids)
        b.u64(rec.createdS)
        b.u64(rec.updatedS)
        b.u64(rec.enrolledS)
        b.u64(rec.lastMatchS)
        b.u64(rec.lastVerifiedCallS)
        b.u64(rec.peerConsentS)
        for t in rec.lastUpdateS { b.u64(t) }
        b.u64(rec.refreshEnteredS)
        b.u32(try range("consensus_speech_ms", rec.consensusSpeechMs, 0, 0xFFFF_FFFF))
        b.u16(try range("sessions_seen_total", rec.sessionsSeenTotal, 0, 65535))
        b.u16(try range("update_count", rec.updateCount, 0, 65535))
        b.u8(try range("n_days_consensus", rec.nDaysConsensus, 0, 255))
        b.u8(try range("refresh_neg_streak", rec.refreshNegStreak, 0, 255))
        b.pos = headerBytes // 70 reserved bytes stay zero
        b.vector(try words(rec.anchor))
        b.vector(try words(rec.adaptive))
        for sl in rec.slots {
            let st = try range("slot state", sl.state, 0, 2)
            if st == TemplateSlot.empty {
                if sl.routeGroup != 0 || sl.nb != 0 || sl.nSessions != 0 || sl.deviceTag != 0 || sl.firstDay != 0 ||
                    sl.lastDay != 0 || sl.speechMs != 0 || sl.lastUsedS != 0 || sl.centroid != nil {
                    throw TemplateFormatError("encode", "an empty slot must have no fields")
                }
                b.skip(slotBytes)
                continue
            }
            b.vector(try words(sl.centroid))
            b.u8(st)
            b.u8(try range("route_group", sl.routeGroup, 0, 255))
            b.u8(try range("nb", sl.nb, 0, 255))
            b.u8(try range("slot n_sessions", sl.nSessions, 0, 255))
            b.u32(try range("slot device_tag", sl.deviceTag, 0, 0xFFFF_FFFF))
            b.u32(sl.firstDay)
            b.u32(sl.lastDay)
            b.u32(try range("slot speech_ms", sl.speechMs, 0, 0xFFFF_FFFF))
            b.u64(sl.lastUsedS)
            b.skip(4) // reserved
        }
        for s in rec.sessions {
            b.u32(try range("speech_ms", s.speechMs, 0, 0xFFFF_FFFF))
            b.u32(s.dayIndex)
            b.u64(s.startS)
            b.u64(s.endS)
            b.u32(try range("device_tag", s.deviceTag, 0, 0xFFFF_FFFF))
            b.u8(try range("route_class", s.routeClass, 0, maxRouteClass))
            b.u8((s.inConsensus ? 1 : 0) | (s.conflict ? 2 : 0) | (s.merged ? 4 : 0))
            b.u16(try range("n_windows", s.nWindows, 0, 65535))
        }
        b.pos = offSessions + maxSessions * sessionBytes
        if nCentroids > 0 { for s in rec.sessions { b.vector(try words(s.centroid)) } }
        precondition(b.pos == b.bytes.count)
        return b.bytes
    }

    private static func zero(_ d: [UInt8], _ from: Int, _ to: Int) -> Bool {
        for i in from..<to where d[i] != 0 { return false }
        return true
    }

    // Little-endian readers.
    private static func u16(_ d: [UInt8], _ o: Int) -> Int { Int(d[o]) | (Int(d[o + 1]) << 8) }
    private static func u32(_ d: [UInt8], _ o: Int) -> Int { u16(d, o) | (u16(d, o + 2) << 16) }
    private static func i32(_ d: [UInt8], _ o: Int) -> Int { Int(Int32(truncatingIfNeeded: u32(d, o))) }
    private static func i64(_ d: [UInt8], _ o: Int) -> Int {
        Int(truncatingIfNeeded: UInt64(u32(d, o)) | (UInt64(u32(d, o + 4)) << 32))
    }

    /// The record of `data`, or throws `TemplateFormatError`: never a part of a record.
    static func decode(_ data: [UInt8]) throws -> TemplateRecord {
        let n = data.count
        if n < headerBytes { throw TemplateFormatError("truncated", "R1") }
        for i in 0..<4 where data[i] != magic[i] { throw TemplateFormatError("magic", "R2") }
        if u16(data, 4) != formatVersion { throw TemplateFormatError("version", "R3") }
        let state = Int(data[6])
        if !(1...4).contains(state) { throw TemplateFormatError("state", "R4") }
        let flags = Int(data[7])
        if (flags & ~0x07) != 0 { throw TemplateFormatError("flags", "R5") }
        let nSessions = Int(data[30])
        if nSessions > maxSessions { throw TemplateFormatError("n_sessions", "R6") }
        let nCentroids = Int(data[31])
        if nCentroids != centroidsFor(state: state, nSessions: nSessions) { throw TemplateFormatError("n_centroids", "R7") }
        if n != bodyFixed + vecBytes * nCentroids { throw TemplateFormatError("length", "R8") }
        if !zero(data, 122, headerBytes) { throw TemplateFormatError("reserved", "R9") }

        func vec(_ off: Int, _ what: String, absentIfZero: Bool) throws -> [Float]? {
            let w = (0..<dim).map { u16(data, off + 2 * $0) }
            if !w.allSatisfy({ Fp16.isFinite($0) }) { throw TemplateFormatError("non_finite", "R12 \(what)") }
            if absentIfZero && w.allSatisfy({ $0 == 0 }) { return nil }
            return w.map { Fp16.toFloat($0) }
        }

        let rec = TemplateRecord(
            state: state,
            conflict: (flags & 1) != 0,
            anchorFrozen: (flags & 2) != 0,
            refreshReprompted: (flags & 4) != 0,
            modelId: Array(data[8..<24]),
            constantsVersion: u32(data, 24),
            frontendVersion: u16(data, 28),
            createdS: i64(data, 32),
            updatedS: i64(data, 40),
            enrolledS: i64(data, 48),
            lastMatchS: i64(data, 56),
            lastVerifiedCallS: i64(data, 64),
            peerConsentS: i64(data, 72),
            lastUpdateS: [i64(data, 80), i64(data, 88), i64(data, 96)],
            refreshEnteredS: i64(data, 104),
            consensusSpeechMs: u32(data, 112),
            sessionsSeenTotal: u16(data, 116),
            updateCount: u16(data, 118),
            nDaysConsensus: Int(data[120]),
            refreshNegStreak: Int(data[121]))
        rec.anchor = try vec(offAnchor, "anchor", absentIfZero: true)
        rec.adaptive = try vec(offAdaptive, "adaptive", absentIfZero: true)
        for k in 0..<nSlots {
            let base = offSlots + k * slotBytes
            let st = Int(data[base + vecBytes])
            if st > 2 { throw TemplateFormatError("slot_state", "R10") }
            if st == TemplateSlot.empty {
                if !zero(data, base, base + slotBytes) { throw TemplateFormatError("slot_unused", "R10") }
                continue
            }
            let o = base + vecBytes
            if !zero(data, o + 28, o + 32) { throw TemplateFormatError("reserved", "R9") }
            let sl = rec.slots[k]
            sl.state = st
            sl.routeGroup = Int(data[o + 1])
            sl.nb = Int(data[o + 2])
            sl.nSessions = Int(data[o + 3])
            sl.deviceTag = u32(data, o + 4)
            sl.firstDay = i32(data, o + 8)
            sl.lastDay = i32(data, o + 12)
            sl.speechMs = u32(data, o + 16)
            sl.lastUsedS = i64(data, o + 20)
            sl.centroid = try vec(base, "slot \(k) centroid", absentIfZero: true)
        }
        for k in 0..<maxSessions {
            let base = offSessions + k * sessionBytes
            if k >= nSessions {
                if !zero(data, base, base + sessionBytes) { throw TemplateFormatError("session_unused", "R11") }
                continue
            }
            let fl = Int(data[base + 29])
            if (fl & ~0x07) != 0 { throw TemplateFormatError("session_flags", "R11") }
            let rcl = Int(data[base + 28])
            if rcl > maxRouteClass { throw TemplateFormatError("route_class", "R11") }
            rec.sessions.append(TemplateSession(
                speechMs: u32(data, base),
                dayIndex: i32(data, base + 4),
                startS: i64(data, base + 8),
                endS: i64(data, base + 16),
                deviceTag: u32(data, base + 24),
                routeClass: rcl,
                inConsensus: (fl & 1) != 0,
                conflict: (fl & 2) != 0,
                merged: (fl & 4) != 0,
                nWindows: u16(data, base + 30),
                centroid: nil))
        }
        if nCentroids > 0 {
            for k in 0..<nCentroids {
                rec.sessions[k].centroid = try vec(offCentroids + k * vecBytes, "session \(k) centroid", absentIfZero: false)
            }
        }
        return rec
    }
}
