import Foundation

// Relay video in the modes of the outer relay layer. One `RelayVideoLayers` per call, created when the call's key state says the
// exchange is in effect; it holds ports, never a key.
//
//     outerOnly   payload = 0x02 || BE16(fragIdx) || BE16(totalFrags) || u8(isKey) || fragment
//     double      unit    = innerVideoEnvelope(fragment);   payload = 0x02 || BE16 || BE16 || u8 || unit
//     wire        = outerSeal(video, payload)
//
// A call without the exchange (`legacy`) never builds this type: the video path keeps its own sealer, byte for byte. A call whose
// outer layer is not up (`none`) sends nothing and opens nothing: relay video never goes out without the layer.

public enum RelayVideoMode: Equatable, Sendable {
    case legacy
    case outerOnly
    case double
    case none

    /// The number of the log line.
    public var logCode: Int {
        switch self {
        case .legacy: return 0
        case .outerOnly: return 1
        case .double: return 2
        case .none: return 3
        }
    }
}

public enum RelayVideoPayload {

    public struct Shape: Equatable, Sendable {
        public let fragIdx: UInt16
        public let totalFrags: UInt16
        public let isKey: Bool
        /// What follows the six-byte header: the fragment itself, or the inner envelope that holds it.
        public let unit: Data
    }

    public static func encode(fragIdx: UInt16, totalFrags: UInt16, isKey: Bool, unit: Data) -> Data {
        InnerSealV2.fragmentWire(fragIdx: fragIdx, totalFrags: totalFrags, isKey: isKey, envelope: unit)
    }

    /// The shape only: the first byte is `0x02`, something follows the six-byte header and the key flag is 0 or 1.
    public static func decodeShape(_ payload: Data) -> Shape? {
        guard payload.count > 6 else { return nil }
        let base = payload.startIndex
        guard payload[base] == 0x02 else { return nil }
        let flag = payload[base + 5]
        guard flag == 0 || flag == 1 else { return nil }
        let index = (UInt16(payload[base + 1]) << 8) | UInt16(payload[base + 2])
        let total = (UInt16(payload[base + 3]) << 8) | UInt16(payload[base + 4])
        return Shape(fragIdx: index, totalFrags: total, isKey: flag == 1, unit: Data(payload.dropFirst(6)))
    }
}

public struct RelayVideoSealed: Equatable, Sendable {
    public let wire: Data
    /// The outer round the fragment was sealed under, and the envelope byte of the inner round (-1: no inner layer).
    public let outerEpoch: Int32
    public let innerEpoch: Int32
}

public struct RelayVideoOpened: Equatable, Sendable {
    public let fragment: Data
    public let fragIdx: UInt16
    public let totalFrags: UInt16
    public let isKey: Bool
}

public final class RelayVideoLayers: @unchecked Sendable {

    public let mode: RelayVideoMode
    private let outer: OuterSealPort?
    private let inner: InnerVideoPort?

    public init(mode: RelayVideoMode, outer: OuterSealPort?, inner: InnerVideoPort?) {
        self.mode = mode
        self.outer = outer
        self.inner = inner
    }

    /// One plain fragment to its wire bytes, or nil: the caller drops this fragment and every later one of the same frame.
    public func sealFragment(_ fragment: Data, fragIdx: UInt16, totalFrags: UInt16, isKey: Bool) -> RelayVideoSealed? {
        switch mode {
        case .legacy, .none:
            return nil
        case .outerOnly:
            guard let outer else { return nil }
            let payload = RelayVideoPayload.encode(fragIdx: fragIdx, totalFrags: totalFrags, isKey: isKey, unit: fragment)
            guard case .sealed(let wire, let epoch) = outer.seal(.video, payload) else { return nil }
            return RelayVideoSealed(wire: wire, outerEpoch: epoch, innerEpoch: -1)
        case .double:
            guard let outer, let inner else { return nil }
            guard case .sealed(let envelope, _, let epochByte) = inner.sealVideo(fragment: fragment) else { return nil }
            let payload = RelayVideoPayload.encode(fragIdx: fragIdx, totalFrags: totalFrags, isKey: isKey, unit: envelope)
            guard case .sealed(let wire, let epoch) = outer.seal(.video, payload) else { return nil }
            return RelayVideoSealed(wire: wire, outerEpoch: epoch, innerEpoch: Int32(epochByte))
        }
    }

    /// The wire bytes of one fragment to the plain fragment, or nil (dropped). The members of the JSON envelope are never read: the
    /// header inside the opened payload is the only one.
    public func openFragment(_ wire: Data) -> RelayVideoOpened? {
        guard mode == .outerOnly || mode == .double, let outer else { return nil }
        guard case .opened(let payload, _) = outer.open(.video, wire), let shape = RelayVideoPayload.decodeShape(payload) else { return nil }
        if mode == .outerOnly {
            return RelayVideoOpened(fragment: shape.unit, fragIdx: shape.fragIdx, totalFrags: shape.totalFrags, isKey: shape.isKey)
        }
        guard let inner, case .opened(let block, _) = inner.openVideo(wire: shape.unit) else { return nil }
        return RelayVideoOpened(fragment: block, fragIdx: shape.fragIdx, totalFrags: shape.totalFrags, isKey: shape.isKey)
    }

    /// Whether these layers are the ones that `mode` and these two ports would give (the same objects, not equal ones): an install
    /// that finds them built again changes nothing, so no state is rebuilt for a call that already has its layers.
    public func isBuilt(mode otherMode: RelayVideoMode, outer otherOuter: OuterSealPort?, inner otherInner: InnerVideoPort?) -> Bool {
        guard mode == otherMode else { return false }
        switch (outer, otherOuter) {
        case (nil, nil): break
        case (let a?, let b?): if a !== b { return false }
        default: return false
        }
        switch (inner, otherInner) {
        case (nil, nil): return true
        case (let a?, let b?): return a === b
        default: return false
        }
    }

    /// The outer round the layer seals under now (-1: none).
    public func currentOuterEpoch() -> Int32 {
        outer?.sendEpoch() ?? -1
    }

    /// The stamp of an inner round: its envelope byte.
    public static func innerStamp(forEpoch epoch: Int32) -> Int32 {
        Int32(UInt8(truncatingIfNeeded: epoch))
    }

    /// A cached fragment is resent only when it was sealed under the round each layer sends under now. A layer that is not in use
    /// carries -1 on the current side and is not compared.
    public static func mayResend(entryOuter: Int32, entryInner: Int32, currentOuter: Int32, currentInner: Int32) -> Bool {
        let outerOk = currentOuter < 0 || entryOuter == currentOuter
        let innerOk = currentInner < 0 || entryInner == currentInner
        return outerOk && innerOk
    }
}
