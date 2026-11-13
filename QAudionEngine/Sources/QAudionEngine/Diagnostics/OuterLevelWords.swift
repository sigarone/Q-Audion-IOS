import Foundation

// The words of the protection line that come from the outer relay layer. Pure: the app prints what this says and nothing else.

/// What the call's key state knows (an internal snapshot; it holds no key and no counter).
struct OuterLevelInput: Equatable, Sendable {
    let status: OuterStatus
    let relayKemInEffect: Bool
    let relayRotInEffect: Bool
    /// The last round that gave up its outer keys, and why.
    let holdEpoch: Int32?
    let holdReason: OuterHoldReason?
    /// The sticky reason of round 1.
    let round1Reason: OuterHoldReason?
    /// The round the send pointer was put back from.
    let revertFrom: Int32?
    /// The highest round that authenticated a frame (-1: none).
    let rxEpoch: Int32
}

public struct OuterLevelWords: Equatable, Sendable {
    /// `ind` or `indrot` while the layer keyed by its own exchange is up; nil otherwise (the caller prints its own word).
    public let kout: PqOuterState?
    /// `x25519_zero`, `relay_kem`, `slot_collision`, `send_revert` or empty.
    public let reason: String

    /// The clearing rules: a hold of round E clears when a frame of a round above E authenticated; a revert clears when a frame of
    /// the round that was left (or a later one) authenticated; the reason of round 1 is sticky.
    static func compute(_ input: OuterLevelInput) -> OuterLevelWords {
        var kout: PqOuterState?
        if input.status == .ok && input.relayKemInEffect {
            kout = input.relayRotInEffect ? .indrot : .ind
        }
        var reason = ""
        if let sticky = input.round1Reason {
            reason = sticky.word
        } else if let epoch = input.holdEpoch, let held = input.holdReason, input.rxEpoch <= epoch {
            reason = held.word
        } else if let left = input.revertFrom, input.rxEpoch < left {
            reason = "send_revert"
        }
        return OuterLevelWords(kout: kout, reason: reason)
    }
}
