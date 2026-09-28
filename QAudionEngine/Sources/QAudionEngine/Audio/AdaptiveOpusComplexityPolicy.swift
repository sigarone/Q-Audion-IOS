import Foundation

/// W-M150ADAPTIVECOMPLEXITY (2026-09-29, webrtc-plan.md v2 §3.1 "Complessità
/// dell'encoder", updated same day per the owner's explicit instruction —
/// see this task's own report) — pure policy for how hard the Opus
/// encoder/decoder are allowed to work RIGHT NOW, shared by:
///   - the NATIVE path, via `QaudionRuntimeTuning` (P8:
///     `setQaudionOpusEncoderComplexity`/`setQaudionOpusDecoderComplexity`);
///   - the CUSTOM path, via `OpusCodec.setComplexity` (encoder only — the
///     custom decoder's complexity is NOT adaptive, see
///     `OpusCodec`/`opus_helpers.h`'s own notes on why).
///
/// Owner instruction (2026-09-29, verbatim in spirit): "la complexity di
/// opus fai in modo che possa essere spinta al massimo dove abbiamo potenza
/// a sufficienza in modo adattivo e non farci limitare da telefoni
/// obsoleti" — i.e. default to the CEILING on a capable device at a healthy
/// thermal state, and only step down for a REAL constraint (thermal, power
/// save, or a device this table itself calls out as weak), never as a
/// blanket caution.
///
/// No WebRTC / UIKit / Foundation-notification types here on purpose — this
/// file is Group A (compiles against today's linked WebRTC.xcframework;
/// nothing here calls a P8 selector), pure and deterministic so it is
/// exactly pinned by `AdaptiveOpusComplexityPolicyTests` with an injected
/// clock, same discipline as `PlpPolicy`/`IceTerminationPolicy`.
public enum ThermalTier: Equatable, Sendable {
    case nominalOrFair
    case serious
    case critical
    /// `.critical` and anything worse (`ProcessInfo.ThermalState` has no
    /// level past `.critical` today, but `@unknown default` in a future SDK
    /// must fail toward the SAFE — i.e. most conservative — side, not the
    /// capable one, so it maps here rather than to `.nominalOrFair`).
    case emergencyOrWorse
}

/// The two device-level (not moment-to-moment thermal) signals the plan's
/// table keys off. Doesn't read anything itself — see `QaudionDeviceClass`
/// for the real `isOldDevice` detector and `ProcessInfo.processInfo
/// .isLowPowerModeEnabled` for the other half — so this stays a plain value
/// type a test can construct directly.
public struct DeviceCapabilityHint: Equatable, Sendable {
    /// iOS's "old device" line per the plan: A11 (iPhone 8/8 Plus/X) or
    /// earlier. See `QaudionDeviceClass.isA11OrEarlier()`.
    public var isOldDevice: Bool
    /// `ProcessInfo.processInfo.isLowPowerModeEnabled`.
    public var isLowPowerModeEnabled: Bool

    public init(isOldDevice: Bool, isLowPowerModeEnabled: Bool) {
        self.isOldDevice = isOldDevice
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }

    /// The device is neither old nor in low-power mode — the common case,
    /// and the only one that reaches the ceiling.
    public static let capable = DeviceCapabilityHint(isOldDevice: false, isLowPowerModeEnabled: false)
}

/// Encoder complexity policy — table shared by the native (P8) and custom
/// (`OpusCodec`) encoders.
public enum AdaptiveOpusComplexityPolicy {

    /// Ceiling for a capable device at a healthy thermal state. Opus's own
    /// max.
    public static let maxComplexity = 10
    /// Ceiling for an old device OR one in low-power mode, REGARDLESS of
    /// thermal state — a real, standing constraint, not a thermal event.
    /// Coincides numerically with `seriousThermalComplexity`; kept as its
    /// own named constant because the two are conceptually independent
    /// inputs that just happen to land on the same value today.
    public static let oldDeviceOrPowerSaveCeiling = 8
    public static let seriousThermalComplexity = 8
    public static let criticalThermalComplexity = 6
    public static let emergencyThermalComplexity = 5

    /// The complexity a fresh, instantaneous read of `thermalTier`/`device`
    /// alone would pick — before hysteresis. Exposed directly for tests and
    /// for seeding a call's first value (there is no "previous state" to
    /// debounce the very first read against). `step(...)`/
    /// `ComplexityHysteresisDriver` below are what a live caller should
    /// actually drive the encoder from.
    public static func target(thermalTier: ThermalTier, device: DeviceCapabilityHint) -> Int {
        switch thermalTier {
        case .emergencyOrWorse: return emergencyThermalComplexity
        case .critical:         return criticalThermalComplexity
        case .serious:          return seriousThermalComplexity
        case .nominalOrFair:
            return (device.isOldDevice || device.isLowPowerModeEnabled)
                ? oldDeviceOrPowerSaveCeiling : maxComplexity
        }
    }

    /// The ordered rungs reachable for a given device, worst to best — e.g.
    /// `[5, 6, 8]` for an old/low-power device (whose ceiling, 8, already
    /// equals the "serious" rung, so there is nothing above it to add) or
    /// `[5, 6, 8, 10]` for a capable one. `AdaptiveComplexityHysteresis.step`
    /// climbs this list one rung at a time; it never invents a rung
    /// `target(...)` could not itself produce for this device.
    public static func ladder(for device: DeviceCapabilityHint) -> [Int] {
        let ceiling = (device.isOldDevice || device.isLowPowerModeEnabled)
            ? oldDeviceOrPowerSaveCeiling : maxComplexity
        var rungs = [emergencyThermalComplexity, criticalThermalComplexity, seriousThermalComplexity]
        if ceiling > rungs[rungs.count - 1] { rungs.append(ceiling) }
        return rungs
    }
}

/// Decoder complexity policy — NATIVE path only (P8
/// `setQaudionOpusDecoderComplexity`). The custom-path decoders
/// (`opus_jni.c:333` on Android, `opus_helpers.h:117` on iOS, `opus_addon.cc`
/// on desktop) stay fixed at 5: their bundled libopus is not built with OSCE
/// (`ENABLE_OSCE` is not defined for any of the three, and iOS's vendored
/// `Sources/COpus/src/dnn/osce.h` has no matching `osce.c` implementation —
/// verified by reading the vendored source tree, not assumed), so asking for
/// complexity 6/7 there would be a silent no-op at best.
///
/// Superseded plan text: the ORIGINAL plan (webrtc-plan.md v2 §3.1) said
/// "decoder always 5" for every path, native included. The owner's update
/// (2026-09-29, this task's own instructions) corrects that for the NATIVE
/// decoder only, because M150's bundled libopus (the one the P8 API's own
/// `kQaudionDefaultDecoderComplexity = 7` targets) IS built with OSCE, and
/// at this app's fixed operating point (SILK/Hybrid, ~100% of packets —
/// OSCE does not activate on CELT/fullband content) NoLACE (7) measured
/// useful. Unlike the encoder table above, an old device does not get a
/// REDUCED ceiling here — it is pinned to 5 outright, same as a critical
/// thermal state: NoLACE/LACE are neural models, meaningfully heavier per
/// frame than plain SILK decode plus classic or deep-PLC concealment, and a
/// device this table already calls "old" is exactly the one that cannot
/// absorb that per-frame cost as a matter of course, not only under thermal
/// duress.
public enum AdaptiveOpusDecoderComplexityPolicy {

    /// NoLACE. `kQaudionDefaultDecoderComplexity` in `qaudion_tuning.h`.
    public static let capableNominalOrFair = 7
    /// LACE — the lighter of the two OSCE methods.
    public static let serious = 6
    /// Deep PLC only, no OSCE — same numeric value the custom-path decoders
    /// are fixed at, so a capability gap between the two paths never shows
    /// up as a WORSE-than-custom decode on the native path.
    public static let criticalOrWorseOrOldDevice = 5

    public static func target(thermalTier: ThermalTier, device: DeviceCapabilityHint) -> Int {
        guard !device.isOldDevice else { return criticalOrWorseOrOldDevice }
        switch thermalTier {
        case .nominalOrFair:    return capableNominalOrFair
        case .serious:          return serious
        case .critical, .emergencyOrWorse: return criticalOrWorseOrOldDevice
        }
    }

    /// See `AdaptiveOpusComplexityPolicy.ladder(for:)` — same idea, but an
    /// old device's ladder is a single rung (5), because `target(...)` never
    /// asks for anything else on one regardless of thermal state.
    public static func ladder(for device: DeviceCapabilityHint) -> [Int] {
        device.isOldDevice
            ? [criticalOrWorseOrOldDevice]
            : [criticalOrWorseOrOldDevice, serious, capableNominalOrFair]
    }
}

/// The hysteresis rule itself, shared by both tables above (and by any
/// future one with the same shape): drop to a worse target immediately —
/// every under-provisioned frame at a complexity the device cannot sustain
/// is a real cost RIGHT NOW — but climb back up only one rung at a time,
/// and only after the target has held at least that rung for
/// `stepIntervalMs` — mirrors Android's identical rule from the same plan
/// section, so a call that migrates OS mid-life (unlikely, but the policy
/// doesn't assume otherwise) still converges to the same place either
/// platform would have reached alone.
public enum AdaptiveComplexityHysteresis {
    public static let stepIntervalMs: Int64 = 60_000

    /// - Parameters:
    ///   - current: the complexity actually applied right now.
    ///   - target: what `target(thermalTier:device:)` (either table above)
    ///     would pick from a fresh, instantaneous read.
    ///   - ladder: `AdaptiveOpusComplexityPolicy.ladder(for:)` or
    ///     `AdaptiveOpusDecoderComplexityPolicy.ladder(for:)` — the rungs
    ///     valid for THIS device; unsorted input is sorted defensively.
    ///   - msSinceTargetImproved: how long `target` has held at its CURRENT
    ///     value (not how long it has been better than `current`
    ///     specifically) — the caller's own bookkeeping, see
    ///     `ComplexityHysteresisDriver` for a ready-made one.
    public static func step(current: Int, target: Int, ladder: [Int], msSinceTargetImproved: Int64) -> Int {
        guard target != current else { return current }
        if target < current { return target }  // drop immediately, any distance
        guard msSinceTargetImproved >= stepIntervalMs else { return current }
        let rungs = ladder.sorted()
        // `current` not on this device's ladder (e.g. a compile-time
        // default, or a device-class change mid-call) — nothing to climb
        // FROM, so jump straight to the target rather than guessing a step.
        guard let idx = rungs.firstIndex(of: current) else { return target }
        let nextIdx = min(idx + 1, rungs.count - 1)
        return min(rungs[nextIdx], target)
    }
}

/// Stateful driver: owns only the two numbers `step(...)` needs across
/// calls (the currently-applied complexity, and how long the target has
/// held its current value) — never a thermal/device read itself, an
/// injected clock instead of the wall clock, so it is exactly as testable
/// as the pure functions above. One instance per call, per table (encoder
/// and decoder get independent instances — their ladders differ).
public final class ComplexityHysteresisDriver {
    private var current: Int
    private var lastTarget: Int
    private var targetHeldSinceMs: Int64
    private let ladder: [Int]
    private let nowMs: () -> Int64

    public init(initial: Int, ladder: [Int], nowMs: @escaping () -> Int64) {
        self.current = initial
        self.lastTarget = initial
        self.ladder = ladder
        self.nowMs = nowMs
        self.targetHeldSinceMs = nowMs()
    }

    /// Feed a fresh target (from `AdaptiveOpus(Decoder)ComplexityPolicy
    /// .target(thermalTier:device:)`) and get back the complexity to apply
    /// NOW. Call this both from a thermal/power-state-changed observer AND
    /// from a periodic tick, so `msSinceTargetImproved` keeps advancing even
    /// with no new notification in a given 60 s window.
    @discardableResult
    public func update(target: Int) -> Int {
        if target != lastTarget {
            lastTarget = target
            targetHeldSinceMs = nowMs()
        }
        let heldMs = nowMs() - targetHeldSinceMs
        current = AdaptiveComplexityHysteresis.step(
            current: current, target: target, ladder: ladder, msSinceTargetImproved: heldMs)
        return current
    }

    public var currentComplexity: Int { current }
}
