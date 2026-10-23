import Foundation

// The stop control `loc_stop` (WIRE_SPEC section 14.7): a variant of the `qa_ctl` control envelope that ends a live share.
//
//     {"qa_ctl":1,"t":"loc_stop","target":"<clientMsgId of the live start>","ts":<unix seconds>}
//
// It travels only on the CONTROL lane. Its validation is the JSON profile of section 12.7.2 on BYTES (not `JSONSerialization`): UTF-8,
// under 8192 bytes, one object, unique member names, at most 4 nested containers. `qa_ctl` is the integer 1, `t` the string `loc_stop`
// (compared as bytes), `target` a string of 1...128 bytes, `ts` an integer 0...2^53 - 1 that is informational and never used for
// ordering or authority. Unknown members are ignored. A rejected envelope is dropped silently: no placeholder, nothing kept.
//
// The authority rule (the target names a live-start row of the SAME 1:1 conversation whose author is the account that sent the
// envelope) is the receiver's (`LocationShareReceiver.receiveStop`).

public enum LocationStopControl {

    /// A valid stop.
    public struct Stop: Equatable, Sendable {
        public let target: String
        public let ts: Int64

        public init(target: String, ts: Int64) {
            self.target = target
            self.ts = ts
        }
    }

    /// Why a stop envelope was dropped: a telemetry label only. The strings are those of the vector file.
    public enum Drop: String, Error, Equatable, Sendable {
        case size
        case utf8
        case jsonSyntax = "json.syntax"
        case jsonDepth = "json.depth"
        case jsonDuplicateMember = "json.duplicate_member"
        case jsonSurrogate = "json.surrogate"
        case qaCtl = "qa_ctl"
        case type = "t"
        case target
        case ts
    }

    /// Why the builder refuses.
    public enum BuildRefusal: String, Error, Equatable, Sendable {
        case target
        case ts
    }

    private static let typeBytes: [UInt8] = Array("loc_stop".utf8)

    /// Whether `bytes` is a JSON object that names the `loc_stop` variant of the control envelope, valid or not: `qa_ctl` is the plain
    /// integer 1 and `t` is the string `loc_stop`. Used by the control envelope parser to route the envelope to the strict validation
    /// below instead of the lenient one.
    public static func names(utf8 body: Data) -> Bool {
        guard case .success(let object) = FileV2JSONParser.parse([UInt8](body)),
              case .number(let version)? = object.value("qa_ctl"), FileV2JSONInteger.parse(version) == 1,
              case .string(let type)? = object.value("t") else { return false }
        return type == typeBytes
    }

    /// Validates the bytes of an envelope as a `loc_stop` (section 14.7).
    public static func parse(utf8 body: Data) -> Result<Stop, Drop> {
        let object: FileV2JSONObject
        switch FileV2JSONParser.parse([UInt8](body)) {
        case .failure(let failure):
            switch failure {
            case .tooLarge: return .failure(.size)
            case .invalidUTF8: return .failure(.utf8)
            case .syntax, .notAnObject: return .failure(.jsonSyntax)
            case .depth: return .failure(.jsonDepth)
            case .duplicateMember: return .failure(.jsonDuplicateMember)
            case .loneSurrogate: return .failure(.jsonSurrogate)
            }
        case .success(let parsed):
            object = parsed
        }
        guard case .number(let versionToken)? = object.value("qa_ctl"), FileV2JSONInteger.parse(versionToken) == 1 else {
            return .failure(.qaCtl)
        }
        guard case .string(let type)? = object.value("t"), type == typeBytes else { return .failure(.type) }
        guard case .string(let targetBytes)? = object.value("target"), targetBytes.count >= 1,
              targetBytes.count <= LocationWire.stopTargetMax else { return .failure(.target) }
        guard case .number(let tsToken)? = object.value("ts"), let ts = FileV2JSONInteger.parse(tsToken), ts >= 0 else {
            return .failure(.ts)
        }
        return .success(Stop(target: String(decoding: targetBytes, as: UTF8.self), ts: ts))
    }

    /// The canonical text of a stop: compact JSON, the members in the order `qa_ctl`, `t`, `target`, `ts`, `target` a canonical JSON
    /// string (section 12.7.1 escaping). `target` is the client message id of the live start.
    public static func build(target: String, ts: Int64) -> Result<String, BuildRefusal> {
        let length = target.utf8.count
        guard length >= 1, length <= LocationWire.stopTargetMax else { return .failure(.target) }
        guard ts >= 0, ts <= FileV2.maxJSONInteger else { return .failure(.ts) }
        var out: [UInt8] = Array(#"{"qa_ctl":1,"t":"loc_stop","target":"#.utf8)
        FileV2DescriptorBuilder.string(&out, target)
        out.append(contentsOf: Array(#","ts":"#.utf8))
        out.append(contentsOf: Array(String(ts).utf8))
        out.append(UInt8(ascii: "}"))
        return .success(String(decoding: out, as: UTF8.self))
    }
}
