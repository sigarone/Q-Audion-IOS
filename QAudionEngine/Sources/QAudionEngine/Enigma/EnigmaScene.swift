import Foundation

/// Result of rendering one frame (reused by the caller: no allocation per frame).
public struct EnigmaFrameInfo {
    /// Overall progress of the scene, 0...1.
    public var progress: Double = 0
    /// Units revealed in the current phase.
    public var reveal: Int = 0
    /// Continuous advance index of the decorative drums (see `EnigmaRotors`): characters resolved so far across the whole
    /// scene, with the fraction of the character being resolved. It only ever grows, holds do not turn the drums, and it
    /// depends on unit counts and time alone, never on the text, the cipher or the seed.
    public var rotorIndex: Double = 0

    public init() {}
}

/// What one message plays: a list of phases on a single timeline. Built only from an `EnigmaResult.ok`; there is no way
/// to build a scene for a failed verification.
///
/// Send:    plain -> cipher (morph), a pause on the cipher, cipher -> plain (shorter morph).
/// Receive: the cipher that really arrived (pause), then cipher -> plain (morph).
public final class EnigmaScene {
    /// `base` = units resolved by the moving phases before this one (the drums keep their place across a hold).
    private struct Phase {
        let from: EnigmaUnits
        let to: EnigmaUnits
        let durationMs: Int64
        let hold: Bool
        let base: Int
    }

    /// Pause on the cipher after a send. Longer than the first Android version on purpose (the owner asked for about one
    /// second more, so the real packet and its label can be read).
    public static let holdSendMs: Int64 = 1100
    public static let holdReceiveMs: Int64 = 1000

    public let direction: EnigmaDirection
    public let labelKind: EnigmaLabelKind
    public let packetBytes: Int
    public let totalMs: Int64

    private let phases: [Phase]
    private let suffix: String

    private init(
        direction: EnigmaDirection,
        labelKind: EnigmaLabelKind,
        packetBytes: Int,
        phases: [Phase],
        suffix: String,
        totalMs: Int64
    ) {
        self.direction = direction
        self.labelKind = labelKind
        self.packetBytes = packetBytes
        self.phases = phases
        self.suffix = suffix
        self.totalMs = totalMs
    }

    /// Duration of the main morph: clamp(900 + 16 * length, 1300, 2600) ms.
    public static func morphMs(length: Int) -> Int64 {
        let raw = 900 + 16 * Int64(max(0, min(length, 100_000)))
        return min(2600, max(1300, raw))
    }

    /// Duration of the way back (send only): half of the morph, clamp(d / 2, 650, 1300) ms.
    public static func backMorphMs(morph: Int64) -> Int64 {
        min(1300, max(650, morph / 2))
    }

    /// `from` and `to` are the two strings handed to the effect: plain -> cipher on send, cipher -> plain on receive. The
    /// cipher side is cut to its first `EnigmaUnits.maxUnits` units (a base64 packet of a long message must not blow the
    /// bubble up); the plain text beyond the 240th unit stays as it is. Returns nil for a rejected result or an empty side.
    public static func build(direction: EnigmaDirection, from: String, to: String, result: EnigmaResult) -> EnigmaScene? {
        guard case .ok(let packetBytes) = result else { return nil }
        if from.isEmpty || to.isEmpty { return nil }
        let plain = direction == .send ? from : to
        let cipher = direction == .send ? to : from
        let plainUnits = EnigmaUnits(text: plain)
        let cipherUnits = EnigmaUnits(text: cipher)
        if plainUnits.count == 0 || cipherUnits.count == 0 { return nil }
        let d = morphMs(length: plainUnits.count)
        var phases: [Phase] = []
        switch direction {
        case .send:
            phases.append(Phase(from: plainUnits, to: cipherUnits, durationMs: d, hold: false, base: 0))
            phases.append(Phase(from: cipherUnits, to: cipherUnits, durationMs: holdSendMs, hold: true, base: cipherUnits.count))
            phases.append(Phase(from: cipherUnits, to: plainUnits, durationMs: backMorphMs(morph: d), hold: false, base: cipherUnits.count))
        case .receive:
            phases.append(Phase(from: cipherUnits, to: cipherUnits, durationMs: holdReceiveMs, hold: true, base: 0))
            phases.append(Phase(from: cipherUnits, to: plainUnits, durationMs: d, hold: false, base: 0))
        }
        var total: Int64 = 0
        for phase in phases { total += phase.durationMs }
        return EnigmaScene(
            direction: direction,
            labelKind: direction == .receive ? .verified : .sealed,
            packetBytes: max(0, packetBytes),
            phases: phases,
            suffix: plainUnits.rest,
            totalMs: total
        )
    }

    /// Renders the frame at `elapsedMs` into `out` (cleared first) and `info`.
    public func render(
        elapsedMs: Int64,
        full: Bool,
        seed: UInt64,
        frameIndex: Int,
        out: inout String,
        info: inout EnigmaFrameInfo
    ) {
        let t = min(totalMs, max(0, elapsedMs))
        var start: Int64 = 0
        guard var chosen = phases.last else {
            out.removeAll(keepingCapacity: true)
            info.progress = 1
            return
        }
        var chosenStart: Int64 = totalMs - chosen.durationMs
        for phase in phases {
            if t < start + phase.durationMs {
                chosen = phase
                chosenStart = start
                break
            }
            start += phase.durationMs
        }
        let p: Double
        if chosen.hold || chosen.durationMs <= 0 {
            p = 1.0
        } else {
            p = Double(t - chosenStart) / Double(chosen.durationMs)
        }
        info.reveal = EnigmaFrame.render(
            into: &out, from: chosen.from, to: chosen.to, p: p, full: full, seed: seed, frameIndex: frameIndex, suffix: suffix
        )
        if chosen.hold || chosen.durationMs <= 0 {
            info.rotorIndex = Double(chosen.base)
        } else {
            let clamped = min(1.0, max(0.0, p))
            info.rotorIndex = Double(chosen.base) + EnigmaFrame.ease(clamped) * Double(chosen.to.count)
        }
        info.progress = totalMs <= 0 ? 1.0 : Double(t) / Double(totalMs)
    }
}
