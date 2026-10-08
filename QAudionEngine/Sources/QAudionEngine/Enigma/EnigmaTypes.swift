import Foundation

// Enigma mode (visual effect only): the pure model.
//
// Nothing in the Enigma folder imports UIKit or SwiftUI, and nothing in it touches the crypto types: the animator only
// ever receives two strings and an outcome that was already computed by the real cipher. The effect WATCHES the message
// path, it never takes part in it. Port of the Android implementation (feature-chat/.../enigma), adapted to Swift.
//
// Safety rule for every file of this folder: it runs inside the message path hooks, so it must never trap. No force
// unwraps, no unchecked indexing, no Double -> Int conversion of a value that could be NaN or infinite.

/// Effect level, ordered from the cheapest to the richest.
public enum EnigmaLevel: Int, Comparable, Sendable {
    case off = 0
    case lite = 1
    case full = 2

    public static func < (lhs: EnigmaLevel, rhs: EnigmaLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// One step down (full -> lite -> off); off stays off.
    public func lowered() -> EnigmaLevel {
        switch self {
        case .full: return .lite
        case .lite: return .off
        case .off: return .off
        }
    }

    /// Stored value (0 off, 1 lite, 2 full) to level; anything unknown reads as off.
    public static func fromStored(_ value: Int) -> EnigmaLevel {
        switch value {
        case 1: return .lite
        case 2: return .full
        default: return .off
        }
    }

    public static func lowest(_ a: EnigmaLevel, _ b: EnigmaLevel) -> EnigmaLevel {
        a.rawValue <= b.rawValue ? a : b
    }
}

public enum EnigmaDirection: Sendable {
    case send
    case receive
}

/// What the real cipher already decided. The animator never decides it and never looks at anything else.
public enum EnigmaResult: Equatable, Sendable {
    /// Sealing (send) or tag verification (receive) succeeded; `packetBytes` is the real length of the packet.
    case ok(packetBytes: Int)
    /// Verification failed: no scene is ever built for this.
    case rejected
}

/// Which true sentence the label may carry. There is deliberately no kind for a failed verification.
public enum EnigmaLabelKind: Sendable {
    /// Receive, tag verified.
    case verified
    /// Send, the packet was sealed by the app (nobody has verified it yet, so the label does not say so).
    case sealed
}

public enum EnigmaAdmission: Sendable {
    case immediate
    case active
    case queued
}

/// Device conditions read once when a scene starts (never polled at rest).
public struct EnigmaEnvironment: Equatable, Sendable {
    /// The system asks for less motion (Reduce Motion).
    public var reduceMotion: Bool
    /// Low Power Mode.
    public var lowPowerMode: Bool
    /// ProcessInfo.ThermalState raw value (0 nominal, 1 fair, 2 serious, 3 critical), or nil when unknown.
    public var thermalLevel: Int?

    public init(reduceMotion: Bool = false, lowPowerMode: Bool = false, thermalLevel: Int? = nil) {
        self.reduceMotion = reduceMotion
        self.lowPowerMode = lowPowerMode
        self.thermalLevel = thermalLevel
    }
}

public enum EnigmaPolicy {
    /// ProcessInfo.ThermalState.serious.
    public static let thermalSerious: Int = 2

    /// The level that actually runs: the user's choice, capped by the governor; at most lite in Low Power Mode or at a
    /// thermal state of serious or worse; off when the flag is off, the user chose off or the system asks for less motion.
    public static func effective(
        flagOn: Bool,
        user: EnigmaLevel,
        governorCap: EnigmaLevel,
        env: EnigmaEnvironment
    ) -> EnigmaLevel {
        if !flagOn || user == .off || env.reduceMotion { return .off }
        var level = EnigmaLevel.lowest(user, governorCap)
        var constrained = env.lowPowerMode
        if let thermal = env.thermalLevel, thermal >= thermalSerious { constrained = true }
        if constrained { level = EnigmaLevel.lowest(level, .lite) }
        return level
    }
}

public enum EnigmaBytes {
    /// Decoded size of a standard base64 string (padding aware).
    public static func decodedSize(base64: String) -> Int {
        let total = base64.utf8.count
        if total == 0 { return 0 }
        let equals = UInt8(ascii: "=")
        var pad = 0
        for byte in base64.utf8.suffix(2) where byte == equals { pad += 1 }
        let len = max(0, total - pad)
        return len * 3 / 4
    }
}

/// The true sentences of the scene. The Italian text is the default value of the localized strings (the app asks the
/// bundle for them with these as fallback). NEVER add the size of the tag: the GCM tag is 128 bit, the key is 256 bit.
public enum EnigmaLabels {
    public static let verifiedKey = "enigma.label.verified"
    public static let sealedKey = "enigma.label.sealed"
    public static let fileKey = "enigma.label.file"
    public static let rotorsCaptionKey = "enigma.rotors.caption"
    public static let rejectedKey = "enigma.rejected.label"
    public static let degradedKey = "enigma.degraded.notice"

    public static let verifiedDefault = "AES-256-GCM · chiave 256 bit · %lld byte · integrità verificata"
    public static let sealedDefault = "AES-256-GCM · chiave 256 bit · %lld byte · integrità protetta"
    public static let fileDefault = "file cifrato · AES-256-GCM · chiave 256 bit · %lld%%"
    public static let rotorsCaptionDefault = "solo grafica, il cifrario è AES-256-GCM"
    public static let rejectedDefault = "Scartato · verifica di integrità non riuscita"
    public static let degradedDefault = "Effetto Enigma ridotto per mantenere fluida la chat"

    /// The line under a message: the real packet size and the percentage of the scene. `verifiedFormat` and
    /// `sealedFormat` are the localized templates (one `%lld` each); the defaults are the Italian ones.
    public static func line(
        kind: EnigmaLabelKind,
        packetBytes: Int,
        percent: Int,
        verifiedFormat: String = verifiedDefault,
        sealedFormat: String = sealedDefault
    ) -> String {
        let template = (kind == .verified) ? verifiedFormat : sealedFormat
        let bytes = max(0, packetBytes)
        let base = String(format: template, bytes)
        let pct = min(100, max(0, percent))
        return base + " " + String(pct) + "%"
    }
}
