import Foundation

/// `constants.enroll`.
struct EnrollConstants: Equatable {
    var sessionMinMs: Int
    var sessionCapMs: Int
    var tauWin: Double
    var mixedFracMax: Double
    var tauSess: Double
    var tauLoo: Double
    var deltaJk: Double
    var provMs: Int
    var enrMs: Int
    var enrSessions: Int
    var enrDays: Int
    var enrSpanS: Int
    var mergeGapS: Int
    var maxShare: Double
    var maxSessions: Int
    var purgeDays: Int
}

/// `constants.update`.
struct UpdateConstants: Equatable {
    var wMax: Double
    var theta: Double
    var b: Double
    var rhoMin: Double
    var maxPer7d: Int
    var minWindows: Int
    var minMatchFrac: Double
}

/// `constants.refresh`.
struct RefreshConstants: Equatable {
    var negStreak: Int
    var minWindows: Int
    var gateFracMin: Double
    var gapDays: Int
    var repromptDays: Int
}

/// `constants.conditions`: route classes, route groups and the slot rules.
struct ConditionConstants: Equatable {
    var routeGroups: [String: Int]
    var routeClassNames: [Int: String]
    var tauSlotAnchor: Double
    var slotMinSessions: Int
    var slotMinDays: Int
    var slotMinMs: Int
    var slotIdleDays: Int

    /// The route group of a route class code; a code that the table does not have is `unknown`.
    func routeGroup(_ code: Int) -> Int {
        routeGroups[routeClassNames[code] ?? "unknown"] ?? 0
    }
}

/// The state part of `constants.json`: everything that the template record, its state machine and its storage read. The
/// values of `enroll`, `update`, `refresh` and `conditions` are defaults in bundle v0; the code never depends on a value,
/// a test case may overlay some. `modelId` is the first 16 bytes of the embedder's SHA-256.
struct VoiceStateConstants {
    var enroll: EnrollConstants
    var update: UpdateConstants
    var refresh: RefreshConstants
    var conditions: ConditionConstants
    var retentionDays: Int
    var modelId: [UInt8]
    var constantsVersion: Int
    var frontendVersion: Int

    static func parse(_ data: Data) throws -> VoiceStateConstants {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw VoiceBundleError.malformed("constants.json: not JSON")
        }
        guard let top = parsed as? [String: Any] else { throw VoiceBundleError.malformed("constants.json: not an object") }
        let root = JsonFields(top, "constants")
        guard try root.string("schema") == "voice.constants" else { throw VoiceBundleError.malformed("not a voice constants file") }
        let en = try root.object("enroll")
        let up = try root.object("update")
        let rf = try root.object("refresh")
        let co = try root.object("conditions")
        let codes = try co.object("route_class_codes")
        let groups = try co.object("route_groups")
        let modelHex = try root.object("model").string("embedder_sha256")
        let hex = Array(modelHex.utf8)
        guard hex.count >= 32, hex.count % 2 == 0 else { throw VoiceBundleError.malformed("bad embedder_sha256") }
        var modelId = [UInt8]()
        for i in 0..<16 {
            guard let byte = UInt8(String(decoding: hex[(2 * i)..<(2 * i + 2)], as: UTF8.self), radix: 16) else {
                throw VoiceBundleError.malformed("bad embedder_sha256")
            }
            modelId.append(byte)
        }
        guard try co.int("slots") == TemplateCodec.nSlots else {
            throw VoiceBundleError.malformed("the record has exactly \(TemplateCodec.nSlots) slots")
        }
        var groupMap = [String: Int]()
        for key in groups.keys { groupMap[key] = try groups.int(key) }
        var classNames = [Int: String]()
        for key in codes.keys { classNames[try codes.int(key)] = key }
        let c = VoiceStateConstants(
            enroll: EnrollConstants(
                sessionMinMs: try en.int("session_min_ms"), sessionCapMs: try en.int("session_cap_ms"),
                tauWin: try en.double("tau_win"), mixedFracMax: try en.double("mixed_frac_max"),
                tauSess: try en.double("tau_sess"), tauLoo: try en.double("tau_loo"), deltaJk: try en.double("delta_jk"),
                provMs: try en.int("prov_ms"), enrMs: try en.int("enr_ms"), enrSessions: try en.int("enr_sessions"),
                enrDays: try en.int("enr_days"), enrSpanS: try en.int("enr_span_s"), mergeGapS: try en.int("merge_gap_s"),
                maxShare: try en.double("max_share"), maxSessions: try en.int("max_sessions"),
                purgeDays: try en.int("purge_days")),
            update: UpdateConstants(
                wMax: try up.double("w_max"), theta: try up.double("theta"), b: try up.double("b"),
                rhoMin: try up.double("rho_min"), maxPer7d: try up.int("max_per_7d"), minWindows: try up.int("min_windows"),
                minMatchFrac: try up.double("min_match_frac")),
            refresh: RefreshConstants(
                negStreak: try rf.int("neg_streak"), minWindows: try rf.int("min_windows"),
                gateFracMin: try rf.double("gate_frac_min"), gapDays: try rf.int("gap_days"),
                repromptDays: try rf.int("reprompt_days")),
            conditions: ConditionConstants(
                routeGroups: groupMap, routeClassNames: classNames, tauSlotAnchor: try co.double("tau_slot_anchor"),
                slotMinSessions: try co.int("slot_min_sessions"), slotMinDays: try co.int("slot_min_days"),
                slotMinMs: try co.int("slot_min_ms"), slotIdleDays: try co.int("slot_idle_days")),
            retentionDays: try root.int("retention_days"),
            modelId: modelId,
            constantsVersion: try root.int("constants_version"),
            frontendVersion: try root.int("frontend_version"))
        guard (1...TemplateCodec.maxSessions).contains(c.enroll.maxSessions) else {
            throw VoiceBundleError.malformed("enroll.max_sessions is out of the record's range")
        }
        guard c.enroll.sessionCapMs >= 32 else { throw VoiceBundleError.malformed("enroll.session_cap_ms") }
        guard groupMap["unknown"] != nil else { throw VoiceBundleError.malformed("conditions.route_groups needs unknown") }
        return c
    }
}

/// Typed reads of a decoded JSON object; every miss is a malformed-bundle error naming the field.
private struct JsonFields {
    let fields: [String: Any]
    let path: String

    init(_ fields: [String: Any], _ path: String) {
        self.fields = fields
        self.path = path
    }

    func object(_ key: String) throws -> JsonFields {
        guard let v = fields[key] as? [String: Any] else { throw VoiceBundleError.malformed("\(path).\(key) is not an object") }
        return JsonFields(v, "\(path).\(key)")
    }

    var keys: [String] { Array(fields.keys) }

    func string(_ key: String) throws -> String {
        guard let v = fields[key] as? String else { throw VoiceBundleError.malformed("\(path).\(key) is not a string") }
        return v
    }

    func double(_ key: String) throws -> Double {
        guard let n = fields[key] as? NSNumber else {
            throw VoiceBundleError.malformed("\(path).\(key) is not a number")
        }
        return n.doubleValue
    }

    func int(_ key: String) throws -> Int {
        guard let n = fields[key] as? NSNumber else {
            throw VoiceBundleError.malformed("\(path).\(key) is not a number")
        }
        let d = n.doubleValue
        guard d == d.rounded(), abs(d) < 9.0e15 else { throw VoiceBundleError.malformed("\(path).\(key) is not an integer") }
        return n.intValue
    }
}
