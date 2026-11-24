import XCTest
import Foundation
@testable import QAudionEngine

extension KatJSON {
    var bool: Bool {
        if case .bool(let b) = self { return b }
        XCTFail("not a boolean: \(self)")
        return false
    }

    var isString: Bool {
        if case .string = self { return true }
        return false
    }

    /// The tree as plain Foundation values (for JSONSerialization).
    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.foundationValue }
        case .object(let o): return o.mapValues { $0.foundationValue }
        }
    }
}

/// Shared by the stage 8 and stage 9 tests: the record fields of a vector file to a `TemplateRecord` (vectors are rows of the
/// stage's `vectors.f32`, converted through `Fp16` to the value that a file holds), and the comparison of a record with them.
enum VoiceStateKat {
    static let dim = TemplateCodec.dim

    static func hex(_ s: String) -> [UInt8] {
        let chars = Array(s.utf8)
        return stride(from: 0, to: chars.count, by: 2).map { UInt8(String(decoding: chars[$0..<$0 + 2], as: UTF8.self), radix: 16)! }
    }

    /// The raw 32-bit patterns of a little endian float32 file (NaN payloads intact).
    static func bits(_ path: String) throws -> [UInt32] {
        let b = try VoiceKat.bytes(path)
        return stride(from: 0, to: b.count, by: 4).map {
            UInt32(b[$0]) | (UInt32(b[$0 + 1]) << 8) | (UInt32(b[$0 + 2]) << 16) | (UInt32(b[$0 + 3]) << 24)
        }
    }

    static func row(_ rows: [Float], _ r: Int) -> [Float] {
        Array(rows[(r * dim)..<((r + 1) * dim)])
    }

    /// The value of a vector after a trip through binary16 (what a stored vector reads back as).
    static func viaWords(_ v: [Float]) -> [Float] {
        v.map { Fp16.toFloat(Fp16.fromFloat($0)) }
    }

    static func vec(_ e: KatJSON, _ rows: [Float]) -> [Float]? {
        e.isNull ? nil : viaWords(row(rows, e["vec"].int))
    }

    private static func names(_ a: KatJSON) -> Set<String> {
        Set(a.array.map { $0.string })
    }

    static func fieldsToRecord(_ f: KatJSON, _ rows: [Float]) -> TemplateRecord {
        let flags = names(f["flags"])
        let rec = TemplateRecord(
            state: f["state"].int,
            conflict: flags.contains("conflict"),
            anchorFrozen: flags.contains("anchor_frozen"),
            refreshReprompted: flags.contains("refresh_reprompted"),
            modelId: hex(f["model_id"].string),
            constantsVersion: f["constants_version"].int,
            frontendVersion: f["frontend_version"].int,
            createdS: f["created_s"].int,
            updatedS: f["updated_s"].int,
            enrolledS: f["enrolled_s"].int,
            lastMatchS: f["last_match_s"].int,
            lastVerifiedCallS: f["last_verified_call_s"].int,
            peerConsentS: f["peer_consent_s"].int,
            lastUpdateS: f["last_update_s"].ints,
            refreshEnteredS: f["refresh_entered_s"].int,
            consensusSpeechMs: f["consensus_speech_ms"].int,
            sessionsSeenTotal: f["sessions_seen_total"].int,
            updateCount: f["update_count"].int,
            nDaysConsensus: f["n_days_consensus"].int,
            refreshNegStreak: f["refresh_neg_streak"].int,
            anchor: vec(f["anchor"], rows),
            adaptive: vec(f["adaptive"], rows))
        for (k, s) in f["slots"].array.enumerated() {
            let sl = rec.slots[k]
            sl.state = s["state"].int
            if sl.state == 0 { continue }
            sl.routeGroup = s["route_group"].int
            sl.nb = s["nb"].int
            sl.nSessions = s["n_sessions"].int
            sl.deviceTag = s["device_tag"].int
            sl.firstDay = s["first_day"].int
            sl.lastDay = s["last_day"].int
            sl.speechMs = s["speech_ms"].int
            sl.lastUsedS = s["last_used_s"].int
            sl.centroid = vec(s["centroid"], rows)
        }
        for s in f["sessions"].array {
            let fl = names(s["flags"])
            rec.sessions.append(TemplateSession(
                speechMs: s["speech_ms"].int, dayIndex: s["day_index"].int, startS: s["start_s"].int, endS: s["end_s"].int,
                deviceTag: s["device_tag"].int, routeClass: s["route_class"].int, inConsensus: fl.contains("in_consensus"),
                conflict: fl.contains("conflict"), merged: fl.contains("merged"), nWindows: s["n_windows"].int,
                centroid: vec(s["centroid"], rows)))
        }
        return rec
    }

    private static func assertVec(_ what: String, _ got: [Float]?, _ want: [Float]?, _ tol: Double,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard let want else {
            XCTAssertNil(got, "\(what): present but expected absent", file: file, line: line)
            return
        }
        guard let got else {
            XCTFail("\(what): absent but expected present", file: file, line: line)
            return
        }
        var worst = 0.0
        for i in 0..<dim { worst = max(worst, abs(Double(got[i]) - Double(want[i]))) }
        XCTAssertLessThanOrEqual(worst, tol, "\(what): largest component deviation", file: file, line: line)
    }

    /// Every scalar field exact; every vector component within `tol` (0: the words are equal); absent equals absent.
    static func assertRecord(_ label: String, _ got: TemplateRecord?, _ wantFields: KatJSON, _ rows: [Float], _ tol: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        if wantFields.isNull {
            XCTAssertNil(got, "\(label): a record where none is expected", file: file, line: line)
            return
        }
        guard let got else {
            XCTFail("\(label): no record, one expected", file: file, line: line)
            return
        }
        let w = fieldsToRecord(wantFields, rows)
        func eq<T: Equatable>(_ what: String, _ want: T, _ have: T) {
            XCTAssertEqual(want, have, "\(label): \(what)", file: file, line: line)
        }
        eq("state", w.state, got.state)
        eq("conflict", w.conflict, got.conflict)
        eq("anchor_frozen", w.anchorFrozen, got.anchorFrozen)
        eq("refresh_reprompted", w.refreshReprompted, got.refreshReprompted)
        eq("model_id", w.modelId, got.modelId)
        eq("constants_version", w.constantsVersion, got.constantsVersion)
        eq("frontend_version", w.frontendVersion, got.frontendVersion)
        eq("created_s", w.createdS, got.createdS)
        eq("updated_s", w.updatedS, got.updatedS)
        eq("enrolled_s", w.enrolledS, got.enrolledS)
        eq("last_match_s", w.lastMatchS, got.lastMatchS)
        eq("last_verified_call_s", w.lastVerifiedCallS, got.lastVerifiedCallS)
        eq("peer_consent_s", w.peerConsentS, got.peerConsentS)
        eq("last_update_s", w.lastUpdateS, got.lastUpdateS)
        eq("refresh_entered_s", w.refreshEnteredS, got.refreshEnteredS)
        eq("consensus_speech_ms", w.consensusSpeechMs, got.consensusSpeechMs)
        eq("sessions_seen_total", w.sessionsSeenTotal, got.sessionsSeenTotal)
        eq("update_count", w.updateCount, got.updateCount)
        eq("n_days_consensus", w.nDaysConsensus, got.nDaysConsensus)
        eq("refresh_neg_streak", w.refreshNegStreak, got.refreshNegStreak)
        assertVec("\(label): anchor", got.anchor, w.anchor, tol, file: file, line: line)
        assertVec("\(label): adaptive", got.adaptive, w.adaptive, tol, file: file, line: line)
        for k in w.slots.indices {
            let a = got.slots[k]
            let b = w.slots[k]
            let at = "slot \(k)"
            eq("\(at) state", b.state, a.state)
            if b.state == 0 { continue }
            eq("\(at) route_group", b.routeGroup, a.routeGroup)
            eq("\(at) nb", b.nb, a.nb)
            eq("\(at) n_sessions", b.nSessions, a.nSessions)
            eq("\(at) device_tag", b.deviceTag, a.deviceTag)
            eq("\(at) first_day", b.firstDay, a.firstDay)
            eq("\(at) last_day", b.lastDay, a.lastDay)
            eq("\(at) speech_ms", b.speechMs, a.speechMs)
            eq("\(at) last_used_s", b.lastUsedS, a.lastUsedS)
            assertVec("\(label): \(at) centroid", a.centroid, b.centroid, tol, file: file, line: line)
        }
        eq("number of sessions", w.sessions.count, got.sessions.count)
        guard w.sessions.count == got.sessions.count else { return }
        for k in w.sessions.indices {
            let a = got.sessions[k]
            let b = w.sessions[k]
            let at = "session \(k)"
            eq("\(at) speech_ms", b.speechMs, a.speechMs)
            eq("\(at) day_index", b.dayIndex, a.dayIndex)
            eq("\(at) start_s", b.startS, a.startS)
            eq("\(at) end_s", b.endS, a.endS)
            eq("\(at) device_tag", b.deviceTag, a.deviceTag)
            eq("\(at) route_class", b.routeClass, a.routeClass)
            eq("\(at) in_consensus", b.inConsensus, a.inConsensus)
            eq("\(at) conflict", b.conflict, a.conflict)
            eq("\(at) merged", b.merged, a.merged)
            eq("\(at) n_windows", b.nWindows, a.nWindows)
            assertVec("\(label): \(at) centroid", a.centroid, b.centroid, tol, file: file, line: line)
        }
    }
}
