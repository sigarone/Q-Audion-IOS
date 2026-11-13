import Foundation

/// Which frame-key scheme a call runs. `pending` means the call has no resolved scheme yet: no key is produced, never a default.
public enum FrameKeyMode: Equatable, Sendable {
    case pending
    case v5(gen: UInt64)
    case v6(callIdL: String, gen: UInt64)

    var gen: UInt64? {
        switch self {
        case .pending: return nil
        case .v5(let gen): return gen
        case .v6(_, let gen): return gen
        }
    }
}

/// The mode of a call with the two closures a controller needs: whether a key is the key of a signed round of the call, and
/// whether a generation is no longer the current open object of the call.
public struct FrameKeyDecision: Sendable {
    public let mode: FrameKeyMode
    public let isRoundKey: @Sendable (Data) -> Bool
    public let isGenStale: @Sendable (UInt64) -> Bool

    public init(mode: FrameKeyMode,
                isRoundKey: @escaping @Sendable (Data) -> Bool = { _ in true },
                isGenStale: @escaping @Sendable (UInt64) -> Bool = { _ in false }) {
        self.mode = mode
        self.isRoundKey = isRoundKey
        self.isGenStale = isGenStale
    }

    public static let pending = FrameKeyDecision(mode: .pending)
}

/// The pure choice of the frame keys of one round.
public enum FrameKeyResolver {

    /// The key this side sends with and the key it receives with, or nil. `v5` is exactly what it was before (one pair for audio
    /// and video, the call id as the transcript carries it). `v6` needs a 32-byte key that is not all zero and that is the key of
    /// a signed round of the call: anything else gives nil, never the v5 pair.
    public static func keys(
        decision: FrameKeyDecision, sessionKey: Data, wireCallId: String, isOfferer: Bool, kind: FrameKeysV6.Kind
    ) -> (send: Data, recv: Data)? {
        switch decision.mode {
        case .pending:
            return nil
        case .v5:
            guard let pair = OneToOneFrameKeys.derive(sessionKey: sessionKey, callId: wireCallId) else { return nil }
            return (pair.sendKey(isOfferer: isOfferer), pair.receiveKey(isOfferer: isOfferer))
        case .v6(let callIdL, _):
            guard sessionKey.count == 32, sessionKey.contains(where: { $0 != 0 }), decision.isRoundKey(sessionKey),
                  let all = FrameKeysV6.derive(sessionKey: sessionKey, callIdL: callIdL) else { return nil }
            let pair = all.keys(for: kind)
            return (pair.sendKey(isOfferer: isOfferer), pair.receiveKey(isOfferer: isOfferer))
        }
    }
}

/// Keeps the first resolved decision of a controller. A decision of another generation is withheld (`pending`) while the latched
/// object is the current open one, and replaces it when that object is gone.
public final class FrameKeyLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var latched: FrameKeyDecision?
    private var latchedGen: UInt64 = 0

    public init() {}

    /// What the controller should use for a decision just read from the call.
    public func resolve(_ fresh: FrameKeyDecision) -> FrameKeyDecision {
        lock.lock()
        defer { lock.unlock() }
        guard let freshGen = fresh.mode.gen else { return latched ?? FrameKeyDecision.pending }
        guard let current = latched else {
            latched = fresh
            latchedGen = freshGen
            return fresh
        }
        if freshGen == latchedGen {
            latched = fresh
            return fresh
        }
        if current.isGenStale(latchedGen) {
            latched = fresh
            latchedGen = freshGen
            return fresh
        }
        return FrameKeyDecision.pending
    }
}
