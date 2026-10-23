import Foundation

// The location body (WIRE_SPEC section 14.3 and 14.5): a pin or a live start, recognised by its byte prefix exactly like `{"qa_reply":`.
//
//     {"qa_loc":1,"m":"pin","lat":454642110,"lon":91899820,"acc":12,"age":3,"ap":0}
//     {"qa_loc":1,"m":"live","sid":"<base64, 16 bytes>","k":"<base64, 32 bytes>","st":<unix s>,"du":<s>,"lat":..,"lon":..,"acc":..,"age":..,"ap":..}
//
// Recognition, the strict JSON profile (the one of file messages, section 12.7.2), the typed members and the canonical builder live
// here. Everything is on BYTES: no decoder that strips a byte order mark or substitutes U+FFFD, no `hasPrefix`, no `JSONSerialization`.
//
// A recognised body that is rejected is NEVER displayed as text (it may contain a position and a key): the caller shows one
// placeholder (`LocationBodyPlaceholder`). The types that hold a position or a key print a fixed placeholder as their description so
// that a stray `print`, string interpolation or assertion message can never put one in a log.

/// The channel a body arrives on: a 1:1 chat, a group payload or the BLE mesh (section 14.2).
public enum LocationChannel: String, CaseIterable, Sendable {
    case chat, group, mesh
}

/// A position as it travels in a body: E7 integers (degrees times 10^7), the accuracy radius in metres, the age of the fix in
/// seconds at the building of the body, and whether the platform granted approximate location only.
public struct LocationPosition: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let latE7: Int32
    public let lonE7: Int32
    public let accuracy: Int
    public let age: Int
    public let approximate: Bool

    public init(latE7: Int32, lonE7: Int32, accuracy: Int, age: Int, approximate: Bool) {
        self.latE7 = latE7
        self.lonE7 = lonE7
        self.accuracy = accuracy
        self.age = age
        self.approximate = approximate
    }

    public var description: String { "LocationPosition(redacted)" }
    public var debugDescription: String { description }
}

/// The part of a live start that is not a position: the share id, the share key, the sender's clock when the share started and its
/// duration. `key` never leaves the memory of the process that needs it and is never persisted, logged or described.
public struct LocationLiveStart: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let sid: Data
    public let key: Data
    public let startedAt: Int64
    public let duration: Int64

    public init(sid: Data, key: Data, startedAt: Int64, duration: Int64) {
        self.sid = sid
        self.key = key
        self.startedAt = startedAt
        self.duration = duration
    }

    public var description: String { "LocationLiveStart(redacted)" }
    public var debugDescription: String { description }
}

/// A valid location body.
public enum LocationBody: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case pin(LocationPosition)
    case live(LocationLiveStart, LocationPosition)

    public var position: LocationPosition {
        switch self {
        case .pin(let position): return position
        case .live(_, let position): return position
        }
    }

    public var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    public var description: String { "LocationBody(redacted)" }
    public var debugDescription: String { description }
}

/// Why a recognised body was rejected: a telemetry label only. The body is never shown.
public enum LocationRejection: String, CaseIterable, Equatable, Sendable {
    case badLocation = "bad_location"
    case unsupportedVersion = "unsupported_version"
    case unsupportedContext = "unsupported_context"
}

/// What a chat body is when location messages are concerned (section 14.3.2).
public enum LocationRecognition: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The bytes do not begin with `{"qa_loc":`: handled exactly as before.
    case notLocation
    /// A valid body for the channel it arrived on.
    case location(LocationBody)
    /// Recognised and rejected: one placeholder, the content is never shown.
    case rejected(LocationRejection)

    public var description: String {
        switch self {
        case .notLocation: return "notLocation"
        case .location: return "location(redacted)"
        case .rejected(let code): return "rejected(\(code.rawValue))"
        }
    }
    public var debugDescription: String { description }
}

/// Why the builder refuses; the strings are those of the vector file (`builder_cases`, `conversion_cases`).
public enum LocationBuildRefusal: String, Error, Equatable, Sendable {
    /// The fix is missing or invalid (NaN, infinite, a negative accuracy).
    case fix
    /// The fix is older than `BUILD_MAX_FIX_AGE`.
    case age
    /// A converted latitude or longitude is out of range, or `st` is not a valid unix time.
    case range
    /// The duration is missing or outside `DU_MIN`...`DU_MAX`.
    case du
    /// A live start was requested in a group or over the mesh.
    case context
}

/// A fix as the platform gives it, before conversion (section 14.4).
public struct LocationFix: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let latitude: Double
    public let longitude: Double
    /// `horizontalAccuracy` of CoreLocation: the radius in metres.
    public let horizontalAccuracy: Double
    /// Milliseconds between the fix and the building of the body, on a monotonic clock.
    public let elapsedMs: Int64
    /// `accuracyAuthorization == .reducedAccuracy`.
    public let approximate: Bool

    public init(latitude: Double, longitude: Double, horizontalAccuracy: Double, elapsedMs: Int64, approximate: Bool) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.elapsedMs = elapsedMs
        self.approximate = approximate
    }

    public var description: String { "LocationFix(redacted)" }
    public var debugDescription: String { description }
}

public enum LocationCodec {

    // MARK: Prefix tests

    public static func hasLocationPrefix(_ text: String) -> Bool {
        text.utf8.starts(with: LocationWire.prefix)
    }

    public static func hasLocationPrefix(_ body: Data) -> Bool {
        [UInt8](body).starts(with: LocationWire.prefix)
    }

    // MARK: Recognition and validation (section 14.3.2)

    /// Recognises and validates a body given as text (its UTF-8 bytes). Prefer the bytes as decrypted when they are at hand.
    public static func recognize(_ text: String, channel: LocationChannel) -> LocationRecognition {
        guard text.utf8.starts(with: LocationWire.prefix) else { return .notLocation }
        return recognize(utf8: Data(text.utf8), channel: channel)
    }

    /// Recognises and validates the body of a message exactly as decrypted: a byte-prefix test, the version, the JSON profile of
    /// section 12.7.2, the members of the mode, then the context rule of section 14.3.4. Any failure after recognition is a
    /// rejection, never an error for the user and never text.
    public static func recognize(utf8 body: Data, channel: LocationChannel) -> LocationRecognition {
        let bytes = [UInt8](body)
        guard bytes.starts(with: LocationWire.prefix) else { return .notLocation }
        // The version: the bytes after the prefix up to the first `,`, `}` or JSON whitespace (or the end), read before anything else.
        let versionStart = LocationWire.prefix.count
        var versionEnd = bytes.count
        var index = versionStart
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x2C || byte == 0x7D || byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                versionEnd = index
                break
            }
            index += 1
        }
        guard let number = FileV2JSONInteger.parse(Array(bytes[versionStart..<versionEnd])) else {
            return .rejected(.badLocation)
        }
        guard number == LocationWire.version else { return .rejected(.unsupportedVersion) }
        switch FileV2JSONParser.parse(bytes) {
        case .failure:
            return .rejected(.badLocation)
        case .success(let object):
            guard let decoded = decode(from: object) else { return .rejected(.badLocation) }
            // Section 14.3.4: a live start is valid in a 1:1 chat only. Applied AFTER validation, so an invalid live start in a
            // group is `bad_location`.
            if decoded.isLive && channel != .chat { return .rejected(.unsupportedContext) }
            return .location(decoded)
        }
    }

    /// The members of section 14.3.1, all required and typed for the mode. Unknown members were checked by the profile and are ignored.
    private static func decode(from object: FileV2JSONObject) -> LocationBody? {
        guard case .number(let versionToken)? = object.value("qa_loc"),
              FileV2JSONInteger.parse(versionToken) == LocationWire.version else { return nil }
        guard case .string(let modeBytes)? = object.value("m") else { return nil }
        let isPin: Bool = modeBytes == Array("pin".utf8)
        let isLive: Bool = modeBytes == Array("live".utf8)
        guard isPin || isLive else { return nil }

        guard let lat = integer(object, "lat", LocationWire.latE7Min...LocationWire.latE7Max),
              let lon = integer(object, "lon", LocationWire.lonE7Min...LocationWire.lonE7Max),
              let acc = integer(object, "acc", LocationWire.accMin...LocationWire.accMax),
              let age = integer(object, "age", 0...LocationWire.ageMax),
              let ap = integer(object, "ap", 0...1) else { return nil }
        let position = LocationPosition(latE7: Int32(lat), lonE7: Int32(lon), accuracy: Int(acc), age: Int(age), approximate: ap == 1)

        if isPin {
            // A pin never carries a share member, whatever its value (even null): a key can never ride on a plain pin.
            for name in ["sid", "k", "st", "du"] where object.value(name) != nil { return nil }
            return .pin(position)
        }
        guard let sid = base64(object, "sid", length: LocationWire.sidLength),
              let key = base64(object, "k", length: LocationWire.keyLength),
              let startedAt = integer(object, "st", 0...FileV2.maxJSONInteger),
              let duration = integer(object, "du", LocationWire.duMin...LocationWire.duMax) else { return nil }
        return .live(LocationLiveStart(sid: sid, key: key, startedAt: startedAt, duration: duration), position)
    }

    private static func integer(_ object: FileV2JSONObject, _ name: String, _ range: ClosedRange<Int64>) -> Int64? {
        guard case .number(let token)? = object.value(name), let value = FileV2JSONInteger.parse(token),
              range.contains(value) else { return nil }
        return value
    }

    private static func base64(_ object: FileV2JSONObject, _ name: String, length: Int) -> Data? {
        guard case .string(let text)? = object.value(name), let decoded = FileV2Base64.decode(text),
              decoded.count == length else { return nil }
        return decoded
    }

    /// The plain integer between the prefix and the first `,`, `}` or JSON whitespace of a body that begins with the prefix; `nil` when
    /// the bytes do not begin with the prefix or that token is not a plain integer (section 14.3.2).
    public static func version(ofBody body: Data) -> Int64? {
        let bytes = [UInt8](body)
        guard bytes.starts(with: LocationWire.prefix) else { return nil }
        var end = bytes.count
        var index = LocationWire.prefix.count
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x2C || byte == 0x7D || byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                end = index
                break
            }
            index += 1
        }
        return FileV2JSONInteger.parse(Array(bytes[LocationWire.prefix.count..<end]))
    }

    /// For a stored row that holds a location body: whether it is a live start (`m` is `live`) and not a pin. Reads the member `m`
    /// of the strict profile; a body that does not parse is a pin for this purpose (the row is never a live card then).
    public static func isLiveBody(_ body: Data) -> Bool {
        let bytes = [UInt8](body)
        guard bytes.starts(with: LocationWire.prefix),
              case .success(let object) = FileV2JSONParser.parse(bytes),
              case .string(let mode)? = object.value("m") else { return false }
        return mode == Array("live".utf8)
    }

    // MARK: Builder (section 14.5)

    /// The canonical text of a pin, or the reason it refuses. The user interface keeps nothing and tells the user why.
    public static func buildPin(fix: LocationFix) -> Result<String, LocationBuildRefusal> {
        switch convert(fix) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let position):
            let parts: [String] = [
                #"{"qa_loc":1,"m":"pin","lat":"#, String(position.latE7), #","lon":"#, String(position.lonE7),
                #","acc":"#, String(position.accuracy), #","age":"#, String(position.age),
                #","ap":"#, position.approximate ? "1" : "0", "}"
            ]
            let text: String = parts.joined()
            return .success(text)
        }
    }

    /// The canonical text of a live start, or the reason it refuses. `sid` (16 bytes) and `key` (32 bytes) come from a CSPRNG, fresh for
    /// every share (`LocationShareSecrets.generate()`); `startedAt` is the unix time of the user's confirmation and `duration` a value of
    /// `DU_MIN`...`DU_MAX`. `channel` is where the caller means to send it: a live start is valid in a 1:1 chat only.
    public static func buildLiveStart(fix: LocationFix, sid: Data, key: Data, startedAt: Int64?, duration: Int64?,
                                      channel: LocationChannel = .chat) -> Result<String, LocationBuildRefusal> {
        if channel != .chat { return .failure(.context) }
        let position: LocationPosition
        switch convert(fix) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let converted): position = converted
        }
        guard let startedAt = startedAt, startedAt >= 0, startedAt <= FileV2.maxJSONInteger,
              sid.count == LocationWire.sidLength, key.count == LocationWire.keyLength else { return .failure(.range) }
        guard let duration = duration, duration >= LocationWire.duMin, duration <= LocationWire.duMax else {
            return .failure(.du)
        }
        let parts: [String] = [
            #"{"qa_loc":1,"m":"live","sid":""#, sid.base64EncodedString(), #"","k":""#, key.base64EncodedString(),
            #"","st":"#, String(startedAt), #","du":"#, String(duration),
            #","lat":"#, String(position.latE7), #","lon":"#, String(position.lonE7),
            #","acc":"#, String(position.accuracy), #","age":"#, String(position.age),
            #","ap":"#, position.approximate ? "1" : "0", "}"
        ]
        let text: String = parts.joined()
        return .success(text)
    }

    /// The conversions of section 14.4 and the refusals of section 14.5 that depend on the fix alone, in the order `fix`, `age`, `range`.
    private static func convert(_ fix: LocationFix) -> Result<LocationPosition, LocationBuildRefusal> {
        let lat: Result<Int32, LocationBuildRefusal> = LocationConversion.e7(degrees: fix.latitude, axis: .latitude)
        let lon: Result<Int32, LocationBuildRefusal> = LocationConversion.e7(degrees: fix.longitude, axis: .longitude)
        let acc: Result<Int64, LocationBuildRefusal> = LocationConversion.accuracy(metres: fix.horizontalAccuracy)
        // An invalid input of any kind is `fix` before anything is judged for its range or its age.
        if case .failure(.fix) = lat { return .failure(.fix) }
        if case .failure(.fix) = lon { return .failure(.fix) }
        if case .failure(.fix) = acc { return .failure(.fix) }
        let age: Int64 = LocationConversion.age(elapsedMs: fix.elapsedMs)
        if age > LocationWire.buildMaxFixAge { return .failure(.age) }
        guard case .success(let latValue) = lat, case .success(let lonValue) = lon, case .success(let accValue) = acc else {
            return .failure(.range)
        }
        return .success(LocationPosition(latE7: latValue, lonE7: lonValue, accuracy: Int(accValue), age: Int(age),
                                         approximate: fix.approximate))
    }
}

/// A fresh share id (16 bytes) and share key (32 bytes) from the operating system's cryptographic generator. Never reused for a second
/// share (section 14.3.1).
public enum LocationShareSecrets {
    public static func generate() -> (sid: Data, key: Data) {
        (random(LocationWire.sidLength), random(LocationWire.keyLength))
    }

    private static func random(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var out = Data(count: count)
        for index in 0..<count {
            out[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        return out
    }
}

/// The text a location message that was rejected becomes (section 14.3.3). The engine has no localisation of its own: the default is
/// Italian, and the app installs the localised lookup once at launch (set it before the first message is recorded).
public enum LocationBodyPlaceholder: Sendable {
    /// The version of the body is greater than 1: "update the app".
    case unsupportedVersion
    /// Any other rejection: "the location could not be shown".
    case unavailable

    public static var text: @Sendable (LocationBodyPlaceholder) -> String = { placeholder in
        switch placeholder {
        case .unsupportedVersion: return "📍 Posizione non supportata: aggiorna l'app per aprirla"
        case .unavailable: return "📍 Posizione non disponibile"
        }
    }

    /// The placeholder a rejection stands for (section 14.3.3): a plain version above 1 asks for an update; every other rejection, a
    /// version of 0 or below included, says that the location cannot be shown.
    public static func forRejection(_ rejection: LocationRejection, body: Data) -> LocationBodyPlaceholder {
        guard rejection == .unsupportedVersion, let version = LocationCodec.version(ofBody: body), version > LocationWire.version else {
            return .unavailable
        }
        return .unsupportedVersion
    }
}
