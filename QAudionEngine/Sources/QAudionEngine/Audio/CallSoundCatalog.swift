import Foundation

/// The call cues, independent of the audio stack: which bundled file each one plays and which settings gate it.
public enum CallCueKind: String, CaseIterable, Sendable {
    case dialingTick
    case connecting
    case ringback
    case keyExchange
    case connected
    case ended
    case busy

    /// Bundled resource name (extension `caf`).
    public var resourceName: String {
        switch self {
        case .dialingTick: return "qa_cue_dialing_tick"
        case .connecting: return "qa_cue_connecting"
        case .ringback: return "qa_cue_ringback"
        case .keyExchange: return "qa_cue_key_exchange"
        case .connected: return "qa_cue_connected"
        case .ended: return "qa_cue_ended"
        case .busy: return "qa_cue_busy"
        }
    }

    /// Cues that loop while the call is being set up; the others are one-shots.
    public var loops: Bool {
        switch self {
        case .connecting, .ringback, .keyExchange: return true
        case .dialingTick, .connected, .ended, .busy: return false
        }
    }
}

/// Ringtones and cue files, and how a stored ringtone id maps to files.
public enum CallSoundCatalog {

    /// The optional bundled ringtones, in the order the picker shows them after the default.
    public static let ringtoneIds: [String] = ["vetro", "impulso", "arpeggio", "calore", "digitale", "legno", "duetto"]
    /// Id stored when the user picked an imported file.
    public static let customId = "custom"
    /// The Q-Audion ringtone the app has always had (`qaudion_ringtone.caf`); also what an empty or legacy stored id means.
    public static let defaultRingtoneId = "qaudion-default"
    public static let defaultCallKitFileName = "qaudion_ringtone.caf"
    /// The 3 s unit of the default ringtone, looped by the in-app ring.
    public static let defaultLoopResourceName = "qaudion_ringtone_unit"
    /// File name of the imported ringtone, in `Library/Sounds`.
    public static let customFileName = "qa_custom_ring.caf"
    /// CallKit refuses ringtones longer than this.
    public static let maxRingtoneSeconds: Double = 30
    /// Length of the bundled busy cue, in milliseconds.
    public static let busyCueMs = 3_000

    /// File name of the 28 s CallKit ringtone of a bundled id.
    public static func callKitFileName(forBundledId id: String) -> String { "qa_ring_\(id).caf" }
    /// Resource name (extension `caf`) of the in-app loop of a bundled id.
    public static func loopResourceName(forBundledId id: String) -> String { "qa_loop_\(id)" }

    public enum FallbackReason: String, Equatable, Sendable {
        /// The stored id names no ringtone.
        case unknownId
        /// The imported ringtone is selected but its file is not there.
        case customMissing
    }

    /// What a stored ringtone id resolves to.
    public struct Resolution: Equatable, Sendable {
        /// `qaudion-default`, `vetro` to `duetto`, or `custom`.
        public let effectiveId: String
        /// Name handed to `CXProviderConfiguration.ringtoneSound`.
        public let callKitFileName: String
        /// Bundled loop resource for the in-app ring; `nil` for the imported file.
        public let bundledLoopResource: String?
        public let fallbackReason: FallbackReason?
        public var isCustom: Bool { effectiveId == CallSoundCatalog.customId }
        public var usedFallback: Bool { fallbackReason != nil }
    }

    /// Maps the stored ringtone id to files. `customAvailable` says whether the imported file exists and is usable.
    /// The default ringtone is the fallback for an unknown id and for a missing imported file.
    public static func resolve(ringtoneId: String, customAvailable: Bool) -> Resolution {
        if ringtoneIds.contains(ringtoneId) { return bundled(ringtoneId, reason: nil) }
        if ringtoneId == customId {
            if customAvailable {
                return Resolution(effectiveId: customId, callKitFileName: customFileName,
                                  bundledLoopResource: nil, fallbackReason: nil)
            }
            return defaultResolution(reason: .customMissing)
        }
        if ringtoneId == defaultRingtoneId || ringtoneId.isEmpty { return defaultResolution(reason: nil) }
        return defaultResolution(reason: .unknownId)
    }

    private static func defaultResolution(reason: FallbackReason?) -> Resolution {
        Resolution(effectiveId: defaultRingtoneId, callKitFileName: defaultCallKitFileName,
                   bundledLoopResource: defaultLoopResourceName, fallbackReason: reason)
    }

    private static func bundled(_ id: String, reason: FallbackReason?) -> Resolution {
        Resolution(effectiveId: id, callKitFileName: callKitFileName(forBundledId: id),
                   bundledLoopResource: loopResourceName(forBundledId: id), fallbackReason: reason)
    }
}

/// User settings of the call sounds. Defaults are what a fresh install has.
public struct CallSoundSettings: Codable, Equatable, Sendable {
    /// Volume of the in-app ring (foreground), 0...1. With the phone locked the system ringer volume applies.
    public var ringVolume: Float
    /// Volume of the cues heard during a call (connecting, ringback, key exchange, connected, ended, busy), 0...1.
    public var inCallVolume: Float
    /// Connecting sounds: the start tick, the connecting loop, the key exchange and the connected chime.
    public var connectionSoundEnabled: Bool
    /// The call-ended chime and the busy tone.
    public var endSoundsEnabled: Bool
    /// Haptics while the in-app ring plays.
    public var ringHapticsEnabled: Bool
    /// Imported ringtone: file name in `Library/Sounds`, name shown to the user, start of the excerpt in the source.
    public var customFileName: String?
    public var customDisplayName: String?
    public var customStartSeconds: Double

    public init(ringVolume: Float = 1.0, inCallVolume: Float = 1.0, connectionSoundEnabled: Bool = true,
                endSoundsEnabled: Bool = true, ringHapticsEnabled: Bool = true,
                customFileName: String? = nil, customDisplayName: String? = nil, customStartSeconds: Double = 0) {
        self.ringVolume = Self.clamp(ringVolume)
        self.inCallVolume = Self.clamp(inCallVolume)
        self.connectionSoundEnabled = connectionSoundEnabled
        self.endSoundsEnabled = endSoundsEnabled
        self.ringHapticsEnabled = ringHapticsEnabled
        self.customFileName = customFileName
        self.customDisplayName = customDisplayName
        self.customStartSeconds = max(0, customStartSeconds)
    }

    public static let defaults = CallSoundSettings()

    static func clamp(_ v: Float) -> Float { v.isNaN ? 1 : min(1, max(0, v)) }

    enum CodingKeys: String, CodingKey {
        case ringVolume, inCallVolume, connectionSoundEnabled, endSoundsEnabled, ringHapticsEnabled
        case customFileName, customDisplayName, customStartSeconds
    }

    /// Missing keys take their default, so a field added later never discards the stored ones.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CallSoundSettings.defaults
        self.init(
            ringVolume: try c.decodeIfPresent(Float.self, forKey: .ringVolume) ?? d.ringVolume,
            inCallVolume: try c.decodeIfPresent(Float.self, forKey: .inCallVolume) ?? d.inCallVolume,
            connectionSoundEnabled: try c.decodeIfPresent(Bool.self, forKey: .connectionSoundEnabled) ?? d.connectionSoundEnabled,
            endSoundsEnabled: try c.decodeIfPresent(Bool.self, forKey: .endSoundsEnabled) ?? d.endSoundsEnabled,
            ringHapticsEnabled: try c.decodeIfPresent(Bool.self, forKey: .ringHapticsEnabled) ?? d.ringHapticsEnabled,
            customFileName: try c.decodeIfPresent(String.self, forKey: .customFileName),
            customDisplayName: try c.decodeIfPresent(String.self, forKey: .customDisplayName),
            customStartSeconds: try c.decodeIfPresent(Double.self, forKey: .customStartSeconds) ?? 0)
    }
}

/// Which cues play, and how loud, for a given set of settings.
public enum CallCueGate {

    public static func isEnabled(_ kind: CallCueKind, settings: CallSoundSettings) -> Bool {
        switch kind {
        case .dialingTick, .connecting, .keyExchange, .connected: return settings.connectionSoundEnabled
        case .ended, .busy: return settings.endSoundsEnabled
        // The far end ringing is the call's own ring: its loudness is the in-line volume, never a switch.
        case .ringback: return true
        }
    }

    /// Player gain for a cue; 0 means silent.
    public static func gain(_ kind: CallCueKind, settings: CallSoundSettings) -> Float {
        isEnabled(kind, settings: settings) ? settings.inCallVolume : 0
    }

    /// True when the cue should be started at all.
    public static func shouldPlay(_ kind: CallCueKind, settings: CallSoundSettings) -> Bool {
        gain(kind, settings: settings) > 0
    }
}

public extension Notification.Name {
    /// Posted by the settings screen after it changed the ringtone; the CallKit provider reconfigures its ringtone.
    static let qaudionCallRingtoneChanged = Notification.Name("qaudion.callRingtoneChanged")
}
